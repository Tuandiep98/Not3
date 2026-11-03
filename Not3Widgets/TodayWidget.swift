import AppIntents
import SwiftUI
import WidgetKit

/// "Việc hôm nay": tick tasks right on the widget. GitHub / Jira tasks show their logo; sent-back
/// tasks show why. Large adds the morning (design "Widget lớn · Hôm nay").
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.today, provider: SnapshotProvider()) { entry in
            TodayWidgetView(entry: entry)
                // App lock on: hidden on the Lock Screen / locked device.
                .privacySensitive(entry.snapshot.isPrivate == true)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Việc hôm nay")
        .description("Tích xong ngay trên màn hình chính, kể cả việc từ GitHub và Jira.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct TodayWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var s: WidgetSnapshot { entry.snapshot }
    private var isToday: Bool { Calendar.current.isDate(s.day, inSameDayAs: entry.date) }

    private var capacity: Int {
        switch family {
        case .systemSmall: 2
        case .systemMedium: 3
        default: 5
        }
    }

    /// Open work first when space is short; finished ones fill what is left (still ticked).
    private var rows: [WidgetSnapshot.TaskRow] {
        let tasks = isToday ? s.tasks : s.openTasks
        let open = tasks.filter { !$0.isDone }
        let done = tasks.filter(\.isDone)
        let picked = Set((open + done).prefix(capacity).map(\.id))
        return tasks.filter { picked.contains($0.id) }
    }

    private var doneCount: Int { (isToday ? s.tasks : []).filter(\.isDone).count }
    private var total: Int { isToday ? s.tasks.count : s.openTasks.count }

    var body: some View {
        VStack(spacing: 0) {
            WidgetHeader(title: family == .systemSmall ? "Hôm nay" : "Việc hôm nay", systemImage: family == .systemSmall ? nil : "checklist") {
                if total > 0 { Text("\(doneCount)/\(total)").monospacedDigit() }
            }
            VStack(alignment: .leading, spacing: 0) {
                if family == .systemLarge && isToday && !s.morning.isEmpty {
                    sectionTitle("Buổi sáng")
                    ForEach(s.morning.suffix(3)) { item in
                        HStack(spacing: 8) {
                            SourceMark(source: item.source, size: 12)
                            Text(item.title).font(.footnote).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(WFormat.time(item.time)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .frame(height: 22)
                    }
                    sectionTitle("Việc cần làm").padding(.top, 6)
                }
                if rows.isEmpty {
                    Spacer()
                    Text("Chưa có việc nào").font(.subheadline).foregroundStyle(.secondary)
                    Text("Chốt việc trong check-in 12h").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, task in
                        if index > 0 { Divider().padding(.leading, 30) }
                        TaskRowView(task: task, compact: family == .systemSmall, now: entry.date)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .widgetURL(DeepLink.today)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 2)
    }
}

struct TaskRowView: View {
    let task: WidgetSnapshot.TaskRow
    var compact = false
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: ToggleTaskIntent(taskID: task.id, done: !task.isDone)) {
                ZStack {
                    if task.isDone {
                        Circle().fill(WStyle.band)
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Circle().strokeBorder(WStyle.ring, lineWidth: 1.6)
                    }
                }
                .frame(width: 20, height: 20)
                .frame(width: 26, height: 34)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Bỏ đánh dấu: \(task.title)" : "Đánh dấu xong: \(task.title)")

            VStack(alignment: .leading, spacing: 0) {
                Text(task.title)
                    .font(compact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                    .lineLimit(1)
                if let reason = task.reopenedReason {
                    Text("↺ \(reason)").font(.caption2.weight(.medium)).foregroundStyle(.orange).lineLimit(1)
                } else {
                    let detail = WFormat.detail(task, now: now)
                    if !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 2)
            if task.source == "github" || task.source == "jira" {
                SourceMark(source: task.source, size: 12)
            }
        }
        .frame(minHeight: compact ? 40 : 38)
    }
}
