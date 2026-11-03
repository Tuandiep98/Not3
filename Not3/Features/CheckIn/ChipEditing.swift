import SwiftUI

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
