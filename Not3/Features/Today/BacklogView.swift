import SwiftData
import SwiftUI

/// "Hộp chờ": work without a day. Nothing here reminds you; check-in offers it in the afternoon.
struct BacklogView: View {
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @Environment(SupabaseService.self) private var supabase
    @Query(sort: \TaskItem.createdAt) private var tasks: [TaskItem]

    @State private var newTitle = ""
    @FocusState private var isAdding: Bool

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accentInk)
                    TextField("Thêm vào hộp chờ", text: $newTitle)
                        .focused($isAdding)
                        .submitLabel(.done)
                        .onSubmit(add)
                }
                .frame(minHeight: 44)
            } footer: {
                Text("Việc chưa biết làm ngày nào. Không có nhắc giờ; lúc check-in sẽ gợi ý lấy ra làm buổi chiều.")
            }

            Section {
                if backlog.isEmpty {
                    Text("Hộp chờ trống.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(backlog) { task in
                        Button {
                            router.taskEditor = .edit(task.id)
                        } label: {
                            BacklogRow(task: task)
                        }
                        .foregroundStyle(.primary)
                        .swipeActions(edge: .leading) {
                            Button("Làm hôm nay", systemImage: "sun.max") {
                                Task { await TaskActions.schedule(task, at: nil, serverPushActive: supabase.hasServerPush) }
                            }
                            .tint(.orange)
                        }
                        .swipeActions {
                            Button("Huỷ", systemImage: "xmark", role: .destructive) {
                                TaskActions.cancel(task)
                            }
                            Button("Lên lịch…", systemImage: "calendar") {
                                router.taskEditor = .edit(task.id)
                            }
                            .tint(.blue)
                        }
                    }
                }
            } header: {
                Text("\(backlog.count) việc")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Hộp chờ")
        .toolbarTitleDisplayMode(.large)
    }

    private var backlog: [TaskItem] { TodayList.backlog(tasks) }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        newTitle = ""
        guard !title.isEmpty else { return }
        let task = TaskItem(title: title, category: nil, plannedAt: nil, durationMinutes: nil, source: .manual)
        task.isSomeday = true
        context.insert(task)
        try? context.save()
        isAdding = true
    }
}

private struct BacklogRow: View {
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title)
            let parts = ["Thêm \(DayClock.dayMonth(task.createdAt))", task.durationMinutes.map { "\($0) phút" }, task.category]
                .compactMap { $0 }
            Text(parts.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }
}
