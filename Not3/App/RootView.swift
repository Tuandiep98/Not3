import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(Router.self) private var router

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-widgetGallery") {
            WidgetGalleryView()
        } else {
            main
        }
        #else
        main
        #endif
    }

    @ViewBuilder
    private var main: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            FolderListView()
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .sheet(isPresented: $router.isCheckInPresented) {
            CheckInSheet()
                .appCheckInSheet()
        }
        .sheet(item: $router.taskEditor) { target in
            TaskEditorSheet(target: target)
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .today:
            TodayView()
        case .backlog:
            BacklogView()
        case .summary:
            WeeklySummaryView()
        case .activityDay(let day):
            DayActivityView(day: day)
        case .activityHistory:
            ActivityHistoryView()
        case .activityMethod:
            ActivityMethodView()
        case .allNotes:
            NoteListView(folderID: nil)
        case .folder(let id):
            NoteListView(folderID: id)
        case .note(let id):
            NoteEditorView(noteID: id)
        }
    }
}
