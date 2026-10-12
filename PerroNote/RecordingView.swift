import SwiftUI

struct RecordingView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var recorder = AudioRecorder()
    @State private var errorText: String?
    @State private var started = false
    @State private var title = RecordingView.defaultTitle()

    /// The name the meeting gets until the notes give it a better one.
    static func defaultTitle() -> String {
        "Meeting " + Date().roundedToQuarterHour().formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            TimelineView(.animation(minimumInterval: nil,
                                    paused: recorder.isPaused || !recorder.isRecording || reduceMotion)) { context in
                let turn = (context.date.timeIntervalSinceReferenceDate * 120).truncatingRemainder(dividingBy: 360)
                CassetteView(label: title, width: 220, reelAngle: .degrees(turn))
            }

            Text(formatDuration(recorder.elapsed))
                .font(.system(size: 38, design: .monospaced))
                .foregroundColor(Color(hex: 0xFFD9A0))
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Color(hex: 0x1A1410), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0x3B2A20), lineWidth: 2))

            Text(statusText)
                .font(.custom(CassetteView.markerFont, size: 20))
                .foregroundColor(.accentColor)

            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.footnote)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            Spacer()

            HStack(spacing: 24) {
                Button(role: .cancel) { cancel() } label: {
                    Text("Discard").frame(width: 80)
                }
                .buttonStyle(.bordered)

                Button { recorder.isPaused ? recorder.resume() : recorder.pause() } label: {
                    Image(systemName: recorder.isPaused ? "mic.fill" : "pause.fill")
                        .font(.title2).frame(width: 48, height: 48)
                }
                .buttonStyle(.bordered).clipShape(Circle())
                .disabled(!recorder.isRecording)

                Button { finish() } label: {
                    Text("Done").frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!recorder.isRecording)
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperScreen()
        .task {
            guard !started else { return }
            started = true
            do {
                try await recorder.start()
                RecordingActivity.shared.start(title: title)
            } catch {
                errorText = error.localizedDescription
            }
        }
        .onChange(of: recorder.isPaused) { paused in
            RecordingActivity.shared.setPaused(paused, elapsed: recorder.elapsed)
        }
        .interactiveDismissDisabled()
    }

    private var statusText: String {
        if recorder.isPaused { return "paused" }
        return recorder.isRecording ? "recording..." : "starting..."
    }

    private func finish() {
        RecordingActivity.shared.end()
        guard let result = recorder.stop() else { dismiss(); return }
        let id = store.add(fileName: result.fileName, duration: result.duration,
                           date: result.startedAt.roundedToQuarterHour())
        dismiss()
        Task { await store.process(id) }
    }

    private func cancel() {
        RecordingActivity.shared.end()
        if let result = recorder.stop() {
            try? FileManager.default.removeItem(at: MeetingStore.audioURL(for: result.fileName))
        }
        dismiss()
    }
}
