import SwiftData
import SwiftUI

/// Which chip the editor sheet is for.
enum ChipEdit: Identifiable {
    case new(ChipGroup)
    case edit(Chip)

    var id: String {
        switch self {
        case .new(let group): "new-\(group.rawValue)"
        case .edit(let chip): chip.id.uuidString
        }
    }

    var chip: Chip? {
        if case .edit(let chip) = self { return chip }
        return nil
    }

    var group: ChipGroup {
        switch self {
        case .new(let group): group
        case .edit(let chip): chip.group
        }
    }
}

extension View {
    /// Sheet to add or edit a category / feeling. `onSaved(oldName, chip)` lets the screen
    /// select a new chip or follow a rename (old name is nil for a new one).
    func chipEditor(_ edit: Binding<ChipEdit?>,
                    onSaved: @escaping (String?, Chip) -> Void = { _, _ in }) -> some View {
        sheet(item: edit) { edit in
            ChipEditorSheet(edit: edit, onSaved: onSaved)
        }
    }

    /// Long-press menu on a category / feeling chip: edit, delete (not the last one).
    func chipMenu(_ chip: Chip, edit: Binding<ChipEdit?>, canDelete: Bool,
                  onDelete: @escaping () -> Void) -> some View {
        contextMenu {
            Button("Sửa", systemImage: "pencil") { edit.wrappedValue = .edit(chip) }
            if canDelete {
                Button(chip.group == .mood ? "Xoá cảm nhận" : "Xoá danh mục", systemImage: "trash",
                       role: .destructive, action: onDelete)
            }
        }
    }
}

/// Name, level (feelings), colour (categories) and symbol, with a live preview of the chip.
private struct ChipEditorSheet: View {
    let edit: ChipEdit
    let onSaved: (String?, Chip) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var chips: [Chip]
    @State private var draft = ChipDraft()
    @FocusState private var nameFocused: Bool

    private var isMood: Bool { edit.group == .mood }
    private var isNew: Bool { edit.chip == nil }
    private var sameGroup: [Chip] { chips.filter { $0.group == edit.group } }
    private var isValid: Bool { ChipStore.isValidName(draft.name, editing: edit.chip, among: sameGroup) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ChipButton(title: draft.trimmedName.isEmpty ? "Xem trước" : draft.trimmedName,
                               systemImage: draft.symbol, tint: draft.color?.color) {}
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                Section {
                    TextField(isMood ? "Tên cảm nhận" : "Tên danh mục", text: $draft.name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    if !draft.trimmedName.isEmpty && !isValid {
                        Text("Đã có \(isMood ? "cảm nhận" : "danh mục") tên này.")
                    } else if !isNew {
                        Text(isMood ? "Check-in cũ vẫn giữ tên cũ." : "Việc và ghi chú cũ vẫn giữ tên cũ.")
                    }
                }

                if isMood {
                    Section {
                        Picker("Mức độ", selection: Binding(get: { draft.level ?? .ok }, set: { draft.level = $0 })) {
                            ForEach(Mood.allCases) { Text($0.levelLabel).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Mức độ")
                    } footer: {
                        Text("Tổng kết tuần đếm theo mức độ, nên bạn đặt tên thế nào cũng được.")
                    }
                } else {
                    Section("Màu") {
                        colorGrid
                    }
                }

                Section("Biểu tượng") {
                    symbolGrid
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Thêm" : "Lưu", systemImage: "checkmark", action: save)
                        .disabled(!isValid)
                }
            }
        }
        .onAppear {
            draft = edit.chip.map(ChipDraft.init) ?? ChipDraft(level: isMood ? .ok : nil)
            if isNew { nameFocused = true }
        }
    }

    private var title: String {
        switch (isMood, isNew) {
        case (true, true): "Cảm nhận mới"
        case (true, false): "Sửa cảm nhận"
        case (false, true): "Danh mục mới"
        case (false, false): "Sửa danh mục"
        }
    }

    private var colorGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
            ForEach(ChipColor.allCases) { option in
                let isOn = draft.color == option
                Button {
                    draft.color = isOn ? nil : option
                } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if isOn {
                                Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
            ForEach(isMood ? ChipSymbols.mood : ChipSymbols.category, id: \.self) { name in
                let isOn = draft.symbol == name
                Button {
                    draft.symbol = isOn ? nil : name
                } label: {
                    Image(systemName: name)
                        .font(.body)
                        .foregroundStyle(isOn ? Color.black : (draft.color?.color ?? .primary))
                        .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
                        .background(isOn ? Theme.accent : Theme.chipOff, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private func save() {
        guard isValid else { return }
        let old = edit.chip?.label
        let chip = ChipStore.save(draft, group: edit.group, editing: edit.chip, in: context)
        onSaved(old, chip)
        dismiss()
    }
}
