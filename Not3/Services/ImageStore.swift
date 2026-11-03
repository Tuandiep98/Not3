import SwiftData
import UIKit

/// Photos in notes: downscaled JPEG + a small thumbnail, so iCloud sync stays light.
enum ImageStore {
    static let maxSide: CGFloat = 2048
    static let thumbnailSide: CGFloat = 400

    struct Prepared: Sendable {
        let data: Data
        let thumbnail: Data?
    }

    static func prepare(_ data: Data) -> Prepared? {
        UIImage(data: data).flatMap(prepare)
    }

    static func prepare(_ image: UIImage) -> Prepared? {
        guard let data = resized(image, maxSide: maxSide).jpegData(compressionQuality: 0.8) else { return nil }
        return Prepared(data: data, thumbnail: resized(image, maxSide: thumbnailSide).jpegData(compressionQuality: 0.7))
    }

    /// Never upscales. Scale 1 so the pixel size is exactly the target.
    static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return image }
        let factor = min(1, maxSide / longest)
        let target = CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Appends photos to the end of a note.
    @MainActor
    static func attach(_ images: [Prepared], to note: Note, in context: ModelContext) {
        var order = (note.sortedAttachments.last?.order ?? -1) + 1
        for image in images {
            let attachment = NoteAttachment(data: image.data, thumbnail: image.thumbnail, order: order)
            attachment.note = note
            context.insert(attachment)
            order += 1
        }
        note.updatedAt = Date()
    }
}
