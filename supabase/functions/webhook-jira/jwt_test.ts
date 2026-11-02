import { assertEquals } from "jsr:@std/assert@1.0.8";
import { verifyJwt } from "./jwt.ts";

const encoder = new TextEncoder();

function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function sign(
  secret: string,
  claims: Record<string, unknown>,
  alg = "HS256",
): Promise<string> {
  const head = b64url(encoder.encode(JSON.stringify({ alg, typ: "JWT" })));
  const body = b64url(encoder.encode(JSON.stringify(claims)));
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, encoder.encode(`${head}.${body}`)),
  );
  return `${head}.${body}.${b64url(mac)}`;
}

const now = 1_800_000_000;

Deno.test(
  "jira jwt: accepts a token signed with the client secret",
  async () => {
    const token = await sign("client-secret", { iss: "app", exp: now + 120 });
    const result = await verifyJwt("client-secret", `Bearer ${token}`, now);
    assertEquals(result.ok, true);
  },
);

Deno.test(
  "jira jwt: rejects wrong secret, tampering, expiry, alg and missing header",
  async () => {
    const token = await sign("client-secret", { exp: now + 120 });
    assertEquals(
      (await verifyJwt("other-secret", `Bearer ${token}`, now)).ok,
      false,
    );
    const [h, , s] = token.split(".");
    const forged = `${h}.${
      b64url(
        encoder.encode(JSON.stringify({ exp: now + 999 })),
      )
    }.${s}`;
    assertEquals(
      (await verifyJwt("client-secret", `Bearer ${forged}`, now)).ok,
      false,
    );
    const expired = await sign("client-secret", { exp: now - 3600 });
    assertEquals(
      (await verifyJwt("client-secret", `Bearer ${expired}`, now)).ok,
      false,
    );
    const none = await sign("client-secret", { exp: now + 120 }, "none");
    assertEquals(
      (await verifyJwt("client-secret", `Bearer ${none}`, now)).ok,
      false,
    );
    assertEquals((await verifyJwt("client-secret", null, now)).ok, false);
    assertEquals(
      (await verifyJwt("client-secret", "Bearer abc", now)).ok,
      false,
    );
  },
);
