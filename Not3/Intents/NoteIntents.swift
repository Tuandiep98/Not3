import AppIntents
import Foundation
import SwiftData

struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Ghi chú nhanh"
    static let description = IntentDescription("Lưu một ghi chú vào thư mục \"Ghi chú nhanh\". Dòng đầu là tiêu đề.")

    @Parameter(title: "Nội dung", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "Ghi gì?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ghi chú \(\.$text)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<NoteEntity> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw $text.needsValueError("Ghi gì?") }
        let context = Persistence.shared.mainContext
        let folders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        let note = Note(folder: folders.first { $0.name == "Ghi chú nhanh" })
        let lines = trimmed.split(separator: "\n", maxSplits: 1).map(String.init)
        note.title = lines.first ?? trimmed
        note.body = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        context.insert(note)
        try? context.save()
        return .result(value: NoteEntity(note), dialog: "Đã lưu \"\(note.displayTitle)\".")
    }
}

/// Opens a note (Shortcuts, and Spotlight results of `NoteEntity`).
struct OpenNoteIntent: OpenIntent {
    static let title: LocalizedStringResource = "Mở ghi chú"

    @Parameter(title: "Ghi chú")
    var target: NoteEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        Router.shared.open(DeepLink.note(target.id))
        return .result()
    }
}
