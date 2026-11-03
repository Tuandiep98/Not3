import AppIntents
import SwiftUI
import WidgetKit

/// Check-in widget: changes with the time of day (design "Trạng thái widget theo giờ").
///  - before check-in: what was synced this morning (GitHub / Jira / Calendar)
///  - check-in time, not answered: "Sáng nay thế nào?" + 3 mood buttons (answer from the widget)
///  - after check-in: the if–then plan + "Bắt đầu" / its status
struct CheckInWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.checkIn, provider: SnapshotProvider()) { entry in
            CheckInWidgetView(entry: entry)
                // App lock on: hidden on the Lock Screen / locked device.
                .privacySensitive(entry.snapshot.isPrivate == true)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Check-in")
        .description("Buổi sáng, check-in 12h và kế hoạch chiều — đổi theo giờ.")
        .supportedFamilies([.systemMedium, .accessoryRectangular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

enum CheckInPhase {
    case morning, waiting, planned

    init(_ s: WidgetSnapshot, at date: Date) {
        let sameDay = Calendar.current.isDate(s.day, inSameDayAs: date)
        if sameDay && s.mood != nil {
            self = .planned
        } else if date >= s.checkInTime(on: date) {
            self = .waiting
        } else {
            self = .morning
        }
    }
}

struct CheckInWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var s: WidgetSnapshot { entry.snapshot }
    private var phase: CheckInPhase { CheckInPhase(s, at: entry.date) }
    private var isToday: Bool { Calendar.current.isDate(s.day, inSameDayAs: entry.date) }
    private var morning: [WidgetSnapshot.Item] { isToday ? s.morning : [] }
    private var checkInLabel: String { "Check-in " + WFormat.time(s.checkInTime(on: entry.date)) }
    private var nextTask: WidgetSnapshot.TaskRow? {
        s.openTasks.first { ($0.plannedAt ?? .distantFuture) >= entry.date } ?? s.openTasks.first
    }

    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryRectangular: rectangular
        default: medium
        }
    }

    // MARK: Lock screen

    @ViewBuilder
    private var inline: some View {
        switch phase {
        case .morning: Text("\(checkInLabel) · \(morning.count) mục")
        case .waiting: Text("\(checkInLabel) · chờ bạn")
        case .planned:
            if let task = nextTask { Text("\(task.plannedAt.map(WFormat.time) ?? "Tiếp") \(task.title)") } else { Text("Hôm nay xong việc") }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch phase {
            case .morning, .waiting:
                Text(checkInLabel).font(.headline).widgetAccentable()
                Text(morning.isEmpty ? "Sáng nay thế nào?" : "\(morning.count) mục chờ xác nhận").font(.caption)
                Text(morning.suffix(2).map(\.title).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            case .planned:
                Text("Việc tiếp theo").font(.caption).foregroundStyle(.secondary)
                Text(nextTask?.title ?? "Không còn việc nào").font(.headline).lineLimit(1).widgetAccentable()
                if let task = nextTask { Text(WFormat.detail(task, now: entry.date)).font(.caption) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(phase == .planned ? DeepLink.today : DeepLink.checkIn)
    }

    // MARK: Home screen (medium)

    private var medium: some View {
        VStack(spacing: 0) {
            switch phase {
            case .morning:
                WidgetHeader(title: "Sáng nay", systemImage: "sun.max") { Text(checkInLabel) }
                morningList
            case .waiting:
                WidgetHeader(title: checkInLabel, systemImage: "clock") {
                    if !morning.isEmpty { Text("\(morning.count) mục mới") }
                }
                moodPicker
            case .planned:
                WidgetHeader(title: "Chiều nay", systemImage: "sunset") {
                    if let at = s.checkInAt { Text("Check-in " + WFormat.time(at)) }
                }
                planBody
            }
        }
        .widgetURL(phase == .planned ? DeepLink.today : DeepLink.checkIn)
    }

    private var morningList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if morning.isEmpty {
                Spacer()
                Text("Chưa có gì từ GitHub, Jira hay Lịch.").font(.subheadline).foregroundStyle(.secondary)
                Text("Đến \(WFormat.time(s.checkInTime(on: entry.date))) mình sẽ hỏi bạn sáng nay thế nào.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(morning.suffix(3)) { item in
                    HStack(spacing: 8) {
                        SourceMark(source: item.source, size: 13)
                        Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(WFormat.time(item.time)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if morning.count > 3 {
                    Text("+\(morning.count - 3) mục khác").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var moodPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sáng nay thế nào?").font(.headline)
            Text(morning.isEmpty ? "Chạm một ô để ghi lại" : morning.suffix(3).map { $0.title.components(separatedBy: " · ").first ?? $0.title }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                ForEach([("good", "Hiệu quả"), ("ok", "Bình thường"), ("empty", "Trống")], id: \.0) { mood, label in
                    Button(intent: RecordMoodIntent(mood: mood)) {
                        Text(label).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(WStyle.chipText)
                    .background(WStyle.chipFill, in: .capsule)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var planBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let plan = s.plan {
                Text(plan.sentence).font(.headline).lineLimit(2).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                switch plan.status {
                case "done":
                    Label("Đã xong", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(WStyle.chipText)
                case "doing":
                    HStack {
                        Label("Đang làm", systemImage: "timer").font(.subheadline.weight(.semibold)).foregroundStyle(WStyle.chipText)
                        Spacer()
                        Button(intent: ToggleTaskIntent(taskID: plan.taskId, done: true)) {
                            Text("Xong").font(.footnote.weight(.semibold)).padding(.horizontal, 16).frame(minHeight: 34)
                        }
                        .buttonStyle(.plain).foregroundStyle(.white).background(WStyle.band, in: .capsule)
                    }
                default:
                    Button(intent: StartTaskIntent(taskID: plan.taskId)) {
                        Text(plan.durationMinutes.map { "Bắt đầu \($0) phút" } ?? "Bắt đầu")
                            .font(.footnote.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.plain).foregroundStyle(.white).background(WStyle.band, in: .capsule)
                }
            } else {
                Text(nextTask.map { "Tiếp theo: \($0.title)" } ?? "Không còn việc nào hôm nay").font(.headline).lineLimit(2)
                Spacer(minLength: 0)
                Text("Đã check-in sáng nay").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
