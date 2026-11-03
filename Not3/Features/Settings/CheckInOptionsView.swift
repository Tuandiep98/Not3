import SwiftData
import SwiftUI

/// "Tuỳ chỉnh lựa chọn" (Cài đặt → Check-in): the chips offered in the check-in sheet —
/// categories, afternoon times and durations. Add, rename, swipe to delete.
struct CheckInOptionsView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Chip> { $0.groupRaw == "category" }, sort: \Chip.label)
    private var categories: [Chip]
    @AppStorage(SettingsKey.checkInDurations) private var durationsRaw = IntList.encode(ChipCatalog.defaultDurations)
    @AppStorage(SettingsKey.checkInTimeSlots) private var timeSlotsRaw = IntList.encode(ChipCatalog.defaultTimeSlots)

    @State private var editing: CategoryEdit?
    @State private var draftDuration = 30
    @State private var draftTime = DayClock.at(hour: 16, minute: 0)
    @State private var isConfirmingReset = false

    private var durations: [Int] { IntList.decode(durationsRaw) }
    private var timeSlots: [Int] { IntList.decode(timeSlotsRaw) }

    var body: some View {
        Form {
            categorySection
            timeSection
            durationSection
            Section {
                Button("Khôi phục mặc định", role: .destructive) { isConfirmingReset = true }
            }
        }
        .navigationTitle("Tuỳ chỉnh lựa chọn")
        .navigationBarTitleDisplayMode(.inline)
        .categoryEditor($editing)
        .confirmationDialog("Khôi phục mặc định?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Khôi phục", role: .destructive, action: resetDefaults)
        } message: {
            Text("Mốc giờ và thời lượng về như ban đầu, danh mục mặc định đã xoá được thêm lại. Danh mục bạn tự thêm vẫn giữ.")
        }
    }

    // MARK: Sections

    private var categorySection: some View {
        Section {
            ForEach(categories) { chip in
                Button {
                    editing = .rename(chip)
                } label: {
                    LabeledContent {
                        if chip.useCount > 0 {
                            Text("\(chip.useCount) lần").monospacedDigit()
                        }
                    } label: {
                        if chip.isWork {
                            Label(chip.label, systemImage: "briefcase.fill").foregroundStyle(.primary)
                        } else {
                            Text(chip.label).foregroundStyle(.primary)
                        }
                    }
                }
                .accessibilityHint("Chạm để đổi tên")
                .accessibilityValue(chip.isWork ? "Danh mục công việc" : "")
                .swipeActions(edge: .leading) {
                    if !chip.isWork {
                        Button("Là công việc", systemImage: "briefcase") { ChipStore.setWork(chip, in: context) }
                            .tint(.blue)
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { categories[$0] }.forEach { ChipStore.deleteCategory($0, in: context) }
            }
            .deleteDisabled(categories.count <= 1)
            Button("Thêm danh mục", systemImage: "plus") { editing = .new }
        } header: {
            Text("Danh mục")
        } footer: {
            Text("Chạm để đổi tên, vuốt sang trái để xoá, vuốt sang phải để đặt làm danh mục công việc (\(Image(systemName: "briefcase.fill"))). Gợi ý buổi chiều ưu tiên việc phát triển bản thân trước công việc. Việc đã gắn danh mục bị xoá vẫn giữ nhãn đó.")
        }
    }

    private var timeSection: some View {
        Section {
            ForEach(timeSlots, id: \.self) { slot in
                Text(ChipStore.slotLabel(slot)).monospacedDigit()
            }
            .onDelete { offsets in
                let removed = Set(offsets.map { timeSlots[$0] })
                timeSlotsRaw = IntList.encode(timeSlots.filter { !removed.contains($0) })
            }
            HStack {
                DatePicker("Mốc mới", selection: $draftTime, displayedComponents: .hourAndMinute)
                Button("Thêm", action: addTime)
                    .buttonStyle(.borderless)
                    .disabled(!canAddTime)
            }
        } header: {
            Text("Mốc giờ buổi chiều")
        } footer: {
            Text("\"Tối nay\" (20:00) luôn có. Mốc đã qua tự ẩn khi check-in. Tối đa \(ChipCatalog.maxPerRow) mốc.")
        }
    }

    private var durationSection: some View {
        Section {
            ForEach(durations, id: \.self) { minutes in
                Text("\(minutes) phút").monospacedDigit()
            }
            .onDelete { offsets in
                let removed = Set(offsets.map { durations[$0] })
                durationsRaw = IntList.encode(durations.filter { !removed.contains($0) })
            }
            .deleteDisabled(durations.count <= 1)
            HStack {
                Stepper("\(draftDuration) phút", value: $draftDuration, in: 5...ChipStore.maxDurationMinutes, step: 5)
                    .monospacedDigit()
                Button("Thêm", action: addDuration)
                    .buttonStyle(.borderless)
                    .disabled(!canAddDuration)
            }
        } header: {
            Text("Thời lượng")
        } footer: {
            Text("Tối đa \(ChipCatalog.maxPerRow) lựa chọn, tự xếp từ ngắn đến dài.")
        }
    }

    // MARK: Times & durations

    private var canAddTime: Bool { ChipStore.adding(ChipStore.slot(of: draftTime), to: timeSlotsRaw) != nil }

    private func addTime() {
        if let updated = ChipStore.adding(ChipStore.slot(of: draftTime), to: timeSlotsRaw) { timeSlotsRaw = updated }
    }

    private var canAddDuration: Bool { ChipStore.adding(draftDuration, to: durationsRaw) != nil }

    private func addDuration() {
        if let updated = ChipStore.adding(draftDuration, to: durationsRaw) { durationsRaw = updated }
    }

    private func resetDefaults() {
        durationsRaw = IntList.encode(ChipCatalog.defaultDurations)
        timeSlotsRaw = IntList.encode(ChipCatalog.defaultTimeSlots)
        let existing = Set(categories.map(\.label))
        for name in ChipCatalog.defaultCategories where !existing.contains(name) {
            context.insert(Chip(group: .category, label: name, isBuiltIn: true))
        }
        try? context.save()
    }
}
