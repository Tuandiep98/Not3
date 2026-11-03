import SwiftUI

/// "Hôm nay" on the watch: check-in when it is due, then today's tasks (tap = tick,
/// swipe = Bắt đầu) and "Thêm việc" by dictation.
struct WatchTodayView: View {
    @Environment(WatchStore.self) private var store

    private var s: WidgetSnapshot { store.snapshot }
    private var isToday: Bool { Calendar.current.isDateInToday(s.day) }

    var body: some View {
        NavigationStack {
            List {
                if isToday, s.checkInAt == nil, Date() >= s.checkInTime(on: Date()) {
                    NavigationLink {
                        WatchCheckInView()
                    } label: {
                        Label(String(format: "Check-in %02d:%02d", s.checkInHour, s.checkInMinute), systemImage: "clock")
                            .foregroundStyle(.orange)
                    }
                }

                if let plan = s.plan, isToday, plan.status != "done" {
                    Section("Kế hoạch") {
                        Text(plan.sentence).font(.footnote)
                        if plan.status == "todo" {
                            Button("Bắt đầu", systemImage: "play.fill") {
                                store.perform(WidgetAction(kind: .startTask, taskId: plan.taskId))
                            }
                        }
                    }
                }

                Section {
                    if !isToday || s.tasks.isEmpty {
                        Text(s.generatedAt == .distantPast ? "Mở Not3 trên iPhone một lần để đồng bộ." : "Chưa có việc nào hôm nay.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(s.tasks) { task in
                            WatchTaskRow(task: task)
                        }
                    }
                    TextFieldLink(prompt: Text("Việc cần làm")) {
                        Label("Thêm việc", systemImage: "plus")
                    } onSubmit: { text in
                        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty else { return }
                        store.perform(WidgetAction(kind: .addTask, title: title))
                    }
                } header: {
                    if isToday, !s.tasks.isEmpty {
                        Text("\(s.tasks.filter(\.isDone).count)/\(s.tasks.count) xong")
                    }
                }
            }
            .navigationTitle("Hôm nay")
        }
    }
}

private struct WatchTaskRow: View {
    let task: WidgetSnapshot.TaskRow
    @Environment(WatchStore.self) private var store

    var body: some View {
        Button {
            store.perform(WidgetAction(kind: .setTaskDone, taskId: task.id, done: !task.isDone))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .strikethrough(task.isDone)
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                        .lineLimit(2)
                    if let detail {
                        Text(detail).font(.caption2).foregroundStyle(task.reopenedReason == nil ? .secondary : .orange)
                    }
                }
            }
        }
        .swipeActions {
            if task.status == "todo" {
                Button("Bắt đầu", systemImage: "play.fill") {
                    store.perform(WidgetAction(kind: .startTask, taskId: task.id))
                }
                .tint(.blue)
            }
        }
        .accessibilityLabel("\(task.title), \(task.isDone ? "đã xong" : "chưa xong")")
    }

    private var detail: String? {
        if let reason = task.reopenedReason, !task.isDone { return "↺ Bị trả lại · \(reason)" }
        let time = task.plannedAt.map { $0.formatted(date: .omitted, time: .shortened) }
        let doing = task.status == "doing" ? "Đang làm" : nil
        let parts = [time, doing, task.durationMinutes.map { "\($0) phút" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Morning feeling in one tap, then the afternoon plan if there is one.
struct WatchCheckInView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let moods: [(raw: String, label: String, symbol: String)] = [
        ("good", "Hiệu quả", "sun.max.fill"),
        ("ok", "Bình thường", "cloud.sun.fill"),
        ("empty", "Trống", "moon.zzz.fill"),
    ]

    var body: some View {
        List {
            Section("Sáng nay thế nào?") {
                ForEach(moods, id: \.raw) { mood in
                    Button {
                        store.perform(WidgetAction(kind: .recordMood, mood: mood.raw))
                        dismiss()
                    } label: {
                        Label(mood.label, systemImage: mood.symbol)
                    }
                }
            }
            if !store.snapshot.morning.isEmpty {
                Section("Đã gom sẵn") {
                    ForEach(store.snapshot.morning.suffix(5)) { item in
                        Text(item.title).font(.footnote).lineLimit(2)
                    }
                }
            }
            Section {
                Text("Chọn việc buổi chiều trên iPhone.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Check-in")
    }
}
