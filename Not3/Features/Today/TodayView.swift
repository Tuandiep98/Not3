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

    @AppStorage(FocusFilterState.categoriesKey) private var focusCategoriesRaw = ""
    @AppStorage(FocusFilterState.showUncategorizedKey) private var focusShowsUncategorized = true
    @AppStorage(LocalModule.enabledKey(.journal)) private var journalModuleOn = false

    @State private var now = Date()
    /// Row flashed after opening a notification / widget link for it.
    @State private var highlighted: UUID?
    /// What the last pull to refresh could not sync ("Jira: Cần đăng nhập lại"); nil = all good.
    @State private var refreshProblem: String?

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
        // Opened from a notification, this view was just pushed: scrolling the List before its
        // collection view has loaded the rows traps (out-of-bounds index path). Let it lay out first.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, todayTasks.contains(where: { $0.id == id }) else { return }
        withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
        withAnimation(.easeIn(duration: 0.2)) { highlighted = id }
        try? await Task.sleep(for: .seconds(1.6))
        withAnimation(.easeOut(duration: 0.6)) { highlighted = nil }
    }

    private var list: some View {
        List {
            Section {
                if let refreshProblem {
                    refreshProblemRow(refreshProblem)
                }
                if showsCheckInCard {
                    checkInCard
                }
                if showsShutdownCard {
                    shutdownCard
                }
            } header: {
                // iOS 26+: the date sits right under the large title (navigationSubtitle).
                if #available(iOS 26, *) {
                    EmptyView()
                } else {
                    Text(DayClock.longDate(now))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
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
                    Text("Chưa có gì từ GitHub, Jira, Lịch hay các nguồn đã bật. Bạn có thể thêm trong lúc check-in.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(morningRows) { row in
                        TimelineRow(row: row)
                    }
                }
                if journalModuleOn && JournalSuggestions.isSupported {
                    MomentPickerButton()
                }
            }
            .headerProminence(.increased)

            Section {
                if todayTasks.isEmpty {
                    Text("Chưa có việc nào hôm nay. Chốt việc trong check-in hoặc kéo xuống để lấy việc từ GitHub, Jira.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    // Fixed order (time, then creation): ticking a task never moves it.
                    ForEach(todayTasks) { task in
                        TaskRow(task: task, now: now)
                            .id(task.id)
                            .listRowBackground(highlighted == task.id ? Theme.accent.opacity(0.18) : nil)
                            .swipeActions(edge: .leading) {
                                // Starts the timer: Bắt đầu → Xong gives the real time in "Tổng kết tuần".
                                if task.status == .todo {
                                    Button("Bắt đầu", systemImage: "play.fill") { task.status = .doing }
                                        .tint(.blue)
                                }
                            }
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
                                    Button("Hộp chờ", systemImage: "tray") {
                                        TaskActions.moveToBacklog(task)
                                    }
                                    .tint(.indigo)
                                }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("Việc hôm nay")
                    if !todayTasks.isEmpty {
                        Text("\(doneCount)/\(todayTasks.count) xong")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    if carriedOverCount > 0 {
                        Menu {
                            Button("Dời \(carriedOverCount) việc tồn sang mai", systemImage: "arrow.turn.up.right") {
                                Task { await TaskActions.postponeAll(todayTasks, serverPushActive: supabase.hasServerPush) }
                            }
                            Button("Đưa \(carriedOverCount) việc tồn vào hộp chờ", systemImage: "tray") {
                                TaskActions.backlogAll(todayTasks)
                            }
                        } label: {
                            // Trailing in its touch area: the icon lines up with the section's right edge.
                            Image(systemName: "ellipsis.circle")
                                .frame(width: Theme.minTouch, height: Theme.minTouch, alignment: .trailing)
                        }
                        .accessibilityLabel("Việc tồn từ hôm trước")
                    }
                }
            } footer: {
                if !focusCategories.isEmpty {
                    Label("Focus đang lọc: \(focusCategories.joined(separator: ", "))", systemImage: "moon.fill")
                }
            }
            .headerProminence(.increased)
        }
        .listStyle(.insetGrouped)
        // Pull to refresh: the server pulls GitHub / Jira first, then the usual pass.
        .refreshable {
            let problem = await AppLifecycle.refreshNow()
            withAnimation { refreshProblem = problem }
        }
        .navigationTitle("Hôm nay")
        .dateSubtitle(DayClock.longDate(now))
        .toolbarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Việc mới", systemImage: "plus") { router.taskEditor = .new(someday: false) }
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
                // Always reachable, also while the card is hidden (early check-in, editing the plan).
                Button(todayCheckIn == nil ? "Check-in" : "Sửa kế hoạch check-in",
                       systemImage: todayCheckIn == nil ? "sun.max" : "checkmark.circle") {
                    router.isCheckInPresented = true
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Ghi chú mới", systemImage: "square.and.pencil") { createNote() }
            }
        }
        .onAppear { now = Date() }
        .task {
            // Minute tick: the check-in card appears, counts down and hides without leaving the screen.
            while !Task.isCancelled {
                let next = DayClock.calendar.nextDate(after: Date(), matching: DateComponents(second: 0),
                                                      matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
                try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
                withAnimation(.snappy) { now = Date() }
            }
        }
    }

    // MARK: Check-in card

    /// Shown from this long before check-in time until it is done (a missed one stays all day).
    private static let checkInLead: TimeInterval = 30 * 60
    /// After checking in, the one-line summary stays this long, then the card hides.
    private static let checkInDoneLinger: TimeInterval = 60 * 60

    private var todayCheckIn: CheckIn? {
        checkIns.first { $0.day == DayClock.startOfDay(now) && $0.mood != nil }
    }

    private var checkInTime: Date {
        DayClock.at(hour: AppSettings.checkInHour, minute: AppSettings.checkInMinute, on: now)
    }

    private var showsCheckInCard: Bool {
        if let done = todayCheckIn {
            return now < done.createdAt.addingTimeInterval(Self.checkInDoneLinger)
        }
        return now >= checkInTime.addingTimeInterval(-Self.checkInLead)
    }

    @ViewBuilder
    private var checkInCard: some View {
        if let checkIn = todayCheckIn {
            checkInDone(checkIn)
        } else {
            checkInPrompt
        }
    }

    /// Due soon / now / missed: status, what is ready, one button.
    private var checkInPrompt: some View {
        let time = checkInTime
        let minutesLeft = Int((time.timeIntervalSince(now) / 60).rounded(.up))
        let minutesLate = Int(now.timeIntervalSince(time) / 60)
        let title: String
        let status: String
        let isLate = minutesLate >= 15
        if minutesLeft > 0 {
            title = "Sắp đến giờ check-in"
            status = "Còn \(minutesLeft) phút"
        } else if !isLate {
            title = "Đến giờ check-in"
            status = "Mất khoảng 1 phút"
        } else {
            title = "Bạn chưa check-in hôm nay"
            status = minutesLate < 60 ? "Trễ \(minutesLate) phút" : "Vẫn kịp chốt việc buổi chiều"
        }
        let ready = morningRows.isEmpty ? "Ghi lại buổi sáng, chốt việc chiều" : "\(morningRows.count) mục sáng đã gom sẵn"

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isLate ? "clock.badge.exclamationmark.fill" : "sun.max.fill")
                    .font(.title3)
                    .foregroundStyle(isLate ? Color.white : Color.black)
                    .frame(width: 40, height: 40)
                    .background(isLate ? Color.orange : Theme.accent, in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text("\(status) · \(ready)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(DayClock.time(time))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isLate ? Color.orange : Theme.accentInk)
            }
            .accessibilityElement(children: .combine)

            Button {
                router.isCheckInPresented = true
            } label: {
                Text(minutesLeft > 0 ? "Check-in sớm" : "Check-in ngay")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .appPrimaryButton()
        }
        .padding(.vertical, 6)
    }

    /// Done: one compact row with the plan, so the day's list moves up.
    private func checkInDone(_ checkIn: CheckIn) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Đã check-in · \(checkIn.moodText ?? "")")
                    .font(.subheadline.weight(.semibold))
                if let plan = todayTasks.first(where: { checkIn.afternoonTaskIds.contains($0.id) }),
                   let sentence = plan.ifThenSentence {
                    Text(sentence)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Sửa") { router.isCheckInPresented = true }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityLabel("Sửa kế hoạch check-in")
        }
        .frame(minHeight: Theme.minTouch)
    }

    // MARK: Khép lại hôm nay

    /// Shown from this long before the shutdown time until the day is closed (or ends).
    private static let shutdownLead: TimeInterval = 90 * 60

    private var showsShutdownCard: Bool {
        guard AppSettings.shutdownEnabled else { return false }
        let closed = checkIns.contains { $0.day == DayClock.startOfDay(now) && $0.closedAt != nil }
        return !closed && now >= AppSettings.shutdownTime(on: now).addingTimeInterval(-Self.shutdownLead)
    }

    private var shutdownCard: some View {
        let open = todayTasks.count - doneCount
        let status = open == 0 ? "Không còn việc dang dở" : "\(open) việc còn lại · xếp cho mai trong 1 phút"
        return HStack(spacing: 12) {
            Image(systemName: "moon.stars.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.indigo, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Khép lại hôm nay").font(.headline)
                Text("\(doneCount) việc xong · \(status)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Mở") { router.isShutdownPresented = true }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityLabel("Khép lại hôm nay")
        }
        .frame(minHeight: Theme.minTouch)
        .padding(.vertical, 4)
    }

    /// Pull to refresh finished but GitHub / Jira could not be synced.
    private func refreshProblemRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Chưa đồng bộ được").font(.subheadline.weight(.semibold))
                Text(message).font(.footnote).foregroundStyle(.secondary)
                Text("Kéo xuống để thử lại, hoặc kiểm tra trong Cài đặt.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Ẩn", systemImage: "xmark") { withAnimation { refreshProblem = nil } }
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Theme.minTouch, height: Theme.minTouch, alignment: .topTrailing)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: Data

    private var morningRows: [TimelineRow.Model] {
        let start = DayClock.startOfDay(now)
        let noon = DayClock.noon(now)
        let external = externalItems
            .filter { $0.occurredAt >= start && $0.occurredAt < noon }
            .map { TimelineRow.Model(id: $0.id.uuidString, title: $0.title, subtitle: "\($0.source.label) · \(DayClock.time($0.occurredAt))", systemImage: $0.source.systemImage, url: $0.url.flatMap(URL.init(string:)), source: $0.source, duration: $0.durationSeconds.map { ActivityStyle.duration(seconds: $0) }) }
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
        // A Focus Filter ("Làm việc" → Công việc only) narrows the list while that Focus is on.
        FocusFilterState.apply(TodayList.tasks(tasks, now: now), categories: focusCategories,
                               showUncategorized: focusShowsUncategorized)
    }

    private var focusCategories: [String] { FocusFilterState.decode(focusCategoriesRaw) }

    private var doneCount: Int { todayTasks.filter { $0.status == .done }.count }

    private var carriedOverCount: Int { todayTasks.filter { TodayList.isCarriedOver($0, now: now) }.count }

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
        /// Jira work log: time spent ("30m", "1h"), shown as a small chip under the subtitle.
        var duration: String? = nil
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
                if let duration = row.duration {
                    TagView(text: duration, highlighted: false)
                        .monospacedDigit()
                        .padding(.top, 2)
                        .accessibilityLabel("Đã log \(duration)")
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

struct TaskRow: View {
    @Bindable var task: TaskItem
    /// The list's minute tick: a plan turns "Lỡ giờ" without leaving the screen.
    var now: Date = Date()
    @Environment(SupabaseService.self) private var supabase
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var context
    @State private var isReplanning = false
    /// Next free stretch, read when "Xếp lại" opens.
    @State private var gap: Date?

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
                if let detail = detailText {
                    detail.font(.footnote).foregroundStyle(.secondary)
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
                if TodayList.isMissed(task, now: now) {
                    missedPrompt
                } else if TodayList.isStale(task, now: now) {
                    stalePrompt
                }
                if let summary = task.cardSummary, !summary.isEmpty, task.status != .done {
                    // Card: where the PR / ticket stand now (AI, or "PR #42 đã merge · …").
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { router.taskEditor = .edit(task.id) }
            .accessibilityAction(named: "Sửa việc") { router.taskEditor = .edit(task.id) }
            Spacer(minLength: 8)
            sourceIcon
        }
        .frame(minHeight: 44)
    }

    /// Small GitHub / Jira logo at the end of a linked task; tap opens the original.
    @ViewBuilder
    private var sourceIcon: some View {
        let items = task.cardItems
        if items.count > 1 {
            // Several PRs / tickets for one piece of work: one menu listing each, both logos shown.
            Menu {
                ForEach(items) { item in
                    if let url = item.url.flatMap(URL.init(string:)) {
                        Link(destination: url) {
                            Label("\(item.label) · \(item.statusText)", systemImage: item.source?.systemImage ?? "link")
                            Text(item.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: -4) {
                    ForEach(Array(Set(items.compactMap(\.source))).sorted { $0.rawValue < $1.rawValue }, id: \.self) {
                        SourceIcon(source: $0, size: 15)
                    }
                }
                .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
                .contentShape(.rect)
            }
            .padding(.trailing, -12)
            .accessibilityLabel("\(items.count) mục liên kết: \(items.map(\.label).joined(separator: ", "))")
        } else if task.linkTitle != nil || task.linkURL != nil {
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

    // MARK: Lỡ giờ → Xếp lại

    /// The time passed without "Bắt đầu": one button, the choices only after a tap.
    private var missedPrompt: some View {
        HStack(spacing: 6) {
            Label("Lỡ giờ \(task.plannedAt.map(DayClock.time) ?? "")", systemImage: "clock.badge.exclamationmark")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
            Button("Xếp lại") {
                gap = TaskActions.nextGap(for: task)
                isReplanning = true
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.top, 2)
        .confirmationDialog("Xếp lại \"\(task.title)\"", isPresented: $isReplanning, titleVisibility: .visible) {
            replanButtons
        } message: {
            if let coping = task.coping {
                Text("Bạn đã hẹn: \(coping.clause)")
            }
        }
    }

    /// The backup picked at check-in first, then the rest (each only once, only when it applies today).
    @ViewBuilder
    private var replanButtons: some View {
        let coping = task.coping
        let evening = TaskActions.eveningSlot(now: now)
        if let coping, coping != .nextGap || gap != nil, coping != .evening || evening != nil {
            Button("Như đã hẹn: \(copingTitle(coping))") { replan { _ = await TaskActions.applyCoping(task, serverPushActive: $0) } }
        }
        if let gap, coping != .nextGap {
            Button("Dời sang \(DayClock.time(gap)) (lúc trống)") {
                replan { await TaskActions.reschedule(task, to: gap, serverPushActive: $0) }
            }
        }
        if coping != .shorter {
            Button("Làm \(CopingPlan.shortMinutes) phút ngay") { replan { _ in TaskActions.startShortVersion(task) } }
        }
        if let evening, coping != .evening {
            Button("Làm tối nay (\(DayClock.time(evening)))") {
                replan { await TaskActions.reschedule(task, to: evening, serverPushActive: $0) }
            }
        }
        if coping != .tomorrow {
            Button("Dời sang mai") { replan { await TaskActions.postponeToTomorrow(task, serverPushActive: $0) } }
        }
        Button("Đưa vào hộp chờ") { replan { _ in TaskActions.moveToBacklog(task) } }
        Button("Để sau", role: .cancel) {}
    }

    private func copingTitle(_ coping: CopingPlan) -> String {
        switch coping {
        case .shorter: "làm \(CopingPlan.shortMinutes) phút ngay"
        case .nextGap: gap.map { "dời sang \(DayClock.time($0))" } ?? "dời sang lúc trống"
        case .evening: TaskActions.eveningSlot(now: now).map { "làm lúc \(DayClock.time($0))" } ?? "làm buổi tối"
        case .tomorrow: "để mai"
        }
    }

    private func replan(_ change: @escaping @MainActor (Bool) async -> Void) {
        let serverPush = supabase.hasServerPush
        Task {
            await change(serverPush)
            try? context.save()
            await supabase.syncPending(context)
            WidgetBridge.publish()
        }
    }

    // MARK: Vẫn muốn làm?

    /// Asked once for work that keeps slipping; neutral, one tap to answer.
    private var stalePrompt: some View {
        let moved = task.postponeCount >= TodayList.staleAfter
        let days = TodayList.daysCarried(since: max(task.keptAt ?? .distantPast, task.plannedAt ?? task.createdAt), now: now)
        let reason = moved ? "Đã dời \(task.postponeCount) lần" : "Tồn \(days) ngày"
        return HStack(spacing: 6) {
            Text("\(reason) · vẫn muốn làm?")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Vẫn làm") {
                withAnimation { TaskActions.keep(task) }
                try? context.save()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.mini)
            Button("Hộp chờ") { replan { _ in TaskActions.moveToBacklog(task) } }
                .font(.caption)
                .buttonStyle(.borderless)
                .controlSize(.mini)
            Button("Bỏ") { replan { _ in TaskActions.cancel(task) } }
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

    /// "Từ 31/10 · 25 phút · ● Sức khoẻ" — the category with its own symbol / colour.
    private var detailText: Text? {
        // Undated work carried over from an earlier day shows where it started.
        let carried = task.plannedAt == nil && TodayList.isCarriedOver(task) ? "Từ \(DayClock.dayMonth(task.createdAt))" : nil
        let doing = task.status == .doing && !isReopened ? TaskStatus.doing.label : nil
        let parts = [carried, doing, task.durationMinutes.map { "\($0) phút" }].compactMap { $0 }
        guard !parts.isEmpty || task.category != nil else { return nil }
        var text = Text(parts.joined(separator: " · "))
        if let category = task.category {
            if !parts.isEmpty { text = text + Text(" · ") }
            let style = CategoryAppearance.style(for: category)
            if let symbol = style?.symbol ?? (style?.color != nil ? "circle.fill" : nil) {
                text = text + Text(Image(systemName: symbol)).foregroundStyle(style?.color?.color ?? .secondary) + Text(" ")
            }
            text = text + Text(category)
        }
        return text
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

private extension View {
    /// The day under the large title, Apple-style ("Thứ Ba, 3 tháng 11"); older iOS shows it as the
    /// first section's header instead.
    @ViewBuilder
    func dateSubtitle(_ text: String) -> some View {
        if #available(iOS 26, *) {
            navigationSubtitle(text)
        } else {
            self
        }
    }
}
