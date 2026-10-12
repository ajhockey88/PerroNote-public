import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct PerroNoteWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        if #available(iOS 18.0, *) {
            RecordControl()
        }
    }
}

/// A Control Center (and Lock Screen) button that opens PerroNote and starts recording.
@available(iOS 18.0, *)
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ajhockey88.perronote.record") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Record Meeting", systemImage: "mic.fill")
            }
        }
        .displayName("Record Meeting")
        .description("Start recording a meeting in PerroNote.")
    }
}

/// The lock screen card and Dynamic Island shown while a meeting is being recorded.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            LockScreenRecording(title: context.attributes.title, state: context.state)
                .activityBackgroundTint(Color(hex: 0x1A1410))
                .activitySystemActionForegroundColor(Color(hex: 0xFFD9A0))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "recordingtape")
                        .font(.title2)
                        .foregroundColor(Color(hex: 0xFF7A45))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingTimer(state: context.state)
                        .font(.system(.title3, design: .monospaced))
                        .foregroundColor(Color(hex: 0xFFD9A0))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.custom(CassetteView.markerFont, size: 15))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.isPaused ? "paused" : "recording...")
                        .font(.custom(CassetteView.markerFont, size: 15))
                        .foregroundColor(Color(hex: 0x7F92FF))
                }
            } compactLeading: {
                Image(systemName: "recordingtape")
                    .foregroundColor(Color(hex: 0xFF7A45))
            } compactTrailing: {
                RecordingTimer(state: context.state)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 52)
            } minimal: {
                Image(systemName: "recordingtape")
                    .foregroundColor(Color(hex: 0xFF7A45))
            }
        }
    }
}

/// A timer that keeps counting by itself, and holds still while paused.
struct RecordingTimer: View {
    let state: RecordingAttributes.ContentState

    var body: some View {
        Text(timerInterval: state.timerStart...state.timerStart.addingTimeInterval(60 * 60 * 24),
             pauseTime: state.pausedAt,
             countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

struct LockScreenRecording: View {
    let title: String
    let state: RecordingAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            CassetteView(label: title, width: 120, reelAngle: .degrees(20))
            VStack(alignment: .leading, spacing: 6) {
                RecordingTimer(state: state)
                    .font(.system(size: 30, design: .monospaced))
                    .foregroundColor(Color(hex: 0xFFD9A0))
                Text(state.isPaused ? "paused" : "recording...")
                    .font(.custom(CassetteView.markerFont, size: 18))
                    .foregroundColor(Color(hex: 0x7F92FF))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
