import Charts
import SwiftData
import SwiftUI

/// "Tổng kết tuần" v2 (canvas "Not3 · Tổng kết tuần v2"): time worked from Lịch, Jira work logs,
/// timed tasks and GitHub sessions — stacked bars per day, highlights, heat map, categories.
/// iOS 26 gets Liquid Glass from the system bars; iOS 18 the standard ones.
struct WeeklySummaryView: View {
    @Environment(\.modelContext) private var context
    @Environment(SupabaseService.self) private var supabase
    @Environment(Router.self) private var router
    @Query private var tasks: [TaskItem]

    @State private var weekStart = DayClock.startOfWeek()
    @State private var snapshot = ActivitySnapshot.empty
    @State private var previous = ActivitySnapshot.empty
    @State private var isLoading = true
    @State private var selectedDay: Int?
    @State private var selectedCell: (day: Int, hour: Int)?
    @State private var byCount = false
    /// Sức khỏe module (on device): one entry per day, empty when off.
    @State private var health: [HealthService.Day] = []

    @State private var summary: WeeklySummaryRecord?
    @State private var question = ""
    @State private var answer: String?
    @State private var askError: String?
    @State private var isAsking = false

    private var days: [Date] { DayClock.daysOfWeek(weekStart) }
    private var report: ActivityReport { snapshot.report }
    private var isCurrentWeek: Bool { weekStart == DayClock.startOfWeek() }

    var body: some View {
        List {
            heroSection
            highlightsSection
            heatSection
            categorySection
            if health.contains(where: { $0 != HealthService.Day() }) {
                healthSection
            }
            historySection
            aiSection
            askSection
            sourcesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tổng kết tuần")
        .toolbar { toolbar }
        .task(id: weekStart) { await load() }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        isLoading = true
        selectedDay = nil
        selectedCell = nil
        let lastWeek = DayClock.daysOfWeek(DayClock.calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart)
        snapshot = await ActivityLoader.load(days: days, in: context, force: force)
        isLoading = false
        health = await HealthService.shared.week(days)
        previous = await ActivityLoader.load(days: lastWeek, in: context, force: force)
        summary = await supabase.fetchWeeklySummary(weekStart: weekStart)
    }

    // MARK: Toolbar — week switcher (glass capsule on iOS 26, toolbar on iOS 18)

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ShareLink(item: shareText) {
                Label("Chia sẻ tổng kết", systemImage: "square.and.arrow.up")
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Tuần trước", systemImage: "chevron.left") { shiftWeek(-1) }
            Text("Tuần \(DayClock.weekNumber(weekStart))")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .fixedSize()
            Button("Tuần sau", systemImage: "chevron.right") { shiftWeek(1) }
                .disabled(isCurrentWeek)
        }
    }

    private func shiftWeek(_ delta: Int) {
        guard let next = DayClock.calendar.date(byAdding: .day, value: 7 * delta, to: weekStart) else { return }
        weekStart = DayClock.startOfWeek(next)
    }

