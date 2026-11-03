import SwiftData
import SwiftUI

/// Which category the name alert is for.
enum CategoryEdit: Identifiable {
    case new
    case rename(Chip)

    var id: String {
        switch self {
        case .new: "new"
        case .rename(let chip): chip.id.uuidString
        }
    }

    var chip: Chip? {
        if case .rename(let chip) = self { return chip }
        return nil
    }
}

extension View {
    /// "Danh mục mới" / "Đổi tên danh mục" alert. `onSaved(oldName, newName)` lets the screen
    /// select a new category or follow a rename (old name is nil for a new one).
    func categoryEditor(_ edit: Binding<CategoryEdit?>,
                        onSaved: @escaping (String?, String) -> Void = { _, _ in }) -> some View {
        modifier(CategoryEditorAlert(edit: edit, onSaved: onSaved))
    }

    /// Long-press menu on a category chip: rename, delete (not the last one).
    func categoryChipMenu(_ chip: Chip, edit: Binding<CategoryEdit?>, canDelete: Bool,
                          onDelete: @escaping () -> Void) -> some View {
        contextMenu {
            Button("Đổi tên", systemImage: "pencil") { edit.wrappedValue = .rename(chip) }
            if canDelete {
                Button("Xoá danh mục", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
    }
}

private struct CategoryEditorAlert: ViewModifier {
    @Binding var edit: CategoryEdit?
    let onSaved: (String?, String) -> Void

    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Chip> { $0.groupRaw == "category" }) private var categories: [Chip]
    @State private var name = ""

    func body(content: Content) -> some View {
        // Captured now: the alert may clear `edit` before its button runs.
        let current = edit
        let renaming = current?.chip
        content
            .alert(renaming == nil ? "Danh mục mới" : "Đổi tên danh mục",
                   isPresented: Binding(get: { edit != nil }, set: { if !$0 { edit = nil } })) {
                TextField("Tên danh mục", text: $name)
                Button("Huỷ", role: .cancel) {}
                Button(renaming == nil ? "Thêm" : "Lưu") {
                    guard ChipStore.isValidCategoryName(name, renaming: renaming, among: categories) else { return }
                    let old = renaming?.label
                    ChipStore.saveCategory(name, renaming: renaming, in: context)
                    onSaved(old, name.trimmingCharacters(in: .whitespaces))
                }
                .disabled(!ChipStore.isValidCategoryName(name, renaming: renaming, among: categories))
            } message: {
                Text(renaming == nil ? "Danh mục mới hiện ở check-in, sửa việc và ghi chú." : "Việc và ghi chú cũ vẫn giữ tên cũ.")
            }
            .onChange(of: current?.id) { name = edit?.chip?.label ?? "" }
    }
}

/// "+" chip at the end of the duration row: pick minutes, add to the user's list.
struct AddDurationChip: View {
    let onAdded: (Int) -> Void
    @AppStorage(SettingsKey.checkInDurations) private var durationsRaw = IntList.encode(ChipCatalog.defaultDurations)
    @State private var isPresented = false
    @State private var minutes = 30

    init(onAdded: @escaping (Int) -> Void = { _ in }) { self.onAdded = onAdded }

    var body: some View {
        if IntList.decode(durationsRaw).count < ChipCatalog.maxPerRow {
            ChipButton(title: "Thêm", systemImage: "plus") { isPresented = true }
                .accessibilityLabel("Thêm thời lượng")
                .popover(isPresented: $isPresented) {
                    VStack(spacing: 14) {
                        Stepper("\(minutes) phút", value: $minutes, in: 5...ChipStore.maxDurationMinutes, step: 5)
                            .monospacedDigit()
                        Button {
                            guard let updated = ChipStore.adding(minutes, to: durationsRaw) else { return }
                            durationsRaw = updated
                            onAdded(minutes)
                            isPresented = false
                        } label: {
                            Text("Thêm vào danh sách").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(IntList.decode(durationsRaw).contains(minutes))
                    }
                    .padding(16)
                    .frame(width: 280)
                    .presentationCompactAdaptation(.popover)
                }
        }
    }
}

/// "+" chip at the end of the time row: pick a time, add to the user's list.
struct AddTimeChip: View {
    let onAdded: (Int) -> Void
    @AppStorage(SettingsKey.checkInTimeSlots) private var timeSlotsRaw = IntList.encode(ChipCatalog.defaultTimeSlots)
    @State private var isPresented = false
    @State private var time = DayClock.at(hour: 16, minute: 0)

    init(onAdded: @escaping (Int) -> Void = { _ in }) { self.onAdded = onAdded }

    var body: some View {
        if IntList.decode(timeSlotsRaw).count < ChipCatalog.maxPerRow {
            ChipButton(title: "Thêm", systemImage: "plus") { isPresented = true }
                .accessibilityLabel("Thêm mốc giờ")
                .popover(isPresented: $isPresented) {
                    let slot = ChipStore.slot(of: time)
                    VStack(spacing: 8) {
                        DatePicker("Mốc giờ", selection: $time, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                        Button {
                            guard let updated = ChipStore.adding(slot, to: timeSlotsRaw) else { return }
                            timeSlotsRaw = updated
                            onAdded(slot)
                            isPresented = false
                        } label: {
                            Text("Thêm \(ChipStore.slotLabel(slot))").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(IntList.decode(timeSlotsRaw).contains(slot))
                    }
                    .padding(16)
                    .frame(width: 300)
                    .presentationCompactAdaptation(.popover)
                }
        }
    }
}
