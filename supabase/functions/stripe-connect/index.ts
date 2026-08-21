import {
  authenticatedUser,
  adminClient,
  corsHeaders,
  json,
  siteUrl,
  stripeRequest,
} from "../_shared/faberio.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const user = await authenticatedUser(req);
    const db = adminClient();
    const [{ data: profile }, { data: professional, error }] = await Promise.all([
      db.from("profiles").select("pro_status").eq("id", user.id).single(),
      db.from("pro_profiles").select("*").eq("user_id", user.id).single(),
    ]);
    if (error || !professional) throw new Error("Profilo professionista non trovato");
    if (profile?.pro_status !== "approved") {
      throw new Error("Completa prima la verifica Faberio");
    }

    let accountId = professional.stripe_account_id;
    if (!accountId) {
      const params = new URLSearchParams();
      params.set("type", "express");
      params.set("country", "IT");
      if (user.email) params.set("email", user.email);
      params.set("business_profile[name]", professional.business_name || "Professionista Faberio");
      params.set("business_profile[product_description]", "Servizi professionali per interventi richiesti tramite Faberio");
      params.set("capabilities[transfers][requested]", "true");
      params.set("metadata[faberio_user_id]", user.id);
      const account = await stripeRequest("accounts", params, `faberio-account-${user.id}`);
      accountId = account.id;
      const { error: updateError } = await db.from("pro_profiles")
        .update({ stripe_account_id: accountId, updated_at: new Date().toISOString() })
        .eq("user_id", user.id);
      if (updateError) throw updateError;
    }

    const base = siteUrl();
    const linkParams = new URLSearchParams();
    linkParams.set("account", accountId);
    linkParams.set("type", "account_onboarding");
    linkParams.set("refresh_url", `${base}/?stripe=refresh`);
    linkParams.set("return_url", `${base}/?stripe=return`);
    const link = await stripeRequest("account_links", linkParams);
    return json({ url: link.url });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Errore inatteso" }, 400);
  }
});
