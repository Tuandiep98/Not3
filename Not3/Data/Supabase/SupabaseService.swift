import CryptoKit
import Foundation
import Observation
import Supabase
import SwiftData

/// Supabase client wrapper. The app runs fully local when Config/Secrets.xcconfig is missing.
@MainActor
@Observable
final class SupabaseService {
    static let shared = SupabaseService()

    private(set) var client: SupabaseClient?
    private(set) var userId: UUID?
    private(set) var email: String?
    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    /// True once the server has delivered at least one push to this device. Until then the app keeps
    /// its on-device notifications, so a broken APNs setup (wrong key environment…) never leaves
    /// the user with no reminders at all.
    private(set) var hasServerPush = false

    /// Last full refresh (foreground pass or the ↻ button on "Hôm nay").
    private(set) var lastRefreshAt: Date? = UserDefaults.standard.object(forKey: "lastRefreshAt") as? Date

    func markRefreshed(at date: Date = Date()) {
        lastRefreshAt = date
        UserDefaults.standard.set(date, forKey: "lastRefreshAt")
    }

    var isConfigured: Bool { client != nil }
    var isSignedIn: Bool { userId != nil }

    private var pendingDeviceToken: String?

    private init() {
        let info = Bundle.main.infoDictionary
        let host = (info?["SupabaseHost"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = (info?["SupabaseAnonKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !host.isEmpty, !key.isEmpty, let url = URL(string: "https://\(host)") else { return }
        client = SupabaseClient(supabaseURL: url, supabaseKey: key)
    }

    // MARK: Auth

    func restoreSession() async {
        guard let client else { return }
        if let session = try? await client.auth.session {
            userId = session.user.id
            email = session.user.email
        }
    }

    /// Nonce pair for Sign in with Apple: send `hashed` to Apple, `raw` to Supabase.
    static func makeNonce() -> (raw: String, hashed: String) {
        let raw = UUID().uuidString + UUID().uuidString
        let hashed = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return (raw, hashed)
    }

    func signInWithApple(idToken: String, rawNonce: String) async throws {
        guard let client else { throw ServiceError.notConfigured }
        let session = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: rawNonce)
        )
        userId = session.user.id
        email = session.user.email
        await upsertProfile()
        if let token = pendingDeviceToken { await registerDevice(token: token) }
    }

    func signOut() async {
        try? await client?.auth.signOut()
        userId = nil
        email = nil
        hasServerPush = false
    }

    /// Calls the `delete_account` RPC (deletes the auth user + all rows via cascade).
    func deleteAccount() async throws {
        guard let client else { throw ServiceError.notConfigured }
        try await client.rpc("delete_account").execute()
        await signOut()
    }

    // MARK: Profile & devices

    func upsertProfile() async {
        guard let client, let userId else { return }
        let row = ProfileRecord(
            userId: userId,
            timezone: TimeZone.current.identifier,
            checkinHour: AppSettings.checkInHour,
            checkinMinute: AppSettings.checkInMinute,
            aiNotesEnabled: UserDefaults.standard.bool(forKey: SettingsKey.aiReadsIntegrations),
            syncNoteContent: AppSettings.syncNoteContent,
            eveningCheckin: UserDefaults.standard.bool(forKey: SettingsKey.eveningCheckIn)
        )
        do {
            try await client.from("profiles").upsert(row, onConflict: "user_id").execute()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func registerDevice(token: String) async {
        pendingDeviceToken = token
        guard let client, let userId else { return }
        do {
            try await client.from("devices")
                .upsert(DeviceRecord(userId: userId, apnsToken: token, environment: Self.apnsEnvironment), onConflict: "apns_token")
                .execute()
            let rows: [DeviceDeliveryRecord] = try await client.from("devices")
                .select("last_sent_at")
                .eq("apns_token", value: token)
                .limit(1)
                .execute()
                .value
            let delivered = rows.first?.lastSentAt != nil
            if delivered != hasServerPush {
                hasServerPush = delivered
                // The token usually arrives after the launch pass already scheduled local check-ins.
                await NotificationService.rescheduleCheckIns(in: Persistence.shared.mainContext, serverPushActive: delivered)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// APNs environment of the token this build receives. It follows the provisioning profile, not the
    /// build configuration: Xcode-installed builds (development profile, Debug or Release) get sandbox
    /// tokens; TestFlight / App Store builds have no embedded profile and get production tokens.
    nonisolated static var apnsEnvironment: String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return "production" }
        // The profile is a signed CMS blob with the plist stored as plain text inside.
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "<key>aps-environment</key>"),
              let start = text.range(of: "<string>", range: key.upperBound..<text.endIndex),
              let end = text.range(of: "</string>", range: start.upperBound..<text.endIndex) else { return "production" }
        return text[start.upperBound..<end.lowerBound] == "development" ? "sandbox" : "production"
    }

    // MARK: Sync (SwiftData first, push pending rows when online)

    func syncPending(_ context: ModelContext) async {
        guard let client, let userId, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.needsSync }))
            if !tasks.isEmpty {
                try await client.from("tasks").upsert(tasks.map { TaskRecord($0, userId: userId) }).execute()
                tasks.forEach { $0.needsSync = false }
            }
            let checkIns = try context.fetch(FetchDescriptor<CheckIn>(predicate: #Predicate { $0.needsSync }))
            if !checkIns.isEmpty {
                try await client.from("checkins")
                    .upsert(checkIns.map { CheckInRecord($0, userId: userId) }, onConflict: "user_id,day")
                    .execute()
                checkIns.forEach { $0.needsSync = false }
            }
            let notes = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.needsSync }))
            if !notes.isEmpty {
                let includeBody = AppSettings.syncNoteContent
                try await client.from("notes")
                    .upsert(notes.map { NoteRecord($0, userId: userId, includeBody: includeBody) })
                    .execute()
                notes.forEach { $0.needsSync = false }
            }
            try context.save()
            lastSyncAt = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Suggestions

    /// New suggestions for a local day (empty when offline / signed out → local rules apply).
    func fetchSuggestions(day: Date) async -> [SuggestionRecord] {
        guard let client, userId != nil else { return [] }
        do {
            return try await client.from("suggestions")
                .select("id, kind, payload")
                .eq("day", value: DayClock.isoDay(day))
                .eq("status", value: "new")
                .execute()
                .value
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    /// Learning signal: which suggestions were tapped and which were ignored.
    func markSuggestions(picked: [UUID], dismissed: [UUID]) async {
        guard let client, userId != nil else { return }
        for (ids, status) in [(picked, "picked"), (dismissed, "dismissed")] where !ids.isEmpty {
            do {
                try await client.from("suggestions")
                    .update(StatusUpdate(status: status))
                    .in("id", values: ids.map(\.uuidString))
                    .execute()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: AI (phase 2)

    /// Summary written by `weekly-summary` on Sunday 20:00 for the week starting `weekStart`.
    func fetchWeeklySummary(weekStart: Date) async -> WeeklySummaryRecord? {
        guard let client, userId != nil else { return nil }
        do {
            let rows: [WeeklySummaryRecord] = try await client.from("weekly_summaries")
                .select("summary, source, created_at")
                .eq("week_start", value: DayClock.isoDay(weekStart))
                .limit(1)
                .execute()
                .value
            return rows.first
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// "Hỏi đáp lịch sử" — answered by `ai-gateway` using tools over the user's own rows.
    func ask(_ question: String) async throws -> String {
        guard let client else { throw ServiceError.notConfigured }
        guard userId != nil else { throw ServiceError.signedOut }
        let response: AskResponse = try await client.functions.invoke(
            "ai-gateway",
            options: FunctionInvokeOptions(body: AskRequest(question: question, timezone: TimeZone.current.identifier))
        )
        if let answer = response.answer, !answer.isEmpty { return answer }
        throw ServiceError.message(response.error ?? "AI chưa trả lời được.")
    }

    /// Pulls chips suggested by `tag-note` into `Note.suggestedCategories` (user taps to accept).
    func pullNoteSuggestions(_ context: ModelContext) async {
        guard let client, userId != nil else { return }
        let key = "lastNoteSuggestionPull"
        let since = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        let now = Date()
        do {
            let rows: [NoteAIChipsRecord] = try await client.from("notes")
                .select("id, ai_chips")
                .gt("ai_tagged_at", value: since.ISO8601Format())
                .execute()
                .value
            guard !rows.isEmpty else {
                UserDefaults.standard.set(now, forKey: key)
                return
            }
            let byId = Dictionary(rows.map { ($0.id, $0.aiChips) }, uniquingKeysWith: { $1 })
            let notes = try context.fetch(FetchDescriptor<Note>())
            for note in notes {
                guard let chips = byId[note.id] else { continue }
                note.suggestedCategories = chips.filter { !note.categories.contains($0) }
            }
            try context.save()
            UserDefaults.standard.set(now, forKey: key)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Integrations (phase 3)

    private(set) var integrations: [IntegrationRecord] = []
    private(set) var providersReady = ProvidersStatus(github: false, jira: false)

    #if DEBUG
    /// Simulator screenshots of Settings without real connections (`-fakeIntegrations`).
    private var fakeIntegrations = false
    func useFakeIntegrations() {
        fakeIntegrations = true
        providersReady = ProvidersStatus(github: true, jira: true)
        integrations = [
            IntegrationRecord(provider: "github", accountName: "tuandiep98", lastSyncedAt: Date().addingTimeInterval(-600), lastError: nil),
            IntegrationRecord(provider: "jira", accountName: "not3-team", lastSyncedAt: nil,
                              lastError: "Jira 401: Unauthorized; scope does not match"),
        ]
    }
    #endif

    func refreshIntegrations() async {
        #if DEBUG
        if fakeIntegrations { return }
        #endif
        guard let client, userId != nil else { integrations = []; return }
        do {
            integrations = try await client.from("integrations")
                .select("provider, account_name, last_synced_at, last_error, settings, done_rules, meta")
                .execute()
                .value
            providersReady = try await client.functions.invoke(
                "integrations", options: FunctionInvokeOptions(body: IntegrationsRequest(action: "status"))
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Settings → GitHub / Jira toggles (RLS: the app may update only this column of its own rows).
    func updateIntegrationSettings(_ provider: ExternalSource, settings: [String: Bool]) async {
        guard let client, userId != nil else { return }
        do {
            try await client.from("integrations")
                .update(IntegrationSettingsUpdate(settings: settings))
                .eq("provider", value: provider.rawValue)
                .execute()
            await refreshIntegrations()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// "Tính là hoàn thành" rules for one integration.
    func updateDoneRules(_ provider: ExternalSource, rules: DoneRules) async {
        guard let client, userId != nil else { return }
        do {
            try await client.from("integrations")
                .update(DoneRulesUpdate(doneRules: rules))
                .eq("provider", value: provider.rawValue)
                .execute()
            await refreshIntegrations()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The user's Jira statuses (all visible projects), for the done-status picker.
    func jiraStatuses() async throws -> [JiraStatus] {
        guard let client else { throw ServiceError.notConfigured }
        let response: JiraStatusesResponse = try await client.functions.invoke(
            "integrations", options: FunctionInvokeOptions(body: IntegrationsRequest(action: "jira_statuses"))
        )
        if response.statuses.isEmpty, let error = response.error { throw ServiceError.message(error) }
        return response.statuses
    }

    /// Server builds the provider's authorize URL (state stored server-side).
    func connectURL(provider: ExternalSource) async throws -> URL {
        guard let client else { throw ServiceError.notConfigured }
        guard userId != nil else { throw ServiceError.signedOut }
        let response: ConnectResponse = try await client.functions.invoke(
            "integrations",
            options: FunctionInvokeOptions(body: IntegrationsRequest(action: "connect", provider: provider.rawValue))
        )
        guard let string = response.url, let url = URL(string: string) else {
            throw ServiceError.message(response.error ?? "Không mở được trang kết nối.")
        }
        return url
    }

    func disconnect(provider: ExternalSource, context: ModelContext) async throws {
        guard let client else { throw ServiceError.notConfigured }
        try await client.rpc("disconnect_integration", params: DisconnectParams(pProvider: provider.rawValue)).execute()
        let raw = provider.rawValue
        try? context.delete(model: ExternalItem.self, where: #Predicate { $0.sourceRaw == raw })
        await refreshIntegrations()
    }

    /// "Đồng bộ ngay": server pulls GitHub/Jira, then the app pulls today's items.
    func syncIntegrationsNow(_ context: ModelContext) async {
        guard let client, userId != nil else { return }
        do {
            try await client.functions.invoke(
                "integrations",
                options: FunctionInvokeOptions(body: IntegrationsRequest(action: "sync", timezone: TimeZone.current.identifier))
            )
        } catch {
            lastError = error.localizedDescription
        }
        await pullExternalItems(context)
        await refreshIntegrations()
    }

    /// GitHub / Jira items from the server → local ExternalItem: everything from today (morning,
    /// journal, chips) plus older items still waiting for a decision ("Chưa phân loại").
    func pullExternalItems(_ context: ModelContext) async {
        guard let client, userId != nil else { return }
        let start = DayClock.startOfDay()
        do {
            let rows: [ExternalItemRecord] = try await client.from("external_items")
                .select("source, external_id, title, url, status, kind, occurred_at, decision, role, scope")
                .in("source", values: ["github", "jira"])
                .or("occurred_at.gte.\(start.ISO8601Format()),and(decision.is.null,status.in.(open,review_requested,todo,in_progress))")
                .order("occurred_at", ascending: false)
                .limit(300)
                .execute()
                .value
            let calendar = ExternalSource.calendar.rawValue
            let local = try context.fetch(FetchDescriptor<ExternalItem>(predicate: #Predicate {
                $0.sourceRaw != calendar
            }))
            var byKey = Dictionary(local.map { ("\($0.sourceRaw)|\($0.externalId)", $0) }, uniquingKeysWith: { a, _ in a })
            for row in rows {
                guard let source = ExternalSource(rawValue: row.source) else { continue }
                let key = "\(row.source)|\(row.externalId)"
                let item = byKey.removeValue(forKey: key)
                    ?? ExternalItem(source: source, externalId: row.externalId, title: row.title, url: row.url, occurredAt: row.occurredAt)
                if item.modelContext == nil { context.insert(item) }
                item.title = row.title
                item.url = row.url
                item.status = row.status
                item.kind = row.kind
                item.decision = row.decision
                item.role = row.role
                item.scope = row.scope
                item.occurredAt = row.occurredAt
            }
            // Anything the server no longer lists (old and resolved) is dropped locally.
            byKey.values.forEach(context.delete)
            try context.save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: "Mới đồng bộ" inbox

    private(set) var ignoreRules: Set<String> = []   // "provider|kind|scope" ("" scope = whole kind)

    func pullContentRules() async {
        guard let client, userId != nil else { return }
        do {
            let rows: [ContentRuleRecord] = try await client.from("content_rules").select("provider, kind, scope, action").execute().value
            ignoreRules = Set(rows.filter { $0.action == "ignore" }.map { "\($0.provider)|\($0.kind)|\($0.scope)" })
        } catch {
            lastError = error.localizedDescription
        }
    }

    func isIgnored(_ item: ExternalItem) -> Bool {
        let base = "\(item.sourceRaw)|\(item.kind ?? "")|"
        return ignoreRules.contains(base) || ignoreRules.contains(base + (item.scope ?? ""))
    }

    enum InboxDecision: String { case task, note, ignored }

    /// Thành việc / Thành ghi chú / Bỏ qua — local first, then the server row.
    func decide(_ item: ExternalItem, _ decision: InboxDecision, context: ModelContext) async {
        item.decision = decision.rawValue
        switch decision {
        case .task:
            let task = TaskItem(title: item.title, category: ChipCatalog.workCategory, plannedAt: nil,
                                durationMinutes: nil, source: .integration)
            context.insert(task)
            await attach(task, to: item, context: context)
        case .note:
            let folderName = "Ghi chú nhanh"
            let folder = try? context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.name == folderName })).first
            let note = Note(folder: folder)
            note.title = item.title
            note.body = item.url ?? ""
            note.categories = [ChipCatalog.workCategory]
            context.insert(note)
        case .ignored:
            break
        }
        try? context.save()
        await saveDecision(decision, for: [item])
    }

    /// Links a task to a synced item: its status then follows GitHub / Jira, and the item is marked
    /// "task" so the server does not auto-create a second task for it.
    func attach(_ task: TaskItem, to item: ExternalItem, context: ModelContext) async {
        task.linkTitle = item.title
        task.linkURL = item.url
        item.decision = InboxDecision.task.rawValue
        try? context.save()
        await syncPending(context)   // the task row must exist before the link (foreign key)
        if let client, let userId {
            try? await client.from("task_links").upsert(
                ManualLinkRecord(userId: userId, taskId: task.id, provider: item.sourceRaw,
                                 externalId: item.externalId, url: item.url, title: item.title),
                onConflict: "task_id,provider,external_id"
            ).execute()
        }
        await saveDecision(.task, for: [item])
    }

    /// "Luôn bỏ qua": a rule for provider + kind, optionally only this repo / project.
    func alwaysIgnore(like item: ExternalItem, onlyThisScope: Bool, context: ModelContext) async {
        let source = item.sourceRaw
        let kind = item.kind ?? ""
        let scope = onlyThisScope ? (item.scope ?? "") : ""
        ignoreRules.insert("\(source)|\(kind)|\(scope)")
        let matching = ((try? context.fetch(FetchDescriptor<ExternalItem>(predicate: #Predicate {
            $0.sourceRaw == source && $0.decision == nil
        }))) ?? []).filter { ($0.kind ?? "") == kind && (scope.isEmpty || $0.scope == scope) }
        matching.forEach { $0.decision = InboxDecision.ignored.rawValue }
        try? context.save()
        guard let client, let userId else { return }
        do {
            try await client.from("content_rules")
                .upsert(ContentRuleRecord(userId: userId, provider: source, kind: kind, scope: scope),
                        onConflict: "user_id,provider,kind,scope")
                .execute()
        } catch {
            lastError = error.localizedDescription
        }
        await saveDecision(.ignored, for: matching)
    }

    private func saveDecision(_ decision: InboxDecision, for items: [ExternalItem]) async {
        guard let client, userId != nil else { return }
        for item in items {
            try? await client.from("external_items")
                .update(DecisionUpdate(decision: decision.rawValue))
                .eq("source", value: item.sourceRaw)
                .eq("external_id", value: item.externalId)
                .execute()
        }
    }

    // MARK: Task status from integrations (PR merged → task done)

    /// Applies status changes the server made from GitHub / Jira, and adds tasks the server created
    /// by auto-classification. A newer local edit wins.
    func pullTaskUpdates(_ context: ModelContext) async {
        guard let client, userId != nil else { return }
        let key = "lastTaskSyncPull"
        let since = UserDefaults.standard.object(forKey: key) as? Date ?? Date().addingTimeInterval(-7 * 86_400)
        do {
            let rows: [TaskStatusRecord] = try await client.from("tasks")
                .select("id, title, chips, status, source, planned_at, duration_minutes, completed_at, created_at, updated_at, reopened_at, reopened_reason")
                .eq("updated_by", value: "sync")
                .gt("updated_at", value: since.ISO8601Format())
                .execute()
                .value
            var newest = since
            for row in rows {
                newest = max(newest, row.updatedAt)
                // Created on the server by auto-classification (review request, assigned ticket…).
                if TaskActions.task(id: row.id, in: context) == nil {
                    let task = TaskItem(title: row.title, category: row.chips.first, plannedAt: row.plannedAt,
                                        durationMinutes: row.durationMinutes,
                                        source: TaskSource(rawValue: row.source) ?? .integration)
                    task.id = row.id
                    task.statusRaw = row.status
                    task.completedAt = row.completedAt
                    task.createdAt = row.createdAt
                    task.updatedAt = row.updatedAt
                    task.needsSync = false
                    context.insert(task)
                    continue
                }
                guard let task = TaskActions.task(id: row.id, in: context),
                      task.updatedAt <= row.updatedAt,
                      let status = TaskStatus(rawValue: row.status), status != task.status else { continue }
                let wasClosed = task.status == .done || task.status == .cancelled
                task.statusRaw = status.rawValue
                task.completedAt = row.completedAt
                task.updatedAt = row.updatedAt
                task.reopenedAt = row.reopenedAt
                task.reopenedReason = row.reopenedReason
                task.needsSync = false
                if status == .done || status == .cancelled {
                    NotificationService.cancelReminder(for: task.id)
                } else if wasClosed {
                    // Sent back by GitHub / Jira: unticked again, reminders come back if still planned.
                    await NotificationService.scheduleTaskNotifications(for: task, serverPushActive: hasServerPush)
                }
            }
            try context.save()
            UserDefaults.standard.set(newest, forKey: key)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Link badges + pending "Liên kết với …?" suggestions for local tasks.
    func pullLinks(_ context: ModelContext) async {
        guard let client, userId != nil else { return }
        do {
            let links: [TaskLinkRecord] = try await client.from("task_links")
                .select("task_id, title, url")
                .execute()
                .value
            let suggestions: [SuggestionRecord] = try await client.from("suggestions")
                .select("id, kind, payload")
                .eq("kind", value: "link")
                .eq("status", value: "new")
                .execute()
                .value
            let tasks = try context.fetch(FetchDescriptor<TaskItem>())
            let linkByTask = Dictionary(links.map { ($0.taskId, $0) }, uniquingKeysWith: { a, _ in a })
            let suggestionByTask = Dictionary(
                suggestions.compactMap { s in s.payload.taskId.map { ($0, s) } },
                uniquingKeysWith: { a, _ in a }
            )
            for task in tasks {
                if let link = linkByTask[task.id] {
                    task.linkTitle = link.title
                    task.linkURL = link.url
                    task.linkSuggestionId = nil
                    task.linkSuggestionTitle = nil
                } else if let suggestion = suggestionByTask[task.id] {
                    task.linkSuggestionId = suggestion.id
                    task.linkSuggestionTitle = suggestion.payload.title
                } else {
                    task.linkSuggestionId = nil
                    task.linkSuggestionTitle = nil
                }
            }
            try context.save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func answerLinkSuggestion(_ task: TaskItem, accept: Bool, context: ModelContext) async {
        guard let client, let id = task.linkSuggestionId else { return }
        do {
            if accept {
                try await client.rpc("accept_link_suggestion", params: AcceptLinkParams(pSuggestion: id)).execute()
            } else {
                await markSuggestions(picked: [], dismissed: [id])
            }
            task.linkSuggestionId = nil
            task.linkSuggestionTitle = nil
            if accept {
                await syncIntegrationsNow(context)   // apply the linked item's status right away
                await pullTaskUpdates(context)
                await pullLinks(context)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Calendar events are read on device and uploaded so build-checkin / AI see them (README §11).
    func uploadCalendarItems(_ context: ModelContext) async {
        guard let client, let userId else { return }
        let start = DayClock.startOfDay()
        let raw = ExternalSource.calendar.rawValue
        guard let items = try? context.fetch(FetchDescriptor<ExternalItem>(predicate: #Predicate {
            $0.sourceRaw == raw && $0.occurredAt >= start
        })), !items.isEmpty else { return }
        let rows = items.map {
            ExternalItemRecord(userId: userId, source: raw, externalId: $0.externalId, title: $0.title,
                               url: nil, status: nil, kind: "event", occurredAt: $0.occurredAt)
        }
        do {
            try await client.from("external_items").upsert(rows, onConflict: "user_id,source,external_id").execute()
        } catch {
            lastError = error.localizedDescription
        }
    }

    enum ServiceError: LocalizedError {
        case notConfigured
        case signedOut
        case message(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Chưa cấu hình Supabase. Điền Config/Secrets.xcconfig rồi build lại."
            case .signedOut: "Đăng nhập bằng Apple trong Cài đặt để dùng tính năng này."
            case .message(let text): text
            }
        }
    }
}
