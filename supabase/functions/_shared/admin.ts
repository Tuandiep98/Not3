import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.45.4";

// Supabase API keys: new projects use `sb_publishable_…` / `sb_secret_…` (exposed to functions as
// SUPABASE_PUBLISHABLE_KEYS / SUPABASE_SECRET_KEYS, JSON dictionaries). The legacy JWT keys
// (SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY) are being retired by the end of 2026.
// Everything here accepts both, preferring the new ones.

function keysFrom(jsonVar: string, legacyVar: string): string[] {
  const keys: string[] = [];
  const raw = Deno.env.get(jsonVar);
  if (raw) {
    try {
      const parsed = JSON.parse(raw) as Record<string, string>;
      keys.push(
        ...Object.values(parsed).filter(
          (k) => typeof k === "string" && k.length > 0,
        ),
      );
    } catch {
      /* not JSON — ignore */
    }
  }
  const legacy = Deno.env.get(legacyVar);
  if (legacy) keys.push(legacy);
  return keys;
}

/** All keys that grant service-role access (new secret keys first, then the legacy JWT). */
export function secretKeys(): string[] {
  return keysFrom("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
}

export function serviceKey(): string {
  const key = secretKeys()[0];
  if (!key) throw new Error("No Supabase secret key available to the function");
  return key;
}

export function publishableKey(): string {
  const key = keysFrom("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY")[0];
  if (!key) {
    throw new Error("No Supabase publishable key available to the function");
  }
  return key;
}

/** Service-role client. Only for Edge Functions invoked by cron (never exposed to the app). */
export function adminClient(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), {
    auth: { persistSession: false },
  });
}

/**
 * Rejects calls that do not carry a secret key. New `sb_secret_` keys arrive on `apikey`
 * (they are not JWTs); the legacy service_role JWT arrives as `Authorization: Bearer`.
 */
export function requireServiceRole(req: Request): Response | null {
  const presented = [
    req.headers.get("apikey") ?? "",
    (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, ""),
  ].filter(Boolean);
  const allowed = secretKeys();
  const ok = presented.some((key) =>
    allowed.some((secret) => timingSafeEqual(key, secret))
  );
  return ok ? null : new Response("Forbidden", { status: 403 });
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Function → function call with the service key (both headers, so either key style works). */
export async function invoke(name: string, body: unknown): Promise<Response> {
  const key = serviceKey();
  return await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/${name}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: key,
      Authorization: `Bearer ${key}`,
    },
    body: JSON.stringify(body),
  });
}

export const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
