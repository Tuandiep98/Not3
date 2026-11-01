@preconcurrency import AVFoundation
import Observation
@preconcurrency import Speech

/// Live Vietnamese speech-to-text (fallback input — "chạm trước, gõ sau").
@MainActor
@Observable
final class VoiceInput {
    private(set) var transcript = ""
    private(set) var isRecording = false
    private(set) var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "vi-VN"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil
        transcript = ""
        guard await Self.authorize() else {
            errorMessage = "Cần quyền Micro và Nhận dạng giọng nói trong Cài đặt."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Nhận dạng tiếng Việt chưa sẵn sàng trên máy này."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tapBlock(request))
            engine.prepare()
            try engine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] text, isFinal in
                guard let self else { return }
                if let text { self.transcript = text }
                if isFinal { self.stop() }
            })
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Closures below run on audio / recognition threads, so they are built outside the main actor.

    nonisolated private static func tapBlock(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func resultHandler(
        _ onUpdate: @escaping @MainActor @Sendable (String?, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in onUpdate(text, isFinal) }
        }
    }

    nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
