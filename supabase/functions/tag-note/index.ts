// Database webhook (notes insert/update of title/body): suggest category chips for a note.
// Writes notes.ai_chips only — the app shows them as suggestions the user taps to accept.
import { adminClient, json, requireServiceRole } from "../_shared/admin.ts";
import { canUseAI, tagNote } from "../_shared/ai.ts";

const DEFAULT_CATEGORIES = ["Công việc", "Học ngôn ngữ", "Sở thích", "Sức khoẻ", "Đọc sách"];

Deno.serve(async (req) => {
  const denied = requireServiceRole(req);
  if (denied) return denied;
  const { note_id } = await req.json() as { note_id: string };
  const db = adminClient();

  const { data: note } = await db.from("notes").select("id, user_id, title, body, chips").eq("id", note_id).maybeSingle();
  if (!note) return json({ skipped: "not found" });
  if (!(await canUseAI(db, note.user_id))) return json({ skipped: "ai off" });

  const { data: profile } = await db.from("profiles").select("sync_note_content").eq("user_id", note.user_id).maybeSingle();
  const { data: chips } = await db.from("chips").select("label").eq("user_id", note.user_id).eq("group", "category");
  const categories = chips?.length ? chips.map((c) => c.label) : DEFAULT_CATEGORIES;

  const suggested = await tagNote({
    title: note.title,
    body: profile?.sync_note_content === false ? null : note.body,
    categories,
  });
  if (suggested === null) return json({ skipped: "ai failed" });

  const fresh = suggested.filter((c) => !(note.chips ?? []).includes(c));
  await db.from("notes").update({ ai_chips: fresh, ai_tagged_at: new Date().toISOString() }).eq("id", note.id);
  return json({ ai_chips: fresh });
});
