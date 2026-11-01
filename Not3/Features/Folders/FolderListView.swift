import SwiftData
import SwiftUI

/// "Thư mục" — pinned Hôm nay / Tổng kết tuần, then the iCloud folders (artboard `Main`).
struct FolderListView: View {
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]
    @Query private var notes: [Note]
    @Query private var tasks: [TaskItem]

    @State private var searchText = ""
    @State private var isAddingFolder = false
    @State private var newFolderName = ""
    @State private var isShowingSettings = false

    var body: some View {
        List {
            if searchText.isEmpty {
                pinnedSection
                foldersSection
            } else {
                searchResults
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Thư mục")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Tìm kiếm")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cài đặt", systemImage: "ellipsis") { isShowingSettings = true }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Thư mục mới", systemImage: "folder.badge.plus") { isAddingFolder = true }
            }
            if #available(iOS 26, *) {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            } else {
                ToolbarItem(placement: .bottomBar) { Spacer() }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Ghi chú mới", systemImage: "square.and.pencil") { createNote() }
            }
        }
        .alert("Thư mục mới", isPresented: $isAddingFolder) {
            TextField("Tên", text: $newFolderName)
            Button("Huỷ", role: .cancel) { newFolderName = "" }
            Button("Lưu") { addFolder() }
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-openSettings") { isShowingSettings = true }
        }
        #endif
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack { SettingsView() }
        }
    }

    private var pinnedSection: some View {
        Section {
            NavigationLink(value: Route.today) {
                FolderRow(title: "Hôm nay", systemImage: "sun.max", count: todayCount)
            }
            NavigationLink(value: Route.summary) {
                FolderRow(title: "Tổng kết tuần", systemImage: "chart.bar", countText: "\(meaningfulDays)/7")
            }
        }
    }

    private var foldersSection: some View {
        Section("iCloud") {
            NavigationLink(value: Route.allNotes) {
                FolderRow(title: "Tất cả ghi chú", systemImage: "folder", count: notes.count)
            }
            ForEach(folders) { folder in
                NavigationLink(value: Route.folder(folder.persistentModelID)) {
                    FolderRow(title: folder.name, systemImage: "folder", count: folder.notes?.count ?? 0)
                }
            }
            .onDelete(perform: deleteFolders)
        }
        .headerProminence(.increased)
    }

    private var searchResults: some View {
        let query = searchText.lowercased()
        let matches = notes.filter {
            $0.title.lowercased().contains(query) || $0.body.lowercased().contains(query)
        }
        return Section("\(matches.count) ghi chú") {
            ForEach(matches) { note in
                NavigationLink(value: Route.note(note.persistentModelID)) {
                    NoteRow(note: note)
                }
            }
        }
    }

    private var todayCount: Int {
        let start = DayClock.startOfDay()
        let end = DayClock.endOfDay()
        return tasks.filter { task in
            let date = task.plannedAt ?? task.completedAt ?? task.createdAt
            return date >= start && date < end && task.status != .cancelled
        }.count
    }

    private var meaningfulDays: Int {
        DayClock.daysOfWeek().filter { CheckInPlanner.isMeaningful(day: $0, tasks: tasks) }.count
    }

    private func addFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        newFolderName = ""
        guard !name.isEmpty else { return }
        context.insert(Folder(name: name, sortOrder: (folders.last?.sortOrder ?? 0) + 1))
    }

    private func deleteFolders(_ offsets: IndexSet) {
        offsets.map { folders[$0] }.forEach(context.delete)
    }

    private func createNote() {
        let note = Note(folder: folders.first { $0.name == "Ghi chú nhanh" })
        context.insert(note)
        router.path.append(.note(note.persistentModelID))
    }
}

struct FolderRow: View {
    let title: String
    let systemImage: String
    var count: Int?
    var countText: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Theme.folderIcon)
                .frame(width: 28)
            Text(title)
            Spacer()
            Text(countText ?? count.map(String.init) ?? "")
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
    }
}
