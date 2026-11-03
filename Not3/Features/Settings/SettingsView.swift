import AuthenticationServices
import SwiftData
import SwiftUI

/// "Cài đặt & kết nối" (artboard `Settings`).
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(SupabaseService.self) private var supabase
    @Environment(CalendarService.self) private var calendar
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @AppStorage(SettingsKey.checkInHour) private var checkInHour = 12
    @AppStorage(SettingsKey.checkInMinute) private var checkInMinute = 0
    @AppStorage(SettingsKey.localFallback) private var localFallback = true
    @AppStorage(SettingsKey.eveningCheckIn) private var eveningCheckIn = true
    @AppStorage(SettingsKey.iCloudSync) private var iCloudSync = true
    @AppStorage(SettingsKey.syncNoteContent) private var syncNoteContent = true
    @AppStorage(SettingsKey.aiReadsIntegrations) private var aiReadsIntegrations = true
    @AppStorage(SettingsKey.appLock) private var appLock = false
    @AppStorage(SettingsKey.appLockDelay) private var appLockDelay = 60
    @State private var exportURL: URL?
    @State private var isExporting = false

    @State private var nonce = SupabaseService.makeNonce()
    @State private var errorMessage: String?
    @State private var isConfirmingDelete = false
    @State private var busyProvider: ExternalSource?
    @State private var confirmDisconnect: ExternalSource?
    @State private var isSyncingIntegrations = false
    @State private var iCloudChanged = false
    @State private var debugDetail = ProcessInfo.processInfo.arguments.contains("-openGitHubSettings")

    var body: some View {
        Form {
            Section {
                DatePicker("Giờ check-in", selection: checkInTime, displayedComponents: .hourAndMinute)
                LabeledContent("Tổng kết tuần", value: "CN 20:00")
                Toggle("Hỏi lại buổi tối", isOn: $eveningCheckIn)
                Toggle("Thông báo dự phòng trên máy", isOn: $localFallback)
                NavigationLink("Việc lặp lại") { RecurringTasksView() }
            } header: {
                Text("Check-in")
            } footer: {
                Text("Buổi tối hỏi \"Đã làm chưa?\" cho việc đã lên kế hoạch. Thông báo dự phòng dùng khi push \(String(format: "%02d:%02d", checkInHour, checkInMinute)) từ server không tới được máy.")
            }

            Section {
                calendarRow
                integrationRow(.github, title: "GitHub")
                integrationRow(.jira, title: "Jira Cloud")
                if !supabase.integrations.isEmpty {
                    Button {
                        Task {
                            isSyncingIntegrations = true
                            await supabase.syncIntegrationsNow(context)
                            isSyncingIntegrations = false
                        }
                    } label: {
                        HStack {
                            Label("Đồng bộ ngay", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if isSyncingIntegrations { ProgressView() }
                        }
                    }
                    .disabled(isSyncingIntegrations)
                }
            } header: {
                Text("Dữ liệu đã kết nối")
            } footer: {
                Text("Chỉ xin quyền đọc. Dữ liệu được kéo về 30 phút trước giờ check-in. Ngắt kết nối sẽ xoá token và dữ liệu của nguồn đó. Bitbucket sẽ có ở bản sau.")
            }

            Section {
                Toggle("Đồng bộ iCloud", isOn: $iCloudSync)
                    .onChange(of: iCloudSync) { iCloudChanged = true }
                if iCloudChanged {
                    Text("Có hiệu lực khi mở lại app.").font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Đồng bộ nội dung note lên server", isOn: $syncNoteContent)
                Toggle("Cho AI đọc dữ liệu tích hợp", isOn: $aiReadsIntegrations)
                if supabase.isSignedIn {
                    LabeledContent("Đồng bộ lần cuối") {
                        if supabase.isSyncing {
                            ProgressView()
                        } else {
                            Text(supabase.lastSyncAt.map(DayClock.time) ?? "Chưa có")
                        }
                    }
                }
            } header: {
                Text("Đồng bộ & AI")
            } footer: {
                Text("Nội dung note được đồng bộ lên server để AI gắn chip và viết tổng kết tuần. Tắt đi thì note chỉ lưu trên iCloud.")
            }

            privacySection

            accountSection
        }
        .navigationTitle("Cài đặt")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Xong", systemImage: "checkmark") { dismiss() }
            }
        }
        .onChange(of: checkInHour) { settingsChanged() }
        .onChange(of: checkInMinute) { settingsChanged() }
        .onChange(of: localFallback) { settingsChanged() }
        .onChange(of: eveningCheckIn) { settingsChanged() }
        .onChange(of: syncNoteContent) { settingsChanged() }
        .onChange(of: aiReadsIntegrations) { settingsChanged() }
        .alert("Lỗi", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await supabase.refreshIntegrations() }
        #if DEBUG
        .navigationDestination(isPresented: $debugDetail) { IntegrationDetailView(source: .github) }
        #endif
        .confirmationDialog(
            "Ngắt kết nối \(confirmDisconnect == .github ? "GitHub" : "Jira")?",
            isPresented: Binding(get: { confirmDisconnect != nil }, set: { if !$0 { confirmDisconnect = nil } }),
            titleVisibility: .visible
        ) {
            Button("Ngắt và xoá dữ liệu đã kéo về", role: .destructive) {
                guard let provider = confirmDisconnect else { return }
                busyProvider = provider
                Task {
                    defer { busyProvider = nil }
                    do {
                        try await supabase.disconnect(provider: provider, context: context)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("Token bị xoá khỏi server, các mục đã đồng bộ từ nguồn này cũng bị xoá.")
        }
        .confirmationDialog("Xoá tài khoản?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Xoá tài khoản và dữ liệu", role: .destructive, action: deleteAccount)
        } message: {
            Text("Toàn bộ task, check-in và dữ liệu đồng bộ trên server sẽ bị xoá. Không thể hoàn tác.")
        }
    }

    @ViewBuilder
    private var privacySection: some View {
        Section {
            Toggle("Khoá bằng \(AppLock.biometryName)", isOn: Binding(
                get: { appLock },
                set: { wanted in Task { _ = await AppLock.shared.setEnabled(wanted) } }
            ))
            if appLock {
                Picker("Khoá", selection: $appLockDelay) {
                    ForEach(AppLock.Delay.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            NavigationLink("Hiển thị khi khoá") { LockScreenPrivacyView() }
            Button {
                Task { await export() }
            } label: {
                HStack {
                    Label("Xuất dữ liệu", systemImage: "square.and.arrow.up.on.square")
                    Spacer()
                    if isExporting { ProgressView() }
                }
            }
            .disabled(isExporting)
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Lưu hoặc gửi \(exportURL.lastPathComponent)", systemImage: "doc.zipper")
                }
            }
        } header: {
            Text("Bảo mật & dữ liệu")
        } footer: {
            Text("\"Hiển thị khi khoá\" chọn widget, Spotlight và Siri hiện gì khi iPhone khoá (bật khoá thì mặc định ẩn nội dung). Bản xuất là tệp .zip gồm ghi chú Markdown kèm ảnh, việc (Markdown + JSON), check-in và việc lặp lại.")
        }
    }

    private func export() async {
        isExporting = true
        defer { isExporting = false }
        // Let the spinner draw before the (synchronous) export runs.
        await Task.yield()
        do {
            exportURL = try ExportService.export(in: context)
        } catch {
            errorMessage = "Không xuất được dữ liệu: \(error.localizedDescription)"
        }
    }

    private var accountSection: some View {
        Section {
            if !supabase.isConfigured {
                Text("Chưa cấu hình Supabase — app đang chạy chỉ trên máy.")
                    .foregroundStyle(.secondary)
            } else if supabase.isSignedIn {
                LabeledContent("Đăng nhập bằng Apple", value: "Đã đăng nhập")
                Button("Đăng xuất") { Task { await supabase.signOut() } }
                Button("Xoá tài khoản", role: .destructive) { isConfirmingDelete = true }
            } else {
                SignInWithAppleButton(.signIn) { request in
                    nonce = SupabaseService.makeNonce()
                    request.requestedScopes = [.email]
                    request.nonce = nonce.hashed
                } onCompletion: { result in
                    handleSignIn(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .listRowInsets(EdgeInsets())
            }
        } header: {
            Text("Tài khoản")
        }
    }

    // MARK: Connected data

    private var calendarRow: some View {
        let status = calendar.status
        return ConnectionRow(
            source: .calendar,
            title: "Lịch iOS",
            subtitle: status == .fullAccess ? "Đọc lịch hôm nay · ghi kế hoạch chiều" : "Chưa cấp quyền"
        ) {
            switch status {
            case .fullAccess:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Đã cấp quyền")
            case .denied, .restricted, .writeOnly:
                rowButton("Mở Cài đặt") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            default:
                rowButton("Cấp quyền") { Task { await calendar.requestAccess() } }
            }
        }
    }

    @ViewBuilder
    private func integrationRow(_ provider: ExternalSource, title: String) -> some View {
        let record = supabase.integrations.first { $0.provider == provider.rawValue }
        let serverReady = provider == .github ? supabase.providersReady.github : supabase.providersReady.jira
        if let record {
            // Connected: subtitle = account (or a one-line error); trailing = last sync time.
            NavigationLink { IntegrationDetailView(source: provider) } label: {
                ConnectionRow(
                    source: provider,
                    title: title,
                    subtitle: record.lastError.map(Self.shortError) ?? (record.accountName ?? "Đã kết nối"),
                    subtitleIsWarning: record.lastError != nil
                ) {
                    if record.lastError == nil, let last = record.lastSyncedAt {
                        Text(DayClock.time(last))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .accessibilityLabel("Đồng bộ lúc \(DayClock.time(last))")
                    }
                }
            }
        } else {
            ConnectionRow(
                source: provider,
                title: title,
                subtitle: !supabase.isSignedIn ? "Đăng nhập để kết nối"
                    : !serverReady ? "Chưa cấu hình trên server" : "Chưa kết nối"
            ) {
                if busyProvider == provider {
                    ProgressView()
                } else if supabase.isSignedIn && serverReady {
                    rowButton("Kết nối") { connect(provider) }
                }
            }
        }
    }

    /// Small capsule button used as a row accessory.
    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
    }

    /// "GitHub 422: Validation Failed: …" → "Lỗi 422 · Validation Failed" (full text in the detail screen).
    static func shortError(_ message: String) -> String {
        if message.hasPrefix("Cần đăng nhập lại") { return "Cần đăng nhập lại" }
        let trimmed = message.replacingOccurrences(of: #"^(GitHub|Jira) (\d{3}):\s*"#, with: "Lỗi $2 · ", options: .regularExpression)
        return trimmed.components(separatedBy: ":").first ?? trimmed
    }

    private func integrationStatus(_ record: IntegrationRecord) -> String {
        if let error = record.lastError { return error }
        let account = record.accountName.map { "\($0) · " } ?? ""
        guard let last = record.lastSyncedAt else { return account + "Đã kết nối" }
        return account + "Đồng bộ lần cuối \(DayClock.time(last))"
    }

    private func connect(_ provider: ExternalSource) {
        busyProvider = provider
        Task {
            defer { busyProvider = nil }
            do {
                let url = try await supabase.connectURL(provider: provider)
                let callback = try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: "not3")
                let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let status = items.first { $0.name == "status" }?.value
                if status == "error" {
                    errorMessage = items.first { $0.name == "message" }?.value ?? "Kết nối không thành công."
                }
                await supabase.refreshIntegrations()
                await supabase.pullExternalItems(context)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // User closed the sheet.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var checkInTime: Binding<Date> {
        Binding {
            DayClock.at(hour: checkInHour, minute: checkInMinute)
        } set: { date in
            let comps = DayClock.calendar.dateComponents([.hour, .minute], from: date)
            checkInHour = comps.hour ?? 12
            checkInMinute = comps.minute ?? 0
        }
    }

    private func settingsChanged() {
        Task {
            await NotificationService.rescheduleCheckIns(in: context, serverPushActive: supabase.hasServerPush)
            await supabase.upsertProfile()
        }
    }

    private func handleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Không đọc được thông tin đăng nhập Apple."
                return
            }
            let raw = nonce.raw
            Task {
                do {
                    try await supabase.signInWithApple(idToken: token, rawNonce: raw)
                    await supabase.syncPending(context)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteAccount() {
        Task {
            do {
                try await supabase.deleteAccount()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
