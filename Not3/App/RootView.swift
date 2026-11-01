import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(Router.self) private var router

    var body: some View {
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
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .today:
            TodayView()
        case .summary:
            WeeklySummaryView()
        case .allNotes:
            NoteListView(folderID: nil)
        case .folder(let id):
            NoteListView(folderID: id)
        case .note(let id):
            NoteEditorView(noteID: id)
        }
    }
}
