import { assertEquals } from "jsr:@std/assert@1.0.8";
import { publishableKey, requireServiceRole, serviceKey } from "./admin.ts";

function env(vars: Record<string, string | undefined>) {
  for (const [k, v] of Object.entries(vars)) {
    v === undefined ? Deno.env.delete(k) : Deno.env.set(k, v);
  }
}

const req = (headers: Record<string, string>) =>
  new Request("https://x/functions/v1/tick", { method: "POST", headers });

Deno.test("new sb_secret_ key on the apikey header is accepted", () => {
  env({
    SUPABASE_SECRET_KEYS: '{"default":"sb_secret_abc"}',
    SUPABASE_SERVICE_ROLE_KEY: undefined,
  });
  assertEquals(requireServiceRole(req({ apikey: "sb_secret_abc" })), null);
  assertEquals(
    requireServiceRole(req({ Authorization: "Bearer sb_secret_abc" })),
    null,
  );
  assertEquals(serviceKey(), "sb_secret_abc");
});

Deno.test("legacy service_role JWT as Bearer is still accepted", () => {
  env({
    SUPABASE_SECRET_KEYS: undefined,
    SUPABASE_SERVICE_ROLE_KEY: "eyJlegacy",
  });
  assertEquals(
    requireServiceRole(req({ Authorization: "Bearer eyJlegacy" })),
    null,
  );
});

Deno.test("wrong or missing key is rejected", () => {
  env({
    SUPABASE_SECRET_KEYS: '{"default":"sb_secret_abc"}',
    SUPABASE_SERVICE_ROLE_KEY: "eyJlegacy",
  });
  assertEquals(
    requireServiceRole(req({ apikey: "sb_publishable_xyz" }))?.status,
    403,
  );
  assertEquals(requireServiceRole(req({}))?.status, 403);
});

Deno.test("publishable key prefers the new key, falls back to legacy anon", () => {
  env({
    SUPABASE_PUBLISHABLE_KEYS: '{"default":"sb_publishable_1"}',
    SUPABASE_ANON_KEY: "eyJanon",
  });
  assertEquals(publishableKey(), "sb_publishable_1");
  env({ SUPABASE_PUBLISHABLE_KEYS: undefined });
  assertEquals(publishableKey(), "eyJanon");
});