    // MARK: Hero — total + stacked bars per day (Screen Time)

    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                heroHeader
                WeekBarsChart(report: report, selectedDay: $selectedDay)
                    .frame(height: 210)
                    .opacity(isLoading ? 0.4 : 1)
                    .overlay { if isLoading && report.days.isEmpty { ProgressView() } }
                Divider()
                KindLegend(parts: legendParts)
            }
            .padding(.vertical, 6)
        } header: {
            Text("\(DayClock.dayMonth(days.first ?? weekStart)) – \(DayClock.dayMonth(days.last ?? weekStart))")
                .font(.subheadline)
                .textCase(nil)
        }
    }

    @ViewBuilder
    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let day = selectedDay, report.perDay.indices.contains(day) {
                ChartCaption(text: "\(ActivityStyle.weekdayNames[day]), \(DayClock.dayMonth(days[day]))")
                DurationHeadline(minutes: report.total(day: day))
                Button("Xem chi tiết ngày") { router.path.append(.activityDay(days[day])) }
                    .font(.footnote.weight(.semibold))
            } else {
                ChartCaption(text: report.days.isEmpty ? "Tổng cộng" : "Tổng cộng · TB \(ActivityStyle.duration(report.total / 7)) mỗi ngày")
                DurationHeadline(minutes: report.total)
                Text(comparisonText)
                    .font(.footnote)
                    .foregroundStyle(previous.report.total > 0 && report.total > previous.report.total ? Color.green : Color.secondary)
            }
        }
        .frame(minHeight: 76, alignment: .topLeading)
    }

    private var comparisonText: String {
        let diff = report.total - previous.report.total
        guard previous.report.total > 0 else { return "Chưa có dữ liệu tuần trước để so sánh" }
        if abs(diff) < 10 { return "Bằng tuần trước" }
        return diff > 0
            ? "↑ \(ActivityStyle.longDuration(diff)) so với tuần trước"
            : "↓ \(ActivityStyle.longDuration(-diff)) so với tuần trước"
    }

    private var legendParts: [(kind: ActivityKind, minutes: Int)] {
        let parts = report.kindParts(day: selectedDay)
        return parts.isEmpty ? [(kind: .code, minutes: 0), (kind: .meeting, minutes: 0), (kind: .jira, minutes: 0)] : parts
    }

    // MARK: Highlights (Health)

    private var highlightsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HighlightTitle(title: "Tập trung sâu", symbol: "bolt.fill", color: .blue)
                Text(focusSentence).font(.headline)
                if report.deepFocusMinutes + previous.report.deepFocusMinutes > 0 {
                    ComparisonBars(current: report.deepFocusMinutes, previous: previous.report.deepFocusMinutes, color: .blue)
                }
            }
            .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 10) {
                HighlightTitle(title: "Đã làm được gì", symbol: "checkmark", color: Theme.accentInk)
                Text(doneSentence).font(.headline)
                HStack {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        let on = CheckInPlanner.isMeaningful(day: day, tasks: tasks)
                        VStack(spacing: 4) {
                            Circle()
                                .fill(on ? Theme.accent : Theme.chipOff)
                                .overlay { if on { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black) } }
                                .frame(width: 30, height: 30)
                            Text(DayClock.shortWeekdays[index]).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(ActivityStyle.weekdayNames[index]): \(on ? "có việc ý nghĩa" : "chưa có")")
                    }
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Điểm nổi bật").font(.title2.bold()).foregroundStyle(.primary).textCase(nil)
        }
        .headerProminence(.increased)
    }

    private var focusSentence: String {
        let count = report.deepFocus.count
        guard count > 0 else { return "Chưa có phiên làm liền từ 50 phút trong tuần này." }
        let longest = report.deepFocus.max { $0.duration < $1.duration }
        var text = "\(count) phiên làm liền từ 50 phút"
        let diff = count - previous.report.deepFocus.count
        if previous.report.days.isEmpty == false, diff != 0 {
            text += diff > 0 ? ", nhiều hơn tuần trước \(diff) phiên" : ", ít hơn tuần trước \(-diff) phiên"
        }
        if let longest {
            let day = DayClock.calendar.component(.weekday, from: longest.start)
            let name = ActivityStyle.weekdayNames[(day + 5) % 7].lowercased()
            text += ". Dài nhất \(ActivityStyle.longDuration(Int(longest.duration / 60))), \(name)"
        }
        return text + "."
    }

    private var doneSentence: String {
        let end = DayClock.calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let done = tasks.filter { $0.status == .done && ($0.completedAt ?? .distantPast) >= weekStart && ($0.completedAt ?? .distantFuture) < end }
        let meaningful = days.filter { CheckInPlanner.isMeaningful(day: $0, tasks: tasks) }.count
        var parts = ["\(done.count) việc xong trong \(meaningful) ngày có việc ý nghĩa"]
        var github: [String] = []
        if snapshot.commits > 0 { github.append("\(snapshot.commits) commit") }
        if snapshot.reviews > 0 { github.append("\(snapshot.reviews) review") }
        if snapshot.pullRequests > 0 { github.append("\(snapshot.pullRequests) PR") }
        if !github.isEmpty { parts.append("GitHub: " + github.joined(separator: ", ")) }
        if let jira = report.byKind[.jira], jira > 0 { parts.append("Jira: \(ActivityStyle.longDuration(jira)) log work") }
        return parts.joined(separator: ". ") + "."
    }

    // MARK: Heat map

    private var heatSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HighlightTitle(title: "Bản đồ thời gian", symbol: "square.grid.3x3.fill", color: Theme.accentInk)
                heatInfo
                HeatGrid(report: report, selection: $selectedCell) { day in
                    router.path.append(.activityDay(days[day]))
                }
            }
            .padding(.vertical, 6)
        } footer: {
            Text("Mỗi ô là 1 giờ, màu càng đậm là làm càng nhiều. Chạm một ô để xem đã làm gì, chạm tên ngày để mở cả ngày.")
        }
    }

    @ViewBuilder
    private var heatInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let cell = selectedCell, report.heat.indices.contains(cell.day) {
                let minutes = report.heat[cell.day][cell.hour]
                ChartCaption(text: "\(ActivityStyle.weekdayNames[cell.day]) · \(cell.hour)–\(cell.hour + 1) giờ")
                DurationHeadline(minutes: minutes, size: 28)
                ForEach(blocks(day: cell.day, hour: cell.hour).prefix(3)) { block in
                    HStack(spacing: 6) {
                        Circle().fill(block.kind.color).frame(width: 8, height: 8)
                        Text(block.title).lineLimit(1)
                        Text("· \(sourceWord(block))").foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                }
                if minutes == 0 { Text("Không có hoạt động").font(.footnote).foregroundStyle(.secondary) }
            } else {
                ChartCaption(text: "Giờ làm nhiều nhất")
                if let peak = peakHour {
                    Text("\(ActivityStyle.weekdayNames[peak.day]) · \(peak.hour)–\(peak.hour + 1) giờ").font(.title3.bold())
                } else {
                    Text("Chưa có dữ liệu").font(.title3.bold()).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 70, alignment: .topLeading)
    }

    private var peakHour: (day: Int, hour: Int)? {
        var best: (Int, Int, Int)?
        for (d, row) in report.heat.enumerated() {
            for (h, m) in row.enumerated() where m > (best?.2 ?? 0) { best = (d, h, m) }
        }
        return best.map { ($0.0, $0.1) }
    }

    private func blocks(day: Int, hour: Int) -> [ActivityBlock] {
        guard let start = DayClock.calendar.date(byAdding: .hour, value: hour, to: days[day]) else { return [] }
        let end = start.addingTimeInterval(3600)
        return report.blocks.filter { $0.end > start && $0.start < end }
    }

    private func sourceWord(_ block: ActivityBlock) -> String {
        switch block.source {
        case .calendar: "Lịch"
        case .jira: "Jira"
        case .github: "ước tính"
        case .task: block.precision == .measured ? "bấm giờ" : "dự kiến"
        }
    }

    // MARK: Categories (Screen Time "Most used")

    private var categorySection: some View {
        Section {
            Picker("Đo theo", selection: $byCount) {
                Text("Thời gian").tag(false)
                Text("Số việc").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            let rows = categoryRows
            if rows.isEmpty {
                Text("Chưa có dữ liệu tuần này.").foregroundStyle(.secondary)
            } else {
                KindShareBar(parts: rows.map { (kind: $0.kind, minutes: $0.value) })
                    .listRowSeparator(.hidden)
                let maxValue = rows.map(\.value).max() ?? 1
                let total = max(1, rows.reduce(0) { $0 + $1.value })
                ForEach(rows, id: \.kind) { row in
                    CategoryRow(kind: row.kind,
                                value: byCount ? "\(row.value) việc" : ActivityStyle.duration(row.value),
                                share: Double(row.value) / Double(total),
                                fill: Double(row.value) / Double(maxValue))
                }
            }
        } header: {
            Text("Phân loại").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
        }
    }

    private var categoryRows: [(kind: ActivityKind, value: Int)] {
        if !byCount { return report.kindParts().map { (kind: $0.kind, value: $0.minutes) } }
        var counts: [ActivityKind: Int] = [:]
        let end = DayClock.calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        for task in tasks where task.status == .done && (task.completedAt ?? .distantPast) >= weekStart && (task.completedAt ?? .distantFuture) < end {
            let kind: ActivityKind = switch ExternalSource(linkURL: task.linkURL) {
            case .github: .code
            case .jira: .jira
            default: ActivityCategorySlots.kind(for: task.category)
            }
            counts[kind, default: 0] += 1
        }
        counts[.meeting] = report.blocks.filter { $0.kind == .meeting }.count
        return counts.filter { $0.value > 0 }.sorted { $0.key.order < $1.key.order }.map { (kind: $0.key, value: $0.value) }
    }

    // MARK: History, AI, sources

    private var historySection: some View {
        Section {
            Button {
                router.path.append(.activityHistory)
            } label: {
                Label("Lịch sử 12 tuần", systemImage: "chart.bar.xaxis")
            }
        }
    }

    private var aiSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HighlightTitle(title: summary?.source == "rules" ? "Nhận xét" : "Nhận xét từ AI", symbol: "sparkles", color: .purple)
                if let summary {
                    Text(summary.summary)
                    Text("Tạo lúc \(DayClock.time(summary.createdAt)) \(summary.createdAt.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "vi_VN"))))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(supabase.isSignedIn
                         ? "Nhận xét sẽ có lúc 20:00 Chủ nhật."
                         : "Đăng nhập trong Cài đặt để nhận nhận xét tuần lúc 20:00 Chủ nhật.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
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
                if let answer { Text(answer).transition(.opacity) }
                if let askError { Text(askError).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Hỏi về lịch sử")
            } footer: {
                Text("AI chỉ đọc số liệu thật từ task và check-in của bạn, không đoán.")
            }
        }
    }

    // MARK: Sức khỏe — sleep, steps, workouts (read on device, never uploaded)

    private var healthSection: some View {
        let slept = health.map(\.sleepMinutes).filter { $0 > 0 }
        let walked = health.map(\.steps).filter { $0 > 0 }
        let workouts = health.reduce(0) { $0 + $1.workouts }
        let workoutMinutes = health.reduce(0) { $0 + $1.workoutMinutes }
        let goal = HealthService.stepGoal
        return Section {
            LabeledContent("Ngủ trung bình", value: slept.isEmpty ? "Chưa có" : HealthService.hoursText(slept.reduce(0, +) / slept.count))
            LabeledContent("Bước mỗi ngày", value: walked.isEmpty ? "Chưa có" : (walked.reduce(0, +) / walked.count).formatted(.number.locale(Locale(identifier: "vi_VN"))))
            LabeledContent("Ngày đạt mục tiêu bước", value: "\(health.filter { $0.steps >= goal }.count)/\(walked.count)")
            LabeledContent("Vận động", value: workouts == 0 ? "Chưa có" : "\(workouts) bài · \(ActivityStyle.duration(workoutMinutes))")
            if let short = shortestNight {
                Text("Ngủ ít nhất vào \(short)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Sức khỏe", systemImage: "heart.fill")
        } footer: {
            Text("Đọc từ app Sức khỏe và tính trên iPhone này, không gửi lên server hay AI.")
        }
    }

    /// "Thứ Năm (5 giờ 40 phút)", when a night was clearly shorter than the rest.
    private var shortestNight: String? {
        let nights = health.enumerated().filter { $0.element.sleepMinutes > 0 }
        guard nights.count >= 3, let low = nights.min(by: { $0.element.sleepMinutes < $1.element.sleepMinutes }) else { return nil }
        let average = nights.reduce(0) { $0 + $1.element.sleepMinutes } / nights.count
        guard average - low.element.sleepMinutes >= 60 else { return nil }
        return "\(ActivityStyle.weekdayNames[low.offset]) (\(HealthService.hoursText(low.element.sleepMinutes)))"
    }

    private var sourcesSection: some View {
        Section {
            sourceRow("Lịch", status: CalendarService.shared.isAuthorized ? "Đo chính xác" : "Chưa cấp quyền", ok: CalendarService.shared.isAuthorized)
            sourceRow("Jira log work", status: connected("jira") ? "Đo chính xác" : "Chưa kết nối", ok: connected("jira"))
            sourceRow("Việc Not3", status: "Bấm giờ", ok: true)
            sourceRow("GitHub", status: connected("github") ? "Ước tính" : "Chưa kết nối", ok: false)
            sourceRow("Sức khỏe", status: LocalModule.isEnabled(.health) ? "Trên iPhone" : "Chưa bật", ok: LocalModule.isEnabled(.health))
        } header: {
            Text("Nguồn dữ liệu")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Giờ trùng nhau chỉ tính một lần, ưu tiên nguồn đo chính xác. Bấm \"Bắt đầu\" trước khi làm một việc để có số giờ thật.")
                Button("Cách tính") { router.path.append(.activityMethod) }
                    .font(.footnote.weight(.semibold))
            }
        }
    }

    private func connected(_ provider: String) -> Bool {
        supabase.integrations.contains { $0.provider == provider }
    }

    private func sourceRow(_ name: String, status: String, ok: Bool) -> some View {
        LabeledContent(name) {
            Text(status).foregroundStyle(ok ? Color.green : Color.secondary)
        }
    }

    private var shareText: String {
        var lines = ["Tuần \(DayClock.weekNumber(weekStart)) (\(DayClock.dayMonth(days.first ?? weekStart)) – \(DayClock.dayMonth(days.last ?? weekStart)))",
                     "Thời gian làm việc: \(ActivityStyle.longDuration(report.total))"]
        lines += report.kindParts().map { "• \($0.kind.label): \(ActivityStyle.duration($0.minutes))" }
        lines.append("Tập trung sâu: \(report.deepFocus.count) phiên, \(ActivityStyle.longDuration(report.deepFocusMinutes))")
        return lines.joined(separator: "\n")
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
}

// MARK: - Charts and rows

/// Stacked bars per day by kind, dashed average, hours on the trailing axis; tap a bar to select.
struct WeekBarsChart: View {
    let report: ActivityReport
    @Binding var selectedDay: Int?

    private struct Row: Identifiable {
        let id: String
        let day: String
        let kind: ActivityKind
        let minutes: Int
        let dayIndex: Int
    }

    private var rows: [Row] {
        report.perDay.enumerated().flatMap { index, kinds in
            let parts = kinds.filter { $0.value > 0 }.sorted { $0.key.order < $1.key.order }
            let base = parts.isEmpty ? [(key: ActivityKind.other, value: 0)] : parts.map { (key: $0.key, value: $0.value) }
            return base.map { Row(id: "\(index)-\($0.key.label)", day: DayClock.shortWeekdays[index], kind: $0.key, minutes: $0.value, dayIndex: index) }
        }
    }

    private var kinds: [ActivityKind] {
        Set(rows.map(\.kind)).sorted { $0.order < $1.order }
    }

    private var axisMax: Int {
        let top = max(180, (0..<report.perDay.count).map(report.total(day:)).max() ?? 0)
        let stepHours = Int(ceil(Double(top) / 60 / 3))
        return stepHours * 3 * 60
    }

    var body: some View {
        let average = report.perDay.isEmpty ? 0 : report.total / report.perDay.count
        Chart {
            ForEach(rows) { row in
                BarMark(x: .value("Ngày", row.day), y: .value("Phút", row.minutes), width: .fixed(24))
                    .foregroundStyle(by: .value("Loại", row.kind.label))
                    .cornerRadius(3)
                    .opacity(selectedDay == nil || selectedDay == row.dayIndex ? 1 : 0.35)
            }
            if average > 0 {
                RuleMark(y: .value("Trung bình", average))
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("tb").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    }
            }
        }
        .chartForegroundStyleScale(domain: kinds.map(\.label), range: kinds.map(\.color))
        .chartLegend(.hidden)
        .chartXScale(domain: DayClock.shortWeekdays)
        .chartYScale(domain: 0...axisMax)
        .chartYAxis {
            AxisMarks(position: .trailing, values: Array(stride(from: 0, through: axisMax, by: axisMax / 3))) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    if let minutes = value.as(Int.self) { Text(minutes == 0 ? "0" : "\(minutes / 60)g") }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let day = value.as(String.self) {
                        Text(day).fontWeight(DayClock.shortWeekdays.firstIndex(of: day) == selectedDay ? .bold : .regular)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame else { return }
                        let x = location.x - geometry[frame].origin.x
                        guard let day: String = proxy.value(atX: x),
                              let index = DayClock.shortWeekdays.firstIndex(of: day) else { return }
                        withAnimation(.snappy) { selectedDay = selectedDay == index ? nil : index }
                    }
            }
        }
        .accessibilityLabel("Giờ làm mỗi ngày theo loại")
    }
}

