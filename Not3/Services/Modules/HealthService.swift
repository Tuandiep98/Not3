import Foundation
import HealthKit
import Observation
import SwiftData

/// Apple Health, read only and on device only (module "Sức khỏe", off until turned on in Settings).
/// - Workouts, mindful sessions and reaching the step goal today → done items ("Buổi sáng",
///   check-in chips, Nhật ký), tagged with the Health heart.
/// - Last night's sleep → a line in Nhật ký (not counted as work).
/// - Week numbers (sleep, steps, workout minutes) for "Tổng kết tuần", computed here, never uploaded.
/// HealthKit hides whether read access was granted, so "on" means the user went through the
/// permission sheet; missing data simply reads as nothing.
@MainActor
@Observable
final class HealthService {
    static let shared = HealthService()

    private let store = HKHealthStore()
    static let stepGoalKey = "module.health.stepGoal"
    static let defaultStepGoal = 8_000

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        [
            HKObjectType.workoutType(),
            HKCategoryType(.sleepAnalysis),
            HKCategoryType(.mindfulSession),
            HKQuantityType(.stepCount),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
        ]
    }

    static var stepGoal: Int {
        let stored = UserDefaults.standard.integer(forKey: stepGoalKey)
        return stored > 0 ? stored : defaultStepGoal
    }

    /// Shows the Health permission sheet (read only). True when the sheet was handled.
    func requestAccess() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            return true
        } catch {
            return false
        }
    }

    // MARK: State of Mind (the only thing Not3 writes)

    /// Option in Settings → Sức khỏe: check-in feelings → Health → Tâm trạng. Off by default.
    static let stateOfMindKey = "module.health.stateOfMind"

    private var stateOfMindType: HKStateOfMindType { HKObjectType.stateOfMindType() }

    /// Asks to write State of Mind. Unlike read access, write access is visible: true only when granted.
    func requestStateOfMindAccess() async -> Bool {
        guard isAvailable else { return false }
        try? await store.requestAuthorization(toShare: [stateOfMindType], read: readTypes)
        return store.authorizationStatus(for: stateOfMindType) == .sharingAuthorized
    }

    /// Records a check-in feeling: the noon one as a momentary emotion, "Khép lại hôm nay" as the
    /// day's mood. Only the level goes to Health (valence + one label), never task names.
    func recordStateOfMind(_ mood: Mood, kind: HKStateOfMind.Kind, at date: Date = Date()) async {
        guard LocalModule.isEnabled(.health), UserDefaults.standard.bool(forKey: Self.stateOfMindKey), isAvailable,
              store.authorizationStatus(for: stateOfMindType) == .sharingAuthorized else { return }
        let sample = HKStateOfMind(date: date, kind: kind, valence: Self.valence(mood),
                                   labels: [Self.label(mood)], associations: [])
        try? await store.save(sample)
    }

    nonisolated static func valence(_ mood: Mood) -> Double {
        switch mood {
        case .good: 0.6
        case .ok: 0.0
        case .empty: -0.4
        }
    }

    nonisolated static func label(_ mood: Mood) -> HKStateOfMind.Label {
        switch mood {
        case .good: .satisfied
        case .ok: .indifferent
        case .empty: .drained
        }
    }

    // MARK: Today → done items

    func refresh(in context: ModelContext, now: Date = Date()) async {
        guard LocalModule.isEnabled(.health), isAvailable else { return }
        let start = DayClock.startOfDay(now)
        let end = DayClock.endOfDay(now)
        var fresh: [(id: String, kind: String, title: String, at: Date)] = []

        if LocalModule.isOn("workouts", for: .health) {
            for workout in await workouts(from: start, to: min(end, now)) {
                fresh.append((workout.id, "workout", workout.title, workout.start))
            }
        }
        if LocalModule.isOn("mindful", for: .health) {
            for session in await samples(.mindfulSession, from: start, to: min(end, now)) {
                let minutes = max(1, Int(session.end.timeIntervalSince(session.start) / 60))
                fresh.append((session.id, "mindful", "Chánh niệm \(minutes) phút", session.start))
            }
        }
        let raw = ExternalSource.health.rawValue
        let existing = (try? context.fetch(FetchDescriptor<ExternalItem>(predicate: #Predicate {
            $0.sourceRaw == raw && $0.occurredAt >= start && $0.occurredAt < end
        }))) ?? []
        var byId = Dictionary(existing.map { ($0.externalId, $0) }, uniquingKeysWith: { first, _ in first })

        if LocalModule.isOn("steps", for: .health) {
            let goal = Self.stepGoal
            let id = "steps@\(Int(start.timeIntervalSince1970))"
            if let item = byId[id] {
                // Reached earlier today: keep the time it was first seen.
                fresh.append((id, "steps", item.title, item.occurredAt))
            } else if await steps(from: start, to: now) >= Double(goal) {
                fresh.append((id, "steps", "Đạt \(goal.formatted(.number.locale(Locale(identifier: "vi_VN")))) bước", now))
            }
        }
        if LocalModule.isOn("sleep", for: .health), let night = await sleep(endingOn: now), night.minutes >= 60 {
            fresh.append(("sleep@\(Int(start.timeIntervalSince1970))", "sleep",
                          "Ngủ \(Self.hoursText(night.minutes))", max(start, night.wake)))
        }

        for entry in fresh {
            if let item = byId.removeValue(forKey: entry.id) {
                item.title = entry.title
                item.occurredAt = entry.at
            } else {
                let item = ExternalItem(source: .health, externalId: entry.id, title: entry.title, url: nil, occurredAt: entry.at)
                item.kind = entry.kind
                context.insert(item)
            }
        }
        // Deleted in Health, or the option was turned off.
        byId.values.forEach(context.delete)
        try? context.save()
    }

    /// "Chạy bộ 32 phút · 5,1 km"
    nonisolated static func title(for workout: HKWorkout) -> String {
        let minutes = max(1, Int(workout.duration / 60))
        var parts = ["\(activityName(workout.workoutActivityType)) \(minutes) phút"]
        let distanceType: HKQuantityType? = switch workout.workoutActivityType {
        case .running, .walking, .hiking: HKQuantityType(.distanceWalkingRunning)
        case .cycling: HKQuantityType(.distanceCycling)
        default: nil
        }
        if let distanceType, let meters = workout.statistics(for: distanceType)?.sumQuantity()?.doubleValue(for: .meter()),
           meters >= 100 {
            parts.append((meters / 1000).formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "vi_VN"))) + " km")
        }
        return parts.joined(separator: " · ")
    }

    nonisolated static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "Chạy bộ"
        case .walking: "Đi bộ"
        case .hiking: "Leo núi"
        case .cycling: "Đạp xe"
        case .swimming: "Bơi"
        case .yoga: "Yoga"
        case .pilates: "Pilates"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Tập sức mạnh"
        case .highIntensityIntervalTraining: "HIIT"
        case .coreTraining: "Tập core"
        case .mindAndBody: "Thân và tâm"
        case .socialDance, .cardioDance: "Nhảy"
        case .soccer: "Đá bóng"
        case .badminton: "Cầu lông"
        case .tennis: "Tennis"
        case .tableTennis: "Bóng bàn"
        case .basketball: "Bóng rổ"
        case .volleyball: "Bóng chuyền"
        case .elliptical: "Máy elip"
        case .rowing: "Chèo thuyền"
        case .stairClimbing, .stairs: "Leo cầu thang"
        case .cooldown, .flexibility: "Giãn cơ"
        case .martialArts, .boxing, .kickboxing: "Võ thuật"
        default: "Tập luyện"
        }
    }

    /// 435 → "7 giờ 15 phút"
    nonisolated static func hoursText(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) phút" }
        return rest == 0 ? "\(hours) giờ" : "\(hours) giờ \(rest) phút"
    }

    // MARK: Week → "Tổng kết tuần"

    struct Day: Sendable, Equatable {
        var sleepMinutes = 0
        var steps = 0
        var workoutMinutes = 0
        var workouts = 0
    }

    /// One entry per day (sleep = the night ending that morning). Empty when the module is off.
    func week(_ days: [Date], now: Date = Date()) async -> [Day] {
        guard LocalModule.isEnabled(.health), isAvailable else { return [] }
        var result: [Day] = []
        for day in days {
            guard day <= now else { result.append(Day()); continue }
            let end = min(DayClock.endOfDay(day), now)
            var entry = Day()
            entry.steps = Int(await steps(from: day, to: end))
            let workouts = await workouts(from: day, to: end)
            entry.workouts = workouts.count
            entry.workoutMinutes = Int(workouts.reduce(0) { $0 + $1.duration } / 60)
            entry.sleepMinutes = await sleep(endingOn: day)?.minutes ?? 0
            result.append(entry)
        }
        return result
    }

    // MARK: Queries
    // Nonisolated: HealthKit answers off the main actor; only Sendable values come back.

    struct Workout: Sendable {
        let id: String
        let start: Date
        let duration: TimeInterval
        let title: String
    }

    struct Interval: Sendable {
        let id: String
        let start: Date
        let end: Date
    }

    private func workouts(from start: Date, to end: Date) async -> [Workout] {
        await Self.workouts(store, from: start, to: end)
    }

    private func samples(_ type: HKCategoryTypeIdentifier, from start: Date, to end: Date, values: Set<Int>? = nil) async -> [Interval] {
        await Self.samples(store, type, from: start, to: end, values: values)
    }

    private func steps(from start: Date, to end: Date) async -> Double {
        await Self.steps(store, from: start, to: end)
    }

    nonisolated private static func workouts(_ store: HKHealthStore, from start: Date, to end: Date) async -> [Workout] {
        guard end > start else { return [] }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let found = (try? await descriptor.result(for: store)) ?? []
        return found.map { Workout(id: $0.uuid.uuidString, start: $0.startDate, duration: $0.duration, title: title(for: $0)) }
    }

    nonisolated private static func samples(_ store: HKHealthStore, _ type: HKCategoryTypeIdentifier,
                                            from start: Date, to end: Date, values: Set<Int>?) async -> [Interval] {
        guard end > start else { return [] }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(type), predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let found = (try? await descriptor.result(for: store)) ?? []
        return found
            .filter { values?.contains($0.value) ?? true }
            .map { Interval(id: $0.uuid.uuidString, start: $0.startDate, end: $0.endDate) }
    }

    nonisolated private static func steps(_ store: HKHealthStore, from start: Date, to end: Date) async -> Double {
        guard end > start else { return 0 }
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.stepCount), predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
            options: .cumulativeSum
        )
        return (try? await descriptor.result(for: store))?.sumQuantity()?.doubleValue(for: .count()) ?? 0
    }

    /// Asleep time of the night ending on `day` (18:00 the evening before → 18:00 that day).
    /// iPhone and Watch often both record a night: overlapping pieces count once.
    private func sleep(endingOn day: Date) async -> (minutes: Int, wake: Date)? {
        let morning = DayClock.startOfDay(day)
        let start = morning.addingTimeInterval(-6 * 3600)
        let end = morning.addingTimeInterval(18 * 3600)
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        let pieces = await samples(.sleepAnalysis, from: start, to: end, values: asleep)
            .map { (max($0.start, start), min($0.end, end)) }
        let merged = Self.union(pieces)
        guard let wake = merged.last?.1 else { return nil }
        let seconds = merged.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
        return (Int(seconds / 60), wake)
    }

    /// Joins overlapping intervals.
    nonisolated static func union(_ intervals: [(Date, Date)]) -> [(Date, Date)] {
        var merged: [(Date, Date)] = []
        for interval in intervals.filter({ $0.1 > $0.0 }).sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, interval.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, interval.1)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}
