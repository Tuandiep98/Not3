# Cần bổ sung

Những mục chỉ bạn mới cung cấp hoặc quyết định được. Code đã chờ sẵn: điền xong là chạy.
Làm theo thứ tự từ trên xuống — bước sau thường cần bước trước. Xong mục nào thì đánh dấu `[x]`.

Tổng quan nhanh:

| #   | Việc                                                              | Cần có                               | Thời gian |
| --- | ----------------------------------------------------------------- | ------------------------------------ | --------- |
| A   | Tài khoản Apple Developer: Team ID, App ID, khoá APNs             | Apple Developer Program (99 USD/năm) | 20 phút   |
| B   | Supabase: project, migration, Vault, Apple login, secrets, deploy | Tài khoản supabase.com               | 30 phút   |
| C   | Nối app với Supabase                                              | Kết quả của B                        | 5 phút    |
| D   | DeepSeek API key                                                  | Tài khoản platform.deepseek.com      | 5 phút    |
| E   | Kiểm thử trên máy thật, iOS 18, CI                                | iPhone, GitHub                       | 1 giờ     |
| F   | Quyết định sản phẩm                                               | —                                    | tuỳ bạn   |

---

## A. Apple Developer

### - [x] A1. Lấy Team ID và điền vào project

1. Vào [developer.apple.com/account](https://developer.apple.com/account) → **Membership details** → copy **Team ID** (10 ký tự, ví dụ `AB12CD34EF`).
2. Mở `project.yml`, sửa dòng:
   ```yaml
   DEVELOPMENT_TEAM: "AB12CD34EF"
   ```
3. Sinh lại project và mở Xcode:
   ```bash
   xcodegen && open Not3.xcodeproj
   ```
4. Trong Xcode chọn target **Not3** → **Signing & Capabilities**: phải thấy Team của bạn, không có lỗi đỏ. Xcode tự tạo App ID `com.tuandiep.not3` với **Push Notifications** và **Sign in with Apple** (đã khai báo sẵn trong `Not3/Resources/Not3.entitlements`).

> Muốn đổi bundle id (ví dụ `com.tenban.not3`): sửa `PRODUCT_BUNDLE_IDENTIFIER` trong `project.yml`, `APNS_BUNDLE_ID` ở bước B6 và Client ID ở bước B5 cho khớp.

### - [x] A2. Tạo khoá APNs (.p8)

1. [developer.apple.com/account/resources/authkeys/list](https://developer.apple.com/account/resources/authkeys/list) → nút **+**.
2. Đặt tên (ví dụ `Not3 APNs`), tick **Apple Push Notifications service (APNs)** → **Continue** → **Register**.
3. **Download** file `AuthKey_XXXXXXXXXX.p8`. Apple chỉ cho tải **một lần** — cất vào nơi an toàn, **không** để trong thư mục repo.
4. Ghi lại **Key ID** (10 ký tự, cũng là phần `XXXXXXXXXX` trong tên file).

Một khoá dùng được cho cả sandbox (build Debug) và production (TestFlight/App Store). App tự báo môi trường lên server khi đăng ký thiết bị.

---

## B. Supabase

Bạn sẽ ghi lại 4 giá trị trong phần này. Ghi tạm ra một chỗ an toàn (không phải repo):

| Giá trị | Ví dụ | Dùng ở |
| --- | --- | --- |
| Project ref | `abcdefghijklmnopqrst` | B2, B3, B6, C1 |
| Mật khẩu database | (do bạn đặt) | B2 |
| Publishable key | `sb_publishable_…` | C1 (app) |
| Secret key | `sb_secret_…` | B3 (Vault), lệnh `curl` kiểm tra |

> Supabase đang thay key cũ `anon` / `service_role` (dạng JWT `eyJ…`) bằng `sb_publishable_…` / `sb_secret_…` và bỏ key cũ trong năm 2026. Code đã hỗ trợ cả hai. Nếu project của bạn chỉ có key cũ thì dùng `anon` thay publishable, `service_role` thay secret.

### - [x] B1. Tạo project và lấy key

1. Vào [supabase.com/dashboard](https://supabase.com/dashboard) → đăng nhập (GitHub cũng được) → **New project**.
2. Điền:
   - **Organization**: tổ chức cá nhân của bạn (tạo mới nếu chưa có, chọn gói Free để bắt đầu).
   - **Project name**: `not3`.
   - **Database password**: bấm **Generate a password** rồi **copy lại ngay** — dùng ở B2.
   - **Region**: `Southeast Asia (Singapore)` (gần Việt Nam nhất).
3. **Create new project** → chờ 1–2 phút đến khi trạng thái là *Healthy*.
4. **Project ref**: chuỗi 20 ký tự trong URL trình duyệt `https://supabase.com/dashboard/project/<ref>/…`.
5. **Settings (bánh răng) → API Keys**:
   - **Publishable key** → copy (dùng cho app, an toàn để nằm trong app).
   - **Secret keys** → bấm **Reveal** → copy `sb_secret_…`. Key này bỏ qua mọi RLS: **không** đưa vào app, **không** commit, **không** dán vào chat.

> Gói Free tạm dừng project sau ~1 tuần không có request. Khi đang phát triển thì không sao (cron `tick` chạy mỗi 5 phút giữ project hoạt động); trước khi ra mắt nên lên gói Pro (README §14).

### - [x] B2. Liên kết CLI và chạy migration

Chạy trong thư mục gốc repo (`Not3/`):

```bash
supabase login                              # mở trình duyệt để cấp quyền cho CLI
supabase link --project-ref <ref>           # hỏi mật khẩu database ở B1
supabase db push                            # áp 3 file trong supabase/migrations/
```

`db push` liệt kê 3 migration và hỏi `Do you want to push these migrations? [Y/n]` → `Y`. Kết quả mong đợi:

```
Applying migration 20261101000000_init.sql...
Applying migration 20261101010000_evening_checkin.sql...
Applying migration 20261101020000_ai.sql...
Finished supabase db push.
```

Kiểm tra trên Dashboard:
- **Table Editor**: có `profiles`, `devices`, `notes`, `tasks`, `checkins`, `chips`, `external_items`, `suggestions`, `integrations`, `push_queue`, `ai_usage`, `weekly_summaries`. Mỗi bảng có nhãn **RLS enabled**.
- **Integrations → Cron → Jobs**: có `tick` (`*/5 * * * *`) và `cleanup` (`30 3 * * *`).

Nếu lỗi:
- **`extension "pg_cron" is not available` / permission denied**: **Database → Extensions** → bật **pg_cron** và **pg_net** → chạy lại `supabase db push` (migration lỗi không được ghi nhận nên chạy lại an toàn).
- **Lỗi khác**: SQL này chưa từng được chạy thử (máy chưa có Docker). Copy nguyên thông báo lỗi gửi lại để sửa.

### - [x] B3. Lưu URL và secret key vào Vault

Cron `tick` (chạy trong Postgres) và webhook gắn chip note cần URL + key để gọi Edge Functions. Chúng đọc từ Vault, nên key không nằm trong SQL.

**SQL Editor → New query** → dán (thay giá trị thật) → **Run**:

```sql
select vault.create_secret('https://<ref>.supabase.co', 'project_url');
select vault.create_secret('<sb_secret_… ở B1>', 'service_role_key');
```

Mỗi câu trả về một UUID là thành công. Tên `service_role_key` giữ nguyên dù bạn dùng key mới — code tìm theo tên này.

Nhập sai, muốn sửa:

```sql
select vault.update_secret(id, '<giá trị mới>') from vault.secrets where name = 'service_role_key';
```

Kiểm tra sau ~5 phút: **Integrations → Cron → tick → History** có các lần chạy *Succeeded*. Xem phản hồi HTTP thật ở bảng `net._http_response` (SQL: `select status_code, content from net._http_response order by created desc limit 5;`). Sẽ là `404` cho đến khi deploy function ở B6 — bình thường.

### - [x] B4. Điền secrets cho Edge Functions

```bash
cp supabase/.env.example supabase/.env      # nếu chưa có
```

Mở `supabase/.env`:

```bash
APNS_KEY_P8="-----BEGIN PRIVATE KEY-----\nMIGT...\n-----END PRIVATE KEY-----\n"
APNS_KEY_ID=XXXXXXXXXX          # Key ID ở A2
APNS_TEAM_ID=AB12CD34EF         # Team ID ở A1
APNS_BUNDLE_ID=com.tuandiep.not3
DEEPSEEK_API_KEY=               # bước D; để trống thì AI chạy bằng luật
DEEPSEEK_MODEL=                 # để trống = tự chọn model
DEEPSEEK_BASE_URL=https://api.deepseek.com
AI_DAILY_LIMIT=30
```

`APNS_KEY_P8` phải trên **một dòng**. In sẵn đúng định dạng từ file `.p8`:

```bash
awk 'NF {sub(/\r/, ""); printf "%s\\n", $0}' ~/Downloads/AuthKey_XXXXXXXXXX.p8; echo
```

**Không** thêm `SUPABASE_URL`, `SUPABASE_SECRET_KEYS`… vào file: Supabase tự cấp cho mọi function, và CLI từ chối tên bắt đầu bằng `SUPABASE_`.

Đẩy lên:

```bash
supabase secrets set --env-file supabase/.env
supabase secrets list
```

`secrets list` phải có `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` (+ `DEEPSEEK_API_KEY` nếu đã điền). Function đã deploy đọc secret mới ngay, không cần deploy lại. Xoá 2 dòng cũ `DEEPSEEK_MODEL_FLASH=` / `DEEPSEEK_MODEL_PRO=` nếu còn.

### - [x] B5. Bật đăng nhập Apple

1. **Authentication → Sign In / Providers** → **Apple** → bật **Enable Sign in with Apple**.
2. **Client IDs**: `com.tuandiep.not3` (đúng bundle id của app; nhiều id thì cách nhau bằng dấu phẩy).
3. Các ô **Secret Key (for OAuth)** / Team ID / Key ID: **để trống**. App đăng nhập native rồi gửi `id_token` cho Supabase (`signInWithIdToken`), không đi qua OAuth web.
4. **Save**.

Liên quan: **Authentication → URL Configuration** không cần sửa cho đăng nhập native.

### - [x] B6. Deploy Edge Functions và kiểm tra

```bash
supabase functions deploy tick send-push build-checkin tag-note weekly-summary ai-gateway
```

CLI đọc `supabase/config.toml`: 5 function gọi bằng key nội bộ có `verify_jwt = false` (tự kiểm tra key trong code); `ai-gateway` giữ kiểm tra JWT vì app gọi bằng phiên đăng nhập.

Kiểm tra trên Dashboard: **Edge Functions** liệt kê đủ 6 function.

Gọi thử `tick` (thay `<ref>`, `<sb_secret_…>`):

```bash
curl -s -X POST https://<ref>.supabase.co/functions/v1/tick \
  -H "apikey: <sb_secret_…>" -H "Content-Type: application/json" -d '{}'
```

| Kết quả | Ý nghĩa |
| --- | --- |
| `{"build":0,"checkin":0,"weekly":0,"push":200}` | Chạy đúng (chưa có người dùng tới giờ check-in) |
| `Forbidden` (403) | Key sai — dùng secret key, không phải publishable |
| `{"error":"…users_due…"}` | Migration chưa áp đủ — xem lại B2 |
| 404 | Function chưa deploy |

Xem log từng function: **Edge Functions → \<tên\> → Logs**. Sau B6, `net._http_response` ở B3 sẽ chuyển sang `200`.

---

## C. Nối app với Supabase

### - [x] C1. Điền cấu hình app

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
```

```
SUPABASE_HOST = <ref>.supabase.co
SUPABASE_ANON_KEY = <publishable key ở B1 (sb_publishable_…)>
```

Chỉ ghi host, **không** có `https://` (xcconfig coi `//` là chú thích). File đã gitignore.
Build lại (`⌘B`). Vào **Cài đặt** trong app: mục Tài khoản phải hiện nút **Sign in with Apple** thay vì "Chưa cấu hình Supabase".

### - [x] C2. Đăng nhập và kiểm tra đồng bộ

1. Chạy app trên **iPhone thật** (Sign in with Apple và push không chạy đầy đủ trên simulator).
2. Cài đặt → **Sign in with Apple**.
3. Làm một check-in → **Lưu kế hoạch**.
4. Trên Supabase **Table Editor**: `profiles` có 1 dòng với timezone của bạn; `devices` có `apns_token`; `checkins`, `tasks` có dữ liệu; `push_queue` có dòng `reminder` / `evening` cho task vừa tạo.

---

## D. DeepSeek

### - [x] D1. Lấy API key

1. [platform.deepseek.com](https://platform.deepseek.com) → đăng ký → **Top up** một ít credit (giá xem [pricing](https://api-docs.deepseek.com/quick_start/pricing)).
2. **API Keys → Create new API key** → copy `sk-...` (chỉ hiện một lần).
3. Điền `DEEPSEEK_API_KEY` trong `supabase/.env` rồi `supabase secrets set --env-file supabase/.env`.

Không cần điền tên model: server tự đọc `GET /models` (hiện là `deepseek-flash` cho tác vụ nhẹ, `deepseek-v4-pro` cho tổng kết tuần).

### - [x] D2. Thử AI thật

Các test hiện giả lập DeepSeek. Với key thật, thử lần lượt:

| Tính năng      | Cách thử                                                       | Kết quả mong đợi                                                 |
| -------------- | -------------------------------------------------------------- | ---------------------------------------------------------------- |
| Gắn chip note  | Tạo note "Từ vựng tiếng Anh tuần 45", chờ ~10 giây, mở lại app | Trình soạn hiện chip ✨ "Học ngôn ngữ"                           |
| Gợi ý check-in | Gọi tay `build-checkin` (lệnh dưới), rồi mở sheet check-in     | "Chiều nay làm gì?" có 3 việc cụ thể                             |
| Hỏi lịch sử    | Tổng kết tuần → "Tuần này mình xong mấy việc?"                 | Câu trả lời đúng số trong bảng `tasks`                           |
| Tổng kết tuần  | Gọi tay `weekly-summary` (lệnh dưới)                           | Bảng `weekly_summaries` có dòng `source = ai`; đọc lại giọng văn |

```bash
URL=https://<ref>.supabase.co/functions/v1; KEY=<sb_secret_…>; USER_ID=<user_id trong bảng profiles>
curl -s -X POST $URL/build-checkin -H "apikey: $KEY" -H "Content-Type: application/json" \
  -d "{\"users\":[{\"user_id\":\"$USER_ID\",\"local_day\":\"$(date +%F)\",\"timezone\":\"Asia/Ho_Chi_Minh\"}]}"
curl -s -X POST $URL/weekly-summary -H "apikey: $KEY" -H "Content-Type: application/json" \
  -d "{\"users\":[{\"user_id\":\"$USER_ID\",\"week_start\":\"<thứ Hai tuần này, YYYY-MM-DD>\",\"timezone\":\"Asia/Ho_Chi_Minh\"}]}"
```

`"via_ai": 1` trong kết quả `build-checkin` = AI đã chạy; `0` = đang dùng luật (xem **Logs** của function để biết lý do).

### - [ ] D3. Hạn mức AI

`AI_DAILY_LIMIT` (mặc định 30 lượt/người/ngày) trong `supabase/.env`. Mỗi check-in tốn 1 lượt, mỗi lần sửa note 1 lượt, mỗi câu hỏi 1 lượt, tổng kết tuần 1 lượt. Xem mức dùng ở bảng `ai_usage`.

### - [ ] D4. Chính sách dữ liệu

Đọc chính sách lưu trữ dữ liệu của DeepSeek. Khi nộp App Store, khai báo trong **App Store Connect → App Privacy**: tiêu đề note, chip, tiêu đề task được gửi tới bên thứ ba để xử lý AI; nội dung note chỉ khi người dùng bật "Đồng bộ nội dung note lên server".

---

## E. Kiểm thử cần môi trường

### - [ ] E1. Simulator iOS 18 (giao diện fallback)

Máy hiện chỉ có runtime iOS 27.

- Xcode → **Settings → Components** → **+** → chọn **iOS 18.x** (~8 GB); hoặc `xcodebuild -downloadPlatform iOS -buildVersion 18.6`.
- **Window → Devices and Simulators → Simulators → +** → iPhone 16, OS iOS 18.
- Chạy app trên simulator đó: chip, nút chính, thanh dưới phải hiện kiểu cũ (material), không lỗi.

### - [ ] E2. Nhập giọng nói tiếng Việt

Trên iPhone thật: sheet Check-in → chip **Nói** → nói "lúc 3 giờ chiều học tiếng Anh 25 phút" → **Xong**.
Mong đợi: chip "Học tiếng Anh" được chọn, giờ 15:00, 25 phút. Nếu máy chưa có tiếng Việt cho nhận dạng: **Cài đặt → Chung → Bàn phím → Đọc chính tả**, thêm Tiếng Việt.

### - [x] E3. CI — Xcode Cloud

Đã gỡ GitHub Actions; build/test chạy trên **Xcode Cloud** (workflow tạo trong Xcode, build khi push nhánh `release/*`).
Không cần biến môi trường; `ci_scripts/ci_post_clone.sh` tự chạy XcodeGen và chép `Config/Package.resolved`.

---

## G. Giai đoạn 3 — Tích hợp GitHub, Jira, Lịch, iCloud

Callback URL dùng chung cho cả GitHub và Jira:

```
https://lzeulkgzuhgznmcwoimr.supabase.co/functions/v1/oauth-callback
```

### - [x] G1. Đẩy migration + deploy function mới

```bash
supabase db push      # áp 20261101040000_integrations.sql
supabase functions deploy tick integrations oauth-callback sync-integrations
```

### - [x] G2. Tạo GitHub App (chỉ quyền đọc)

GitHub App cho phép chọn quyền **chỉ đọc** từng loại (OAuth App thường buộc xin `repo` = đọc + ghi).

1. GitHub → avatar → **Settings → Developer settings → GitHub Apps → New GitHub App**.
2. Điền:
   - **GitHub App name**: `Not3-<tên bạn>` (phải duy nhất toàn GitHub).
   - **Homepage URL**: `https://github.com/Tuandiep98/Not3`.
   - **Callback URL**: URL ở đầu mục G.
   - Tick **Expire user authorization tokens** (token 8 giờ + refresh token — server tự làm mới).
   - **Request user authorization (OAuth) during installation**: bỏ tick.
   - **Webhook → Active**: bỏ tick (webhook để giai đoạn sau).
3. **Permissions → Repository permissions** (tất cả **Read-only**): *Contents*, *Issues*, *Metadata*, *Pull requests*.
4. **Where can this GitHub App be installed?** → *Only on this account* → **Create GitHub App**.
5. Trang app vừa tạo: copy **Client ID**; **Generate a new client secret** → copy (chỉ hiện một lần).
6. **Install App** (menu trái) → cài vào tài khoản / org có repo bạn làm việc → chọn *All repositories* hoặc từng repo. Repo nào không cài thì app không đọc được PR / issue private của repo đó.

### - [x] G3. Tạo app Atlassian cho Jira (OAuth 2.0 3LO)

1. [developer.atlassian.com/console/myapps](https://developer.atlassian.com/console/myapps/) → **Create → OAuth 2.0 integration** → đặt tên `Not3` → đồng ý điều khoản → **Create**.
2. **Permissions → Jira API → Add**, rồi **Configure** → **Edit Scopes** (Classic scopes): tick `read:jira-work` và `read:jira-user` → **Save**.
3. **Authorization → OAuth 2.0 (3LO) → Configure** → **Callback URL**: URL ở đầu mục G → **Save changes**.
4. **Settings**: copy **Client ID** và **Secret**.
5. App ở trạng thái *development* chỉ dùng được với tài khoản của bạn — đủ cho bản cá nhân. Muốn người khác dùng: **Distribution → Sharing** (cần khai báo chính sách dữ liệu).

### - [x] G4. Điền secrets

Thêm vào `supabase/.env`:

```bash
GITHUB_CLIENT_ID=Iv23...
GITHUB_CLIENT_SECRET=...
JIRA_CLIENT_ID=...
JIRA_CLIENT_SECRET=...
```

```bash
supabase secrets set --env-file supabase/.env
```

Chưa điền provider nào thì nút **Kết nối** của provider đó hiện "Chưa cấu hình" — phần còn lại vẫn chạy.

### - [ ] G6. Sửa `supabase/.env` (deploy đang lỗi `failed to parse environment file`)

- `APNS_KEY_P8` phải trên **một dòng**: thay khối nhiều dòng bằng kết quả của
  `echo "APNS_KEY_P8=\"$(awk 'NF {sub(/\r/, ""); printf "%s\\n", $0}' ~/Downloads/AuthKey_XXXXXXXXXX.p8)\""`
- Xoá dòng lạ 2 ký tự giữa `AI_DAILY_LIMIT` và `GITHUB_CLIENT_ID`.
- Kiểm tra: `supabase functions deploy tick` không còn lỗi. Không cần `secrets set` lại.

### - [ ] G7. Bật webhook GitHub (tuỳ chọn — cập nhật gần như tức thì)

Không bật thì PR / issue vẫn được cập nhật mỗi 15 phút (08:00–20:00) và lúc 02:00 đối soát lại.

1. Tạo secret ngẫu nhiên (giữ riêng, không dán vào chat): `openssl rand -hex 32`
2. Thêm vào `supabase/.env`: `GITHUB_WEBHOOK_SECRET=<chuỗi vừa tạo>` → `supabase secrets set --env-file supabase/.env`
   (hoặc riêng lẻ: `supabase secrets set GITHUB_WEBHOOK_SECRET=<chuỗi>`).
3. GitHub → Settings → Developer settings → GitHub Apps → app Not3 → **General** → **Webhook**:
   - ✅ **Active**
   - **Webhook URL**: `https://lzeulkgzuhgznmcwoimr.supabase.co/functions/v1/webhook-github`
   - **Webhook secret**: chuỗi ở bước 1 → **Save changes**.
4. **Permissions & events → Subscribe to events**: tick **Issues** và **Pull request** → **Save changes**.
   GitHub có thể yêu cầu bạn chấp nhận lại quyền ở trang cài đặt app.
5. Kiểm tra: app Not3 trên GitHub → **Advanced → Recent Deliveries**: các lần gửi có mã **200**.
   `401` = secret không khớp; `503` = chưa đặt `GITHUB_WEBHOOK_SECRET` trên Supabase.

### - [ ] G8. (Tuỳ chọn) Quyền thêm cho Build / Deploy

Chỉ cần nếu bật **Build GitHub Actions** hoặc **Deploy** trong Cài đặt → GitHub.
GitHub → Settings → Developer settings → GitHub Apps → app Not3 → **Permissions & events → Repository permissions**:
**Actions: Read-only**, **Deployments: Read-only** → Save. GitHub gửi yêu cầu chấp nhận quyền mới tới nơi app được cài
(github.com/settings/installations → Not3 → **Review request** → Accept; repo của org thì owner duyệt).
Nếu đã bật webhook (G7): tick thêm sự kiện **Workflow run**, **Deployment status**, **Pull request review**, **Release**.

### - [ ] G9. Cho tài khoản Jira khác đăng nhập (app Atlassian đang ở chế độ Development)

Lỗi "you don't have access to this app, this app is in development…" = chỉ owner app mới đăng nhập được.
1. developer.atlassian.com/console/myapps → **Not3** → **Distribution** → **Edit** → **Sharing**.
2. Điền **Vendor name**, **Privacy policy URL** (bắt buộc — cần một trang công khai), **Does your app store personal data? → Yes**
   (Not3 lưu accountId Jira + tiêu đề ticket) → **Save changes**.
3. Trước khi phát hành rộng: Not3 cần báo cáo accountId đang lưu qua **Personal Data Reporting API** (≤ 7 ngày / lần)
   và xoá dữ liệu tài khoản đã đóng — chưa làm (ghi ở README §17).
Tài khoản thuộc tổ chức chặn app bên thứ ba vẫn cần admin cho phép.

### - [ ] G10. Bật webhook Jira (cập nhật gần như tức thì)

Code + function `webhook-jira` đã deploy. Chỉ thiếu quyền tạo webhook trong app Atlassian:

1. [developer.atlassian.com/console/myapps](https://developer.atlassian.com/console/myapps/) → **Not3** → **Permissions → Jira API → Configure → Edit Scopes** (Classic scopes).
2. Tick thêm **`manage:jira-webhook`** (Manage Jira webhooks) → **Save**. **Làm bước này trước khi kết nối lại**: server giờ xin cả scope này, app Atlassian chưa có thì màn đăng nhập Jira báo lỗi scope.
3. Trong app Not3: **Cài đặt → Jira → Ngắt kết nối**, rồi **Kết nối** lại và đồng ý quyền mới.
4. Kiểm tra: **Cài đặt → Jira** có dòng ⚡ "Cập nhật tức thì đang bật". Đổi trạng thái một ticket được giao cho bạn → trong ~vài giây task trong app đổi theo (nếu app ở nền: qua silent push).

Ghi chú:
- Không cần secret mới: Jira ký webhook bằng **Client secret** (`JIRA_CLIENT_SECRET`) đã có.
- Webhook chỉ phủ ticket bạn được giao / bạn tạo. "Theo dõi", "chuyển trạng thái", "log work" vẫn đi qua poll 15 phút.
- App Atlassian ở chế độ Development: Jira chỉ gửi webhook cho tài khoản **owner** của app (là bạn). Người khác cần G9 trước.
- Nếu dòng trong Cài đặt báo lỗi: gửi nguyên văn cho mình; xem thêm log function `webhook-jira` trên Supabase Dashboard.

### - [ ] G5. Thử trên iPhone

Build lại app lên máy (bản mới có quyền iCloud + Lịch), rồi:

| Thử | Mong đợi |
| --- | --- |
| Cài đặt → Lịch iOS → **Cấp quyền** | "Đã cấp quyền"; Hôm nay → *Buổi sáng* hiện các sự kiện lịch hôm nay |
| Check-in → chọn việc + giờ, bật **Thêm vào Lịch** → Lưu | App Lịch có lịch **Not3** với sự kiện đúng giờ |
| Trong app Lịch, kéo sự kiện đó sang giờ khác | Mở Not3: task đổi giờ theo, nhắc giờ dời theo |
| Xoá sự kiện đó trong app Lịch | Task chuyển "Đã huỷ" |
| Cài đặt → GitHub → **Kết nối** → đăng nhập → quay về app | Dòng GitHub hiện tên tài khoản + "Đồng bộ lần cuối …"; *Buổi sáng* có PR / commit hôm nay (chạm để mở) |
| Tương tự với Jira | Ticket cập nhật hôm nay, ticket Done hiện "JIRA-xxx → Done" |
| Tạo note trên iPhone, mở Not3 trên máy khác cùng Apple ID | Note xuất hiện (iCloud, có thể chậm vài phút) |
| Check-in → "Khác…" → gõ `Review PR #<số PR đang mở>` → Lưu; merge PR đó trên GitHub → **Đồng bộ ngay** | Task có nhãn 🔗 PR, tự gạch "xong", có push "Đã đánh dấu xong" |
| Task không có mã, ví dụ "Viết test module login", và có PR "Add login tests" hôm nay → Đồng bộ ngay | Dưới task hiện "Liên kết với PR …? Có / Không" (hoặc tự liên kết nếu AI chắc chắn) |
| PR đang mở / được nhờ review hôm nay, chưa có task | Hôm nay → **Mới đồng bộ**: chip Thành việc / Thành ghi chú / Bỏ qua / Luôn bỏ qua loại này |
| Chạm **Thành việc** | Task mới (nhãn 🔗) ở Buổi chiều, mục biến khỏi hộp; merge PR → task tự xong |
| Thư mục **Nhật ký** | Note "Nhật ký d/m": dòng "Hôm nay: …" tóm tắt, rồi SÁNG / CHIỀU (✓ việc xong, ◷ cuộc họp, • GitHub / Jira); tự gõ thêm ngoài khối "— Not3 tự ghi —" thì vẫn giữ sau lần cập nhật sau |

Lần đầu mở bản mới, dữ liệu cũ được chuyển sang kho mới một lần (file cũ giữ lại thành `default.store.migrated`). Nếu thấy thiếu note / task sau khi cập nhật: báo ngay, đừng xoá app.

## H. Widget

### - [ ] H1. Thêm widget trên iPhone

Nhấn giữ màn hình chính → **Sửa** → **Thêm tiện ích** → tìm **Not3** → chọn:
**Check-in** (vừa), **Việc hôm nay** (nhỏ / vừa / lớn), **Tuần này** (nhỏ), **Thư mục ghi chú** (vừa — nhấn giữ widget → *Sửa tiện ích* để chọn thư mục).
Màn hình khoá: nhấn giữ → **Tuỳ chỉnh** → Màn hình khoá → thêm **Check-in** (chữ nhật / dòng) và **Tuần này** (tròn).

Thử: tích một việc trên widget → mở app, việc đã xong; chọn cảm nhận trên widget lúc check-in → app ghi nhận; merge PR liên kết → widget tự cập nhật (silent push, có thể trễ vài phút; iOS tự điều tiết).
Nếu widget trống: mở app một lần để app ghi dữ liệu cho widget.

## I. Hộp chờ & việc lặp lại

### - [ ] I1. Đẩy migration

```bash
supabase db push      # áp 20261104000000_backlog_recurrence.sql (tasks.someday, tasks.series_id, bảng task_series)
```

Cần chạy **trước** khi cài bản app mới. Nếu chưa chạy, app vẫn dùng bình thường trên máy nhưng đồng bộ task lên Supabase sẽ lỗi: thiếu cột `someday` / `series_id`, lỗi hiện ở Cài đặt → "Đồng bộ lần cuối".

Thử:
- Hôm nay → **+** → tạo việc "Ngày thường" lúc 9:00 → sáng hôm sau có việc mới. Lần trước chưa xong thì tự huỷ.
- Vuốt một việc → **Hộp chờ** → việc biến mất khỏi Hôm nay và widget, hiện ở Thư mục → Hộp chờ. Lúc check-in, việc này nằm trong "Gợi ý".
- Cài đặt → **Việc lặp lại**: tắt để dừng tạo việc mới.

## J. Siri, Phím tắt, Control Center, Spotlight

### - [ ] J1. Thử trên máy

- **Siri (tiếng Anh):** "Add a task in Not3", "What's left today in Not3", "Start my next task in Not3", "Complete *tên việc* in Not3", "Quick note in Not3", "Check in with Not3". Lần đầu sau khi cài, mở app một lần để Siri học tên việc.
- **Phím tắt:** app Phím tắt → Not3 có sẵn các thao tác. Gán "Thêm việc" cho **nút Action**: Cài đặt → Nút Tác vụ → Phím tắt.
- **Control Center:** vuốt xuống → **+** → Thêm điều khiển → Not3 → *Thêm việc*, *Check-in*, *Việc tiếp theo*. Màn hình khoá: dùng được ở 2 ô dưới cùng.
- **Spotlight:** vuốt xuống ở màn hình chính, gõ tiêu đề một ghi chú hoặc một việc.

Lưu ý: app có thêm bản địa hoá `en` (chỉ chứa câu lệnh Siri). Nếu ngôn ngữ iPhone là tiếng Anh, một vài chữ của hệ thống trong app (nút trong DatePicker…) có thể hiện tiếng Anh.

## K. Ảnh trong ghi chú & Share Extension

### - [ ] K1. Deploy schema CloudKit

Ghi chú có thêm bảng ảnh (`NoteAttachment`). Sau khi chạy bản mới **một lần trên máy thật cài từ Xcode** (môi trường Development):
[CloudKit Console](https://icloud.developer.apple.com) → container `iCloud.com.tuandiep.not3` → **Schema** → **Deploy Schema Changes…** sang **Production**. Bản TestFlight / App Store dùng Production: nếu chưa deploy, ảnh không đồng bộ giữa các máy (ghi chú vẫn đồng bộ).

### - [ ] K2. App ID cho Share Extension

Target mới `Not3Share` (`com.tuandiep.not3.share`) cần App Group `group.com.tuandiep.not3`. Với ký tự động, Xcode tự tạo App ID khi build lần đầu trên Mac. Nếu Xcode Cloud báo lỗi provisioning cho `com.tuandiep.not3.share`: [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list) → Identifiers → **+** → App IDs → `com.tuandiep.not3.share` → bật **App Groups** → chọn `group.com.tuandiep.not3`.

Thử: Safari mở một PR → Chia sẻ → **Not3** → chọn *Việc* → mở Not3, việc có logo GitHub. Ảnh → Chia sẻ → Not3 → *Ghi chú* → ghi chú có ảnh. Nếu không thấy Not3 trong bảng chia sẻ: kéo hàng app sang phải → **Thêm** → bật Not3.

## L. Thẻ hợp nhất PR ↔ ticket

### - [ ] L1. Migration + deploy

```bash
supabase db push                       # 20261104010000_cards.sql (bảng cards)
supabase functions deploy sync-integrations poll-active webhook-github webhook-jira tick
```

(Deploy mọi function có dùng `_shared/integrations.ts` / `reconcile.ts`. Chắc ăn nhất là `supabase functions deploy` để deploy tất cả.)

Thử: một việc có liên kết ticket Jira `ABC-1`, rồi mở một PR có tiêu đề chứa `ABC-1` → sau lần đồng bộ tiếp theo, dưới việc có dòng tóm tắt; logo GitHub + Jira chạm vào ra danh sách từng mục.

## F. Quyết định sản phẩm (còn mở trong doc kế hoạch)

- [ ] **F1. Kiếm tiền**: miễn phí + gói Pro (tích hợp, tổng kết AI) hay trả một lần? Ảnh hưởng tới giai đoạn 4 (StoreKit, giới hạn tính năng).
- [ ] **F2. Giờ hỏi lại buổi tối**: đang là 21:00, hoặc 15 phút sau khi việc kết thúc nếu muộn hơn. Muốn đổi: báo giờ mới — cần sửa 2 chỗ khớp nhau: `NotificationService.eveningTime` (app) và hàm `queue_task_reminder` (migration mới).
- [x] **F3. App icon**: đã dùng ảnh "Glossy Yellow Notes" — `Not3/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`. Đổi icon: `python3 scripts/make_app_icon.py <ảnh.png> Not3/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png preview.png`.
