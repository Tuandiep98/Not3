import SwiftData
import SwiftUI
import UIKit

/// Photo grid under a note's text; tap opens the photo full screen.
struct NoteAttachmentsGrid: View {
    let note: Note

    @Environment(\.modelContext) private var context
    @State private var viewing: NoteAttachment?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 6)]

    var body: some View {
        let attachments = note.sortedAttachments
        if !attachments.isEmpty {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(attachments) { attachment in
                    Button { viewing = attachment } label: {
                        Thumbnail(attachment: attachment)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ảnh")
                    .contextMenu {
                        Button("Xoá ảnh", systemImage: "trash", role: .destructive) { delete(attachment) }
                    }
                }
            }
            .padding(.top, 6)
            .fullScreenCover(item: $viewing) { attachment in
                AttachmentViewer(attachment: attachment) { delete(attachment) }
            }
        }
    }

    private func delete(_ attachment: NoteAttachment) {
        viewing = nil
        context.delete(attachment)
        note.updatedAt = Date()
    }
}

private struct Thumbnail: View {
    let attachment: NoteAttachment

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let data = attachment.thumbnail ?? attachment.data, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .contentShape(.rect)
    }
}

private struct AttachmentViewer: View {
    let attachment: NoteAttachment
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let data = attachment.data, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                } else {
                    ContentUnavailableView("Ảnh chưa tải xong từ iCloud", systemImage: "icloud.and.arrow.down")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng", systemImage: "xmark") { dismiss() }
                }
                if let data = attachment.data, let image = UIImage(data: data) {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Ảnh", image: Image(uiImage: image))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Chia sẻ")
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Xoá", systemImage: "trash", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

/// Camera capture (PhotosPicker covers the library).
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
