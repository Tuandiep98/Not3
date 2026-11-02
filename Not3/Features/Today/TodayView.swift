import SwiftData
import SwiftUI

/// "Hôm nay" — the day's timeline: check-in card, morning, afternoon (artboard `Today`).
struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @Environment(SupabaseService.self) private var supabase
    @Query(sort: \TaskItem.plannedAt) private var tasks: [TaskItem]
    @Query(sort: \ExternalItem.occurredAt) private var externalItems: [ExternalItem]
    @Query private var checkIns: [CheckIn]
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]

    @State private var now = Date()
    /// Row flashed after opening a notification / widget link for it.
    @State private var highlighted: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            list
                .task(id: router.focusTaskId) { await focus(router.focusTaskId, proxy: proxy) }
        }
    }

    /// Scrolls to the task and flashes it. A task synced from the server may arrive a moment
    /// after the app opens, so it waits briefly for the row.
    private func focus(_ id: UUID?, proxy: ScrollViewProxy) async {
        guard let id else { return }
        for _ in 0..<12 where !todayTasks.contains(where: { $0.id == id }) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        defer { router.focusTaskId = nil }
        guard todayTasks.contains(where: { $0.id == id }) else { return }
        withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
        withAnimation(.easeIn(duration: 0.2)) { highlighted = id }
        try? await Task.sleep(for: .seconds(1.6))
        withAnimation(.easeOut(duration: 0.6)) { highlighted = nil }
    }

    private var list: some View {
        List {
            Section {
                checkInCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } header: {
                Text(DayClock.longDate(now))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }

            if !inbox.isEmpty {
                Section {
                    ForEach(inbox) { item in
                        InboxRow(item: item)
                    }
                } header: {
                    Label("Chưa phân loại", systemImage: "exclamationmark.triangle")
                } footer: {
                    Text("PR nhờ review, PR của bạn và việc được giao đã tự thành task. Đây là những mục app chưa tự xếp được — chạm để chọn.")
                }
                .headerProminence(.increased)
            }

            Section("Buổi sáng") {
                if morningRows.isEmpty {
                    Text("Chưa có gì từ GitHub, Jira hay Lịch. Bạn có thể thêm trong lúc check-in.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(morningRows) { row in
                        TimelineRow(row: row)
                    }
                }
            }
            .headerProminence(.increased)

            Section {
                if todayTasks.isEmpty {
                    Text("Chưa có việc nào hôm nay. Chốt việc trong check-in hoặc chạm ↻ để kéo việc từ GitHub, Jira.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    // Fixed order (time, then creation): ticking a task never moves it.
                    ForEach(todayTasks) { task in
                        TaskRow(task: task)
                            .id(task.id)
                            .listRowBackground(highlighted == task.id ? Theme.accent.opacity(0.18) : nil)
                            .swipeActions {
                                if task.status != .done {
                                    Button("Huỷ", systemImage: "xmark", role: .destructive) {
                                        TaskActions.cancel(task)
                                    }
                                    Button("Dời sang mai", systemImage: "arrow.turn.up.right") {
                                        Task {
                                            await TaskActions.postponeToTomorrow(task, serverPushActive: supabase.hasServerPush)
                                        }
                                    }
                                    .tint(.orange)
                                }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("Việc hôm nay")
                    Spacer()
                    if !todayTasks.isEmpty {
                        Text("\(doneCount)/\(todayTasks.count) xong")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .headerProminence(.increased)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Hôm nay")
        .toolbarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                RefreshButton()
            }
            ToolbarItem(placement: .bottomBar) {
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if #available(iOS 26, *) {
                ToolbarSpacer(.flexible, placement: .bottomBar)
            } else {
                ToolbarItem(placement: .bottomBar) { Spacer() }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Ghi chú mới", systemImage: "square.and.pencil") { createNote() }
            }
        }
        .onAppear { now = Date() }
    }

    // MARK: Check-in card

    @ViewBuilder
    private var checkInCard: some View {
        let checkIn = checkIns.first { $0.day == DayClock.startOfDay(now) }
        let hour = AppSettings.checkInHour
        let minute = AppSettings.checkInMinute
        VStack(alignment: .leading, spacing: 6) {
            Label(String(format: "Check-in %02d:%02d", hour, minute), systemImage: "clock")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accentInk)
            if let checkIn, checkIn.mood != nil {
                Text("Đã check-in · \(checkIn.mood?.label ?? "")")
                    .font(.title3.weight(.semibold))
                if let plan = todayTasks.first(where: { checkIn.afternoonTaskIds.contains($0.id) }),
                   let sentence = plan.ifThenSentence {
                    Text(sentence).font(.subheadline).foregroundStyle(.secondary)
                }
                Button("Sửa kế hoạch") { router.isCheckInPresented = true }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
            } else {
                Text("Sáng nay bạn đã làm được gì?")
                    .font(.title3.weight(.semibold))
                Text(morningRows.isEmpty
                     ? "Chạm vài chip để ghi lại buổi sáng và chốt việc buổi chiều."
                     : "\(morningRows.count) mục đã được gom sẵn.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    router.isCheckInPresented = true
                } label: {
                    Text("Check-in ngay").font(.headline).frame(maxWidth: .infinity)
                }
                .appPrimaryButton()
                .padding(.top, 10)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: .rect(cornerRadius: Theme.cardRadius))
    }

    // MARK: Data

    private var morningRows: [TimelineRow.Model] {
        let start = DayClock.startOfDay(now)
        let noon = DayClock.noon(now)
        let external = externalItems
            .filter { $0.occurredAt >= start && $0.occurredAt < noon }
            .map { TimelineRow.Model(id: $0.id.uuidString, title: $0.title, subtitle: "\($0.source.label) · \(DayClock.time($0.occurredAt))", systemImage: $0.source.systemImage, url: $0.url.flatMap(URL.init(string:)), source: $0.source) }
        return external
    }

    /// Open PRs / issues / tickets not linked, decided or ignored by a rule — from any day.
    private var inbox: [ExternalItem] {
        // Unresolved items stay until decided, like unfinished tasks (no date limit).
        let linkedURLs = Set(tasks.compactMap(\.linkURL))
        let needsDecision: Set<String> = ["open", "review_requested", "todo", "in_progress"]
        return externalItems.filter { item in
            item.source != .calendar
                && item.decision == nil
                && needsDecision.contains(item.status ?? "")
                && !linkedURLs.contains(item.url ?? "")
                && !supabase.isIgnored(item)
        }
    }

    /// Open tasks from any day (carried over until done) + tasks finished today. See `TodayList`.
    private var todayTasks: [TaskItem] {
        TodayList.tasks(tasks, now: now)
    }

    private var doneCount: Int { todayTasks.filter { $0.status == .done }.count }

    private var summaryText: String {
        todayTasks.isEmpty ? "\(morningRows.count) mục đồng bộ" : "\(doneCount)/\(todayTasks.count) việc xong"
    }

    private func createNote() {
        let note = Note(folder: folders.first { $0.name == "Ghi chú nhanh" })
        context.insert(note)
        router.path.append(.note(note.persistentModelID))
    }
}

struct TimelineRow: View {
    struct Model: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let systemImage: String
        let url: URL?
        var source: ExternalSource? = nil
    }

    let row: Model

    var body: some View {
        if let url = row.url {
            Link(destination: url) { content }
                .foregroundStyle(.primary)
                .accessibilityHint("Mở bản gốc")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Group {
                if let source = row.source {
                    SourceIcon(source: source, size: 15)
                } else {
                    Image(systemName: row.systemImage).font(.footnote)
                }
            }
            .frame(width: 30, height: 30)
            .background(Theme.groupedBackground, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text(row.subtitle).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

struct TaskRow: View {
    @Bindable var task: TaskItem
    @Environment(SupabaseService.self) private var supabase
    @Environment(\.modelContext) private var context

    var body: some View {
        HStack(spacing: 4) {
            CheckCircle(isOn: task.status == .done, size: 26, label: task.title) {
                let done = task.status != .done
                withAnimation(.snappy) { task.status = done ? .done : .todo }
                Task { await TaskActions.setDone(task, done, serverPushActive: supabase.hasServerPush) }
            }
            .padding(.leading, -10)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleLine)
                    .strikethrough(task.status == .done)
                    .foregroundStyle(task.status == .done ? .secondary : .primary)
                if let detail = detailLine {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                if isReopened {
                    // GitHub / Jira sent it back: say why, so the user knows to continue.
                    Label(reopenedText, systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .accessibilityLabel("Bị trả lại: \(task.reopenedReason ?? "")")
                }
                if task.linkTitle == nil, let suggestion = task.linkSuggestionTitle {
                    linkSuggestion(suggestion)
                }
            }
            Spacer(minLength: 8)
            sourceIcon
        }
        .frame(minHeight: 44)
    }

    /// Small GitHub / Jira logo at the end of a linked task; tap opens the original.
    @ViewBuilder
    private var sourceIcon: some View {
        if task.linkTitle != nil || task.linkURL != nil {
            let source = ExternalSource(linkURL: task.linkURL)
            let icon = Group {
                if let source {
                    SourceIcon(source: source, size: 15)
                } else {
                    Image(systemName: "link").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(width: Theme.minTouch, height: Theme.minTouch)
            .contentShape(.rect)
            .padding(.trailing, -12)
            if let url = task.linkURL.flatMap(URL.init(string:)) {
                Link(destination: url) { icon }
                    .accessibilityLabel("Mở trên \(source?.label ?? "nguồn gốc"): \(task.linkTitle ?? "")")
            } else {
                icon.accessibilityLabel("Từ \(source?.label ?? "nguồn ngoài")")
            }
        }
    }

    /// "Liên kết với PR #57?" — AI found a possible match (confidence 0.6–0.85); one tap to confirm.
    private func linkSuggestion(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text("Liên kết với \(title)?")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Có") {
                Task { await supabase.answerLinkSuggestion(task, accept: true, context: context) }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.mini)
            Button("Không") {
                Task { await supabase.answerLinkSuggestion(task, accept: false, context: context) }
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .controlSize(.mini)
        }
        .padding(.top, 2)
    }

    /// Reopened by sync and not finished since.
    private var isReopened: Bool {
        task.reopenedAt != nil && task.status != .done && task.status != .cancelled
    }

    private var reopenedText: String {
        let reason = task.reopenedReason ?? ""
        return reason.isEmpty ? "Bị trả lại" : "Bị trả lại · \(reason)"
    }

    private var titleLine: String {
        guard let planned = task.plannedAt else { return task.title }
        // Carried over from an earlier day: show the date too ("31/10 16:00").
        let when = Calendar.current.isDateInToday(planned)
            ? DayClock.time(planned)
            : "\(DayClock.dayMonth(planned)) \(DayClock.time(planned))"
        return "\(when) · \(task.title)"
    }

    private var detailLine: String? {
        // Undated work carried over from an earlier day shows where it started.
        let carried = task.plannedAt == nil && TodayList.isCarriedOver(task) ? "Từ \(DayClock.dayMonth(task.createdAt))" : nil
        let doing = task.status == .doing && !isReopened ? TaskStatus.doing.label : nil
        let parts = [carried, doing, task.durationMinutes.map { "\($0) phút" }, task.category].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// An item the server could not classify: a warning row; actions appear only after a tap.
struct InboxRow: View {
    let item: ExternalItem
    @Environment(SupabaseService.self) private var supabase
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var isChoosing = false

    var body: some View {
        Button { isChoosing = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(width: 30, height: 30)
                    .background(Color.orange.opacity(0.14), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).foregroundStyle(.primary)
                    Text("\(item.source.label) · \(item.unclassifiedReason)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Chạm để chọn cách xử lý")
        .confirmationDialog(item.title, isPresented: $isChoosing, titleVisibility: .visible) {
            Button("Thành việc") { decide(.task) }
            Button("Thành ghi chú") { decide(.note) }
            Button("Bỏ qua mục này") { decide(.ignored) }
            if let scope = item.scopeLabel {
                Button("Luôn bỏ qua \(kindLabel) từ \(scope)") { ignoreAlways(onlyThisScope: true) }
            }
            Button("Luôn bỏ qua mọi \(kindLabel)", role: .destructive) { ignoreAlways(onlyThisScope: false) }
            if let url = item.url.flatMap(URL.init(string:)) {
                Button("Mở bản gốc") { openURL(url) }
            }
            Button("Để sau", role: .cancel) {}
        } message: {
            Text(item.unclassifiedReason)
        }
    }

    private var kindLabel: String {
        switch (item.source, item.kind) {
        case (.github, "pull_request"): "PR"
        case (.github, "issue"): "issue"
        case (.jira, _): "ticket"
        default: "mục loại này"
        }
    }

    private func decide(_ decision: SupabaseService.InboxDecision) {
        Task {
            withAnimation { item.decision = decision.rawValue }
            await supabase.decide(item, decision, context: context)
        }
    }

    private func ignoreAlways(onlyThisScope: Bool) {
        Task {
            withAnimation { item.decision = SupabaseService.InboxDecision.ignored.rawValue }
            await supabase.alwaysIgnore(like: item, onlyThisScope: onlyThisScope, context: context)
        }
    }
}

/// "Đồng bộ ngay" in the app bar: GitHub / Jira on the server, Calendar, push + pull, journal.
/// Shows the last refresh time; the icon spins while running.
struct RefreshButton: View {
    @Environment(SupabaseService.self) private var supabase
    @State private var isRefreshing = false

    var body: some View {
        Button {
            guard !isRefreshing else { return }
            isRefreshing = true
            Task {
                await AppLifecycle.refreshNow()
                isRefreshing = false
            }
        } label: {
            HStack(spacing: 5) {
                if let last = supabase.lastRefreshAt {
                    Text(DayClock.time(last))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isRefreshing)
            }
        }
        .disabled(isRefreshing)
        .accessibilityLabel("Đồng bộ ngay")
        .accessibilityValue(supabase.lastRefreshAt.map { "Cập nhật lúc \(DayClock.time($0))" } ?? "Chưa đồng bộ")
    }
}
