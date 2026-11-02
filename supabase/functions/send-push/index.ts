// Sends due rows of push_queue through APNs. 410 (expired token) deletes the device.
import { adminClient, json, requireServiceRole } from "../_shared/admin.ts";
import { sendApns } from "../_shared/apns.ts";

const MAX_ATTEMPTS = 5;

Deno.serve(async (req) => {
  const denied = requireServiceRole(req);
  if (denied) return denied;
  const db = adminClient();

  const { data: due, error } = await db.from("push_queue")
    .select("id, user_id, kind, payload, attempts")
    .eq("status", "pending").lte("send_at", new Date().toISOString())
    .order("send_at").limit(500);
  if (error) return json({ error: error.message }, 500);

  let sent = 0;
  for (const row of due ?? []) {
    const { data: devices } = await db.from("devices").select("apns_token, environment").eq("user_id", row.user_id);
    if (!devices?.length) {
      await db.from("push_queue").update({ status: "failed" }).eq("id", row.id);
      continue;
    }
    const aps = row.kind === "silent"
      ? { "content-available": 1 }
      : {
        alert: { title: row.payload.title, body: row.payload.body },
        sound: "default",
        ...(row.kind === "checkin" ? { category: "CHECKIN" } : {}),
        ...(row.kind === "evening" ? { category: "EVENING" } : {}),
      };
    let delivered = false;
    const errors: string[] = [];
    for (const d of devices) {
      let res;
      try {
        res = await sendApns(d.apns_token, d.environment, { aps, ...row.payload }, {
          pushType: row.kind === "silent" ? "background" : "alert",
          collapseId: row.kind === "checkin" ? "checkin" : undefined,
        });
      } catch (e) {
        // Provider token (bad APNS_KEY_P8 / missing secret) or network failure.
        const message = (e as Error).message;
        errors.push(`${d.environment} ${d.apns_token.slice(0, 8)}: ${message}`);
        await db.from("devices").update({ last_error: message }).eq("apns_token", d.apns_token);
        continue;
      }
      if (res.ok) {
        delivered = true;
        await db.from("devices").update({ last_sent_at: new Date().toISOString(), last_error: null })
          .eq("apns_token", d.apns_token);
      } else {
        errors.push(`${d.environment} ${d.apns_token.slice(0, 8)}: ${res.status} ${res.reason}`);
        if (res.status === 410 || res.reason === "BadDeviceToken") {
          await db.from("devices").delete().eq("apns_token", d.apns_token);
        } else {
          await db.from("devices").update({ last_error: `${res.status} ${res.reason}` })
            .eq("apns_token", d.apns_token);
        }
      }
    }
    if (errors.length) console.error(`push ${row.id}:`, errors.join("; "));
    const attempts = row.attempts + 1;
    await db.from("push_queue").update({
      status: delivered ? "sent" : attempts >= MAX_ATTEMPTS ? "failed" : "pending",
      attempts,
      last_error: errors.length ? errors.join("; ") : null,
    }).eq("id", row.id);
    if (delivered) sent++;
  }
  return json({ due: due?.length ?? 0, sent });
});
