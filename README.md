# Not3 — Note & To-do (iOS 26)

App ghi chú + việc cần làm theo phong cách **Apple Notes**, giúp mỗi ngày có ít nhất **một việc ý nghĩa** nhờ **check-in 12h trưa**.
Supabase làm phần nặng (cron, push, tính toán, AI DeepSeek); app iOS chủ yếu là cổng hiển thị, điều hướng và thu thập dữ liệu mà server không tự lấy được.

> Nguồn context:
>
> - Kế hoạch triển khai: [Kế hoạch triển khai app Note & To-do (iOS 26)](https://claude.ai/artifact/XeMLfMzoGHLsk8jUXYrSFu)
> - Thiết kế màn hình: [Thiết kế màn hình app Note & To-do](https://claude.ai/artifact/Ks6v96pVazQ6X4Z53chukV)
>
> README này tóm tắt hai nguồn trên (cập nhật 2026-11-01). Khi có mâu thuẫn, doc kế hoạch là nguồn chính.

---

## Mục lục

1. [Nguyên tắc sản phẩm](#1-nguyên-tắc-sản-phẩm)
2. [Màn hình & luồng chính](#2-màn-hình--luồng-chính)
3. [Luồng check-in 12h](#3-luồng-check-in-12h)
4. [Hệ thống chip](#4-hệ-thống-chip)
5. [Giao diện: iOS 26 + fallback iOS 18](#5-giao-diện-ios-26--fallback-ios-18)
6. [Design tokens](#6-design-tokens)
7. [Kiến trúc kỹ thuật](#7-kiến-trúc-kỹ-thuật)
8. [Data model](#8-data-model)
9. [Backend Supabase](#9-backend-supabase)
10. [AI (DeepSeek)](#10-ai-deepseek)
11. [Tích hợp Lịch, GitHub, Jira](#11-tích-hợp-lịch-github-jira)
12. [Đồng bộ trạng thái & thẻ nội dung](#12-đồng-bộ-trạng-thái--thẻ-nội-dung)
13. [Lộ trình MVP](#13-lộ-trình-mvp)
14. [Rủi ro & quyết định](#14-rủi-ro--quyết-định)
15. [Cấu trúc project đề xuất](#15-cấu-trúc-project-đề-xuất)
16. [Bắt đầu phát triển](#16-bắt-đầu-phát-triển)
17. [Trạng thái triển khai](#17-trạng-thái-triển-khai)

---

## 1. Nguyên tắc sản phẩm

Mọi tính năng phải qua được các nguyên tắc sau:

| Nguyên tắc                   | Ý nghĩa                                                                                                                                        |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| **Chạm trước, gõ sau**       | Mọi thao tác chính xong trong ≤ 3 lần chạm. Bàn phím và giọng nói chỉ là phương án dự phòng.                                                   |
| **Giống Apple Notes**        | Thư mục → danh sách note → trình soạn. Dùng component SwiftUI hệ thống, không tự vẽ lại điều hướng.                                            |
| **Server làm, app hiển thị** | Logic, lịch chạy, gợi ý và AI nằm trên Supabase. App chỉ tự xử lý khi bắt buộc phải ở trên máy (Lịch iOS, thông báo cục bộ dự phòng, offline). |
| **Dữ liệu tự đến**           | Commit, PR, ticket Jira, sự kiện lịch được kéo về thành chip gợi ý; người dùng chỉ việc xác nhận.                                              |
| **Ghi lại để nhìn lại**      | Mỗi check-in là bản ghi có cấu trúc, đủ để AI tổng kết tuần mà không cần người dùng viết dài.                                                  |
| **Riêng tư rõ ràng**         | Token tích hợp mã hoá trên server, mọi bảng bật RLS, người dùng biết dữ liệu nào được gửi cho AI.                                              |

Giọng điệu khi buổi sáng không làm được gì phải **trung tính**: màn check-in chỉ hỏi "chiều nay làm gì", không hiện điểm số hay lời trách.

---

## 2. Màn hình & luồng chính

Ba màn hình chính: **Hôm nay** (mở mặc định), **Ghi chú**, **Tổng kết**. Check-in 12h là tính năng làm nên khác biệt.

Mỗi màn dưới đây khớp với một artboard trong file thiết kế (khung iPhone 390×844):

| Artboard       | Màn hình                      | Nội dung chính                                                                                                                                                                               | View SwiftUI đề xuất              |
| -------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| `Main`         | Thư mục                       | Nhóm ghim (Hôm nay, Tổng kết tuần), nhóm iCloud (Tất cả ghi chú, Công việc, Học ngôn ngữ, Sở thích, Ghi chú nhanh) kèm số lượng; thanh dưới: thư mục mới · tìm kiếm · soạn mới               | `FolderListView`                  |
| `Today`        | Hôm nay                       | Thẻ "Check-in 12:00" + nút **Check-in ngay**; nhóm _Buổi sáng_ (mục từ GitHub/Jira/Lịch); nhóm _Buổi chiều_ (task có checkbox tròn, giờ · thời lượng · loại)                                 | `TodayView`                       |
| `CheckIn`      | Check-in buổi trưa (sheet)    | Sáng nay đã làm (chip xác nhận) · Cảm nhận · Chiều nay làm gì (gợi ý AI) · Giờ + thời lượng · câu **nếu–thì** · nút **Lưu kế hoạch**                                                         | `CheckInSheet`                    |
| `Summary`      | Tổng kết tuần                 | "5/7 ngày có việc ý nghĩa", chấm T2–CN, biểu đồ theo loại việc, nhận xét AI (tạo lúc 20:00 CN)                                                                                               | `WeeklySummaryView`               |
| `NoteList`     | Danh sách ghi chú             | Nhóm theo Hôm nay / 7 ngày trước; mỗi note: tiêu đề, giờ + dòng trích, tag loại việc + thời lượng; tìm trong thư mục                                                                         | `NoteListView`                    |
| `Editor`       | Trình soạn                    | Ngày giờ ở giữa, tiêu đề, checklist tròn kiểu Notes; **hàng chip trên bàn phím** (checklist, loại việc, thời lượng) + nút micro                                                              | `NoteEditorView`                  |
| `Settings`     | Cài đặt & kết nối             | Giờ check-in (12:00), tổng kết tuần (CN 20:00), thông báo dự phòng; Lịch iOS / GitHub / Jira; đồng bộ iCloud, đồng bộ note lên server, cho AI đọc dữ liệu; Sign in with Apple, xoá tài khoản | `SettingsView`                    |
| `HomeWidgets`  | Widget màn hình chính         | Widget Check-in (3 nút cảm nhận), Kế hoạch chiều, Tổng kết tuần, Thư mục ghi chú                                                                                                             | `Not3Widgets`                     |
| `LockScreen`   | Màn hình khoá & thông báo 12h | Widget khoá (check-in, 5/7, việc tiếp theo); thông báo có 3 nút Hiệu quả / Bình thường / Trống                                                                                               | Widget + `UNNotificationCategory` |
| `WidgetStates` | Trạng thái widget theo giờ    | Trước 12:00: gom buổi sáng · 12:00–13:00: chờ check-in · sau check-in: kế hoạch nếu–thì + "Bắt đầu 25 phút"; widget lớn "Hôm nay"; chế độ tô màu iOS 26                                      | Timeline provider                 |

Luồng điều hướng hằng ngày: **Thư mục → Hôm nay → Check-in 12h → Tổng kết**. Trên iPad dùng `NavigationSplitView`.

---

## 3. Luồng check-in 12h

Luồng này dựa trên nghiên cứu về theo dõi tiến độ và kế hoạch nếu–thì.

1. **11:30** — `sync-integrations` kéo GitHub/Jira vào `external_items`.
2. **11:45** — `build-checkin` gom dữ liệu buổi sáng, gọi AI tạo chip gợi ý (lỗi AI thì dùng luật SQL).
3. **12:00** — gửi push qua APNs. Người dùng mở sheet, hoặc trả lời ngay trên thông báo / widget tương tác.
4. **Sáng nay đã làm gì?** — chip gợi ý từ commit, PR, ticket Jira đã chuyển trạng thái, sự kiện lịch. Chạm để xác nhận, thêm chip nếu cần.
5. **Cảm nhận** — 3 mức: _Hiệu quả / Bình thường / Trống_.
6. **Mục tiêu buổi chiều** — nếu sáng "Trống" hoặc chưa có việc phát triển bản thân, gợi ý 3 việc nhỏ; chọn 1–2.
7. **Kế hoạch nếu–thì** — chip giờ (14:00 / 15:30 / 17:00 / Tối nay) + chip thời lượng (15 / 25 / 45 / 60 phút) → câu _"Lúc 14:00, mình sẽ học 20 từ vựng Anki trong 25 phút."_ Câu này được gửi lên Supabase, server lên lịch push nhắc. Công tắc **Thêm vào Lịch** mặc định bật.
8. **Tối (tuỳ chọn)** — thông báo "Đã làm chưa?" với hai nút _Xong / Dời sang mai_.

---

## 4. Hệ thống chip

Chip là đơn vị nhập liệu chính. Mỗi chip là một giá trị có cấu trúc, nên dữ liệu luôn sạch để thống kê và để AI đọc.

| Nhóm chip  | Ví dụ                                                 | Nguồn                               |
| ---------- | ----------------------------------------------------- | ----------------------------------- |
| Loại việc  | Công việc, Học ngôn ngữ, Sở thích, Sức khoẻ, Đọc sách | Bộ có sẵn, người dùng thêm được     |
| Thời lượng | 15p, 25p, 45p, 60p                                    | Cố định                             |
| Mốc giờ    | 14:00, 15:30, 17:00, Tối nay                          | Tính từ giờ hiện tại, bỏ giờ đã qua |
| Cảm nhận   | Hiệu quả, Bình thường, Trống                          | Cố định                             |
| Mục cụ thể | "Review PR #42", "JIRA-118 → Done", "Họp sprint 9:30" | Tích hợp + lịch                     |
| Gợi ý AI   | "20 từ vựng Anki", "Viết test cho module login"       | AI dựa trên lịch sử                 |

Quy tắc:

- **Xếp hạng tự học**: chip dùng nhiều trong 14 ngày gần nhất nổi lên đầu; chip không dùng 30 ngày tự ẩn vào "Thêm". Việc xếp hạng chạy trên server.
- **Tối đa 6 chip mỗi hàng**, phần còn lại cuộn ngang.
- **Loại việc + Thời lượng + Mốc giờ = một task có nhắc**, không cần ô nhập.
- **Dự phòng**: nút micro (Speech framework) chuyển giọng nói thành chip; ô gõ chỉ hiện khi bấm "Khác…".
- Note tự do vẫn có, nhưng là lựa chọn phụ. AI có thể gắn chip cho note sau khi viết.

---

## 5. Giao diện: iOS 26 + fallback iOS 18

**Deployment target iOS 18, build bằng Xcode 26.** Trên iOS 26 các component hệ thống tự có Liquid Glass; trên iOS 18 tự trở về giao diện cũ.

| Thành phần       | Theo Apple Notes                                                      | iOS 26                                        | iOS 18 (fallback)                          |
| ---------------- | --------------------------------------------------------------------- | --------------------------------------------- | ------------------------------------------ |
| Khung điều hướng | Thư mục → danh sách → soạn (`NavigationSplitView` trên iPad)          | Thanh điều hướng kính, tự có                  | Thanh điều hướng thường                    |
| Màn "Hôm nay"    | Thư mục ghim trên cùng, mở mặc định                                   | —                                             | —                                          |
| Danh sách note   | List inset grouped, nhóm Hôm nay / 7 ngày / 30 ngày, vuốt để ghim/xoá | Tự có                                         | Tự có                                      |
| Thanh dưới       | Số lượng note ở giữa, nút soạn mới ở phải                             | Toolbar kính                                  | Toolbar thường                             |
| Trình soạn       | Tiêu đề dòng đầu, checklist tròn, hàng chip trên bàn phím             | Toolbar bàn phím kính                         | `.regularMaterial`                         |
| Chip             | Viên bo tròn, chọn = màu nhấn                                         | `.glassEffect()` trong `GlassEffectContainer` | `.background(.thinMaterial, in: .capsule)` |
| Nút chính        | Màu nhấn vàng kiểu Notes                                              | `.buttonStyle(.glassProminent)`               | `.borderedProminent`                       |
| Check-in 12h     | Sheet nửa màn hình                                                    | `.presentationDetents([.medium, .large])`     | Như iOS 26                                 |

**Cách code fallback**: gom mọi API chỉ có trên iOS 26 vào vài modifier riêng (`.appChipStyle()`, `.appPrimaryButton()`…), bên trong dùng `if #available(iOS 26, *)`. Màn hình chỉ gọi modifier đó, nên khi bỏ iOS 18 chỉ cần sửa một chỗ.

```swift
extension View {
    @ViewBuilder
    func appChipStyle(isOn: Bool) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(isOn ? .regular.tint(.accentColor) : .regular, in: .capsule)
        } else {
            self.background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.thinMaterial), in: .capsule)
        }
    }
}
```

Nên làm:

- **Ngoài app**: widget tương tác (WidgetKit + App Intents) để check-in trên màn hình khoá; Live Activity đếm ngược phiên 25 phút; Control Center control (iOS 18+).
- **Tiếp cận**: kiểm tra với _Giảm độ trong suốt_, _Tăng độ tương phản_, Dynamic Type cỡ lớn. Trạng thái luôn có chữ + biểu tượng, không chỉ màu.
- **CI**: chạy simulator iOS 18 **và** iOS 26 cho mỗi lần build.

Không nên: tự vẽ blur, thêm màu nhấn ngoài vàng, đặt kính chồng lên kính. Nền nội dung (note, danh sách) luôn phẳng như Notes.

---

## 6. Design tokens

Các giá trị dưới đây lấy từ file thiết kế. Khi code, ưu tiên màu hệ thống (`Color(.systemGroupedBackground)`…) để tự hỗ trợ Dark Mode. Hex chỉ dùng làm tham chiếu.

| Token              | Giá trị                                   | Dùng cho                                    | SwiftUI gần nhất                    |
| ------------------ | ----------------------------------------- | ------------------------------------------- | ----------------------------------- |
| Nền nhóm           | `#F2F2F7`                                 | Nền màn danh sách                           | `.systemGroupedBackground`          |
| Nền thẻ            | `#FFFFFF`, bo góc 20                      | Nhóm list, thẻ check-in                     | `.secondarySystemGroupedBackground` |
| Màu nhấn           | `#FFD60A`                                 | Nút chính, chip đang chọn, checkbox đã xong | `AccentColor` (vàng Notes)          |
| Chữ nhấn           | `#8A6100`                                 | Link, nhãn "Check-in 12:00", icon soạn mới  | — (đủ tương phản trên nền sáng)     |
| Icon thư mục       | `#B8860B`                                 | Icon thư mục, viền checkbox                 | —                                   |
| Chữ phụ            | `#6C6C70`                                 | Dòng phụ, số đếm                            | `.secondaryLabel`                   |
| Đường kẻ           | `#C6C6C8`, 0.5pt                          | Phân cách hàng                              | `.separator`                        |
| Chip tắt           | `#EFEFF4` / `#E5E5EA`                     | Chip chưa chọn (iOS 18)                     | `.tertiarySystemFill`               |
| Tag loại việc      | nền `#FFF3C2`, chữ `#6B4B00`              | Tag trên danh sách note                     | —                                   |
| Dải tiêu đề widget | `#D46100` (tuỳ chọn `#C45500`, `#FF9500`) | Header widget                               | —                                   |

Kích thước:

- Font hệ thống SF Pro: tiêu đề lớn 34 bold, tiêu đề nhóm 20–22 bold, nội dung 17, phụ 13–15.
- Nút tròn trên thanh điều hướng 44×44; nút / ô tìm kiếm ở thanh dưới cao 50; nút chính cao 50–52, bo tròn hết cỡ.
- Hàng list tối thiểu 54–58pt; lề ngang 16, lề chữ tiêu đề 20.
- Mọi vùng chạm ≥ 44pt.

---

## 7. Kiến trúc kỹ thuật

**App hiển thị, Supabase xử lý, CloudKit đồng bộ note.**

```
┌──────────────────────────── Trên iPhone ─────────────────────────────┐
│  App iOS · Apple Notes style · iOS 18 → 26                           │
│  (Ghi chú · Hôm nay · Tổng kết · Sheet check-in · Widget · Intents)  │
│        │                    │                      │                 │
│   SwiftData            Supabase SDK         Lịch iOS (EventKit)      │
│  (cache offline)    (Auth, API, Realtime)  (app đọc → gửi lên) ──┐   │
└────────│────────────────────│─────────────────────────────────────│──┘
         ↕                    ↕                                     │
   CloudKit (private)   Postgres + RLS  ◀──▶  Edge Functions + Cron ◀┘
   (đồng bộ note)       (dữ liệu gốc)        (sync, AI, gợi ý, push)
                              │                     │
                            APNs          DeepSeek · GitHub · Jira
                       (push lúc 12:00)        (API bên ngoài)
```

**Stack app**: Swift 6, SwiftUI + `@Observable` (MVVM), SwiftData (cache) + CloudKit, `supabase-swift`, Sign in with Apple, WidgetKit, App Intents, EventKit, BackgroundTasks, ASWebAuthenticationSession, Speech.

**Offline-first**: ghi vào SwiftData trước, một hàng đợi sync đẩy lên Supabase khi có mạng.

### Chia dữ liệu: CloudKit hay Supabase?

Server không đọc được CloudKit private. Vì vậy mọi thứ cần tính toán phải nằm trên Supabase.

| Loại dữ liệu                     | Nguồn chính        | Bản sao                             | Lý do                                       |
| -------------------------------- | ------------------ | ----------------------------------- | ------------------------------------------- |
| Nội dung note đầy đủ             | CloudKit (private) | Supabase (mặc định bật, có thể tắt) | Riêng tư, miễn phí, đồng bộ như Apple Notes |
| Tiêu đề + chip của note          | Supabase           | SwiftData                           | AI cần để gắn chip và tổng kết              |
| Task, check-in, kế hoạch nếu–thì | Supabase           | SwiftData (offline)                 | Cron, push và AI đọc trực tiếp              |
| Chip, thống kê sử dụng           | Supabase           | SwiftData                           | Xếp hạng chip tính trên server              |
| `external_items`, `suggestions`  | Supabase           | SwiftData                           | Server tạo ra                               |
| Token OAuth                      | Supabase Vault     | Không                               | Không bao giờ xuống app                     |
| Push token thiết bị, múi giờ     | Supabase           | Không                               | Cron gửi push đúng giờ địa phương           |

---

## 8. Data model

Mọi bảng bật **Row Level Security** theo `auth.uid()`.

| Bảng                       | Trường chính                                                                                                                            |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `profiles`                 | user_id, timezone, giờ check-in (mặc định 12:00), bật AI cho note                                                                       |
| `devices`                  | user_id, apns_token, môi trường (sandbox / production)                                                                                  |
| `notes`                    | id, ckRecordName, tiêu đề, chips[], updated_at                                                                                          |
| `tasks`                    | id, tiêu đề, chips[], planned_at, thời lượng, trạng thái, nguồn (tay / AI / tích hợp), calendarItemExternalIdentifier                   |
| `checkins`                 | ngày, morning_items[], cảm nhận, afternoon_plan_ids[]                                                                                   |
| `chips`                    | id, nhóm, nhãn, use_count, last_used_at                                                                                                 |
| `external_items`           | nguồn (calendar / github / jira), external_id, tiêu đề, url, occurred_at                                                                |
| `suggestions`              | loại, payload JSON, trạng thái (mới / đã chọn / bỏ qua), created_at                                                                     |
| `integrations`             | provider, tên tài khoản, scopes, vault_secret_id                                                                                        |
| `push_queue`               | user_id, send_at (UTC), loại, payload, trạng thái                                                                                       |
| `task_links`               | task_id, provider, external_id, url, external_status, external_updated_at, app_updated_at, link_source (tự động / AI / tay), confidence |
| `sync_cursors`             | integration_id, cursor, last_run_at                                                                                                     |
| `sync_events`              | provider, delivery_id (duy nhất), payload, trạng thái, số lần thử                                                                       |
| `sync_runs`, `sync_errors` | Log mỗi lần chạy / sự kiện lỗi quá 5 lần                                                                                                |
| `cards`                    | id, kind, title, status, badges[], summary, primary_action, linked_item_ids[], version, seen_at                                         |
| `content_rules`            | provider, event_type, pattern, action, created_from                                                                                     |

---

## 9. Backend Supabase

`pg_cron` chạy theo UTC, còn mỗi người dùng có múi giờ riêng. Vì vậy chỉ có **một cron mỗi 5 phút** gọi `tick`; `tick` chọn những người dùng đang tới mốc giờ địa phương rồi giao việc cho các function con.

| Edge Function       | Kích hoạt                     | Việc làm                                                                 |
| ------------------- | ----------------------------- | ------------------------------------------------------------------------ |
| `tick`              | pg_cron + pg_net, mỗi 5 phút  | Chọn user theo giờ địa phương, gọi các function dưới                     |
| `sync-integrations` | 30 phút trước check-in        | Kéo GitHub, Jira vào `external_items`                                    |
| `build-checkin`     | 15 phút trước check-in        | Gom dữ liệu sáng, gọi `ai-gateway`, ghi `suggestions`; lỗi AI → luật SQL |
| `build-cards`       | Sau mỗi lần đồng bộ           | Chuẩn hoá → phân loại → gộp trùng → dựng thẻ → phát hành                 |
| `send-push`         | Mỗi lần tick                  | Gửi các dòng `push_queue` đến hạn qua APNs                               |
| `ai-gateway`        | Nội bộ hoặc từ app            | Gọi DeepSeek, kiểm tra JSON (Zod), đếm hạn mức                           |
| `weekly-summary`    | Chủ nhật 20:00 giờ địa phương | Tổng kết tuần (model mức sâu), push "Tổng kết đã sẵn sàng"                   |
| `oauth-callback`    | Redirect từ GitHub/Jira       | Đổi code lấy token, lưu Vault                                            |
| `cleanup`           | Mỗi đêm                       | Xoá `suggestions` và `push_queue` cũ hơn 30 ngày                         |

Job đồng bộ bổ sung: `poll-active` (15 phút, 8:00–20:00), `pre-checkin-sync`, `reconcile-nightly` (02:00), `refresh-tokens` (mỗi giờ), `renew-webhooks` (hằng ngày, webhook Jira ~30 ngày), `retry-failed` (10 phút, giãn 1/5/15/60 phút, quá 5 lần → `sync_errors`).

**Push qua APNs**:

- Token-based auth: file `.p8`, Key ID, Team ID lưu làm secret của Edge Function; ký JWT ES256, gửi qua HTTP/2.
- Thông báo 12:00 có category với 3 nút _Hiệu quả / Bình thường / Trống_. App xử lý trong nền, không cần mở app.
- APNs trả 410 → xoá dòng trong `devices`.
- **Dự phòng trên máy**: nếu push từ server bị chặn hoặc Supabase lỗi kéo dài, app tự đặt thông báo cục bộ 12:00.

**Tính toán**: xếp hạng chip, chuỗi ngày, số buổi mỗi tuần viết bằng SQL function / view. App chỉ đọc kết quả.

---

## 10. AI (DeepSeek)

Mọi lệnh gọi AI đi qua Edge Function `ai-gateway`. **App không bao giờ giữ API key DeepSeek**; key là secret của Edge Function. DeepSeek dùng được định dạng OpenAI Chat Completions, có JSON output và tool calling. **Tên model được chọn tự động** từ `GET /models` (cache 6 giờ). Tác vụ nhẹ dùng model họ "flash", tác vụ sâu dùng họ "pro". Nếu DeepSeek đổi tên model (năm 2026 đã đổi `deepseek-v4-flash` → `deepseek-flash`), server tự làm mới danh sách và gọi lại, không cần deploy lại. Muốn ép một model cố định thì đặt `DEEPSEEK_MODEL`. Các tác vụ đều tắt thinking mode (`thinking: {type: "disabled"}`) để nhanh và rẻ.

| Tác vụ                      | Khi nào                        | Model                | Đầu ra                                      |
| --------------------------- | ------------------------------ | -------------------- | ------------------------------------------- |
| Gom dữ liệu sáng thành chip | Cron 11:45 giờ địa phương      | nhẹ (`deepseek-flash`)                | JSON: chip + nguồn                          |
| Gợi ý 3 việc buổi chiều     | Cùng lúc trên                  | nhẹ (`deepseek-flash`)                | JSON: 3 task (loại, thời lượng, giờ)        |
| Gắn chip cho note tự do     | Khi note được lưu (DB webhook) | nhẹ (`deepseek-flash`)                | JSON: chip                                  |
| Tổng kết tuần               | Cron tối Chủ nhật              | sâu (`deepseek-v4-pro`)               | 3–5 câu + số liệu                           |
| Hỏi đáp lịch sử             | Khi người dùng hỏi             | nhẹ + tool calling                    | Tool truy vấn Postgres, AI không tự đoán số |

Cột Model là tên `/models` trả về ngày 2026-11-01. Code chỉ khai báo mức "nhẹ" hoặc "sâu", không ghi tên model.

Nguyên tắc:

- AI chỉ đề xuất, người dùng chạm để xác nhận. Gợi ý lưu ở `suggestions`, chỉ thành task/check-in sau một lần chạm.
- Luôn yêu cầu JSON và kiểm tra schema bằng Zod trước khi ghi DB.
- Đặt phần hướng dẫn hệ thống cố định ở đầu prompt để tận dụng cache. Giới hạn số lần gọi mỗi người mỗi ngày.
- Khi AI lỗi hoặc hết hạn mức, dùng gợi ý theo luật SQL (chip dùng nhiều nhất + loại việc bị thiếu 7 ngày) để flow vẫn chạy.
- Gửi tối thiểu: chỉ tiêu đề + chip, trừ khi người dùng bật gửi nội dung note.
- Siri / Phím tắt: App Intents "Check-in buổi trưa", "Thêm việc buổi chiều".

---

## 11. Tích hợp Lịch, GitHub, Jira

| Nguồn                                         | Ai lấy dữ liệu        | Xác thực                                     | Dữ liệu                                                                  |
| --------------------------------------------- | --------------------- | -------------------------------------------- | ------------------------------------------------------------------------ |
| Lịch iOS (gồm Google/Outlook đã thêm vào máy) | **App**, qua EventKit | Quyền Lịch iOS (toàn quyền)                  | Đọc sự kiện trong ngày; ghi kế hoạch chiều vào lịch riêng "Note & To-do" |
| GitHub                                        | Edge Function         | GitHub App / OAuth App, đổi code trên server | Commit, PR mở/merge, review, issue đóng                                  |
| Jira Cloud                                    | Edge Function         | Atlassian OAuth 2.0 (3LO), refresh token     | Issue chuyển trạng thái, worklog, issue được giao (JQL theo ngày)        |
| Để sau                                        | Supabase              | —                                            | Bitbucket, Google Calendar trực tiếp, Notion, Linear, Slack              |

- **OAuth**: app mở `ASWebAuthenticationSession` → provider redirect về `oauth-callback` → server đổi code, mã hoá token vào Vault → universal link về app.
- **Adapter chung**: mỗi nguồn là một module trả về `ExternalItem[]`, nên thêm nguồn mới không phải sửa app.
- **Lịch iOS**: đọc khi mở app, trong `BGAppRefreshTask` buổi sáng, và luôn đọc lại khi mở sheet check-in. Nếu máy chưa báo lên quá 6 giờ, server gửi silent push.

### Đồng bộ hai chiều với Lịch iOS (chạy trên máy)

- **App → Lịch**: "Lưu kế hoạch" tạo sự kiện EventKit trong lịch riêng của app. Task lưu `calendarItemExternalIdentifier`.
- **Lịch → App**: lắng nghe `EKEventStoreChanged`.
  - Dời giờ → cập nhật `planned_at`, thời lượng; server dời push.
  - Xoá sự kiện → task "Đã huỷ", có hoàn tác.
  - Hết giờ → không tự đánh dấu xong; check-in tối hỏi lại.
- **Xung đột**: sửa gần nhất thắng. Chỉ đồng bộ giờ, thời lượng, trạng thái; tiêu đề lấy app làm nguồn chính.
- **Tuỳ chọn**: ghi vào Lời nhắc thay vì Lịch (chọn trong Cài đặt, mặc định Lịch).

---

## 12. Đồng bộ trạng thái & thẻ nội dung

Ba nguồn tín hiệu đi chung một hàng đợi có chống trùng: **webhook** cho tốc độ, **cron quét bù** cho độ chắc chắn, **app báo lên** cho Lịch iOS. Thay đổi được đẩy về app (Realtime) và widget (silent push).

Ánh xạ trạng thái:

| Nguồn  | Sự kiện                                | Trạng thái task                                          |
| ------ | -------------------------------------- | -------------------------------------------------------- |
| GitHub | PR merged                              | Xong                                                     |
| GitHub | PR đóng không merge                    | Huỷ                                                      |
| GitHub | Issue đóng (completed / not planned)   | Xong / Huỷ                                               |
| GitHub | PR hoặc issue mở lại                   | Mở lại                                                   |
| Jira   | `statusCategory = Done`                | Xong                                                     |
| Jira   | `statusCategory = In Progress / To Do` | Đang làm / Chưa làm                                      |
| Jira   | Issue bị xoá / giao người khác         | Gỡ liên kết, hỏi người dùng                              |
| Lịch   | Dời giờ / Xoá / Hết giờ                | Dời task + push / Huỷ có hoàn tác / Hỏi lúc check-in tối |

Quy tắc chính:

- **Liên kết task ↔ mục ngoài**: AI so khớp. Độ tin cậy ≥ 0,85 thì tự liên kết; 0,6–0,85 thì hiện chip "Liên kết với PR #57?"; thấp hơn thì bỏ qua.
- **Chống trùng**: `sync_events` có khoá duy nhất `(provider, delivery_id)`. Xác thực chữ ký webhook (GitHub HMAC `X-Hub-Signature-256`, Jira secret). Upsert theo `(provider, external_id)`. Cursor quét lùi 10 phút. Chỉ ghi khi `external_updated_at` mới hơn bản đang lưu.
- **Nguồn chính theo trường**: trạng thái lấy từ bên ngoài, giờ lấy từ Lịch, tiêu đề lấy từ app. Ghi ngược mặc định bật cho Lịch và tắt cho GitHub/Jira. Thay đổi do hệ thống ghi mang `origin = app` để chống vòng lặp.

**Thẻ nội dung** (`build-cards`): mọi mục đồng bộ được dựng thành một khuôn thẻ chung gồm huy hiệu nguồn, tiêu đề dạng câu hành động, trạng thái (chữ + icon), dòng phụ xám 13pt, tóm tắt AI 1–2 dòng và **một** hành động chính có hoàn tác. Server tự tạo ghi chú **"Nhật ký hôm nay"** trong một khối được quản lý; chữ người dùng tự thêm ở ngoài khối không bị ghi đè. Hộp **"Mới đồng bộ"** có chip _Thành việc / Thành ghi chú / Bỏ qua / Luôn bỏ qua_; chọn "Luôn…" sẽ tạo luật trong `content_rules`.

Hiển thị: mở app là thấy cache ngay, sau đó chỉ thay phần đã đổi (theo version). Có hoạt ảnh tick nhẹ, nhãn "Mới", nhiều commit gom thành "5 commit · app-ios", trạng thái trống/lỗi chỉ có đúng một nút xử lý.

---

## 13. Lộ trình MVP

Làm một mình, bán thời gian, khoảng **14–20 tuần**. Mỗi giai đoạn chỉ bắt đầu khi điều kiện của giai đoạn trước đã đạt.

| #   | Giai đoạn          | Thời gian | Nội dung                                                                           | Điều kiện sang bước sau |
| --- | ------------------ | --------- | ---------------------------------------------------------------------------------- | ----------------------- |
| 1   | **Nền tảng + MVP** | 6–8 tuần  | Supabase Auth + RLS · App Notes iOS 18/26 · Chip + check-in 12h · Cron + push APNs | TestFlight 10–20 người  |
| 2   | AI DeepSeek        | 2–3 tuần  | Edge `ai-gateway` · chip, gợi ý chiều · tổng kết tuần · dự phòng theo luật         | Gợi ý được chọn dùng    |
| 3   | Tích hợp + sync    | 3–5 tuần  | Lịch iOS (EventKit) · GitHub OAuth · Jira OAuth (3LO) · đồng bộ CloudKit           | Chip sáng tự điền đúng  |
| 4   | Ra mắt             | 3–4 tuần  | Widget, Live Activity · App Intents, Siri · Supabase gói Pro · App Store, privacy  | Qua App Review          |

Chỉ riêng giai đoạn 1 đã đủ để dùng hằng ngày. AI bắt đầu khi có API key DeepSeek.

---

## 14. Rủi ro & quyết định

| Rủi ro                                             | Ảnh hưởng                                  | Cách giảm                                                                |
| -------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------ |
| Supabase lỗi / gói free tạm dừng project           | Không có push 12h, không có gợi ý          | Thông báo cục bộ dự phòng; cache SwiftData; lên gói Pro trước khi ra mắt |
| DeepSeek lỗi, đổi tên model, hết hạn mức           | Không có chip gợi ý AI                     | Gợi ý theo luật SQL; tên model tự lấy từ `/models`                     |
| Dữ liệu công việc gửi tới AI                       | Vi phạm chính sách công ty; khó qua review | Bật AI riêng từng tích hợp; chỉ gửi tiêu đề; khai báo App Privacy        |
| CloudKit + Supabase xung đột                       | Dữ liệu lệch giữa thiết bị                 | Mỗi loại dữ liệu chỉ có một nguồn chính                                  |
| Lịch iOS chỉ đọc trên máy, chạy nền không đúng giờ | Chip sáng thiếu sự kiện lịch               | Đọc lại lịch khi mở sheet check-in                                       |
| Hỗ trợ iOS 18 + 26                                 | Gấp đôi công kiểm thử UI                   | Gom API iOS 26 vào vài modifier; CI chạy cả hai simulator                |
| Yêu cầu App Store                                  | Bị từ chối                                 | Sign in with Apple; nút xoá tài khoản; mô tả rõ dữ liệu thu thập         |

**Đã chốt**

- Backend: Supabase (cron, push, tính toán, AI)
- iOS: target iOS 18, giao diện đầy đủ trên iOS 26
- AI: DeepSeek qua Edge Function
- Đồng bộ: CloudKit cho nội dung note, Supabase cho dữ liệu cần tính toán
- Tích hợp đợt đầu: Lịch iOS, GitHub, Jira (Bitbucket để sau)
- Nội dung note đồng bộ lên Supabase mặc định, có công tắc tắt trong Cài đặt

**Còn mở**

- [x] Gửi API key DeepSeek (lưu thành secret Supabase, không đưa vào app)
- [ ] Kiếm tiền: miễn phí + gói Pro (tích hợp, tổng kết AI), hay trả một lần?

---

## 15. Cấu trúc project đề xuất

> Đây là đề xuất để bắt đầu. Cấu trúc này chưa có trong doc kế hoạch.

```
Not3/
├── Not3.xcodeproj
├── Not3/                       # App target (iOS 18+)
│   ├── App/                    # Not3App, AppDelegate (push), routing
│   ├── DesignSystem/           # Tokens, .appChipStyle(), .appPrimaryButton(), components
│   ├── Features/
│   │   ├── Folders/            # FolderListView
│   │   ├── Today/              # TodayView
│   │   ├── CheckIn/            # CheckInSheet, if-then plan builder
│   │   ├── Notes/              # NoteListView, NoteEditorView
│   │   ├── Summary/            # WeeklySummaryView
│   │   └── Settings/           # SettingsView, integrations
│   ├── Data/
│   │   ├── Models/             # SwiftData @Model: Note, Task, CheckIn, Chip, Card…
│   │   ├── Sync/               # Offline queue → Supabase, Realtime, CloudKit
│   │   └── Supabase/           # Client, DTOs, API
│   ├── Services/               # EventKit, Notifications, BackgroundTasks, Speech
│   └── Intents/                # App Intents (check-in, thêm việc chiều)
├── Not3Widgets/                # WidgetKit + Live Activity
├── Not3Tests/
└── supabase/
    ├── migrations/             # Bảng, RLS, SQL functions/views
    └── functions/              # tick, sync-integrations, build-checkin, build-cards,
                                # send-push, ai-gateway, weekly-summary, oauth-callback, cleanup
```

---

## 16. Bắt đầu phát triển

Yêu cầu:

- Xcode 26 (SDK iOS 26), deployment target iOS 18.0
- Swift 6
- Tài khoản Apple Developer (Push Notifications, Sign in with Apple, iCloud/CloudKit, App Groups cho widget)
- [Supabase CLI](https://supabase.com/docs/guides/cli) cho phần backend

Secrets (lưu trên Supabase, **không** commit vào repo):

| Secret                                                              | Dùng cho               |
| ------------------------------------------------------------------- | ---------------------- |
| `DEEPSEEK_API_KEY` (bắt buộc), `DEEPSEEK_MODEL` (tuỳ chọn, ép một model) | Các tác vụ AI |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`      | `send-push`            |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_WEBHOOK_SECRET` | OAuth + webhook GitHub |
| `JIRA_CLIENT_ID`, `JIRA_CLIENT_SECRET`                              | OAuth Jira (3LO)       |

Phía app chỉ cần `SUPABASE_HOST` (không có `https://`) và `SUPABASE_ANON_KEY` trong `Config/Secrets.xcconfig` (đã gitignore). Không có file này thì app vẫn chạy, chỉ lưu trên máy.

### Chạy app

```bash
brew install xcodegen            # một lần
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # tuỳ chọn, điền Supabase
xcodegen                         # sinh Not3.xcodeproj từ project.yml (project không commit)
open Not3.xcodeproj
```

Test: `xcodebuild -project Not3.xcodeproj -scheme Not3 -destination 'platform=iOS Simulator,name=iPhone 17' test`

### Xcode Cloud

`ci_scripts/ci_post_clone.sh` cài XcodeGen, sinh `Not3.xcodeproj` và chép `Config/Package.resolved` vào project (Xcode Cloud không tự resolve package). Sau khi đổi version package, chép lại file:

```bash
cp Not3.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Config/Package.resolved
```

Workflow (test simulator iOS 18 + 26, archive → TestFlight) tạo trong Xcode: **Product → Xcode Cloud → Create Workflow**.

Tham số chạy chỉ có ở bản DEBUG: `-openCheckIn` mở thẳng sheet check-in, `-openFolders` mở màn Thư mục.

### Chạy backend

```bash
supabase link --project-ref <ref>
supabase db push                                   # supabase/migrations
cp supabase/.env.example supabase/.env             # điền APNs
supabase secrets set --env-file supabase/.env
supabase functions deploy tick send-push build-checkin tag-note weekly-summary ai-gateway integrations oauth-callback sync-integrations
```

Sau đó lưu URL project và service role key vào Vault để cron `tick` gọi được function:

```sql
select vault.create_secret('https://<ref>.supabase.co', 'project_url');
select vault.create_secret('<service_role_key>', 'service_role_key');
```

Trong Supabase Dashboard, bật provider **Apple** ở Authentication → Providers, với Client ID là bundle id `com.tuandiep.not3`.

---

## 17. Trạng thái triển khai

**Giai đoạn 1 — Nền tảng + MVP** (đang làm)

- [x] Project XcodeGen, iOS 18+, Swift 6, Supabase SDK
- [x] Design system: tokens, `.appChipStyle()`, `.appPrimaryButton()`, `.appCheckInSheet()` (fallback iOS 26 / 18)
- [x] SwiftData: Folder, Note, ChecklistItem, TaskItem, CheckIn, Chip, ExternalItem
- [x] Màn Thư mục, Hôm nay, Check-in 12h, Danh sách ghi chú, Trình soạn, Tổng kết tuần, Cài đặt
- [x] Check-in: chip buổi sáng, cảm nhận, gợi ý chiều theo luật, giờ + thời lượng, câu nếu–thì
- [x] Thông báo cục bộ 12:00 dự phòng (7 ngày tới, bỏ qua hôm đã check-in) + 3 nút trả lời nhanh; nhắc giờ kế hoạch
- [x] Sign in with Apple → Supabase, đồng bộ task / check-in / note (cờ `needsSync`), đăng ký APNs token, xoá tài khoản
- [x] Supabase: migration (bảng, RLS, trigger nhắc giờ, `users_due`, `delete_account`, `weekly_stats`, cron `tick` + `cleanup`)
- [x] Edge Functions: `tick`, `send-push` (APNs ES256), `build-checkin` (theo luật)
- [x] Kéo `suggestions` từ server về sheet check-in (gợi ý server đứng trước, luật trên máy bù phần còn lại; đánh dấu picked/dismissed khi lưu)
- [x] Hỏi lại buổi tối "Đã làm chưa?" (21:00 hoặc 15 phút sau khi xong việc) với nút Xong / Dời sang mai — thông báo cục bộ + push server (migration `evening_checkin`, tự huỷ push cũ khi task đổi giờ/xong)
- [x] Không nhắc trùng: server đã gửi được push tới máy (`devices.last_sent_at`) thì app không đặt nhắc cục bộ; trước đó vẫn giữ thông báo trên máy
- [x] Môi trường APNs lấy theo provisioning profile (cài từ Xcode → sandbox, TestFlight / App Store → production); lỗi gửi lưu ở `push_queue.last_error` và `devices.last_error`
- [x] Nhập giọng nói (Speech, vi-VN, trên máy khi có thể): nút "Nói" trong check-in tách câu thành việc + giờ + thời lượng; nút micro trong trình soạn
- [x] CI GitHub Actions: test trên simulator iOS 26 + iOS 18, type-check Edge Functions (chưa chạy thử, xem `CAN_BO_SUNG.md`)
- [ ] TestFlight 10–20 người (cần Team ID, APNs, Supabase — xem `CAN_BO_SUNG.md`)

**Giai đoạn 2 — AI DeepSeek** (code xong, chờ API key)

- [x] `_shared/deepseek.ts`: Chat Completions, JSON mode, kiểm tra schema bằng Zod, tool calling, tự chọn model từ `/models` (mức nhẹ/sâu), tắt thinking, gọi lại khi JSON rỗng hoặc model bị đổi tên, timeout 25 s
- [x] Hạn mức `AI_DAILY_LIMIT` lượt/người/ngày (`try_consume_ai`), tôn trọng công tắc "Cho AI đọc dữ liệu"
- [x] `build-checkin`: AI gom chip sáng + gợi ý 3 việc chiều; lỗi/không có key → luật cũ
- [x] `tag-note` (database webhook khi note đổi tiêu đề/nội dung): gợi ý chip vào `notes.ai_chips`; chỉ gửi nội dung khi người dùng cho phép
- [x] `weekly-summary` (CN 20:00 giờ địa phương, model mức sâu) + push "Tổng kết tuần đã sẵn sàng"; không có AI → tổng kết theo luật
- [x] `ai-gateway` "Hỏi về lịch sử": tool calling truy vấn Postgres dưới RLS, AI không tự đoán số
- [x] App: chip AI gợi ý trong trình soạn (chạm để nhận, ✕ để bỏ), nhận xét tuần + ô hỏi đáp ở màn Tổng kết
- [x] Test Deno cho phần AI (mock DeepSeek): schema, fallback, vòng tool
- [ ] Đo tỉ lệ gợi ý được chọn (`suggestions.status = picked`) — điều kiện sang giai đoạn 3

**Giai đoạn 3 — Tích hợp + sync** (code xong, chờ GitHub App / Atlassian app — xem `CAN_BO_SUNG.md` mục G)

- [x] Lịch iOS (EventKit, trên máy): đọc sự kiện hôm nay → chip sáng (đọc lại khi mở check-in), đẩy lên `external_items`
- [x] Ghi kế hoạch chiều vào lịch riêng "Not3" (công tắc "Thêm vào Lịch" trong check-in); dời giờ / xoá trong app Lịch → task đổi giờ / huỷ, nhắc giờ dời theo; huỷ / dời trong app → sự kiện cập nhật
- [x] GitHub (GitHub App, chỉ đọc) + Jira (OAuth 2.0 3LO): `integrations` (connect / sync / status), `oauth-callback` (đổi code trên server, token vào Vault qua `save_integration`), tự làm mới token
- [x] Kéo dữ liệu: PR merge / review / đóng, issue, commit gom theo repo; ticket Jira theo `statusCategory`; cron 30 phút trước check-in (`sync-integrations`) + "Đồng bộ ngay"
- [x] Cài đặt: cấp quyền Lịch, Kết nối / Ngắt (xoá token + dữ liệu nguồn đó) / Đồng bộ ngay, trạng thái "Đồng bộ lần cuối" / lỗi
- [x] CloudKit: note (thư mục, note, checklist) đồng bộ qua iCloud private DB; task / check-in / chip ở kho riêng trên máy; chuyển dữ liệu một lần từ kho cũ (giữ bản sao `default.store.migrated`)
- [x] Liên kết task ↔ PR / ticket (`task_links`): theo mã trong tên task (`#42`, `JIRA-118`), hoặc AI so khớp (≥ 0,85 tự liên kết, 0,6–0,85 hỏi "Liên kết với …?"); trạng thái theo bên ngoài (PR merge / ticket Done → xong, PR đóng → huỷ) + push "Đã đánh dấu xong"; app kéo thay đổi (`updated_by = 'sync'`), sửa tay mới hơn thì giữ của người dùng
- [x] Ghi chú "Nhật ký hôm nay" (thư mục "Nhật ký"): Sáng / Chiều với việc xong, PR, ticket, sự kiện; chỉ viết trong khối tự động, chữ người dùng ngoài khối giữ nguyên
- [x] GitHub: báo nguyên văn lỗi; tìm kiếm bị 422 thì tự đọc từng repo đã cài GitHub App
- [x] Webhook GitHub (`webhook-github`: HMAC `X-Hub-Signature-256`, chống trùng bằng `sync_events`), bật trong GitHub App — xem `CAN_BO_SUNG.md` G7
- [x] `poll-active`: mỗi 15 phút 08:00–20:00 giờ địa phương kéo GitHub + Jira (đường chính cho Jira)
- [x] Đối soát 02:00: đọc lại trạng thái thật của mọi PR / ticket đang liên kết với task chưa xong
- [x] Tự phân loại trên server (`_shared/classify.ts`): PR nhờ review / PR của mình đang mở / issue, ticket giao cho mình → task có liên kết; đã xong & commit → nhật ký; khớp luật → bỏ qua; còn lại → "Chưa phân loại" (dòng ⚠️ ở Hôm nay, chạm mới hiện lựa chọn: Thành việc / Thành ghi chú / Bỏ qua / Luôn bỏ qua theo repo-project hoặc cả loại)
- [x] Cài đặt riêng cho GitHub / Jira (`integrations.settings`, mặc định ở `_shared/settings.ts` + `IntegrationOptions.swift`): GitHub — PR & issue, review được nhờ / đã gửi (task Review tự xong), commit, release & tag, PR mình merge, bình luận, @mention (task "Trả lời …" tự xong khi bình luận lại), build Actions & deploy (lỗi → task "Sửa: …", chạy lại xanh thì tự xong); Jira — được giao, mình tạo, sprint đang chạy, theo dõi, chuyển trạng thái, log work
- [x] "Tính là hoàn thành" (`integrations.done_rules`): Jira — chọn thêm trạng thái tính là xong (danh sách lấy từ Jira, vd Code Review / Release Testing); GitHub — PR của tôi xong khi merge / được duyệt / sẵn sàng review, nhãn tính là xong (vd `ready-for-qa`)
- [x] Mở lại khi bị trả lại: việc đã xong vì mục ngoài đã xong, nay mục quay lại đang làm (ticket về In Progress, request changes, review lại, PR mở lại, build đỏ lại) → tự bỏ tích, nhãn "Bị trả lại · …" + push (`tasks.reopened_at / reopened_reason`)
- [x] Bảo mật: app chỉ được sửa cột `settings` của dòng `integrations` của mình (trước đây sửa được cả `vault_secret_id`)
- [ ] Webhook Jira (cần đăng ký động qua API, gia hạn 30 ngày) — hiện dùng poll 15 phút
- [ ] Atlassian Personal Data Reporting API (bắt buộc khi app Jira ở chế độ Sharing và lưu accountId)
- [ ] GitHub: Projects v2, Discussions, cảnh báo bảo mật, tổng đóng góp (GraphQL / quyền riêng)
- [ ] Thẻ nội dung hợp nhất `build-cards` (gộp PR ↔ ticket cùng việc, tóm tắt AI 2 dòng)

**Giai đoạn 4 — Widget** (đang làm)

- [x] Widget extension `Not3Widgets` (WidgetKit, iOS 18+): **Check-in** (vừa + màn hình khoá; đổi theo giờ: sáng nay → "Sáng nay thế nào?" với 3 nút → câu nếu–thì + "Bắt đầu"), **Việc hôm nay** (nhỏ / vừa / lớn, tích ngay trên widget, logo GitHub / Jira, "↺ Bị trả lại"), **Tuần này** (nhỏ + vòng màn hình khoá), **Thư mục ghi chú** (chọn thư mục khi sửa widget)
- [x] Dữ liệu: app ghi ảnh chụp JSON vào App Group `group.com.tuandiep.not3` (`Shared/WidgetSnapshot.swift`); widget chỉ đọc. Thao tác trên widget → cập nhật ảnh chụp + xếp hàng (`widget-actions/`), app áp vào SwiftData và đồng bộ ở lần chạy sau
- [x] Tự cập nhật: sau mọi lần lưu SwiftData (debounce), khi vào nền, BGAppRefreshTask (~30 phút) và silent push từ server khi GitHub / Jira đổi task (`_shared/push.ts`, tối đa 1 lần / 10 phút)
- [x] Deep link `not3://today | checkin | summary | folder/<id> | note/<id> | new-note`
- [x] DEBUG: `-widgetGallery` (`-widgetGallery2`) vẽ mọi trạng thái widget trên simulator
- [ ] Live Activity đếm ngược phiên (nút "Bắt đầu" hiện chỉ chuyển việc sang Đang làm)
- [ ] App Intents / Siri, Control Center

Những mục cần bạn cung cấp hoặc quyết định nằm trong [`CAN_BO_SUNG.md`](CAN_BO_SUNG.md).
