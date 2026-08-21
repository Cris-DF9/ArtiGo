import { adminClient, json } from "../_shared/faberio.ts";

function bytesToHex(bytes: ArrayBuffer) {
  return Array.from(new Uint8Array(bytes)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return result === 0;
}

async function verifySignature(raw: string, header: string, secret: string) {
  const parts = header.split(",").map((x) => x.trim());
  const timestamp = parts.find((x) => x.startsWith("t="))?.slice(2);
  const signatures = parts.filter((x) => x.startsWith("v1=")).map((x) => x.slice(3));
  if (!timestamp || !signatures.length) return false;
  if (Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const digest = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${raw}`));
  const expected = bytesToHex(digest);
  return signatures.some((signature) => safeEqual(expected, signature));
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
    if (!secret) throw new Error("Webhook Stripe non configurato");
    const raw = await req.text();
    const signature = req.headers.get("stripe-signature") || "";
    if (!await verifySignature(raw, signature, secret)) return json({ error: "Invalid signature" }, 400);
    const event = JSON.parse(raw);
    const db = adminClient();
    const object = event?.data?.object || {};
    const paymentId = object?.metadata?.payment_id || null;
    const { data: alreadyProcessed } = await db.from("payment_events").select("id")
      .eq("provider_event_id", event.id).maybeSingle();
    if (alreadyProcessed) return json({ received: true, duplicate: true });

    if (event.type === "account.updated") {
      await db.from("pro_profiles").update({
        stripe_onboarding_complete: Boolean(object.details_submitted),
        stripe_details_submitted: Boolean(object.details_submitted),
        stripe_charges_enabled: Boolean(object.charges_enabled),
        stripe_payouts_enabled: Boolean(object.payouts_enabled),
        updated_at: new Date().toISOString(),
      }).eq("stripe_account_id", object.id);
    } else if (event.type === "checkout.session.completed" || event.type === "checkout.session.async_payment_succeeded") {
      if (paymentId) {
        const { error } = await db.rpc("finalize_stripe_payment", {
          p_payment_id: paymentId,
          p_checkout_session_id: object.id,
          p_payment_intent_id: object.payment_intent,
        });
        if (error) throw error;
      }
    } else if (event.type === "payment_intent.payment_failed" && paymentId) {
      await db.from("payments").update({ status: "failed", updated_at: new Date().toISOString() }).eq("id", paymentId);
    } else if (event.type === "charge.refunded") {
      const status = Number(object.amount_refunded) >= Number(object.amount) ? "refunded" : "partially_refunded";
      await db.from("payments").update({ status, stripe_refund_id: object.refunds?.data?.[0]?.id || null,
        refunded_at: new Date().toISOString(), updated_at: new Date().toISOString() })
        .eq("stripe_payment_intent_id", object.payment_intent);
    }
    const { error: eventError } = await db.from("payment_events").insert({
      payment_id: paymentId, provider_event_id: event.id, event_type: event.type,
      payload: { livemode: event.livemode, created: event.created, object_id: object.id },
    });
    if (eventError?.code !== "23505" && eventError) throw eventError;
    return json({ received: true });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Errore inatteso" }, 400);
  }
});
