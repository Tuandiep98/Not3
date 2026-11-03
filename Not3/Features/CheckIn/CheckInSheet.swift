import SwiftData
import SwiftUI

/// "Check-in buổi trưa" sheet (artboard `CheckIn`). Everything is chips — typing only via "Khác…",
/// voice via the mic chip.
struct CheckInSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SupabaseService.self) private var supabase
    @Environment(CalendarService.self) private var calendar
    @AppStorage(SettingsKey.addToCalendar) private var addToCalendar = true
    @Query private var chips: [Chip]
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var tasks: [TaskItem]
    @Query(sort: \ExternalItem.occurredAt) private var externalItems: [ExternalItem]

    @State private var morningOptions: [String] = []
    @State private var confirmedMorning: Set<String> = []
    /// Morning chips that came from the server, label → suggestion id.
    @State private var morningServerIds: [String: UUID] = [:]
    @State private var mood: Mood?
    @State private var suggestions: [AfternoonSuggestion] = []
    @State private var selectedTask: AfternoonSuggestion?
    @State private var timeOptions: [TimeOption] = []
    @State private var selectedTime: TimeOption?
    @State private var duration: Int? = 25
    @State private var addingMode: AddMode?
    @State private var draftText = ""
    @State private var isShowingVoice = false
    @State private var didLoad = false

    private enum AddMode { case morning, afternoon }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    morningSection
                    moodSection
                    afternoonSection
                    timeSection
                    planCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 24)
                // Readable width in landscape / on iPad.
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.groupedBackground)
            .safeAreaInset(edge: .bottom) {
                Button(action: save) {
                    Text("Lưu kế hoạch").font(.headline).frame(maxWidth: .infinity)
                }
                .appPrimaryButton()
                .disabled(mood == nil && selectedTask == nil && confirmedMorning.isEmpty)
                .frame(maxWidth: 600)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .navigationTitle("Check-in buổi trưa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(DayClock.time(Date())).foregroundStyle(.secondary).fixedSize()
                }
            }
            .alert(addingMode == .morning ? "Sáng nay đã làm" : "Chiều nay làm gì?",
                   isPresented: Binding(get: { addingMode != nil }, set: { if !$0 { addingMode = nil } })) {
                TextField("Khác…", text: $draftText)
                Button("Huỷ", role: .cancel) { draftText = "" }
                Button("Thêm") { addDraft() }
            }
            .sheet(isPresented: $isShowingVoice) {
                VoiceCaptureSheet(onDone: applyVoice)
            }
        }
        .onAppear(perform: load)
        .task {
            // Background refresh is not guaranteed on time: read Calendar again when the sheet opens.
            await calendar.refresh(in: context)
            mergeMorning(todaysExternalTitles())
            await loadServerSuggestions()
        }
    }

    // MARK: Sections

    private var morningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetSectionHeader(
                title: "Sáng nay đã làm",
                subtitle: morningOptions.isEmpty
                    ? "Chạm \"Thêm\" để ghi lại việc buổi sáng"
                    : "Gợi ý từ dữ liệu buổi sáng · chạm để xác nhận"
            )
            ChipGroupContainer {
                ForEach(morningOptions, id: \.self) { item in
                    ChipButton(title: item, isOn: confirmedMorning.contains(item)) {
                        toggle(item, in: &confirmedMorning)
                    }
                }
                ChipButton(title: "Thêm", systemImage: "plus") { addingMode = .morning }
            }
        }
    }

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetSectionHeader(title: "Cảm nhận buổi sáng")
            ChipGroupContainer {
                ForEach(Mood.allCases) { option in
                    ChipButton(title: option.label, isOn: mood == option) {
                        mood = mood == option ? nil : option
                    }
                }
            }
        }
    }

    private var afternoonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetSectionHeader(title: "Chiều nay làm gì?", subtitle: "Việc sáng chưa xong, hoặc chọn một gợi ý")
            let leftovers = leftoverFromMorning
            if !leftovers.isEmpty {
                Text("Chưa xong từ sáng")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                ChipGroupContainer {
                    ForEach(leftovers) { suggestion in
                        ChipButton(title: suggestion.title, isOn: selectedTask == suggestion,
                                   systemImage: "arrow.uturn.forward") {
                            select(suggestion)
                        }
                    }
                }
                Text("Gợi ý")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            ChipGroupContainer {
                ForEach(suggestions.prefix(ChipCatalog.maxPerRow)) { suggestion in
                    ChipButton(title: suggestion.title, isOn: selectedTask == suggestion) {
                        select(suggestion)
                    }
                }
                ChipButton(title: "Khác…", systemImage: "plus") { addingMode = .afternoon }
                ChipButton(title: "Nói", systemImage: "mic") { isShowingVoice = true }
                    .accessibilityLabel("Nhập bằng giọng nói")
            }
        }
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetSectionHeader(title: "Lúc mấy giờ, bao lâu?")
            ChipGroupContainer {
                ForEach(timeOptions) { option in
                    ChipButton(title: option.label, isOn: selectedTime == option) {
                        selectedTime = selectedTime == option ? nil : option
                    }
                }
            }
            ChipGroupContainer {
                ForEach(ChipCatalog.durations, id: \.self) { minutes in
                    ChipButton(title: "\(minutes) phút", isOn: duration == minutes) {
                        duration = duration == minutes ? nil : minutes
                    }
                }
            }
            Toggle(isOn: $addToCalendar) {
                Label("Thêm vào Lịch", systemImage: "calendar.badge.plus")
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var planCard: some View {
        if let task = selectedTask {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kế hoạch nếu – thì").font(.footnote).foregroundStyle(.secondary)
                Text(CheckInPlanner.sentence(task: task.title, time: selectedTime, duration: duration))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: .rect(cornerRadius: 18))
            .transition(.opacity)
        }
    }

    // MARK: Loading

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let now = Date()
        let start = DayClock.startOfDay(now)

        var items = todaysExternalTitles(now: now)
        items += tasks.filter { task in
            guard task.status == .done, let done = task.completedAt else { return false }
            return done >= start
        }.map(\.title)

        if let existing = CheckInService.todaysCheckIn(context, now: now) {
            items += existing.morningItems.filter { !items.contains($0) }
            confirmedMorning = Set(existing.morningItems)
            mood = existing.mood
        } else {
            confirmedMorning = Set(items)
        }
        morningOptions = items

        suggestions = CheckInPlanner.suggestions(categories: chips, recentTasks: tasks, now: now)
            + CheckInPlanner.backlogSuggestions(tasks)
        timeOptions = CheckInPlanner.timeOptions(now: now)
        selectedTime = timeOptions.first
    }

    private func todaysExternalTitles(now: Date = Date()) -> [String] {
        let start = DayClock.startOfDay(now)
        return externalItems.filter { $0.occurredAt >= start && $0.occurredAt <= now }.map(\.title)
    }

    /// New morning items (Calendar just re-read, server sync) appear unconfirmed: tap to confirm.
    private func mergeMorning(_ titles: [String]) {
        for title in titles where !morningOptions.contains(title) {
            morningOptions.append(title)
        }
    }

    /// Server chips (built at check-in − 15 min) go first; local rules fill the rest.
    private func loadServerSuggestions() async {
        let records = await supabase.fetchSuggestions(day: Date())
        guard !records.isEmpty else { return }
        var serverTasks: [AfternoonSuggestion] = []
        for record in records {
            switch record.kind {
            case "morning_chip":
                guard let label = record.payload.label else { continue }
                morningServerIds[label] = record.id
                if !morningOptions.contains(label) { morningOptions.append(label) }
            case "afternoon_task":
                guard let title = record.payload.title else { continue }
                serverTasks.append(AfternoonSuggestion(
                    title: title,
                    category: record.payload.category,
                    source: .ai,
                    durationMinutes: record.payload.durationMinutes,
                    serverId: record.id
                ))
            default:
                continue
            }
        }
        let serverTitles = Set(serverTasks.map(\.title))
        // Typed-in chips first; rule chips and "Hộp chờ" items (they carry a taskId) after the server's.
        let isCustom: (AfternoonSuggestion) -> Bool = { $0.category == nil && $0.taskId == nil }
        let custom = suggestions.filter(isCustom)
        suggestions = custom + serverTasks + suggestions.filter { !isCustom($0) && !serverTitles.contains($0.title) }
    }

    // MARK: Actions

    /// Unfinished morning work that can move to the afternoon:
    /// open tasks not yet planned for later today (incl. carried over), and morning chips left
    /// unticked in "Sáng nay đã làm" (updates live as you tick / untick above).
    private var leftoverFromMorning: [AfternoonSuggestion] {
        let now = Date()
        var result: [AfternoonSuggestion] = []
        var seen = Set<String>()
        for task in TodayList.tasks(tasks, now: now)
        where (task.status == .todo || task.status == .doing) && (task.plannedAt.map { $0 <= now } ?? true) {
            guard seen.insert(task.title).inserted else { continue }
            result.append(AfternoonSuggestion(title: task.title, category: task.category, source: task.source,
                                              durationMinutes: task.durationMinutes, taskId: task.id))
        }
        let start = DayClock.startOfDay(now)
        for title in morningOptions where !confirmedMorning.contains(title) {
            guard seen.insert(title).inserted else { continue }
            if let task = tasks.first(where: { $0.title == title }) {
                result.append(AfternoonSuggestion(title: title, category: task.category, source: task.source,
                                                  durationMinutes: task.durationMinutes, taskId: task.id))
            } else if let item = externalItems.first(where: { $0.title == title && $0.occurredAt >= start }),
                      item.source != .calendar {
                result.append(AfternoonSuggestion(title: title, category: ChipCatalog.workCategory, source: .integration,
                                                  externalKey: "\(item.sourceRaw)|\(item.externalId)"))
            } else {
                result.append(AfternoonSuggestion(title: title, category: nil, source: .manual))
            }
        }
        return result
    }

    private func select(_ suggestion: AfternoonSuggestion) {
        if selectedTask == suggestion {
            selectedTask = nil
            return
        }
        selectedTask = suggestion
        if let minutes = suggestion.durationMinutes { duration = minutes }
    }

    private func addDraft() {
        let text = draftText.trimmingCharacters(in: .whitespaces)
        draftText = ""
        guard !text.isEmpty, let mode = addingMode else { return }
        switch mode {
        case .morning:
            if !morningOptions.contains(text) { morningOptions.append(text) }
            confirmedMorning.insert(text)
        case .afternoon:
            addCustomTask(text)
        }
        addingMode = nil
    }

    private func addCustomTask(_ title: String) {
        let custom = AfternoonSuggestion(title: title, category: nil, source: .manual)
        suggestions.insert(custom, at: 0)
        selectedTask = custom
    }

    /// Voice → chips: task title, duration and time are pulled out of the sentence.
    private func applyVoice(_ text: String) {
        let parsed = VoiceChipParser.parse(text)
        if !parsed.title.isEmpty { addCustomTask(parsed.title) }
        if let minutes = parsed.durationMinutes { duration = minutes }
        if let hour = parsed.hour {
            let date = DayClock.at(hour: hour, minute: parsed.minute ?? 0)
            if let match = timeOptions.first(where: { abs($0.date.timeIntervalSince(date)) < 60 }) {
                selectedTime = match
            } else if date > Date() {
                let label = String(format: "%02d:%02d", hour, parsed.minute ?? 0)
                let option = TimeOption(id: label, label: label, date: date)
                timeOptions.append(option)
                timeOptions.sort { $0.date < $1.date }
                selectedTime = option
            }
        }
    }

    private func toggle(_ item: String, in set: inout Set<String>) {
        if set.contains(item) { set.remove(item) } else { set.insert(item) }
    }

    private func save() {
        let plan = CheckInService.Plan(
            morningItems: morningOptions.filter(confirmedMorning.contains),
            mood: mood,
            task: selectedTask,
            time: selectedTask == nil ? nil : selectedTime,
            durationMinutes: selectedTask == nil ? nil : duration
        )
        let task = CheckInService.save(plan, in: context)
        let wantsCalendar = addToCalendar && task?.plannedAt != nil
        let linkedItem = selectedTask?.externalKey.flatMap { key in
            externalItems.first { "\($0.sourceRaw)|\($0.externalId)" == key }
        }

        let serverAfternoon = suggestions.compactMap(\.serverId)
        let pickedAfternoon = selectedTask?.serverId.map { [$0] } ?? []
        let pickedMorning = morningServerIds.filter { confirmedMorning.contains($0.key) }.map(\.value)
        let picked = pickedAfternoon + pickedMorning
        let dismissed = (serverAfternoon + Array(morningServerIds.values)).filter { !picked.contains($0) }

        Task {
            await NotificationService.requestAuthorization()
            if let task, wantsCalendar, await calendar.requestAccess() {
                calendar.writePlan(task)
                try? context.save()
            }
            if let task {
                await NotificationService.scheduleTaskNotifications(for: task, serverPushActive: supabase.hasServerPush)
            }
            if let task, let linkedItem {
                await supabase.attach(task, to: linkedItem, context: context)
            }
            await NotificationService.rescheduleCheckIns(in: context, serverPushActive: supabase.hasServerPush)
            await supabase.syncPending(context)
            await supabase.markSuggestions(picked: picked, dismissed: dismissed)
        }
        dismiss()
    }
}
