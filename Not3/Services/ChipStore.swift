import Foundation
import SwiftData

/// Edits to the user's check-in choices, shared by "Tuỳ chỉnh lựa chọn" and the chip rows
/// (long-press menu, "+" chip). Categories are `Chip`s; times and durations are `IntList`s.
enum ChipStore {
    /// Non-empty and not already used (ignoring case); keeping a chip's own name while renaming is fine.
    static func isValidCategoryName(_ name: String, renaming: Chip?, among categories: [Chip]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if let renaming, renaming.label == trimmed { return true }
        return !categories.contains { $0.label.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Adds a category, or renames `renaming`. Tasks and notes keep the label they already have.
    static func saveCategory(_ name: String, renaming: Chip?, in context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let renaming {
            renaming.label = trimmed
        } else {
            let chip = Chip(group: .category, label: trimmed, isBuiltIn: false)
            // A new "Công việc" is the work category only when none is marked yet.
            if chip.isWork, workCategory(in: context) != nil { chip.isWork = false }
            context.insert(chip)
        }
        try? context.save()
    }

    // MARK: Work category

    static func workCategory(in context: ModelContext) -> Chip? {
        let descriptor = FetchDescriptor<Chip>(predicate: #Predicate { $0.groupRaw == "category" && $0.isWork })
        return try? context.fetch(descriptor).first
    }

    /// Current name of the work category, for work items filed on this device.
    static func workCategoryName(in context: ModelContext) -> String {
        workCategory(in: context)?.label ?? ChipCatalog.workCategory
    }

    static func workCategoryName(_ chips: [Chip]) -> String {
        chips.first { $0.group == .category && $0.isWork }?.label ?? ChipCatalog.workCategory
    }

    /// Makes `chip` the one work category.
    static func setWork(_ chip: Chip, in context: ModelContext) {
        let descriptor = FetchDescriptor<Chip>(predicate: #Predicate { $0.groupRaw == "category" && $0.isWork })
        for other in (try? context.fetch(descriptor)) ?? [] { other.isWork = false }
        chip.isWork = true
        try? context.save()
    }

    static func deleteCategory(_ chip: Chip, in context: ModelContext) {
        context.delete(chip)
        try? context.save()
    }

    // MARK: Times & durations

    static let maxDurationMinutes = 240

    /// The list with `value` added, or nil when it is already there or the row is full.
    static func adding(_ value: Int, to raw: String) -> String? {
        let list = IntList.decode(raw)
        guard list.count < ChipCatalog.maxPerRow, !list.contains(value) else { return nil }
        return IntList.encode(list + [value])
    }

    static func removing(_ value: Int, from raw: String) -> String {
        IntList.encode(IntList.decode(raw).filter { $0 != value })
    }

    /// Minutes after midnight for a time slot.
    static func slot(of date: Date) -> Int {
        let parts = DayClock.calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func slotLabel(_ slot: Int) -> String {
        String(format: "%02d:%02d", slot / 60, slot % 60)
    }
}
