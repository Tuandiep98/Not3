import AppIntents
import SwiftUI
import WidgetKit

/// "Thư mục ghi chú": the 4 newest notes of a chosen folder (edit the widget to pick one),
/// tap a note to open it, + for a new note in that folder.
struct FolderWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.folder, intent: SelectFolderIntent.self, provider: FolderProvider()) { entry in
            FolderWidgetView(entry: entry)
                // "Hiển thị khi khoá": redacted while the device is locked.
                .privacySensitive(entry.snapshot.hidesAll)
                .environment(\.hidesPrivateContent, entry.snapshot.hidesContent)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Thư mục ghi chú")
        .description("Ghi chú mới nhất của một thư mục.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct FolderWidgetView: View {
    let entry: SnapshotEntry

    private var folder: WidgetSnapshot.FolderRow? {
        entry.snapshot.folders.first { $0.id == entry.folderID } ?? entry.snapshot.folders.first
    }

    var body: some View {
        let id = folder?.id ?? WidgetSnapshot.allNotesID
        VStack(spacing: 0) {
            WidgetHeader(title: folder?.name ?? "Ghi chú", systemImage: "folder") {
                Link(destination: DeepLink.newNote(folder: id == WidgetSnapshot.allNotesID ? nil : id)) {
                    Image(systemName: "square.and.pencil").font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Ghi chú mới")
            }
            let notes = folder?.notes ?? []
            if notes.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Text("Chưa có ghi chú").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                    ForEach(Array(stride(from: 0, to: notes.count, by: 2)), id: \.self) { row in
                        if row > 0 { Divider().gridCellColumns(2) }
                        GridRow {
                            noteCell(notes[row])
                            if row + 1 < notes.count { noteCell(notes[row + 1]) } else { Color.clear }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(maxHeight: .infinity)
            }
        }
        .widgetURL(DeepLink.folder(id))
    }

    private func noteCell(_ note: WidgetSnapshot.NoteRow) -> some View {
        Link(destination: DeepLink.note(note.id)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title).font(.footnote.weight(.semibold)).lineLimit(1).privateContent()
                HStack(spacing: 4) {
                    Text(Calendar.current.isDateInToday(note.updatedAt) ? WFormat.time(note.updatedAt)
                         : note.updatedAt.formatted(.dateTime.day().month(.defaultDigits)))
                        .foregroundStyle(Color.primary)
                    Text(note.preview).foregroundStyle(Color.secondary).privateContent()
                }
                .font(.caption2)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.rect)
            .foregroundStyle(.primary)   // Links would otherwise take the accent tint
        }
    }
}
