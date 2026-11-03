import EventKit
import SwiftData
import SwiftUI

// Settings screens of the on-device Apple sources: Lịch, Lời nhắc, Sức khỏe, Gợi ý nhật ký and the
// Focus Filter. Same layout as GitHub / Jira (IntegrationDetailView): header tile, what to read,
// then turning it off.

/// Big tile · name · one-line status, the first row of each screen.
struct ModuleHeader: View {
    let source: ExternalSource
    let status: String
    var isWarning = false

    var body: some View {
        HStack(spacing: 14) {
            SourceTile(source: source, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.label).font(.headline)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(isWarning ? Color.orange : Color.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Toggles of `IntegrationOption.options(for:)`, stored on device.
private struct ModuleOptionsSections: View {
    let source: ExternalSource
    var onChange: () -> Void
    @State private var values: [String: Bool]

    init(source: ExternalSource, onChange: @escaping () -> Void = {}) {
        self.source = source
        self.onChange = onChange
        _values = State(initialValue: LocalModule.options(source))
    }

    var body: some View {
        ForEach(IntegrationOption.Group.allCases, id: \.self) { group in
            let options = IntegrationOption.options(for: source).filter { $0.group == group }
            if !options.isEmpty {
                Section(group.rawValue) {
                    ForEach(options) { option in
                        Toggle(isOn: binding(option)) {
                            Text(option.title)
                            Text(option.detail)
                        }
                    }
                }
            }
        }
    }

    private func binding(_ option: IntegrationOption) -> Binding<Bool> {
        Binding {
            IntegrationOption.value(option, in: values)
        } set: { newValue in
            values[option.key] = newValue
            LocalModule.setOptions(source, values)
            onChange()
        }
    }
}

/// "Đọc từ": one switch per calendar / reminder list (all on by default).
private struct SourceListsSection: View {
    let source: ExternalSource
    let lists: [EKCalendar]
    let footer: String
    var onChange: () -> Void
    @State private var excluded: Set<String>

    init(source: ExternalSource, lists: [EKCalendar], footer: String, onChange: @escaping () -> Void = {}) {
        self.source = source
        self.lists = lists
        self.footer = footer
        self.onChange = onChange
        _excluded = State(initialValue: LocalModule.excluded(source))
    }

    var body: some View {
        Section {
            if lists.isEmpty {
                Text("Chưa có danh sách nào.").foregroundStyle(.secondary)
            }
            ForEach(lists, id: \.calendarIdentifier) { list in
                Toggle(isOn: binding(list.calendarIdentifier)) {
                    Label {
                        Text(list.title)
                        if let account = list.source?.title { Text(account) }
                    } icon: {
                        Circle().fill(list.cgColor.map { Color(cgColor: $0) } ?? .gray).frame(width: 12, height: 12)
                    }
                }
            }
        } header: {
            Text("Đọc từ")
        } footer: {
            Text(footer)
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding {
            !excluded.contains(id)
        } set: { on in
            if on { excluded.remove(id) } else { excluded.insert(id) }
            LocalModule.setExcluded(source, excluded)
            onChange()
        }
    }
}

private func openSystemSettings(_ openURL: OpenURLAction) {
    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
}

// MARK: Lịch

struct CalendarSettingsView: View {
    @Environment(CalendarService.self) private var calendar
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @AppStorage(SettingsKey.addToCalendar) private var addToCalendar = true
    @State private var lists: [EKCalendar] = []

    var body: some View {
        Form {
            Section {
                ModuleHeader(source: .calendar, status: statusText, isWarning: calendar.status != .fullAccess)
                switch calendar.status {
                case .fullAccess:
                    EmptyView()
                case .denied, .restricted, .writeOnly:
                    Button("Mở Cài đặt để cấp toàn quyền") { openSystemSettings(openURL) }
                default:
                    Button("Cấp quyền") {
                        Task {
                            await calendar.requestAccess()
                            await reload()
                        }
                    }
                }
            } footer: {
                Text("Gồm cả lịch Google, Outlook đã thêm vào iPhone. Sự kiện hôm nay được gửi lên server để gợi ý check-in.")
            }

            if calendar.status == .fullAccess {
                SourceListsSection(
                    source: .calendar,
                    lists: lists,
                    footer: "Sự kiện của lịch đang bật hiện ở Buổi sáng, chip check-in, Nhật ký và Tổng kết tuần. Lịch “Not3” chứa kế hoạch của bạn nên không đọc lại.",
                    onChange: { Task { await reload() } }
                )

                Section {
                    Toggle(isOn: $addToCalendar) {
                        Text("Ghi kế hoạch vào lịch")
                        Text("Lịch “Not3”, dời hay xoá sự kiện sẽ cập nhật việc")
                    }
                } header: {
                    Text("Kế hoạch chiều")
                } footer: {
                    Text("Mặc định cho nút “Thêm vào Lịch” khi chốt kế hoạch trong check-in.")
                }
            }
        }
        .navigationTitle("Lịch")
        .navigationBarTitleDisplayMode(.inline)
        .task { lists = calendar.calendars() }
    }

    private var statusText: String {
        switch calendar.status {
        case .fullAccess: "Đã cấp quyền · đọc \(readCount)/\(lists.count) lịch"
        case .denied, .restricted: "Đã từ chối quyền"
        case .writeOnly: "Chỉ có quyền ghi"
        default: "Chưa cấp quyền"
        }
    }

    private var readCount: Int {
        let excluded = LocalModule.excluded(.calendar)
        return lists.filter { !excluded.contains($0.calendarIdentifier) }.count
    }

    private func reload() async {
        lists = calendar.calendars()
        await calendar.refresh(in: context)
        JournalService.updateToday(in: context)
        WidgetBridge.publishSoon()
    }
}

// MARK: Lời nhắc

struct RemindersSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var lists: [EKCalendar] = []
    @State private var refreshTask: Task<Void, Never>?
    @State private var isConfirmingOff = false

    var body: some View {
        Form {
            Section {
                ModuleHeader(source: .reminders, status: "Đang bật · tick hai chiều")
            } footer: {
                Text("Đọc và ghi lời nhắc ngay trên iPhone, không gửi lên server. Việc tạo từ lời nhắc đồng bộ như việc bình thường.")
            }

            ModuleOptionsSections(source: .reminders, onChange: scheduleRefresh)

            SourceListsSection(
                source: .reminders,
                lists: lists,
                footer: "Chỉ lấy lời nhắc từ các danh sách đang bật.",
                onChange: scheduleRefresh
            )

            Section {
                Button("Tắt Lời nhắc", role: .destructive) { isConfirmingOff = true }
            } footer: {
                Text("Việc đã tạo vẫn giữ lại nhưng không còn tick hai chiều. Thu hồi quyền trong Cài đặt → Not3 → Lời nhắc.")
            }
        }
        .navigationTitle("Lời nhắc")
        .navigationBarTitleDisplayMode(.inline)
        .task { lists = RemindersService.shared.lists() }
        .confirmationDialog("Tắt Lời nhắc?", isPresented: $isConfirmingOff, titleVisibility: .visible) {
            Button("Tắt", role: .destructive) {
                LocalModule.disable(.reminders, in: context)
                dismiss()
            }
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await RemindersService.shared.refresh(in: context)
            JournalService.updateToday(in: context)
            WidgetBridge.publishSoon()
        }
    }
}

// MARK: Sức khỏe

struct HealthSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(HealthService.stepGoalKey) private var stepGoal = HealthService.defaultStepGoal
    @AppStorage(HealthService.stateOfMindKey) private var writesStateOfMind = false
    @State private var today = HealthService.Day()
    @State private var refreshTask: Task<Void, Never>?
    @State private var isConfirmingOff = false
    @State private var stateOfMindDenied = false

    var body: some View {
        Form {
            Section {
                ModuleHeader(source: .health, status: writesStateOfMind ? "Đang bật · đọc, ghi tâm trạng" : "Đang bật · chỉ đọc")
                LabeledContent("Đêm qua ngủ", value: today.sleepMinutes > 0 ? HealthService.hoursText(today.sleepMinutes) : "Chưa có")
                LabeledContent("Bước hôm nay", value: today.steps.formatted(.number.locale(Locale(identifier: "vi_VN"))))
                LabeledContent("Vận động hôm nay", value: today.workouts > 0 ? "\(today.workouts) bài · \(today.workoutMinutes) phút" : "Chưa có")
            } footer: {
                Text("Không thấy số liệu? Có thể bạn chưa cho phép một loại dữ liệu — mở app Sức khỏe → Hồ sơ → Ứng dụng → Not3.")
            }

            ModuleOptionsSections(source: .health, onChange: scheduleRefresh)

            Section {
                Stepper(value: $stepGoal, in: 2_000...30_000, step: 500) {
                    LabeledContent("Mục tiêu bước", value: stepGoal.formatted(.number.locale(Locale(identifier: "vi_VN"))))
                }
                .onChange(of: stepGoal) { scheduleRefresh() }
            } footer: {
                Text("Việc từ Sức khỏe mang biểu tượng trái tim ở Buổi sáng, chip check-in và Nhật ký. Tổng kết tuần có thêm giấc ngủ, số bước và thời gian vận động.")
            }

            Section {
                Toggle(isOn: $writesStateOfMind) {
                    Text("Ghi cảm nhận vào Sức khỏe")
                    Text("Check-in trưa → cảm xúc lúc đó · Khép lại hôm nay → tâm trạng cả ngày")
                }
                if stateOfMindDenied {
                    Text("Chưa có quyền ghi. Mở app Sức khỏe → Hồ sơ → Ứng dụng → Not3 và bật Tâm trạng.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Chỉ ghi mức độ (dễ chịu, bình thường, mệt) vào mục Tâm trạng, không ghi tên việc hay ghi chú.")
            }
            .onChange(of: writesStateOfMind) { _, isOn in
                guard isOn else { stateOfMindDenied = false; return }
                Task {
                    let granted = await HealthService.shared.requestStateOfMindAccess()
                    if !granted { writesStateOfMind = false }
                    stateOfMindDenied = !granted
                }
            }

            Section {
                Button("Mở app Sức khỏe") {
                    if let url = URL(string: "x-apple-health://") { openURL(url) }
                }
                Button("Tắt Sức khỏe", role: .destructive) { isConfirmingOff = true }
            } footer: {
                Text("Dữ liệu sức khỏe chỉ đọc và tính trên iPhone này, không gửi lên server hay AI. Chỉ tên việc bạn chọn trong check-in (ví dụ “Chạy bộ 30 phút”) mới được lưu cùng check-in.")
            }
        }
        .navigationTitle("Sức khỏe")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadToday() }
        .confirmationDialog("Tắt Sức khỏe?", isPresented: $isConfirmingOff, titleVisibility: .visible) {
            Button("Tắt và xoá mục đã đọc", role: .destructive) {
                LocalModule.disable(.health, in: context)
                dismiss()
            }
        } message: {
            Text("Not3 thôi đọc dữ liệu. Thu hồi hẳn quyền trong app Sức khỏe → Hồ sơ → Ứng dụng → Not3.")
        }
    }

    private func loadToday() async {
        today = await HealthService.shared.week([DayClock.startOfDay()]).first ?? HealthService.Day()
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await HealthService.shared.refresh(in: context)
            JournalService.updateToday(in: context)
            WidgetBridge.publishSoon()
        }
    }
}

// MARK: Gợi ý nhật ký

struct JournalSuggestionsSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var moments: [ExternalItem]
    @State private var isConfirmingOff = false

    init() {
        let raw = ExternalSource.journal.rawValue
        let weekAgo = DayClock.startOfDay(Date().addingTimeInterval(-6 * 86_400))
        _moments = Query(filter: #Predicate<ExternalItem> { $0.sourceRaw == raw && $0.occurredAt >= weekAgo },
                         sort: \.occurredAt, order: .reverse)
    }

    var body: some View {
        Form {
            Section {
                ModuleHeader(source: .journal, status: "Đang bật")
                MomentPickerButton()
            } footer: {
                Text("iPhone gợi ý các khoảnh khắc: bài tập, nơi đã đến, ảnh, bài hát, người bạn gặp. Not3 chỉ nhận khoảnh khắc bạn chọn, rồi ghi thành việc đã làm và vào Nhật ký. Nút này cũng có ở Hôm nay → Buổi sáng.")
            }

            Section("7 ngày qua") {
                if moments.isEmpty {
                    Text("Chưa có khoảnh khắc nào.").foregroundStyle(.secondary)
                }
                ForEach(moments) { moment in
                    LabeledContent(moment.title, value: "\(DayClock.dayMonth(moment.occurredAt)) \(DayClock.time(moment.occurredAt))")
                }
                .onDelete { offsets in
                    offsets.map { moments[$0] }.forEach(context.delete)
                    try? context.save()
                    JournalService.updateToday(in: context)
                }
            }

            Section {
                Button("Tắt Gợi ý nhật ký", role: .destructive) { isConfirmingOff = true }
            } footer: {
                Text("Mọi thứ chỉ lưu trên iPhone, không gửi lên server hay AI. Quản lý gợi ý trong Cài đặt → Quyền riêng tư & Bảo mật → Gợi ý nhật ký.")
            }
        }
        .navigationTitle("Gợi ý nhật ký")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Tắt Gợi ý nhật ký?", isPresented: $isConfirmingOff, titleVisibility: .visible) {
            Button("Tắt và xoá khoảnh khắc đã thêm", role: .destructive) {
                LocalModule.disable(.journal, in: context)
                dismiss()
            }
        }
    }
}

