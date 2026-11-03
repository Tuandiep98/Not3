import AppIntents
import Foundation
import SwiftData

// Focus Filter (Cài đặt → Tập trung → chọn Focus → Bộ lọc Focus → Not3): while e.g. "Làm việc" is
// on, "Hôm nay" and the widgets only show the chosen task categories.

/// A task category ("Công việc", "Học ngôn ngữ"…) as the Focus Filter picks it.
struct CategoryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Loại việc"
    static let defaultQuery = CategoryEntityQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

struct CategoryEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [CategoryEntity] {
        identifiers.map(CategoryEntity.init(id:))
    }

    func suggestedEntities() async throws -> [CategoryEntity] {
        await MainActor.run {
            let category = ChipGroup.category.rawValue
            let chips = (try? Persistence.shared.mainContext.fetch(FetchDescriptor<Chip>(
                predicate: #Predicate { $0.groupRaw == category },
                sortBy: [SortDescriptor(\.label)]
            ))) ?? []
            var seen = Set<String>()
            return chips.map(\.label).filter { seen.insert($0).inserted }.map(CategoryEntity.init(id:))
        }
    }
}

struct TaskFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Lọc việc theo Focus"
    static let description = IntentDescription("Chỉ hiện các loại việc đã chọn trong Hôm nay và widget khi Focus này bật.")

    @Parameter(title: "Loại việc")
    var categories: [CategoryEntity]?

    @Parameter(title: "Hiện việc chưa có loại", default: true)
    var showUncategorized: Bool

    init() {}

    var displayRepresentation: DisplayRepresentation {
        let names = (categories ?? []).map(\.id)
        guard !names.isEmpty else { return DisplayRepresentation(title: "Không lọc") }
        let subtitle: LocalizedStringResource = showUncategorized ? "Cả việc chưa có loại" : "Ẩn việc chưa có loại"
        return DisplayRepresentation(title: "\(names.joined(separator: ", "))", subtitle: subtitle)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        FocusFilterState.save(categories: (categories ?? []).map(\.id), showUncategorized: showUncategorized)
        WidgetBridge.publish()
        return .result()
    }
}

/// The active Focus Filter, kept for "Hôm nay" and the widget snapshot. No categories = no filter.
enum FocusFilterState {
    static let categoriesKey = "focusFilter.categories"
    static let showUncategorizedKey = "focusFilter.showUncategorized"

    /// One category per line, so @AppStorage can watch it.
    static func save(categories: [String], showUncategorized: Bool) {
        UserDefaults.standard.set(categories.joined(separator: "\n"), forKey: categoriesKey)
        UserDefaults.standard.set(showUncategorized, forKey: showUncategorizedKey)
    }

    static func decode(_ raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static var categories: [String] { decode(UserDefaults.standard.string(forKey: categoriesKey) ?? "") }
    static var showUncategorized: Bool { UserDefaults.standard.object(forKey: showUncategorizedKey) as? Bool ?? true }
    static var isActive: Bool { !categories.isEmpty }

    /// Keeps tasks of the chosen categories (finished ones too, so the count stays honest).
    @MainActor
    static func apply(_ tasks: [TaskItem], categories: [String] = FocusFilterState.categories,
                      showUncategorized: Bool = FocusFilterState.showUncategorized) -> [TaskItem] {
        guard !categories.isEmpty else { return tasks }
        let wanted = Set(categories)
        return tasks.filter { task in
            guard let category = task.category, !category.isEmpty else { return showUncategorized }
            return wanted.contains(category)
        }
    }
}
