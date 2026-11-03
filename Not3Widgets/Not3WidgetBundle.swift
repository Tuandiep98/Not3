import SwiftUI
import WidgetKit

@main
struct Not3WidgetBundle: WidgetBundle {
    var body: some Widget {
        CheckInWidget()
        TodayWidget()
        WeekWidget()
        FolderWidget()
        NewTaskControl()
        CheckInControl()
        NextTaskControl()
    }
}

#Preview("Check-in", as: .systemMedium) {
    CheckInWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: Timelines.preview)
}

#Preview("Hôm nay", as: .systemLarge) {
    TodayWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: Timelines.preview)
}
