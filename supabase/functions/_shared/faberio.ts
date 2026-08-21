import { createClient } from "npm:@supabase/supabase-js@2.57.4";

export const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("SITE_URL") || "https://faberio.it",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, stripe-signature",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function keyFromJson(name: string, fallback: string) {
  try {
    const value = JSON.parse(Deno.env.get(name) || "{}").default;
    if (value) return value;
  } catch (_) {
    // Uses the legacy automatically injected variable as a compatibility fallback.
  }
  return Deno.env.get(fallback) || "";
}

export function adminClient() {
  const key = keyFromJson("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
  if (!key) throw new Error("Supabase secret key not configured");
  return createClient(Deno.env.get("SUPABASE_URL") || "", key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export function userClient(req: Request) {
  const key = keyFromJson("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY");
  if (!key) throw new Error("Supabase publishable key not configured");
  return createClient(Deno.env.get("SUPABASE_URL") || "", key, {
    global: { headers: { Authorization: req.headers.get("Authorization") || "" } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export async function authenticatedUser(req: Request) {
  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  if (!token) throw new Error("Authentication required");
  const { data, error } = await adminClient().auth.getUser(token);
  if (error || !data.user) throw new Error("Invalid session");
  return data.user;
}

export function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export async function stripeRequest(
  path: string,
  params: URLSearchParams,
  idempotencyKey?: string,
) {
  const secret = Deno.env.get("STRIPE_SECRET_KEY");
  if (!secret) throw new Error("Pagamenti Stripe non ancora configurati");
  const headers: Record<string, string> = {
    Authorization: `Bearer ${secret}`,
    "Content-Type": "application/x-www-form-urlencoded",
  };
  if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;
  const response = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: "POST",
    headers,
    body: params,
  });
  const body = await response.json();
  if (!response.ok) throw new Error(body?.error?.message || "Errore Stripe");
  return body;
}

export function siteUrl() {
  return (Deno.env.get("SITE_URL") || "https://faberio.it").replace(/\/$/, "");
}
