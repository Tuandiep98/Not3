import SwiftData
import SwiftUI

/// Note editor: title, body, round checklist, chip row above the keyboard (artboard `Editor`).
struct NoteEditorView: View {
    let noteID: PersistentIdentifier

    @Environment(\.modelContext) private var context

    var body: some View {
        if let note = context.model(for: noteID) as? Note {
            NoteEditorContent(note: note)
        } else {
            ContentUnavailableView("Không tìm thấy ghi chú", systemImage: "note.text")
        }
    }
}

private struct NoteEditorContent: View {
    @Bindable var note: Note

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var chips: [Chip]
    @FocusState private var focus: Field?
    @State private var isShowingVoice = false

    private enum Field: Hashable {
        case title, body
        case item(UUID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(note.createdAt.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Locale(identifier: "vi_VN"))))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)

                aiSuggestions

                TextField("Tiêu đề", text: $note.title, axis: .vertical)
                    .font(.title.bold())
                    .focused($focus, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focus = .body }

                TextField("Ghi chú", text: $note.body, axis: .vertical)
                    .font(.body)
                    .focused($focus, equals: .body)

                ForEach(note.sortedChecklist) { item in
                    ChecklistRow(item: item, focus: $focus, field: .item(item.id)) {
                        addChecklistItem(after: item)
                    } onDelete: {
                        context.delete(item)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareText) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Chia sẻ")
            }
            if focus != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong", systemImage: "checkmark") { focus = nil }
                }
            }
            ToolbarItemGroup(placement: .keyboard) { chipBar }
        }
        .safeAreaInset(edge: .bottom) {
            if focus == nil { chipBar.padding(.horizontal, 10).padding(.bottom, 6) }
        }
        .onChange(of: note.title) { note.updatedAt = Date(); note.needsSync = true }
        .onChange(of: note.body) { note.updatedAt = Date(); note.needsSync = true }
        .onAppear {
            if note.title.isEmpty && note.body.isEmpty { focus = .title }
        }
        .onDisappear(perform: cleanUpIfEmpty)
        .sheet(isPresented: $isShowingVoice) {
            VoiceCaptureSheet(prompt: "Nói nội dung ghi chú") { text in
                note.body = note.body.isEmpty ? text : note.body + "\n" + text
            }
        }
    }

    /// Chips AI suggested after the note was saved. One tap accepts; AI never applies them itself.
    @ViewBuilder
    private var aiSuggestions: some View {
        let pending = note.suggestedCategories.filter { !note.categories.contains($0) }
        if !pending.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.accentInk)
                    .accessibilityLabel("Gợi ý từ AI")
                ChipGroupContainer {
                    ForEach(pending, id: \.self) { label in
                        ChipButton(title: label, systemImage: "plus") {
                            toggleCategory(label)
                            note.suggestedCategories.removeAll { $0 == label }
                        }
                    }
                }
                Button {
                    note.suggestedCategories = []
                } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold))
                        .frame(width: Theme.minTouch, height: Theme.minTouch)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Bỏ qua gợi ý")
            }
            .transition(.opacity)
        }
    }

    /// Chips above the keyboard: checklist, categories, durations.
    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { addChecklistItem(after: nil) } label: {
                    Image(systemName: "checklist").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Thêm danh sách kiểm")
                Button { isShowingVoice = true } label: {
                    Image(systemName: "mic").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Nhập bằng giọng nói")
                ForEach(CheckInPlanner.rankedCategories(chips)) { chip in
                    ChipButton(title: chip.label, isOn: note.categories.contains(chip.label)) {
                        toggleCategory(chip.label)
                    }
                }
                ForEach([25, 45], id: \.self) { minutes in
                    ChipButton(title: "\(minutes)p", isOn: note.durationMinutes == minutes) {
                        note.durationMinutes = note.durationMinutes == minutes ? nil : minutes
                        note.needsSync = true
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var shareText: String {
        ([note.title, note.body] + note.sortedChecklist.map { ($0.isDone ? "✓ " : "○ ") + $0.text })
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func addChecklistItem(after item: ChecklistItem?) {
        let items = note.sortedChecklist
        let order = item.map { $0.order + 1 } ?? ((items.last?.order ?? -1) + 1)
        for later in items where later.order >= order { later.order += 1 }
        let newItem = ChecklistItem(text: "", order: order)
        newItem.note = note
        context.insert(newItem)
        note.updatedAt = Date()
        focus = .item(newItem.id)
    }

    private func toggleCategory(_ label: String) {
        if let index = note.categories.firstIndex(of: label) {
            note.categories.remove(at: index)
        } else {
            note.categories.append(label)
            CheckInService.bumpChip(group: .category, label: label, in: context)
        }
        note.needsSync = true
    }

    private func cleanUpIfEmpty() {
        let isEmpty = note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && note.sortedChecklist.allSatisfy { $0.text.isEmpty }
        if isEmpty { context.delete(note) }
    }
}

private struct ChecklistRow<F: Hashable>: View {
    @Bindable var item: ChecklistItem
    var focus: FocusState<F?>.Binding
    let field: F
    let onSubmit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            CheckCircle(isOn: item.isDone, label: item.text) {
                withAnimation(.snappy) { item.isDone.toggle() }
            }
            .padding(.leading, -10)
            TextField("", text: $item.text)
                .strikethrough(item.isDone)
                .foregroundStyle(item.isDone ? .secondary : .primary)
                .focused(focus, equals: field)
                .submitLabel(.next)
                .onSubmit {
                    if item.text.isEmpty { onDelete() } else { onSubmit() }
                }
        }
    }
}