/// This week vs last week, Health highlight style.
struct ComparisonBars: View {
    let current: Int
    let previous: Int
    let color: Color

    var body: some View {
        let top = max(1, max(current, previous))
        VStack(alignment: .leading, spacing: 8) {
            bar(minutes: current, caption: "tuần này", fill: color, fraction: Double(current) / Double(top), dim: false)
            bar(minutes: previous, caption: "tuần trước", fill: Color(.systemGray4), fraction: Double(previous) / Double(top), dim: true)
        }
    }

    private func bar(minutes: Int, caption: String, fill: Color, fraction: Double, dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ActivityStyle.duration(minutes)).font(.title3.bold()).fontDesign(.rounded).monospacedDigit()
                    .foregroundStyle(dim ? .secondary : .primary)
                Text(caption).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 6)
                    .fill(fill)
                    .frame(width: max(6, proxy.size.width * fraction))
            }
            .frame(height: 20)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Weekday × hour (7–23 h) grid; tap a cell to inspect it, the weekday to open the day.
struct HeatGrid: View {
    let report: ActivityReport
    @Binding var selection: (day: Int, hour: Int)?
    var openDay: (Int) -> Void

    static let hours = Array(7...23)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Color.clear.frame(width: 28, height: 12)
                ForEach(Self.hours, id: \.self) { hour in
                    Text([7, 10, 13, 16, 19, 22].contains(hour) ? "\(hour)" : "")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .leading)
                        .fixedSize()
                }
            }
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: 3) {
                    Button(DayClock.shortWeekdays[day]) { openDay(day) }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                        .accessibilityLabel("Mở \(ActivityStyle.weekdayNames[day])")
                    ForEach(Self.hours, id: \.self) { hour in
                        let minutes = report.heat.indices.contains(day) ? report.heat[day][hour] : 0
                        let isOn = selection?.day == day && selection?.hour == hour
                        RoundedRectangle(cornerRadius: 4)
                            .fill(ActivityStyle.heatRamp[ActivityStyle.heatLevel(minutes: minutes)])
                            .frame(width: 14, height: 14)
                            .overlay {
                                if isOn { RoundedRectangle(cornerRadius: 4).stroke(.primary, lineWidth: 2).padding(-2) }
                            }
                            .contentShape(Rectangle().inset(by: -1.5))
                            .onTapGesture { withAnimation(.snappy) { selection = isOn ? nil : (day, hour) } }
                            .accessibilityElement()
                            .accessibilityLabel("\(ActivityStyle.weekdayNames[day]), \(hour) giờ: \(minutes > 0 ? "\(minutes) phút" : "không có")")
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
            HStack(spacing: 5) {
                Text("Ít")
                ForEach(ActivityStyle.heatRamp.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3).fill(ActivityStyle.heatRamp[index]).frame(width: 12, height: 12)
                }
                Text("Nhiều · 0–60 phút mỗi giờ")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 31)
            .padding(.top, 6)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Coloured icon square, name, thin bar, value — Screen Time "Most used" row.
struct CategoryRow: View {
    let kind: ActivityKind
    let value: String
    let share: Double
    let fill: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(kind.color, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(kind.label)
                    Spacer()
                    Text("\(value) · \(Int((share * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                GeometryReader { proxy in
                    Capsule().fill(Color(.tertiarySystemFill))
                        .overlay(alignment: .leading) {
                            Capsule().fill(kind.color).frame(width: max(4, proxy.size.width * fill))
                        }
                }
                .frame(height: 4)
                Text(kind.sourceLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
