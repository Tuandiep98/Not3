import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share sheet → Not3. No SwiftData here: the choice is queued as a `WidgetAction` (photos as files
/// in the App Group) and the app creates the task / note on its next run.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel()
        model.onFinish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.onCancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "Not3Share", code: NSUserCancelledError))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let titles = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).compactMap { $0.attributedContentText?.string }
        Task { await model.load(providers, contentText: titles.first) }
    }
}

@MainActor
@Observable
final class ShareModel {
    enum Destination: Hashable { case task, someday, note }

    var title = ""
    var text = ""
    var url: URL?
    var photos: [String] = []
    var destination: Destination = .task
    var folderId: UUID?
    var isLoading = true

    var onFinish: () -> Void = {}
    var onCancel: () -> Void = {}

    let folders = WidgetSnapshot.load().folders.filter { $0.id != WidgetSnapshot.allNotesID }

    func load(_ providers: [NSItemProvider], contentText: String?) async {
        var texts: [String] = []
        if let contentText, !contentText.isEmpty { texts.append(contentText) }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), url == nil,
               let found = await Self.loadURL(provider), !found.isFileURL {
                url = found
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let data = await Self.loadData(provider, type: .image), let name = Self.savePhoto(data) {
                photos.append(name)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let found = await Self.loadText(provider) {
                if url == nil, let link = URL(string: found.trimmingCharacters(in: .whitespacesAndNewlines)), link.scheme?.hasPrefix("http") == true {
                    url = link
                } else {
                    texts.append(found)
                }
            }
        }
        text = texts.joined(separator: "\n")
        title = ShareParsing.title(text: text, url: url)
        // Photos only make sense in a note.
        if !photos.isEmpty && url == nil { destination = .note }
        folderId = folders.first { $0.name == "Ghi chú nhanh" }?.id ?? folders.first?.id
        isLoading = false
    }

    func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch destination {
        case .task, .someday:
            WidgetAction(kind: .addTask, title: trimmed, url: url?.absoluteString,
                         someday: destination == .someday, photos: nil).enqueue()
            removePhotos()
        case .note:
            let body = [text == trimmed ? nil : text, url?.absoluteString]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            WidgetAction(kind: .addNote, title: trimmed, body: body, url: url?.absoluteString,
                         folderId: folderId, photos: photos).enqueue()
        }
        onFinish()
    }

    func cancel() {
        removePhotos()
        onCancel()
    }

    private func removePhotos() {
        for name in photos {
            try? FileManager.default.removeItem(at: AppGroup.shareInboxDirectory.appending(path: name))
        }
        photos = []
    }

    // MARK: Item providers

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
        }
    }

    /// Raw image bytes into the App Group; the app downsizes them when it attaches them.
    private static func savePhoto(_ data: Data) -> String? {
        let dir = AppGroup.shareInboxDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).img"
        do {
            try data.write(to: dir.appending(path: name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }
}
