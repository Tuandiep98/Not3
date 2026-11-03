import Foundation
import SwiftData

/// Edits to the user's check-in choices, shared by "Tuỳ chỉnh lựa chọn" and the chip rows
/// (long-press menu, "+" chip). Categories are `Chip`s; times and durations are `IntList`s.
/// What the chip editor fills in: a name, plus a level for feelings and a look for both.
struct ChipDraft: Equatable {
    var name = ""
    var level: Mood?
    var color: ChipColor?
    var symbol: String?

    init(name: String = "", level: Mood? = nil, color: ChipColor? = nil, symbol: String? = nil) {
        self.name = name
        self.level = level
        self.color = color
        self.symbol = symbol
    }

    init(_ chip: Chip) {
        self.init(name: chip.label, level: chip.level, color: chip.colorName.flatMap(ChipColor.init(rawValue:)),
                  symbol: chip.symbol)
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
}

/// Edits to the user's check-in choices, shared by "Tuỳ chỉnh lựa chọn" and the chip rows
/// (long-press menu, "+" chip). Categories and feelings are `Chip`s; times and durations are `IntList`s.
@MainActor
enum ChipStore {
    /// Non-empty and not already used in the group (ignoring case); keeping a chip's own name is fine.
    static func isValidName(_ name: String, editing: Chip?, among chips: [Chip]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if let editing, editing.label == trimmed { return true }
        return !chips.contains { $0.label.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Adds a chip to `group`, or updates `editing`. Tasks, notes and past check-ins keep the
    /// name they already have.
    @discardableResult
    static func save(_ draft: ChipDraft, group: ChipGroup, editing: Chip?, in context: ModelContext) -> Chip {
        let chip: Chip
        if let editing {
            chip = editing
            chip.label = draft.trimmedName
        } else {
            chip = Chip(group: group, label: draft.trimmedName, isBuiltIn: false)
            // A new "Công việc" is the work category only when none is marked yet.
            if chip.isWork, workCategory(in: context) != nil { chip.isWork = false }
            context.insert(chip)
        }
        if group == .mood { chip.level = draft.level ?? chip.level ?? .ok }
        chip.colorName = draft.color?.rawValue
        chip.symbol = draft.symbol
        try? context.save()
        refreshAppearance(in: context)
        return chip
    }

    static func delete(_ chip: Chip, in context: ModelContext) {
        context.delete(chip)
        try? context.save()
        refreshAppearance(in: context)
    }

    /// Rewrites the `CategoryAppearance` mirror and the notification buttons' feeling names.
    static func refreshAppearance(in context: ModelContext) {
        let descriptor = FetchDescriptor<Chip>(predicate: #Predicate { $0.groupRaw == "category" })
        CategoryAppearance.save((try? context.fetch(descriptor)) ?? [])
        let labels = Dictionary(uniqueKeysWithValues: Mood.allCases.map { ($0.rawValue, moodLabel(for: $0, in: context)) })
        if labels != UserDefaults.standard.dictionary(forKey: quickMoodKey) as? [String: String] {
            UserDefaults.standard.set(labels, forKey: quickMoodKey)
            NotificationService.registerCategories()
        }
    }

    private static let quickMoodKey = "quickMoodLabels"

    /// Name on the notification button for a level (kept in UserDefaults; no context needed).
    static func quickMoodLabel(_ level: Mood) -> String {
        (UserDefaults.standard.dictionary(forKey: quickMoodKey)?[level.rawValue] as? String) ?? level.label
    }

    // MARK: Feelings

    /// Feelings offered in check-in: good first, then by name. Chips without a level only count usage.
    static func moodOptions(_ chips: [Chip]) -> [Chip] {
        chips.filter { $0.group == .mood && $0.level != nil }.sorted { lhs, rhs in
            let l = lhs.level?.order ?? 0, r = rhs.level?.order ?? 0
            if l != r { return l < r }
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            return lhs.label.localizedCompare(rhs.label) == .orderedAscending
        }
    }

    /// Name recorded for a quick answer (notification, widget, Watch), which only knows the level.
    static func moodLabel(for level: Mood, in context: ModelContext) -> String {
        let descriptor = FetchDescriptor<Chip>(predicate: #Predicate { $0.groupRaw == "mood" })
        let options = moodOptions((try? context.fetch(descriptor)) ?? [])
        return options.first { $0.level == level }?.label ?? level.label
    }

    /// The three built-in feelings, reusing the usage chips older versions created by name.
    /// Run once (`Persistence.seedIfNeeded`), so deleted ones stay deleted.
    static func seedMoods(in context: ModelContext) {
        let descriptor = FetchDescriptor<Chip>(predicate: #Predicate { $0.groupRaw == "mood" })
        let existing = (try? context.fetch(descriptor)) ?? []
        for level in Mood.allCases {
            let chip = existing.first { $0.label == level.label } ?? {
                let chip = Chip(group: .mood, label: level.label, isBuiltIn: true)
                context.insert(chip)
                return chip
            }()
            chip.isBuiltIn = true
            chip.level = level
            chip.symbol = chip.symbol ?? level.symbol
        }
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
