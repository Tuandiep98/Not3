import SwiftData
import SwiftUI

/// Notes in a folder, grouped Hôm nay / 7 ngày trước / 30 ngày trước / Cũ hơn (artboard `NoteList`).
struct NoteListView: View {
    let folderID: PersistentIdentifier?

    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @Query(sort: \Note.updatedAt, order: .reverse) private var allNotes: [Note]
    @State private var searchText = ""

    var body: some View {
        List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.notes) { note in
                        NavigationLink(value: Route.note(note.persistentModelID)) {
                            NoteRow(note: note)
                        }
                        .swipeActions(edge: .leading) {
                            Button(note.isPinned ? "Bỏ ghim" : "Ghim", systemImage: note.isPinned ? "pin.slash" : "pin") {
                                note.isPinned.toggle()
                            }
                            .tint(Theme.accent)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Xoá", systemImage: "trash", role: .destructive) {
                                context.delete(note)
                            }
                        }
                    }
                }
                .headerProminence(.increased)
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if notes.isEmpty {
                ContentUnavailableView("Chưa có ghi chú", systemImage: "note.text", description: Text("Chạm nút soạn để tạo ghi chú mới."))
            }
        }
        .navigationTitle(folder?.name ?? "Tất cả ghi chú")
        .searchable(text: $searchText, placement: .toolbar, prompt: "\(notes.count) ghi chú")
        .toolbar {
            if #available(iOS 26, *) {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.flexible, placement: .bottomBar)
            } else {
                ToolbarItem(placement: .bottomBar) {
                    Text("\(notes.count) ghi chú").font(.footnote).foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Ghi chú mới", systemImage: "square.and.pencil", action: createNote)
            }
        }
    }

    private var folder: Folder? {
        folderID.flatMap { context.model(for: $0) as? Folder }
    }

    private var notes: [Note] {
        let inFolder = folderID == nil ? allNotes : allNotes.filter { $0.folder?.persistentModelID == folderID }
        guard !searchText.isEmpty else { return inFolder }
        let query = searchText.lowercased()
        return inFolder.filter { $0.title.lowercased().contains(query) || $0.body.lowercased().contains(query) }
    }

    private struct NoteGroup {
        let title: String
        let notes: [Note]
    }

    private var groups: [NoteGroup] {
        let cal = DayClock.calendar
        let today = DayClock.startOfDay()
        let weekAgo = cal.date(byAdding: .day, value: -7, to: today)!
        let monthAgo = cal.date(byAdding: .day, value: -30, to: today)!
        let pinned = notes.filter(\.isPinned)
        let rest = notes.filter { !$0.isPinned }
        let buckets: [NoteGroup] = [
            NoteGroup(title: "Đã ghim", notes: pinned),
            NoteGroup(title: "Hôm nay", notes: rest.filter { $0.updatedAt >= today }),
            NoteGroup(title: "7 ngày trước", notes: rest.filter { $0.updatedAt < today && $0.updatedAt >= weekAgo }),
            NoteGroup(title: "30 ngày trước", notes: rest.filter { $0.updatedAt < weekAgo && $0.updatedAt >= monthAgo }),
            NoteGroup(title: "Cũ hơn", notes: rest.filter { $0.updatedAt < monthAgo }),
        ]
        return buckets.filter { !$0.notes.isEmpty }
    }

    private func createNote() {
        let note = Note(folder: folder)
        context.insert(note)
        router.path.append(.note(note.persistentModelID))
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.displayTitle)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(timeLabel).foregroundStyle(.primary)
                Text(note.preview.isEmpty ? "Không có văn bản bổ sung" : note.preview)
                    .lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            let photoCount = note.attachments?.count ?? 0
            if !note.categories.isEmpty || note.durationMinutes != nil || note.checklistProgress != nil || photoCount > 0 {
                HStack(spacing: 6) {
                    ForEach(note.categories, id: \.self) { TagView(text: $0) }
                    if let minutes = note.durationMinutes {
                        TagView(text: "\(minutes) phút", highlighted: false)
                    }
                    if let progress = note.checklistProgress {
                        TagView(text: "☑︎ \(progress)", highlighted: false)
                    }
                    if photoCount > 0 {
                        TagView(text: "\(photoCount) ảnh", highlighted: false)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private var timeLabel: String {
        if Calendar.current.isDateInToday(note.updatedAt) { return DayClock.time(note.updatedAt) }
        return note.updatedAt.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "vi_VN"))).capitalizedFirst
    }
}
