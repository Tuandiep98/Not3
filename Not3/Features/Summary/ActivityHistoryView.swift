import Charts
import SwiftData
import SwiftUI

/// "Lịch sử": 12 weeks of time worked — weekly bars with the average (Health trends), a trend
/// line, and a day-by-day heat map.
struct ActivityHistoryView: View {
    @Environment(\.modelContext) private var context
    @State private var snapshot = ActivitySnapshot.empty
    @State private var isLoading = true
    @State private var selectedWeek: Int?

    private static let weekCount = 12
    private let weekStarts: [Date] = {
        let current = DayClock.startOfWeek()
        return (0..<weekCount).reversed().compactMap { DayClock.calendar.date(byAdding: .day, value: -7 * $0, to: current) }
    }()
    private var days: [Date] { weekStarts.flatMap { DayClock.daysOfWeek($0) } }
    private var report: ActivityReport { snapshot.report }

    private var weekTotals: [Int] {
        guard report.perDay.count == Self.weekCount * 7 else { return Array(repeating: 0, count: Self.weekCount) }
        return (0..<Self.weekCount).map { w in (0..<7).reduce(0) { $0 + report.total(day: w * 7 + $1) } }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    chart.frame(height: 190).opacity(isLoading ? 0.4 : 1)
                    HStack(spacing: 6) {
                        Rectangle().fill(.green).frame(width: 16, height: 1.5)
                        Text("Trung bình \(ActivityStyle.duration(average)) mỗi tuần")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HighlightTitle(title: "Xu hướng", symbol: "chart.line.uptrend.xyaxis", color: .green)
                    Text(trendSentence).font(.headline)
                }
                .padding(.vertical, 6)
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HighlightTitle(title: "Mỗi ngày", symbol: "calendar", color: Theme.accentInk)
                    dayGrid
                }
                .padding(.vertical, 6)
            } footer: {
                Text("Mỗi ô là một ngày, mỗi cột là một tuần. Màu đậm là làm nhiều giờ.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Lịch sử")
        .task {
            snapshot = await ActivityLoader.load(days: days, in: context)
            isLoading = false
        }
    }

    private var average: Int {
        let active = weekTotals.filter { $0 > 0 }
        return active.isEmpty ? 0 : active.reduce(0, +) / active.count
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let week = selectedWeek {
                ChartCaption(text: "Tuần \(DayClock.dayMonth(weekStarts[week]))" + (week == Self.weekCount - 1 ? " · tuần này" : ""))
                DurationHeadline(minutes: weekTotals[week])
                let active = (0..<7).filter { report.perDay.indices.contains(week * 7 + $0) && report.total(day: week * 7 + $0) > 0 }.count
                Text("\(active)/7 ngày có làm · chạm lại để bỏ chọn").font(.footnote).foregroundStyle(.secondary)
            } else {
                ChartCaption(text: "Trung bình mỗi tuần")
                DurationHeadline(minutes: average)
                Text("\(DayClock.dayMonth(weekStarts.first ?? Date())) – \(DayClock.dayMonth(Date())) · 12 tuần")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 76, alignment: .topLeading)
    }

    private var chart: some View {
        let labels = weekStarts.map { DayClock.dayMonth($0) }
        let top = max(600, weekTotals.max() ?? 0)
        let step = Int(ceil(Double(top) / 60 / 3)) * 60
        return Chart {
            ForEach(Array(weekTotals.enumerated()), id: \.offset) { index, minutes in
                BarMark(x: .value("Tuần", labels[index]), y: .value("Phút", minutes), width: .fixed(16))
                    .foregroundStyle(Color.orange.opacity(selectedWeek == nil || selectedWeek == index ? 1 : 0.35))
                    .cornerRadius(4)
            }
            if average > 0 {
                RuleMark(y: .value("Trung bình", average))
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .chartXScale(domain: labels)
        .chartYScale(domain: 0...(step * 3))
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, step, step * 2, step * 3]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel { if let m = value.as(Int.self) { Text(m == 0 ? "0" : "\(m / 60)h") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: labels.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)) { _ in
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame else { return }
                        let x = location.x - geometry[frame].origin.x
                        guard let label: String = proxy.value(atX: x), let index = labels.firstIndex(of: label) else { return }
                        withAnimation(.snappy) { selectedWeek = selectedWeek == index ? nil : index }
                    }
            }
        }
        .accessibilityLabel("Tổng giờ làm mỗi tuần, 12 tuần gần nhất")
    }

    private var trendSentence: String {
        let recent = weekTotals.suffix(4), earlier = weekTotals.prefix(Self.weekCount - 4)
        let recentAvg = recent.reduce(0, +) / max(1, recent.count)
        let earlierActive = earlier.filter { $0 > 0 }
        var text: String
        if earlierActive.isEmpty {
            text = "Mới có dữ liệu \(weekTotals.filter { $0 > 0 }.count) tuần, xu hướng sẽ rõ hơn sau vài tuần."
        } else {
            let earlierAvg = earlierActive.reduce(0, +) / earlierActive.count
            let diff = recentAvg - earlierAvg
            text = abs(diff) < 30
                ? "4 tuần gần đây giữ nhịp như trước, khoảng \(ActivityStyle.duration(recentAvg)) mỗi tuần."
                : "4 tuần gần đây trung bình \(diff > 0 ? "cao" : "thấp") hơn \(ActivityStyle.longDuration(abs(diff))) so với các tuần trước."
        }
        if streak > 1 { text += " Chuỗi hiện tại \(streak) ngày có làm việc." }
        return text
    }

    /// Consecutive days with time worked, ending today (or yesterday if today is still empty).
    private var streak: Int {
        guard !report.perDay.isEmpty else { return 0 }
        let today = DayClock.startOfDay()
        guard var index = days.lastIndex(where: { $0 <= today }) else { return 0 }
        if report.total(day: index) == 0 { index -= 1 }
        var count = 0
        while index >= 0, report.total(day: index) > 0 {
            count += 1
            index -= 1
        }
        return count
    }

    private var dayGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    Color.clear.frame(width: 22, height: 12)
                    ForEach(DayClock.shortWeekdays, id: \.self) { label in
                        Text(label).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 22, height: 20, alignment: .leading)
                    }
                }
                ForEach(0..<Self.weekCount, id: \.self) { week in
                    VStack(spacing: 4) {
                        Text(monthLabel(week)).font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 12).fixedSize()
                        ForEach(0..<7, id: \.self) { weekday in
                            let index = week * 7 + weekday
                            let minutes = report.perDay.indices.contains(index) ? report.total(day: index) : 0
                            let future = days.indices.contains(index) && days[index] > Date()
                            RoundedRectangle(cornerRadius: 5)
                                .fill(future ? Color.clear : ActivityStyle.heatRamp[ActivityStyle.dayLevel(minutes: minutes)])
                                .overlay { if selectedWeek == week { RoundedRectangle(cornerRadius: 5).stroke(.primary, lineWidth: 1.5) } }
                                .frame(width: 20, height: 20)
                                .accessibilityLabel("\(DayClock.shortWeekdays[weekday]) tuần \(DayClock.dayMonth(weekStarts[week])): \(minutes > 0 ? ActivityStyle.longDuration(minutes) : "không làm")")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 5) {
                Text("Ít")
                ForEach(ActivityStyle.heatRamp.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3).fill(ActivityStyle.heatRamp[index]).frame(width: 12, height: 12)
                }
                Text("Nhiều · 0 đến 7 giờ+ mỗi ngày")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 26)
            .padding(.top, 4)
        }
    }

    private func monthLabel(_ week: Int) -> String {
        let month = DayClock.calendar.component(.month, from: weekStarts[week])
        let previous = week > 0 ? DayClock.calendar.component(.month, from: weekStarts[week - 1]) : -1
        return month != previous ? "Th\(month)" : ""
    }
}

