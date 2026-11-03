import Foundation

/// Toggles of Settings → GitHub / Jira (keys and defaults mirror supabase/functions/_shared/settings.ts)
/// and of the on-device Apple modules (stored in UserDefaults, see `LocalModule`).
struct IntegrationOption: Identifiable, Hashable {
    enum Group: String, CaseIterable {
        case todo = "Tạo việc cần làm"
        case done = "Ghi vào Nhật ký"
        case permission = "Cần thêm quyền"
    }

    let key: String
    let title: String
    let detail: String
    let defaultOn: Bool
    let group: Group

    var id: String { key }

    static func options(for source: ExternalSource) -> [IntegrationOption] {
        switch source {
        case .github: github
        case .jira: jira
        case .reminders: reminders
        case .health: health
        case .calendar, .journal: []
        }
    }

    // Titles ≤ 4 words, details one short line (secondary text under the toggle).
    static let github: [IntegrationOption] = [
        .init(key: "prs", title: "PR & issue của tôi", detail: "PR đang mở, issue được giao cho bạn", defaultOn: true, group: .todo),
        .init(key: "review_requests", title: "PR nhờ tôi review", detail: "Tạo việc “Review PR #…”", defaultOn: true, group: .todo),
        .init(key: "mentions", title: "Được nhắc tên", detail: "Tạo việc “Trả lời…”, xong khi bạn trả lời", defaultOn: true, group: .todo),
        .init(key: "reviews_submitted", title: "Review đã gửi", detail: "Đánh dấu xong việc Review tương ứng", defaultOn: true, group: .done),
        .init(key: "commits", title: "Commit", detail: "Gộp theo repo", defaultOn: true, group: .done),
        .init(key: "releases", title: "Release & tag", detail: "Ví dụ “Phát hành v1.2.0”", defaultOn: true, group: .done),
        .init(key: "merges", title: "PR tôi merge", detail: "PR của người khác do bạn merge", defaultOn: true, group: .done),
        .init(key: "comments", title: "Bình luận của tôi", detail: "Gộp theo issue / PR", defaultOn: false, group: .done),
        .init(key: "builds", title: "Build Actions", detail: "Lỗi thành việc “Sửa…”, xong khi chạy lại xanh", defaultOn: false, group: .permission),
        .init(key: "deploys", title: "Deploy", detail: "Lỗi thành việc “Sửa…”", defaultOn: false, group: .permission),
    ]

    static let jira: [IntegrationOption] = [
        .init(key: "assigned", title: "Ticket giao cho tôi", detail: "Trạng thái theo Jira", defaultOn: true, group: .todo),
        .init(key: "sprint", title: "Sprint đang chạy", detail: "Cả ticket chưa cập nhật hôm nay", defaultOn: false, group: .todo),
        .init(key: "reported", title: "Ticket tôi tạo", detail: "Đưa vào “Chưa phân loại”", defaultOn: true, group: .todo),
        .init(key: "watching", title: "Ticket tôi theo dõi", detail: "Đưa vào “Chưa phân loại”", defaultOn: false, group: .todo),
        .init(key: "transitions", title: "Chuyển trạng thái", detail: "Ví dụ “JIRA-118 → In Review”", defaultOn: true, group: .done),
        .init(key: "worklogs", title: "Log work", detail: "Các lần log work hôm nay", defaultOn: false, group: .done),
    ]

    static let reminders: [IntegrationOption] = [
        .init(key: "due_today", title: "Đến hạn hôm nay", detail: "Cả lời nhắc quá hạn; xong ở đây là xong bên kia", defaultOn: true, group: .todo),
        .init(key: "no_due", title: "Chưa có ngày", detail: "Đưa vào Hộp chờ", defaultOn: false, group: .todo),
        .init(key: "completed", title: "Lời nhắc đã xong", detail: "Lời nhắc tick trong app Lời nhắc hôm nay", defaultOn: true, group: .done),
    ]

    static let health: [IntegrationOption] = [
        .init(key: "workouts", title: "Bài tập", detail: "Ví dụ “Chạy bộ 32 phút · 5,1 km”", defaultOn: true, group: .done),
        .init(key: "mindful", title: "Chánh niệm", detail: "Các phiên thiền, hít thở", defaultOn: true, group: .done),
        .init(key: "steps", title: "Đạt mục tiêu bước", detail: "Ghi một lần khi đạt mục tiêu", defaultOn: true, group: .done),
        .init(key: "sleep", title: "Giấc ngủ", detail: "Số giờ ngủ đêm qua, không tính là việc", defaultOn: true, group: .done),
    ]

    /// Stored value, else the default.
    static func value(_ option: IntegrationOption, in settings: [String: Bool]?) -> Bool {
        settings?[option.key] ?? option.defaultOn
    }
}
