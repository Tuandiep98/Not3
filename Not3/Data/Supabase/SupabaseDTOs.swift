import Foundation

// Row shapes for the Supabase tables in supabase/migrations. Keys are snake_case.

struct ProfileRecord: Encodable, Sendable {
    let userId: UUID
    let timezone: String
    let checkinHour: Int
    let checkinMinute: Int
    let aiNotesEnabled: Bool
    let syncNoteContent: Bool
    let eveningCheckin: Bool

    enum CodingKeys: String, CodingKey {
        case eveningCheckin = "evening_checkin"
        case userId = "user_id", timezone
        case checkinHour = "checkin_hour", checkinMinute = "checkin_minute"
        case aiNotesEnabled = "ai_notes_enabled", syncNoteContent = "sync_note_content"
    }
}

struct DeviceRecord: Encodable, Sendable {
    let userId: UUID
    let apnsToken: String
    let environment: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id", apnsToken = "apns_token", environment
    }
}

struct TaskRecord: Encodable, Sendable {
    let id: UUID
    let userId: UUID
    let title: String
    let chips: [String]
    let plannedAt: Date?
    let durationMinutes: Int?
    let status: String
    let source: String
    let ifThenSentence: String?
    let completedAt: Date?
    let updatedAt: Date
    /// The app's own writes; the server marks its sync changes "sync" so the app pulls only those.
    let updatedBy = "app"

    enum CodingKeys: String, CodingKey {
        case id, userId = "user_id", title, chips
        case plannedAt = "planned_at", durationMinutes = "duration_minutes"
        case status, source, ifThenSentence = "if_then_sentence"
        case completedAt = "completed_at", updatedAt = "updated_at", updatedBy = "updated_by"
    }

    init(_ task: TaskItem, userId: UUID) {
        id = task.id
        self.userId = userId
        title = task.title
        chips = task.category.map { [$0] } ?? []
        plannedAt = task.plannedAt
        durationMinutes = task.durationMinutes
        status = task.statusRaw
        source = task.sourceRaw
        ifThenSentence = task.ifThenSentence
        completedAt = task.completedAt
        updatedAt = task.updatedAt
    }
}

struct CheckInRecord: Encodable, Sendable {
    let id: UUID
    let userId: UUID
    let day: String
    let morningItems: [String]
    let mood: String?
    let afternoonPlanIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case id, userId = "user_id", day
        case morningItems = "morning_items", mood, afternoonPlanIds = "afternoon_plan_ids"
    }

    init(_ checkIn: CheckIn, userId: UUID) {
        id = checkIn.id
        self.userId = userId
        day = DayClock.isoDay(checkIn.day)
        morningItems = checkIn.morningItems
        mood = checkIn.moodRaw
        afternoonPlanIds = checkIn.afternoonTaskIds
    }
}

/// A row of `suggestions` written by `build-checkin` (rules now, AI in phase 2).
struct SuggestionRecord: Decodable, Sendable {
    let id: UUID
    let kind: String
    let payload: Payload

    struct Payload: Decodable, Sendable {
        let label: String?
        let source: String?
        let title: String?
        let category: String?
        let durationMinutes: Int?
        // kind = "link"
        let taskId: UUID?
        let url: String?

        enum CodingKeys: String, CodingKey {
            case label, source, title, category, durationMinutes = "duration_minutes"
            case taskId = "task_id", url
        }
    }
}

struct StatusUpdate: Encodable, Sendable {
    let status: String
}

struct NoteRecord: Encodable, Sendable {
    let id: UUID
    let userId: UUID
    let title: String
    let chips: [String]
    /// Only sent when "Đồng bộ nội dung note lên server" is on.
    let body: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, userId = "user_id", title, chips, body, updatedAt = "updated_at"
    }

    init(_ note: Note, userId: UUID, includeBody: Bool) {
        id = note.id
        self.userId = userId
        title = note.title
        chips = note.categories
        body = includeBody ? note.body : nil
        updatedAt = note.updatedAt
    }
}

/// Delivery state of this device, written by `send-push`.
struct DeviceDeliveryRecord: Decodable, Sendable {
    let lastSentAt: Date?

    enum CodingKeys: String, CodingKey {
        case lastSentAt = "last_sent_at"
    }
}

// MARK: Phase 2 — AI

struct WeeklySummaryRecord: Decodable, Sendable {
    let summary: String
    let source: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case summary, source, createdAt = "created_at"
    }
}

struct NoteAIChipsRecord: Decodable, Sendable {
    let id: UUID
    let aiChips: [String]

    enum CodingKeys: String, CodingKey {
        case id, aiChips = "ai_chips"
    }
}

struct AskRequest: Encodable, Sendable {
    let task = "ask"
    let question: String
    let timezone: String
}

struct AskResponse: Decodable, Sendable {
    let answer: String?
    let error: String?
}

// MARK: Phase 3 — integrations

struct ExternalItemRecord: Codable, Sendable {
    let userId: UUID?
    let source: String
    let externalId: String
    let title: String
    let url: String?
    let status: String?
    let kind: String?
    let occurredAt: Date
    var decision: String?
    var role: String?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id", source, externalId = "external_id", title, url, status, kind
        case occurredAt = "occurred_at", decision, role, scope
    }
}

struct ContentRuleRecord: Codable, Sendable, Hashable {
    var userId: UUID?
    let provider: String
    let kind: String
    var scope = ""
    var action = "ignore"

