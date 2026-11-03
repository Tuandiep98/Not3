import PhotosUI
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
    @Environment(Router.self) private var router
    @Query private var chips: [Chip]
    @AppStorage(SettingsKey.checkInDurations) private var durationsRaw = IntList.encode(ChipCatalog.defaultDurations)
    @FocusState private var focus: Field?
    @State private var isShowingVoice = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var isShowingCamera = false
    @State private var editingCategory: CategoryEdit?

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
                    } onMakeTask: {
                        makeTask(from: item)
                    } onDrop: { id in
                        moveChecklistItem(id, before: item)
                    }
                }

                NoteAttachmentsGrid(note: note)
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
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task { await addPhotos(items) }
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { image in
                Task {
                    guard let prepared = await Task.detached(operation: { ImageStore.prepare(image) }).value else { return }
                    ImageStore.attach([prepared], to: note, in: context)
                }
            }
            .ignoresSafeArea()
        }
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
                PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 10, matching: .images) {
                    Image(systemName: "photo").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Thêm ảnh")
                if CameraPicker.isAvailable {
                    Button { isShowingCamera = true } label: {
                        Image(systemName: "camera").frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Chụp ảnh")
                }
                if hasDoneItemsAbove {
                    Button { moveDoneItemsDown() } label: {
                        Image(systemName: "arrow.down.to.line").frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Dồn mục đã xong xuống dưới")
                }
                let ranked = CheckInPlanner.rankedCategories(chips)
                ForEach(ranked) { chip in
                    ChipButton(title: chip.label, isOn: note.categories.contains(chip.label)) {
                        toggleCategory(chip.label)
                    }
                    .categoryChipMenu(chip, edit: $editingCategory, canDelete: ranked.count > 1) {
                        ChipStore.deleteCategory(chip, in: context)
                    }
                }
                ChipButton(title: "Thêm", systemImage: "plus") { editingCategory = .new }
                    .accessibilityLabel("Thêm danh mục")
                ForEach(durationOptions, id: \.self) { minutes in
                    ChipButton(title: "\(minutes)p", isOn: note.durationMinutes == minutes) {
                        note.durationMinutes = note.durationMinutes == minutes ? nil : minutes
                        note.needsSync = true
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .categoryEditor($editingCategory) { old, new in
            // New one goes on this note; a rename of one it has follows it.
            if let old, let index = note.categories.firstIndex(of: old) {
                note.categories[index] = new
                note.needsSync = true
            } else if old == nil {
                toggleCategory(new)
            }
        }
    }

    /// The user's durations, plus the note's own one when it is not in the list.
    private var durationOptions: [Int] {
        let list = IntList.decode(durationsRaw)
        guard let own = note.durationMinutes, !list.contains(own) else { return list }
        return (list + [own]).sorted()
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

    // MARK: Checklist

    /// Some ticked item sits above an unticked one.
    private var hasDoneItemsAbove: Bool {
        let items = note.sortedChecklist
        guard let lastOpen = items.lastIndex(where: { !$0.isDone }) else { return false }
        return items[..<lastOpen].contains(where: \.isDone)
    }

    private func moveDoneItemsDown() {
        let items = note.sortedChecklist
        withAnimation(.snappy) {
            for (order, item) in (items.filter { !$0.isDone } + items.filter(\.isDone)).enumerated() {
                item.order = order
            }
        }
        note.updatedAt = Date()
    }

    /// Drag handle dropped on `target`: the dragged item takes the target's place.
    private func moveChecklistItem(_ id: UUID, before target: ChecklistItem) {
        var items = note.sortedChecklist
        guard let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == target.id }), from != to else { return }
        items.insert(items.remove(at: from), at: to)
        withAnimation(.snappy) {
            for (order, item) in items.enumerated() { item.order = order }
        }
        note.updatedAt = Date()
    }

    /// "Thành việc": a task for today with the note's first category; the editor opens on it.
    private func makeTask(from item: ChecklistItem) {
        let title = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let task = TaskItem(title: title, category: note.categories.first, plannedAt: nil,
                            durationMinutes: note.durationMinutes, source: .manual)
        context.insert(task)
        try? context.save()
        router.taskEditor = .edit(task.id)
    }

    // MARK: Photos

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        var prepared: [ImageStore.Prepared] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if let image = await Task.detached(operation: { ImageStore.prepare(data) }).value {
                prepared.append(image)
            }
        }
        ImageStore.attach(prepared, to: note, in: context)
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
            && (note.attachments ?? []).isEmpty
        if isEmpty { context.delete(note) }
    }
}

private struct ChecklistRow<F: Hashable>: View {
    @Bindable var item: ChecklistItem
    var focus: FocusState<F?>.Binding
    let field: F
    let onSubmit: () -> Void
    let onDelete: () -> Void
    let onMakeTask: () -> Void
    let onDrop: (UUID) -> Void

    @State private var isTargeted = false

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
            // Handle: drag to reorder, long-press for actions.
            Image(systemName: "line.3.horizontal")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(width: 36, height: Theme.minTouch)
                .contentShape(.rect)
                .draggable(item.id.uuidString)
                .contextMenu {
                    Button("Thành việc", systemImage: "checklist.checked", action: onMakeTask)
                        .disabled(item.text.isEmpty)
                    Button("Xoá", systemImage: "trash", role: .destructive, action: onDelete)
                }
                .accessibilityLabel("Sắp xếp, hoặc nhấn giữ để chọn")
        }
        .overlay(alignment: .top) {
            if isTargeted { Rectangle().fill(Theme.accentInk).frame(height: 2) }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            onDrop(id)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
