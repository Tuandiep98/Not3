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
    for (const d of devices) {
      const res = await sendApns(d.apns_token, d.environment, { aps, ...row.payload }, {
        pushType: row.kind === "silent" ? "background" : "alert",
        collapseId: row.kind === "checkin" ? "checkin" : undefined,
      });
      if (res.ok) delivered = true;
      else if (res.status === 410 || res.reason === "BadDeviceToken") {
        await db.from("devices").delete().eq("apns_token", d.apns_token);
      }
    }
    const attempts = row.attempts + 1;
    await db.from("push_queue").update({
      status: delivered ? "sent" : attempts >= MAX_ATTEMPTS ? "failed" : "pending",
      attempts,
    }).eq("id", row.id);
    if (delivered) sent++;
  }
  return json({ due: due?.length ?? 0, sent });
});