// MARK: Bộ lọc Focus

struct FocusFilterInfoView: View {
    @AppStorage(FocusFilterState.categoriesKey) private var categoriesRaw = ""
    @AppStorage(FocusFilterState.showUncategorizedKey) private var showUncategorized = true
    @Environment(\.openURL) private var openURL

    private var categories: [String] { FocusFilterState.decode(categoriesRaw) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Đang lọc", value: categories.isEmpty ? "Không" : categories.joined(separator: ", "))
                if !categories.isEmpty {
                    LabeledContent("Việc chưa có loại", value: showUncategorized ? "Hiện" : "Ẩn")
                }
            } footer: {
                Text("Khi một Focus có bộ lọc Not3 bật, Hôm nay và widget chỉ hiện các loại việc đã chọn. Tắt Focus là hiện lại tất cả.")
            }

            Section("Cách bật") {
                Label("Mở Cài đặt → Tập trung", systemImage: "1.circle")
                Label("Chọn một Focus, ví dụ Làm việc", systemImage: "2.circle")
                Label("Bộ lọc Focus → Thêm bộ lọc → Not3", systemImage: "3.circle")
                Label("Chọn loại việc, ví dụ Công việc", systemImage: "4.circle")
                Button("Mở Cài đặt") { openSystemSettings(openURL) }
            }
        }
        .navigationTitle("Bộ lọc Focus")
        .navigationBarTitleDisplayMode(.inline)
    }
}
