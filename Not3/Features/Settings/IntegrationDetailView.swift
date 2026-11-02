import SwiftData
import SwiftUI

/// Settings → GitHub / Jira: what to pull and how it is classified, sync now, disconnect.
struct IntegrationDetailView: View {
    let source: ExternalSource

    @Environment(SupabaseService.self) private var supabase
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var settings: [String: Bool] = [:]
    @State private var saveTask: Task<Void, Never>?
    @State private var isSyncing = false
    @State private var isConfirmingDisconnect = false
    @State private var errorMessage: String?
    @State private var rules = DoneRules()
    @State private var rulesTask: Task<Void, Never>?

    private var record: IntegrationRecord? {
        supabase.integrations.first { $0.provider == source.rawValue }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    SourceTile(source: source, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record?.accountName ?? source.label).font(.headline)
                        Text(statusLine)
                            .font(.subheadline)
                            .foregroundStyle(record?.lastError == nil ? Color.secondary : Color.orange)
                    }
                }
                .padding(.vertical, 4)
                if let error = record?.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button {
                    Task {
                        isSyncing = true
                        await AppLifecycle.refreshNow()
                        isSyncing = false
                    }
                } label: {
                    HStack {
                        Text("Đồng bộ ngay")
                        Spacer()
                        if isSyncing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                }
                .disabled(isSyncing)
            } footer: {
                if source == .jira, let webhook = record?.webhook {
                    switch webhook {
                    case .active:
                        Label("Cập nhật tức thì đang bật: Jira báo ngay khi ticket của bạn thay đổi.", systemImage: "bolt.fill")
                    case .failed(let error):
                        Label("Chưa bật cập nhật tức thì — \(error). Dữ liệu vẫn đồng bộ mỗi 15 phút.", systemImage: "bolt.slash")
                    }
                }
            }

            ForEach(IntegrationOption.Group.allCases, id: \.self) { group in
                let options = IntegrationOption.options(for: source).filter { $0.group == group }
                if !options.isEmpty {
                    Section {
                        ForEach(options) { option in
                            // Two Texts → iOS renders title + secondary subtitle.
                            Toggle(isOn: binding(option)) {
                                Text(option.title)
                                Text(option.detail)
                            }
                        }
                    } header: {
                        Text(group.rawValue)
                    } footer: {
                        if group == .permission {
                            Text("Cần quyền Actions / Deployments: Read trong GitHub App. Chưa có quyền thì mục này được bỏ qua.")
                        }
                    }
                }
            }

            doneRulesSection

            Section {
                Button("Ngắt kết nối", role: .destructive) { isConfirmingDisconnect = true }
            } footer: {
                Text("Thay đổi áp dụng từ lần đồng bộ sau. Tắt một mục không xoá dữ liệu đã có.")
            }
        }
        .navigationTitle(source == .github ? "GitHub" : "Jira Cloud")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            settings = record?.settings ?? [:]
            rules = record?.doneRules ?? DoneRules()
        }
        .confirmationDialog("Ngắt kết nối \(source.label)?", isPresented: $isConfirmingDisconnect, titleVisibility: .visible) {
            Button("Ngắt và xoá dữ liệu đã kéo về", role: .destructive) {
                Task {
                    do {
                        try await supabase.disconnect(provider: source, context: context)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("Token bị xoá khỏi server, các mục đã đồng bộ từ nguồn này cũng bị xoá.")
        }
        .alert("Lỗi", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// "Tính là hoàn thành": when linked tasks count as done for you (e.g. a developer's work is
    /// done at Code Review, not when the ticket reaches Done).
    @ViewBuilder
    private var doneRulesSection: some View {
        Section {
            switch source {
            case .jira:
                NavigationLink {
                    JiraDoneStatusesView(rules: $rules, onChange: saveRules)
                } label: {
                    LabeledContent("Trạng thái tính là xong", value: rules.statuses.isEmpty ? "Chỉ Done" : "Done + \(rules.statuses.count)")
                }
            case .github:
                Picker("PR của tôi xong khi", selection: Binding(get: { rules.prDoneWhen }, set: { rules.prDoneWhen = $0; saveRules() })) {
                    ForEach(DoneRules.PRDoneWhen.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                NavigationLink {
                    GitHubDoneLabelsView(rules: $rules, onChange: saveRules)
                } label: {
                    LabeledContent("Nhãn tính là xong", value: rules.labels.isEmpty ? "Không" : "\(rules.labels.count)")
                }
            case .calendar:
                EmptyView()
            }
        } header: {
            Text("Tính là hoàn thành")
        } footer: {
            Text(source == .jira
                 ? "Ví dụ với developer: Code Review, In Review, Release Testing. Task tự xong khi ticket tới trạng thái đã chọn."
                 : "Task tự xong khi PR / issue đạt điều kiện. Đã xong thì không tự mở lại.")
        }
    }

    private func saveRules() {
        rulesTask?.cancel()
        let snapshot = rules
        rulesTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await supabase.updateDoneRules(source, rules: snapshot)
        }
    }

    private var statusLine: String {
        guard let record else { return "Chưa kết nối" }
        if let error = record.lastError { return SettingsView.shortError(error) }
        guard let last = record.lastSyncedAt else { return "Đã kết nối" }
        return "Đồng bộ lần cuối \(DayClock.time(last))"
    }

    private func binding(_ option: IntegrationOption) -> Binding<Bool> {
        Binding {
            IntegrationOption.value(option, in: settings)
        } set: { newValue in
            settings[option.key] = newValue
            // Save after the user stops flipping switches.
            saveTask?.cancel()
            let snapshot = settings
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await supabase.updateIntegrationSettings(source, settings: snapshot)
            }
        }
    }
}
