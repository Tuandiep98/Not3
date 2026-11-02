import SwiftData
import SwiftUI

/// One day of "Tổng kết tuần": total, mix by kind and a Calendar-style timeline. Measured blocks
/// are tinted with a colour stripe; estimated GitHub sessions are dashed.
struct DayActivityView: View {
    let day: Date

    @Environment(\.modelContext) private var context
    @State private var snapshot = ActivitySnapshot.empty
    @State private var isLoading = true

    private var report: ActivityReport { snapshot.report }
    private static let hourHeight: CGFloat = 56

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    ChartCaption(text: DayClock.longDate(day))
                    DurationHeadline(minutes: report.days.isEmpty ? 0 : report.total(day: 0))
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                if !report.kindParts(day: 0).isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        KindShareBar(parts: report.kindParts(day: 0))
                        KindLegend(parts: report.kindParts(day: 0))
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                if report.blocks.isEmpty {
                    Text(isLoading ? "Đang tải…" : "Không có hoạt động nào được ghi nhận trong ngày.")
                        .foregroundStyle(.secondary)
                } else {
                    timeline
                        .padding(.vertical, 8)
                }
            } header: {
                HStack {
                    Text("Dòng thời gian")
                    Spacer()
                    Label("Ước tính", systemImage: "rectangle.dashed").labelStyle(.titleAndIcon)
                }
            } footer: {
                if report.overlapsResolved > 0 {
                    Text("\(report.overlapsResolved) đoạn trùng giờ đã được gộp: chỉ tính một lần, ưu tiên nguồn đo chính xác.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(DayClock.dayMonth(day))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            snapshot = await ActivityLoader.load(days: [DayClock.startOfDay(day)], in: context)
            isLoading = false
        }
    }

    private var subtitle: String {
        let focus = report.deepFocus.count
        let blocks = report.blocks.count
        return "\(blocks) khối thời gian" + (focus > 0 ? " · \(focus) phiên tập trung sâu" : "")
    }

    private var hourRange: ClosedRange<Int> {
        let calendar = DayClock.calendar
        let first = report.blocks.map { calendar.component(.hour, from: $0.start) }.min() ?? 7
        let last = report.blocks.map { calendar.component(.hour, from: $0.end.addingTimeInterval(-1)) + 1 }.max() ?? 21
        return min(7, first)...max(21, min(24, last))
    }

    private var timeline: some View {
        let range = hourRange
        let height = CGFloat(range.upperBound - range.lowerBound) * Self.hourHeight
        let origin = DayClock.calendar.date(byAdding: .hour, value: range.lowerBound, to: DayClock.startOfDay(day)) ?? day
        return ZStack(alignment: .topLeading) {
            ForEach(Array(range), id: \.self) { hour in
                HStack(spacing: 8) {
                    Text(String(format: "%02d:00", hour))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                    Rectangle().fill(Color(.separator)).frame(height: 0.5)
                }
                .offset(y: CGFloat(hour - range.lowerBound) * Self.hourHeight - 6)
            }
            ForEach(report.blocks) { block in
                let top = CGFloat(block.start.timeIntervalSince(origin) / 3600) * Self.hourHeight
                let h = max(22, CGFloat(block.end.timeIntervalSince(block.start) / 3600) * Self.hourHeight - 2)
                TimelineBlock(block: block, tall: h >= 40)
                    .frame(height: h)
                    .padding(.leading, 50)
                    .offset(y: top + 1)
            }
        }
        .frame(height: height, alignment: .top)
    }
}

/// A Calendar-style event: tinted fill, colour stripe, dashed outline when estimated.
private struct TimelineBlock: View {
    let block: ActivityBlock
    let tall: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(block.kind.color).frame(width: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.title).font(.footnote.weight(.semibold)).lineLimit(1)
                if tall {
                    Text(meta).font(.caption).lineLimit(1)
                }
            }
            .foregroundStyle(block.kind.color.mix(with: .primary, by: 0.55))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(block.kind.color.opacity(0.16))
        .clipShape(.rect(cornerRadius: 6))
        .overlay {
            if block.precision == .estimated {
                RoundedRectangle(cornerRadius: 6).strokeBorder(block.kind.color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        let source = switch block.source {
        case .calendar: "Lịch"
        case .jira: "Jira log work"
        case .github: "GitHub · ước tính"
        case .task: block.precision == .measured ? "Bấm giờ" : "Thời lượng dự kiến"
        }
        return "\(DayClock.time(block.start))–\(DayClock.time(block.end)) · \(source)"
    }
}