    enum CodingKeys: String, CodingKey {
        case userId = "user_id", provider, kind, scope, action
    }
}

struct DecisionUpdate: Encodable, Sendable {
    let decision: String
}

struct ManualLinkRecord: Encodable, Sendable {
    let userId: UUID
    let taskId: UUID
    let provider: String
    let externalId: String
    let url: String?
    let title: String
    let linkSource = "manual"

    enum CodingKeys: String, CodingKey {
        case userId = "user_id", taskId = "task_id", provider, externalId = "external_id", url, title
        case linkSource = "link_source"
    }
}

struct IntegrationRecord: Decodable, Sendable, Identifiable {
    let provider: String
    let accountName: String?
    let lastSyncedAt: Date?
    let lastError: String?
    var settings: [String: Bool]?
    var doneRules: DoneRules?
    /// Jira webhook state (integrations.meta): nil = not attempted yet.
    var webhook: WebhookState?

    var id: String { provider }

    enum WebhookState: Equatable, Sendable {
        case active
        case failed(String)
    }

    private struct Meta: Decodable {
        let webhookIds: [Int64]?
        let webhookError: String?
        enum CodingKeys: String, CodingKey { case webhookIds = "webhook_ids", webhookError = "webhook_error" }
    }

    enum CodingKeys: String, CodingKey {
        case provider, accountName = "account_name", lastSyncedAt = "last_synced_at", lastError = "last_error"
        case settings, doneRules = "done_rules", meta
    }

    init(provider: String, accountName: String?, lastSyncedAt: Date?, lastError: String?, settings: [String: Bool]? = nil) {
        self.provider = provider
        self.accountName = accountName
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
        self.settings = settings
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        accountName = try c.decodeIfPresent(String.self, forKey: .accountName)
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        // Tolerate unexpected value types in the jsonb column.
        settings = try? c.decodeIfPresent([String: Bool].self, forKey: .settings)
        doneRules = try? c.decodeIfPresent(DoneRules.self, forKey: .doneRules)
        if let meta = try? c.decodeIfPresent(Meta.self, forKey: .meta) {
            if let ids = meta.webhookIds, !ids.isEmpty {
                webhook = .active
            } else if let error = meta.webhookError {
                webhook = .failed(error)
            }
        }
    }
}

struct IntegrationSettingsUpdate: Encodable, Sendable {
    let settings: [String: Bool]
}

/// "Tính là hoàn thành" (integrations.done_rules) — mirrors DoneRules in _shared/settings.ts.
struct DoneRules: Codable, Sendable, Equatable {
    enum PRDoneWhen: String, Codable, CaseIterable, Sendable {
        case merged, approved, readyForReview = "ready_for_review"

        var label: String {
            switch self {
            case .merged: "Đã merge"
            case .approved: "Được duyệt (Approve)"
            case .readyForReview: "Sẵn sàng review"
            }
        }
    }

    var statuses: [String] = []
    var labels: [String] = []
    var prDoneWhen: PRDoneWhen = .merged

    enum CodingKeys: String, CodingKey {
        case statuses, labels, prDoneWhen = "pr_done_when"
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statuses = (try? c.decodeIfPresent([String].self, forKey: .statuses)) ?? []
        labels = (try? c.decodeIfPresent([String].self, forKey: .labels)) ?? []
        prDoneWhen = (try? c.decodeIfPresent(PRDoneWhen.self, forKey: .prDoneWhen)) ?? .merged
    }
}

struct DoneRulesUpdate: Encodable, Sendable {
    let doneRules: DoneRules

    enum CodingKeys: String, CodingKey { case doneRules = "done_rules" }
}

struct JiraStatus: Decodable, Sendable, Hashable, Identifiable {
    let name: String
    /// new = To Do, indeterminate = In Progress, done = Done.
    let category: String

    var id: String { name }
}

struct JiraStatusesResponse: Decodable, Sendable {
    let statuses: [JiraStatus]
    let error: String?
}

struct IntegrationsRequest: Encodable, Sendable {
    let action: String
    var provider: String?
    var timezone: String?
}

struct ConnectResponse: Decodable, Sendable {
    let url: String?
    let error: String?
}

struct ProvidersStatus: Decodable, Sendable {
    let github: Bool
    let jira: Bool
}

struct DisconnectParams: Encodable, Sendable {
    let pProvider: String

    enum CodingKeys: String, CodingKey { case pProvider = "p_provider" }
}

/// A task the server changed or created (auto-classified PR / ticket).
struct TaskStatusRecord: Decodable, Sendable {
    let id: UUID
    let title: String
    let chips: [String]
    let status: String
    let source: String
    let plannedAt: Date?
    let durationMinutes: Int?
    let completedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let reopenedAt: Date?
    let reopenedReason: String?

    enum CodingKeys: String, CodingKey {
        case id, title, chips, status, source
        case plannedAt = "planned_at", durationMinutes = "duration_minutes"
        case completedAt = "completed_at", createdAt = "created_at", updatedAt = "updated_at"
        case reopenedAt = "reopened_at", reopenedReason = "reopened_reason"
    }
}

struct TaskLinkRecord: Decodable, Sendable {
    let taskId: UUID
    let title: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id", title, url
    }
}

struct AcceptLinkParams: Encodable, Sendable {
    let pSuggestion: UUID

    enum CodingKeys: String, CodingKey { case pSuggestion = "p_suggestion" }
}
