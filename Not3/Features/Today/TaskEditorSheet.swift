import SwiftData
import SwiftUI

/// Add or edit one task: title, category, when (today / a time / "Hộp chờ"), duration, repeat.
struct TaskEditorSheet: View {
    let target: TaskEditorTarget

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SupabaseService.self) private var supabase
    @Query private var chips: [Chip]
    @AppStorage(SettingsKey.checkInDurations) private var durationsRaw = IntList.encode(ChipCatalog.defaultDurations)

    @State private var title = ""
    @State private var category: String?
    @State private var when: When = .today
    @State private var date = DayClock.at(hour: 14, minute: 0)
    @State private var duration: Int?
    @State private var repeatChoice: RepeatChoice = .never
    @State private var weeklyDays: Set<Int> = [Recurrence.weekday(of: Date())]
    @State private var didLoad = false
    @State private var editingCategory: CategoryEdit?
    @FocusState private var titleFocused: Bool

    private enum When: Hashable { case today, at, someday }

    private enum RepeatChoice: String, CaseIterable, Identifiable {
        case never, daily, weekdays, weekly, monthly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .never: "Không lặp"
            case .daily: "Hằng ngày"
            case .weekdays: "Ngày thường (T2–T6)"
            case .weekly: "Hằng tuần"
            case .monthly: "Hằng tháng"
            }
        }
    }

    private var task: TaskItem? {
        guard case .edit(let id) = target else { return nil }
        return TaskActions.task(id: id, in: context)
    }

    /// The user's durations, plus the task's own one when it is not in the list.
    private var durationOptions: [Int] {
        let list = IntList.decode(durationsRaw)
        guard let duration, !list.contains(duration) else { return list }
        return (list + [duration]).sorted()
    }

    private var series: TaskSeries? {
        RecurrenceService.series(id: task?.seriesId, in: context)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Việc cần làm", text: $title, axis: .vertical)
                        .font(.title3)
                        .focused($titleFocused)
                    ChipGroupContainer {
                        let ranked = CheckInPlanner.rankedCategories(chips)
                        ForEach(ranked) { chip in
                            ChipButton(title: chip.label, isOn: category == chip.label) {
                                category = category == chip.label ? nil : chip.label
                            }
                            .categoryChipMenu(chip, edit: $editingCategory, canDelete: ranked.count > 1) {
                                ChipStore.deleteCategory(chip, in: context)
                            }
                        }
                        ChipButton(title: "Thêm", systemImage: "plus") { editingCategory = .new }
                            .accessibilityLabel("Thêm danh mục")
                    }
                    .categoryEditor($editingCategory) { old, new in
                        // New one is picked; a rename of the picked one follows it.
                        if old == nil || category == old { category = new }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }

                Section("Khi nào") {
                    Picker("Khi nào", selection: $when) {
                        Text("Hôm nay").tag(When.today)
                        Text("Chọn giờ").tag(When.at)
                        Text("Hộp chờ").tag(When.someday)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if when == .at {
                        DatePicker("Lúc", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    }
                    ChipGroupContainer {
                        ForEach(durationOptions, id: \.self) { minutes in
                            ChipButton(title: "\(minutes)p", isOn: duration == minutes) {
                                duration = duration == minutes ? nil : minutes
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }

                if when != .someday {
                    repeatSection
                }

                if task != nil {
                    Section {
                        Button("Huỷ việc này", role: .destructive) {
                            if let task { TaskActions.cancel(task) }
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(task == nil ? "Việc mới" : "Sửa việc")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (repeatChoice == .weekly && weeklyDays.isEmpty))
                }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var repeatSection: some View {
        Section {
            Picker("Lặp lại", selection: $repeatChoice) {
                ForEach(RepeatChoice.allCases) { Text($0.label).tag($0) }
            }
            if repeatChoice == .weekly {
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { day in
                        let isOn = weeklyDays.contains(day)
                        Button(Recurrence.dayLabel(day)) {
                            if isOn { weeklyDays.remove(day) } else { weeklyDays.insert(day) }
                        }
                        .font(.subheadline.weight(isOn ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .buttonStyle(.plain)
                        .appChipStyle(isOn: isOn)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
            }
        } footer: {
            if let rule {
                let time = when == .at ? " lúc \(DayClock.time(date))" : ""
                Text("\(rule.label)\(time). Lần trước chưa xong sẽ tự huỷ khi tới lần mới.")
            }
        }
    }

    private var rule: Recurrence? {
        switch repeatChoice {
        case .never: nil
        case .daily: .daily
        case .weekdays: .weekdays
        case .weekly: weeklyDays.isEmpty ? nil : .weekly(weeklyDays)
        case .monthly: .monthly(DayClock.calendar.component(.day, from: when == .at ? date : Date()))
        }
    }

    // MARK: Load / save

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let task else {
            if case .new(let someday) = target, someday { when = .someday }
            // Default time: 14:00, or the next whole hour once that has passed.
            let now = Date()
            if date <= now {
                date = DayClock.calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
            }
            titleFocused = true
            return
        }
        title = task.title
        category = task.category
        duration = task.durationMinutes
        if task.isSomeday {
            when = .someday
        } else if let planned = task.plannedAt {
            when = .at
            date = max(planned, Date())
        }
        if let series, series.isActive {
            switch series.rule {
            case .daily: repeatChoice = .daily
            case .weekdays: repeatChoice = .weekdays
            case .weekly(let days): repeatChoice = .weekly; weeklyDays = days
            case .monthly: repeatChoice = .monthly
            }
        }
    }

    private func save() async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let push = supabase.hasServerPush
        let task: TaskItem
        if let existing = self.task {
            task = existing
        } else {
            task = TaskItem(title: trimmed, category: category, plannedAt: nil, durationMinutes: duration, source: .manual)
            context.insert(task)
        }
        let plannedBefore = task.plannedAt
        let somedayBefore = task.isSomeday
        task.title = trimmed
        if let category, category != task.category {
            CheckInService.bumpChip(group: .category, label: category, in: context)
        }
        task.category = category
        task.durationMinutes = duration
        task.touch()

        switch when {
        case .someday:
            TaskActions.moveToBacklog(task)
        case .today:
            if somedayBefore || plannedBefore != nil || self.task == nil {
                await TaskActions.schedule(task, at: nil, serverPushActive: push)
            }
        case .at:
            if somedayBefore || plannedBefore != date || self.task == nil {
                await TaskActions.schedule(task, at: date, serverPushActive: push)
            }
        }
        // Title / duration edits of a planned task: keep its calendar event in step.
        if task.calendarEventId != nil, task.plannedAt != nil { CalendarService.shared.writePlan(task) }

        if when != .someday, let rule {
            if let series {
                series.rule = rule
                series.isActive = true
                RecurrenceService.apply(task: task, to: series)
            } else {
                _ = RecurrenceService.makeRepeating(task, rule: rule, addToCalendar: task.calendarEventId != nil, in: context)
            }
        } else if let series, series.isActive {
            RecurrenceService.stop(series)
        }
        try? context.save()
        dismiss()
    }
}
