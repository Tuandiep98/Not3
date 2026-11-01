#if DEBUG
import SwiftUI
import WidgetKit

/// DEBUG only (`-widgetGallery`): renders every widget state at home-screen sizes, so widgets can
/// be checked on the simulator without placing them on the home screen.
struct WidgetGalleryView: View {
    private let now = Date()
    private var cal: Calendar { .current }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if ProcessInfo.processInfo.arguments.contains("-widgetGallery2") { page2 } else { page1 }
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.14, green: 0.19, blue: 0.24))
    }

    @ViewBuilder
    private var page2: some View {
        HStack(spacing: 18) {
            VStack { label("Tuần này"); card(.small) { WeekWidgetView(entry: entry(at: at(13), snapshot: Timelines.preview)) } }
            VStack { label("Hôm nay (nhỏ)"); card(.small) { TodayWidgetView(entry: entry(at: at(13), snapshot: Timelines.preview)) } }
        }
        label("Thư mục ghi chú")
        card(.medium) { FolderWidgetView(entry: entry(at: at(13), snapshot: Timelines.preview)) }
        label("Hôm nay (lớn)")
        TodayWidgetView(entry: entry(at: at(13), snapshot: Timelines.preview))
            .frame(width: 338, height: 354)
            .background(Color(.systemBackground))
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var page1: some View {
                label("Check-in · trước giờ check-in")
                card(.medium) { CheckInWidgetView(entry: entry(at: at(10), snapshot: Timelines.preview)) }
                label("Check-in · chờ check-in")
                card(.medium) { CheckInWidgetView(entry: entry(at: at(12, 20), snapshot: Timelines.preview)) }
                label("Check-in · sau check-in")
                card(.medium) { CheckInWidgetView(entry: entry(at: at(12, 30), snapshot: planned)) }
                HStack(spacing: 18) {
                    VStack { label("Hôm nay (nhỏ)"); card(.small) { TodayWidgetView(entry: entry(at: at(13), snapshot: Timelines.preview)) } }
                    VStack { label("Tuần này"); card(.small) { WeekWidgetView(entry: entry(at: at(13), snapshot: Timelines.preview)) } }
                }
                label("Thư mục ghi chú")
                card(.medium) { FolderWidgetView(entry: entry(at: at(13), snapshot: Timelines.preview)) }
    }

    private enum Size { case small, medium
        var frame: CGSize { self == .small ? CGSize(width: 158, height: 158) : CGSize(width: 338, height: 158) }
    }

    private func card<V: View>(_ size: Size, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(width: size.frame.width, height: size.frame.height)
            .background(Color(.systemBackground))
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.white.opacity(0.85))
    }

    private func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: now)! }

    private func entry(at date: Date, snapshot: WidgetSnapshot) -> SnapshotEntry {
        SnapshotEntry(date: date, snapshot: snapshot)
    }

    private var planned: WidgetSnapshot {
        var s = Timelines.preview
        s.mood = "ok"
        s.checkInAt = at(12, 4)
        let task = s.tasks[0]
        s.plan = .init(taskId: task.id, title: task.title, sentence: "Lúc 14:00, mình sẽ học 20 từ vựng Anki trong 25 phút.",
                       plannedAt: task.plannedAt, durationMinutes: 25, status: "todo")
        return s
    }
}
#endif
