import SwiftUI

/// Small sheet: speak, see the live transcript, tap "Xong" to turn it into chips/text.
struct VoiceCaptureSheet: View {
    var prompt = "Nói việc bạn muốn làm, ví dụ \"lúc 3 giờ học tiếng Anh 25 phút\""
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var voice = VoiceInput()

    var body: some View {
        VStack(spacing: 20) {
            Text(voice.transcript.isEmpty ? prompt : voice.transcript)
                .font(voice.transcript.isEmpty ? .callout : .title3.weight(.semibold))
                .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 80)
                .animation(.default, value: voice.transcript)

            if let error = voice.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            Button {
                if voice.isRecording { voice.stop() } else { Task { await voice.start() } }
            } label: {
                Image(systemName: voice.isRecording ? "stop.fill" : "mic.fill")
                    .font(.title2)
                    .frame(width: 64, height: 64)
                    .symbolEffect(.pulse, isActive: voice.isRecording)
            }
            .appCircleButton()
            .accessibilityLabel(voice.isRecording ? "Dừng ghi âm" : "Bắt đầu ghi âm")

            HStack(spacing: 12) {
                Button("Huỷ") {
                    voice.stop()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    voice.stop()
                    let text = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { onDone(text) }
                    dismiss()
                } label: {
                    Text("Xong").frame(maxWidth: .infinity)
                }
                .appPrimaryButton()
                .disabled(voice.transcript.isEmpty)
            }
        }
        .padding(24)
        .presentationDetents([.height(340)])
        .task { await voice.start() }
        .onDisappear { voice.stop() }
    }
}
