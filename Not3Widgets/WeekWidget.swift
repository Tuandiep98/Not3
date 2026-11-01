import SwiftUI
import WidgetKit

/// "Tuần này": x/7 meaningful days + one dot per day (home screen); gauge on the lock screen.
struct WeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.week, provider: SnapshotProvider()) { entry in
            WeekWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Tuần này")
        .description("Số ngày có việc ý nghĩa trong tuần.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
        .contentMarginsDisabled()
    }
}

struct WeekWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode

    private var week: [Bool] { entry.snapshot.week }
    private var count: Int { entry.snapshot.meaningfulDays }

    var body: some View {
        if family == .accessoryCircular {
            Gauge(value: Double(count), in: 0...7) {
                Text("Tuần")
            } currentValueLabel: {
                Text("\(count)/7").font(.system(.body, design: .rounded).weight(.semibold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetURL(DeepLink.summary)
        } else {
            VStack(spacing: 0) {
                WidgetHeader(title: "Tuần này")
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(count)/7")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .widgetAccentable()
                    Text("ngày có việc ý nghĩa").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { i in
                            dot(week.indices.contains(i) && week[i])
                            if i < 6 { Spacer(minLength: 0) }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .widgetURL(DeepLink.summary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tuần này: \(count) trên 7 ngày có việc ý nghĩa")
        }
    }

    @ViewBuilder
    private func dot(_ on: Bool) -> some View {
        if on {
            Circle().fill(mode == .fullColor ? WStyle.band : Color.primary).frame(width: 14, height: 14).widgetAccentable()
        } else {
            Circle().strokeBorder(Color(.systemGray3), lineWidth: 1.5).frame(width: 14, height: 14)
        }
    }
}
