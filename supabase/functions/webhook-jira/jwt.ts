/**
 * Jira webhooks for OAuth 2.0 apps carry `Authorization: Bearer <JWT>` signed with the app's client
 * secret (HS256). Checks the signature (constant time) and the expiry. Returns why it failed, for logs.
 */
const encoder = new TextEncoder();

function base64UrlDecode(part: string): Uint8Array<ArrayBuffer> {
  const b64 = part.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

export async function verifyJwt(
  secret: string,
  header: string | null,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<
  { ok: true; claims: Record<string, unknown> } | { ok: false; reason: string }
> {
  const token = header?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
  if (!token) return { ok: false, reason: "missing bearer token" };
  const parts = token.split(".");
  if (parts.length !== 3) return { ok: false, reason: "malformed token" };
  const [head, payload, signature] = parts;

  let alg: unknown;
  let claims: Record<string, unknown>;
  try {
    alg = JSON.parse(new TextDecoder().decode(base64UrlDecode(head))).alg;
    claims = JSON.parse(new TextDecoder().decode(base64UrlDecode(payload)));
  } catch {
    return { ok: false, reason: "undecodable token" };
  }
  if (alg !== "HS256") return { ok: false, reason: `unsupported alg ${alg}` };

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  let valid = false;
  try {
    // subtle.verify compares in constant time.
    valid = await crypto.subtle.verify(
      "HMAC",
      key,
      base64UrlDecode(signature),
      encoder.encode(`${head}.${payload}`),
    );
  } catch {
    valid = false;
  }
  if (!valid) return { ok: false, reason: "bad signature" };

  const exp = Number(claims.exp);
  if (Number.isFinite(exp) && exp + 60 < nowSeconds) {
    return { ok: false, reason: "expired token" };
  }
  return { ok: true, claims };
}
