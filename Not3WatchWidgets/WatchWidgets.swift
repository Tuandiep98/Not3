import SwiftUI
import WidgetKit

// Watch face complications from the snapshot the watch app keeps in its App Group.

struct WatchEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { WatchEntry(date: Date(), snapshot: .empty) }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        completion(WatchEntry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    /// The "next" task changes as planned times pass; midnight starts a new day.
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        let now = Date()
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
        let dates = Set([now, midnight] + snapshot.tasks.compactMap(\.plannedAt).filter { $0 > now && $0 < midnight }).sorted()
        completion(Timeline(entries: dates.map { WatchEntry(date: $0, snapshot: snapshot) },
                            policy: .after(min(midnight, now.addingTimeInterval(30 * 60)))))
    }
}

private extension WatchEntry {
    var isToday: Bool { Calendar.current.isDate(snapshot.day, inSameDayAs: date) }
    var week: [Bool] { isToday || Calendar.current.isDate(snapshot.day, equalTo: date, toGranularity: .weekOfYear) ? snapshot.week : [] }
    /// The task in progress, else the first open one still ahead.
    var next: WidgetSnapshot.TaskRow? {
        guard isToday else { return nil }
        let open = snapshot.openTasks
        return open.first { $0.status == "doing" } ?? open.first { ($0.plannedAt ?? .distantFuture) >= date } ?? open.first
    }
}

struct WeekComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Not3WatchWeek", provider: WatchProvider()) { entry in
            let days = entry.week.filter { $0 }.count
            Gauge(value: Double(days), in: 0...7) {
                Image(systemName: "checkmark")
            } currentValueLabel: {
                Text("\(days)")
            }
            .gaugeStyle(.accessoryCircular)
            .widgetURL(DeepLink.today)
            .containerBackground(for: .widget) { Color.clear }
            .accessibilityLabel("\(days) trên 7 ngày có làm được việc")
        }
        .configurationDisplayName("Tuần này")
        .description("Số ngày trong tuần đã xong ít nhất một việc.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct NextTaskComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Not3WatchNext", provider: WatchProvider()) { entry in
            NextTaskComplicationView(entry: entry)
                .privacySensitive(entry.snapshot.isPrivate == true)
                .widgetURL(DeepLink.today)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Việc tiếp theo")
        .description("Việc đang làm hoặc việc tiếp theo hôm nay.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

private struct NextTaskComplicationView: View {
    let entry: WatchEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let next = entry.next
        let left = entry.isToday ? entry.snapshot.openTasks.count : 0
        let time = next?.plannedAt.map { $0.formatted(date: .omitted, time: .shortened) }
        switch family {
        case .accessoryInline:
            if let next {
                Text([time, next.title].compactMap { $0 }.joined(separator: " "))
            } else {
                Text("Not3 · không còn việc")
            }
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text(next?.status == "doing" ? "Đang làm" : "Tiếp theo")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .widgetAccentable()
                Text(next?.title ?? "Không còn việc hôm nay")
                    .font(.headline)
                    .lineLimit(2)
                if left > 0 {
                    Text([time, "còn \(left) việc"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@main
struct Not3WatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WeekComplication()
        NextTaskComplication()
    }
}
