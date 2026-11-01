import SwiftUI

/// Jira: tick the statuses that count as done for you (Done-category statuses always do).
struct JiraDoneStatusesView: View {
    @Binding var rules: DoneRules
    let onChange: () -> Void

    @Environment(SupabaseService.self) private var supabase
    @State private var statuses: [JiraStatus] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var customName = ""

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { status in
                        row(status)
                    }
                }
            }
            // Statuses saved earlier that this Jira no longer lists (or typed by hand).
            let extra = rules.statuses.filter { name in !statuses.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
            if !extra.isEmpty || errorMessage != nil {
                Section {
                    ForEach(extra, id: \.self) { name in
                        Label(name, systemImage: "checkmark").foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        let removed = offsets.map { extra[$0] }
                        rules.statuses.removeAll { removed.contains($0) }
                        onChange()
                    }
                    HStack {
                        TextField("Tên trạng thái, vd Code Review", text: $customName)
                            .submitLabel(.done)
                            .onSubmit(addCustom)
                        Button("Thêm", action: addCustom).disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Nhập tay")
                } footer: {
                    if let errorMessage { Text("Không tải được danh sách từ Jira: \(errorMessage)") }
                }
            }
        }
        .navigationTitle("Trạng thái tính là xong")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private struct Group { let title: String; let items: [JiraStatus] }

    private var groups: [Group] {
        [("In Progress", "indeterminate"), ("To Do", "new"), ("Done · luôn tính là xong", "done")].compactMap { title, key in
            let items = statuses.filter { $0.category == key }
            return items.isEmpty ? nil : Group(title: title, items: items)
        }
    }

    @ViewBuilder
    private func row(_ status: JiraStatus) -> some View {
        let alwaysDone = status.category == "done"
        let isOn = alwaysDone || rules.statuses.contains { $0.caseInsensitiveCompare(status.name) == .orderedSame }
        Button {
            guard !alwaysDone else { return }
            if isOn {
                rules.statuses.removeAll { $0.caseInsensitiveCompare(status.name) == .orderedSame }
            } else {
                rules.statuses.append(status.name)
            }
            onChange()
        } label: {
            HStack {
                Text(status.name).foregroundStyle(alwaysDone ? .secondary : .primary)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(alwaysDone ? Color.secondary : Theme.accentInk)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(alwaysDone)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func load() async {
        defer { isLoading = false }
        do {
            statuses = try await supabase.jiraStatuses()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addCustom() {
        let name = customName.trimmingCharacters(in: .whitespaces)
        customName = ""
        guard !name.isEmpty, !rules.statuses.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        rules.statuses.append(name)
        onChange()
    }
}

/// GitHub: labels that mark a PR / issue as done (e.g. ready-for-qa, deployed).
struct GitHubDoneLabelsView: View {
    @Binding var rules: DoneRules
    let onChange: () -> Void
    @State private var newLabel = ""

    private let suggestions = ["ready-for-review", "ready-for-qa", "qa", "deployed", "released", "done"]

    var body: some View {
        List {
            Section {
                ForEach(rules.labels, id: \.self) { label in
                    Label(label, systemImage: "tag")
                }
                .onDelete { offsets in
                    rules.labels.remove(atOffsets: offsets)
                    onChange()
                }
                HStack {
                    TextField("Tên nhãn", text: $newLabel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { add(newLabel) }
                    Button("Thêm") { add(newLabel) }
                        .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("PR hoặc issue đang mở có một trong các nhãn này được tính là xong. Không phân biệt hoa thường.")
            }

            let unused = suggestions.filter { s in !rules.labels.contains { $0.caseInsensitiveCompare(s) == .orderedSame } }
            if !unused.isEmpty {
                Section("Gợi ý") {
                    ChipGroupContainer(spacing: 6) {
                        ForEach(unused, id: \.self) { s in
                            ChipButton(title: s, systemImage: "plus") { add(s) }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
        }
        .navigationTitle("Nhãn tính là xong")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add(_ raw: String) {
        let label = raw.trimmingCharacters(in: .whitespaces)
        newLabel = ""
        guard !label.isEmpty, !rules.labels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) else { return }
        rules.labels.append(label)
        onChange()
    }
}
