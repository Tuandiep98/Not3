import SwiftData
import SwiftUI

/// "Tổng kết tuần" (artboard `Summary`). Counts are local; the AI note comes from `weekly_summaries`.
struct WeeklySummaryView: View {
    @Query private var tasks: [TaskItem]
    @Environment(SupabaseService.self) private var supabase

    @State private var summary: WeeklySummaryRecord?
    @State private var question = ""
    @State private var answer: String?
    @State private var askError: String?
    @State private var isAsking = false

    private let now = Date()

    var body: some View {
        let days = DayClock.daysOfWeek(now)
        let meaningful = days.map { CheckInPlanner.isMeaningful(day: $0, tasks: tasks) }
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(meaningful.filter { $0 }.count)/7")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                        Text("ngày có việc ý nghĩa")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(meaningful[index] ? Theme.accent : Theme.chipOff)
                                    .overlay {
                                        if meaningful[index] {
                                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black)
                                        }
                                    }
                                    .frame(width: 30, height: 30)
                                Text(DayClock.shortWeekdays[index])
                                    .font(.caption)
                                    .foregroundStyle(day > now ? .tertiary : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(DayClock.shortWeekdays[index]): \(meaningful[index] ? "có việc ý nghĩa" : "chưa có")")
                        }
                    }
                }
                .padding(.vertical, 8)
            } header: {
                Text("\(DayClock.dayMonth(DayClock.startOfWeek(now))) – \(DayClock.dayMonth(DayClock.daysOfWeek(now).last ?? now))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }

            Section {
                let counts = categoryCounts
                if counts.isEmpty {
                    Text("Chưa có buổi nào hoàn thành tuần này.")
                        .foregroundStyle(.secondary)
                } else {
                    let maxCount = counts.map(\.count).max() ?? 1
                    ForEach(counts, id: \.label) { entry in
                        HStack(spacing: 12) {
                            Text(entry.label).frame(width: 110, alignment: .leading)
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Theme.folderIcon)
                                    .frame(width: max(8, proxy.size.width * CGFloat(entry.count) / CGFloat(maxCount)))
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(height: 10)
                            Text("\(entry.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                Text("Theo loại việc")
            } footer: {
                Text("Số buổi đã hoàn thành trong tuần")
            }

            aiSection
            askSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tuần \(DayClock.weekNumber(now))")
        .task { summary = await supabase.fetchWeeklySummary(weekStart: DayClock.startOfWeek(now)) }
    }

    // MARK: AI

    private var aiSection: some View {
        Section {
            if let summary {
                VStack(alignment: .leading, spacing: 8) {
                    Text(summary.summary)
                    Text("Tạo lúc \(DayClock.time(summary.createdAt)) \(summary.createdAt.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "vi_VN"))))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                Text(supabase.isSignedIn
                     ? "Nhận xét sẽ có lúc 20:00 Chủ nhật."
                     : "Đăng nhập trong Cài đặt để nhận nhận xét tuần lúc 20:00 Chủ nhật.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label(summary?.source == "rules" ? "Nhận xét tuần" : "Nhận xét từ AI", systemImage: "sparkles")
        }
    }

    @ViewBuilder
    private var askSection: some View {
        if supabase.isSignedIn {
            Section {
                HStack {
                    TextField("Ví dụ: tháng này học tiếng Anh mấy buổi?", text: $question, axis: .vertical)
                        .submitLabel(.send)
                        .onSubmit(sendQuestion)
                    if isAsking {
                        ProgressView()
                    } else {
                        Button("Gửi", systemImage: "arrow.up.circle.fill", action: sendQuestion)
                            .labelStyle(.iconOnly)
                            .font(.title2)
                            .disabled(question.trimmingCharacters(in: .whitespaces).count < 2)
                    }
                }
                if let answer {
                    Text(answer).transition(.opacity)
                }
                if let askError {
                    Text(askError).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Hỏi về lịch sử")
            } footer: {
                Text("AI chỉ đọc số liệu thật từ task và check-in của bạn, không đoán.")
            }
        }
    }

    private func sendQuestion() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, !isAsking else { return }
        isAsking = true
        askError = nil
        Task {
            do {
                let result = try await supabase.ask(text)
                withAnimation { answer = result }
            } catch {
                askError = error.localizedDescription
            }
            isAsking = false
        }
    }

    private var categoryCounts: [(label: String, count: Int)] {
        let start = DayClock.startOfWeek(now)
        let end = DayClock.calendar.date(byAdding: .day, value: 7, to: start) ?? now
        let done = tasks.filter { task in
            guard task.status == .done, let completed = task.completedAt else { return false }
            return completed >= start && completed < end
        }
        let grouped = Dictionary(grouping: done) { $0.category ?? "Khác" }
        return grouped.map { (label: $0.key, count: $0.value.count) }.sorted { $0.count > $1.count }
    }
}