/// "Cách tính": how time is measured, per source.
struct ActivityMethodView: View {
    var body: some View {
        List {
            Section {
                Text("Mỗi nguồn được đổi thành các khoảng thời gian. Chỗ trùng giờ chỉ tính một lần, nguồn đo chính xác được ưu tiên hơn nguồn ước tính. Sau đó chia vào từng giờ, từng ngày và từng loại.")
            }
            Section("Đo chính xác") {
                row("Lịch", "Giờ bắt đầu – kết thúc của từng cuộc họp. Bỏ qua sự kiện cả ngày, sự kiện đã huỷ hoặc bạn đã từ chối, và lịch \"Not3\" của app.", "calendar")
                row("Jira log work", "Giờ bắt đầu và thời lượng của từng lần bạn log work.", "checklist")
                row("Việc Not3", "Từ lúc bấm \"Bắt đầu\" (trong app, widget hoặc thông báo) đến lúc tick xong.", "play.circle")
            }
            Section("Dự kiến") {
                row("Việc Not3 không bấm giờ", "Dùng thời lượng đã đặt cho việc, tính ngược từ lúc tick xong. Việc liên kết với PR / ticket thì không tính thêm.", "hourglass")
            }
            Section("Ước tính") {
                row("GitHub", "Các hoạt động của bạn (push, PR, review, bình luận) cách nhau không quá 45 phút được gộp thành một phiên, cộng 15 phút trước hoạt động đầu tiên. Một hoạt động lẻ tính 15 phút.", "chevron.left.forwardslash.chevron.right")
            }
            Section("Không dùng được") {
                row("Screen Time", "iOS chỉ cho hiển thị số liệu Screen Time trong một tiện ích cách ly, app không đọc được để cộng vào.", "hourglass.bottomhalf.filled")
            }
            Section {
                row("Tập trung sâu", "Một khoảng làm liền từ 50 phút trở lên, không bị họp cắt ngang (nghỉ dưới 5 phút vẫn tính là liền).", "bolt.fill")
                row("Riêng tư", "Chỉ lưu thời điểm, loại và tiêu đề; không đọc nội dung code hay ticket. Lịch chỉ đọc trên máy.", "lock.fill")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Cách tính")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ detail: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accentInk)
        }
        .padding(.vertical, 2)
    }
}
