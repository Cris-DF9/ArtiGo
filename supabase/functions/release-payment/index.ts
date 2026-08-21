import {
  authenticatedUser,
  adminClient,
  corsHeaders,
  json,
  stripeRequest,
} from "../_shared/faberio.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const user = await authenticatedUser(req);
    const { payment_id } = await req.json();
    const db = adminClient();
    const { data: payment, error } = await db.from("payments").select("*")
      .eq("id", payment_id).eq("client_id", user.id).single();
    if (error || !payment) throw new Error("Pagamento non trovato");
    if (payment.status === "transferred") return json({ ok: true, already_released: true });
    if (payment.status !== "paid") throw new Error("Il pagamento non è pronto per il trasferimento");
    const { data: professional } = await db.from("pro_profiles")
      .select("stripe_account_id,stripe_payouts_enabled")
      .eq("user_id", payment.pro_id).single();
    if (!professional?.stripe_account_id || !professional.stripe_payouts_enabled) {
      throw new Error("Incassi del professionista non attivi");
    }
    const params = new URLSearchParams();
    params.set("amount", String(Math.round(Number(payment.amount_pro) * 100)));
    params.set("currency", "eur");
    params.set("destination", professional.stripe_account_id);
    params.set("transfer_group", `FABERIO_${payment.id}`);
    params.set("metadata[payment_id]", payment.id);
    const transfer = await stripeRequest("transfers", params, `faberio-release-${payment.id}`);
    const now = new Date().toISOString();
    const { error: paymentError } = await db.from("payments").update({
      status: "transferred", stripe_transfer_id: transfer.id, transferred_at: now, updated_at: now,
    }).eq("id", payment.id).eq("status", "paid");
    if (paymentError) throw paymentError;
    await db.from("job_requests").update({ status: "completed", updated_at: now }).eq("id", payment.request_id);
    return json({ ok: true });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Errore inatteso" }, 400);
  }
});
