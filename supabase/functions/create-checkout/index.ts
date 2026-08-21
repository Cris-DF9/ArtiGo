import {
  authenticatedUser,
  adminClient,
  corsHeaders,
  json,
  siteUrl,
  stripeRequest,
  userClient,
} from "../_shared/faberio.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const user = await authenticatedUser(req);
    const { offer_id } = await req.json();
    if (!offer_id) throw new Error("Offerta mancante");
    const scoped = userClient(req);
    const { data, error } = await scoped.rpc("prepare_payment", { p_offer_id: offer_id });
    if (error) throw error;
    const payment = Array.isArray(data) ? data[0] : data;
    if (!payment) throw new Error("Pagamento non disponibile");

    const totalCents = Math.round(Number(payment.total_amount) * 100);
    const base = siteUrl();
    const params = new URLSearchParams();
    params.set("mode", "payment");
    params.set("success_url", `${base}/?payment=success&session_id={CHECKOUT_SESSION_ID}`);
    params.set("cancel_url", `${base}/?payment=cancelled`);
    params.set("customer_email", user.email || "");
    params.set("line_items[0][quantity]", "1");
    params.set("line_items[0][price_data][currency]", "eur");
    params.set("line_items[0][price_data][unit_amount]", String(totalCents));
    params.set("line_items[0][price_data][product_data][name]", "Intervento professionale Faberio");
    params.set("line_items[0][price_data][product_data][description]", `Offerta € ${Number(payment.amount_pro).toFixed(2)} + servizio Faberio 10%`);
    params.set("metadata[payment_id]", payment.payment_id);
    params.set("payment_intent_data[metadata][payment_id]", payment.payment_id);
    params.set("payment_intent_data[transfer_group]", `FABERIO_${payment.payment_id}`);
    const session = await stripeRequest(
      "checkout/sessions",
      params,
      `faberio-checkout-${payment.payment_id}`,
    );

    const { error: updateError } = await adminClient().from("payments").update({
      status: "checkout_created",
      stripe_checkout_session_id: session.id,
      updated_at: new Date().toISOString(),
    }).eq("id", payment.payment_id);
    if (updateError) throw updateError;
    return json({ url: session.url });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Errore inatteso" }, 400);
  }
});
