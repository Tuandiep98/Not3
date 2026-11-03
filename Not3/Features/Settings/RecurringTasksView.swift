import SwiftData
import SwiftUI

/// "Việc lặp lại" in Settings: every series, with a switch to pause it.
struct RecurringTasksView: View {
    @Query(sort: \TaskSeries.createdAt) private var series: [TaskSeries]

    var body: some View {
        List {
            if series.isEmpty {
                ContentUnavailableView(
                    "Chưa có việc lặp lại",
                    systemImage: "repeat",
                    description: Text("Mở một việc trong Hôm nay và chọn \"Lặp lại\".")
                )
            } else {
                Section {
                    ForEach(series) { item in
                        SeriesRow(series: item)
                    }
                } footer: {
                    Text("Tắt để dừng tạo việc mới. Việc đã tạo vẫn giữ nguyên.")
                }
            }
        }
        .navigationTitle("Việc lặp lại")
    }
}

private struct SeriesRow: View {
    @Bindable var series: TaskSeries

    var body: some View {
        Toggle(isOn: Binding(
            get: { series.isActive },
            set: { series.isActive = $0; series.touch() }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(series.title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
    }

    private var detail: String {
        let time = series.hour.map { String(format: "%02d:%02d", $0, series.minute ?? 0) }
        return [series.rule.label, time, series.durationMinutes.map { "\($0) phút" }].compactMap { $0 }.joined(separator: " · ")
    }
}
