import { importPKCS8, SignJWT } from "npm:jose@5.9.6";

// APNs token-based auth (README §9). Secrets: APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID.

let cached: { token: string; issuedAt: number } | null = null;

async function providerToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  // Apple accepts a token for up to 60 minutes; refresh every 50.
  if (cached && now - cached.issuedAt < 50 * 60) return cached.token;
  const key = await importPKCS8(
    Deno.env.get("APNS_KEY_P8")!.replaceAll("\\n", "\n"),
    "ES256",
  );
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: Deno.env.get("APNS_KEY_ID")! })
    .setIssuer(Deno.env.get("APNS_TEAM_ID")!)
    .setIssuedAt(now)
    .sign(key);
  cached = { token, issuedAt: now };
  return token;
}

export type ApnsResult = { ok: true } | {
  ok: false;
  status: number;
  reason: string;
};

export async function sendApns(
  deviceToken: string,
  environment: "sandbox" | "production",
  payload: Record<string, unknown>,
  opts: { pushType?: "alert" | "background"; collapseId?: string } = {},
): Promise<ApnsResult> {
  const host = environment === "production"
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";
  const pushType = opts.pushType ?? "alert";
  const headers: Record<string, string> = {
    authorization: `bearer ${await providerToken()}`,
    "apns-topic": Deno.env.get("APNS_BUNDLE_ID")!,
    "apns-push-type": pushType,
    "apns-priority": pushType === "background" ? "5" : "10",
  };
  if (opts.collapseId) headers["apns-collapse-id"] = opts.collapseId;
  const res = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers,
    body: JSON.stringify(payload),
  });
  if (res.ok) return { ok: true };
  const body = await res.json().catch(() => ({}));
  return {
    ok: false,
    status: res.status,
    reason: body.reason ?? res.statusText,
  };
}
