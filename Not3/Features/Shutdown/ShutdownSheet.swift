import SwiftData
import SwiftUI

/// "Khép lại hôm nay": the evening counterpart of the noon check-in, three taps at most —
/// what got done (prefilled, tap what was done but not ticked), where the rest goes
/// (Mai / Hộp chờ / Bỏ), and how the whole day felt.
struct ShutdownSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SupabaseService.self) private var supabase
    @Query private var chips: [Chip]
    @Query(sort: \TaskItem.plannedAt) private var tasks: [TaskItem]
    @Query(sort: \ExternalItem.occurredAt) private var externalItems: [ExternalItem]

    /// Today's list when the sheet opened: rows do not jump while the user taps.
    @State private var dayTaskIds: [UUID] = []
    @State private var done: Set<UUID> = []
    @State private var choices: [UUID: Leftover] = [:]
    @State private var mood: Mood?
    @State private var moodLabel: String?
    @State private var didLoad = false

    enum Leftover: String, CaseIterable, Identifiable {
        case tomorrow, backlog, drop

        var id: String { rawValue }

        var label: String {
            switch self {
            case .tomorrow: "Mai"
            case .backlog: "Hộp chờ"
            case .drop: "Bỏ"
            }
        }

        var systemImage: String {
            switch self {
            case .tomorrow: "arrow.turn.up.right"
            case .backlog: "tray"
            case .drop: "xmark"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    doneSection
                    leftoverSection
                    moodSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.groupedBackground)
            .safeAreaInset(edge: .bottom) {
                Button(action: save) {
                    Text("Khép lại hôm nay").font(.headline).frame(maxWidth: .infinity)
                }
                .appPrimaryButton()
                .frame(maxWidth: 600)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .navigationTitle("Khép lại hôm nay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(DayClock.time(Date())).foregroundStyle(.secondary).fixedSize()
                }
            }
        }
        .onAppear(perform: load)
    }

    // MARK: Sections

    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetSectionHeader(title: "Hôm nay đã xong", subtitle: doneSubtitle)
            if dayTasks.isEmpty {
                Text("Không có việc nào trong danh sách hôm nay.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ChipGroupContainer {
                    ForEach(dayTasks) { task in
                        ChipButton(title: task.title, isOn: done.contains(task.id)) {
                            if done.contains(task.id) { done.remove(task.id) } else { done.insert(task.id) }
                        }
                    }
                }
            }
        }
    }

    private var doneSubtitle: String {
        var parts = ["\(done.count)/\(dayTasks.count) việc"]
        if syncedToday > 0 { parts.append("cùng \(syncedToday) mục từ Lịch, GitHub, Jira, Sức khỏe") }
        return parts.joined(separator: " · ") + ". Chạm việc đã làm mà chưa tick."
    }

    @ViewBuilder
    private var leftoverSection: some View {
        let open = dayTasks.filter { !done.contains($0.id) }
        let sortable = open.filter(TodayList.needsShutdownDecision)
        let automatic = open.count - sortable.count
        VStack(alignment: .leading, spacing: 8) {
            SheetSectionHeader(title: "Việc còn lại", subtitle: sortable.isEmpty ? nil : "Mặc định chuyển sang mai")
            if open.isEmpty {
                Text("Không còn việc nào dang dở.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(sortable) { task in
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.title)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    ChipGroupContainer {
                        ForEach(Leftover.allCases) { choice in
                            ChipButton(title: choice.label, isOn: choices[task.id] == choice, systemImage: choice.systemImage) {
                                choices[task.id] = choice
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardBackground, in: .rect(cornerRadius: 18))
            }
            if automatic > 0 {
                Text("\(automatic) việc từ GitHub, Jira hoặc việc lặp lại tự cập nhật theo nguồn, không cần xếp.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetSectionHeader(title: "Cả ngày thế nào?")
            ChipGroupContainer {
                ForEach(ChipStore.moodOptions(chips)) { chip in
                    let isOn = moodLabel == chip.label
                    ChipButton(title: chip.label, isOn: isOn, systemImage: chip.symbol ?? chip.level?.symbol) {
                        mood = isOn ? nil : chip.level
                        moodLabel = isOn || chip.level == nil ? nil : chip.label
                    }
                }
            }
        }
    }

    // MARK: Data

    private var dayTasks: [TaskItem] {
        dayTaskIds.compactMap { id in tasks.first { $0.id == id } }
    }

    /// Meetings, PRs, tickets, workouts… that happened today (sleep is context, not work).
    private var syncedToday: Int {
        let now = Date()
        let start = DayClock.startOfDay(now)
        return externalItems.filter {
            $0.occurredAt >= start && $0.occurredAt <= now && $0.kind != "sleep" && $0.decision != "ignored"
        }.count
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let now = Date()
        let today = TodayList.tasks(tasks, now: now)
        dayTaskIds = today.map(\.id)
        done = Set(today.filter { $0.status == .done }.map(\.id))
        for task in today where task.status != .done && TodayList.needsShutdownDecision(task) {
            choices[task.id] = .tomorrow
        }
        if let checkIn = CheckInService.todaysCheckIn(context, now: now), checkIn.closedAt != nil {
            mood = checkIn.dayMood
            moodLabel = checkIn.dayMood == nil ? nil : (checkIn.dayMoodLabel ?? checkIn.dayMood?.label)
        }
    }

    private func save() {
        let serverPush = supabase.hasServerPush
        let finished = dayTasks.filter { done.contains($0.id) && $0.status != .done }
        let leftovers = dayTasks.compactMap { task -> (TaskItem, Leftover)? in
            guard !done.contains(task.id), task.status == .todo || task.status == .doing,
                  let choice = choices[task.id] else { return nil }
            return (task, choice)
        }
        CheckInService.closeDay(mood: mood, moodLabel: moodLabel, in: context)

        Task {
            for task in finished {
                await TaskActions.setDone(task, true, serverPushActive: serverPush)
            }
            for (task, choice) in leftovers {
                switch choice {
                case .tomorrow:
                    if task.plannedAt != nil {
                        await TaskActions.postponeToTomorrow(task, serverPushActive: serverPush)
                    } else {
                        // No time: it carries over by itself; still counts as moved.
                        task.postponeCount += 1
                    }
                case .backlog:
                    TaskActions.moveToBacklog(task)
                case .drop:
                    TaskActions.cancel(task)
                }
            }
            try? context.save()
            await NotificationService.rescheduleShutdown(in: context)
            await supabase.syncPending(context)
            WidgetBridge.publish()
        }
        dismiss()
    }
}
