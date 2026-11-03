import SwiftUI

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Section {
                        Picker("Lưu thành", selection: $model.destination) {
                            Text("Việc").tag(ShareModel.Destination.task)
                            Text("Hộp chờ").tag(ShareModel.Destination.someday)
                            Text("Ghi chú").tag(ShareModel.Destination.note)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        TextField("Tiêu đề", text: $model.title, axis: .vertical)
                            .font(.headline)
                    } footer: {
                        Text(footer)
                    }

                    if model.destination == .note && !model.folders.isEmpty {
                        Section {
                            Picker("Thư mục", selection: $model.folderId) {
                                ForEach(model.folders) { folder in
                                    Text(folder.name).tag(Optional(folder.id))
                                }
                            }
                        }
                    }

                    if let url = model.url {
                        Section("Liên kết") {
                            Text(url.absoluteString).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .navigationTitle("Not3")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") { model.save() }
                        .disabled(model.isLoading || model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var footer: String {
        let photos = model.photos.isEmpty ? "" : " \(model.photos.count) ảnh chỉ được lưu khi chọn Ghi chú."
        switch model.destination {
        case .task: return "Thêm vào Hôm nay. Link PR / ticket sẽ tự liên kết với GitHub / Jira." + photos
        case .someday: return "Thêm vào Hộp chờ, chưa có ngày." + photos
        case .note: return model.photos.isEmpty ? "Lưu thành ghi chú." : "Lưu thành ghi chú kèm \(model.photos.count) ảnh."
        }
    }
}
