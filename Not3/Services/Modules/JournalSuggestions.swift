import Foundation
import SwiftData
import SwiftUI
#if canImport(JournalingSuggestions)
import JournalingSuggestions
#endif

/// Apple's Journaling Suggestions (module "Gợi ý nhật ký", iPhone only). There is no permission to
/// read in the background: the system picker shows the user's moments — workouts, places,
/// photos, music, people — and the app only receives the one the user picks. That moment becomes
/// a done item of its day and a line in Nhật ký. Stays on device.
@MainActor
enum JournalSuggestions {
    static var isSupported: Bool {
        #if canImport(JournalingSuggestions) && !targetEnvironment(simulator)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    /// A picked moment → an item at its time (never later than now).
    static func add(title: String, date: DateInterval?, in context: ModelContext, now: Date = Date()) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let at = min(date?.start ?? now, now)
        let id = "\(text)@\(Int(at.timeIntervalSince1970))"
        let raw = ExternalSource.journal.rawValue
        let existing = (try? context.fetchCount(FetchDescriptor<ExternalItem>(predicate: #Predicate {
            $0.sourceRaw == raw && $0.externalId == id
        }))) ?? 0
        guard existing == 0 else { return }
        let item = ExternalItem(source: .journal, externalId: id, title: text, url: nil, occurredAt: at)
        item.kind = "moment"
        context.insert(item)
        try? context.save()
        JournalService.updateToday(in: context, now: now)
        WidgetBridge.publishSoon()
    }
}

/// "Thêm khoảnh khắc": opens the system Journaling Suggestions picker.
struct MomentPickerButton: View {
    var title = "Thêm khoảnh khắc"

    var body: some View {
        #if canImport(JournalingSuggestions) && !targetEnvironment(simulator)
        JournalingSuggestionsPicker {
            Label(title, systemImage: "sparkles")
        } onCompletion: { suggestion in
            let title = suggestion.title
            let date = suggestion.date
            await MainActor.run {
                JournalSuggestions.add(title: title, date: date, in: Persistence.shared.mainContext)
            }
        }
        #else
        EmptyView()
        #endif
    }
}
