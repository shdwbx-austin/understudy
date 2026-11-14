import SwiftUI
import Cam4ProgCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("LTC input") {
                Picker("Audio device", selection: $model.settings.audioDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(model.audioDevices) { device in
                        Text("\(device.name) (\(device.channels) ch)").tag(Optional(device.uid))
                    }
                }
                Stepper("Channel \(model.settings.audioChannel + 1)", value: $model.settings.audioChannel, in: 0...63)
                Picker("Show timecode rate", selection: $model.settings.ltcRate) {
                    ForEach(FrameRate.allCases.filter { $0.nominal <= 30 }) { rate in
                        Text(rate.rawValue).tag(rate)
                    }
                }
                Button("Rescan devices") { model.refreshAudioDevices() }
            }

            Section("Recording") {
                Toggle("Use the decks’ own timecode-run trigger", isOn: $model.settings.nativeRecordTrigger)
                Text("On: each deck starts and stops itself on its LTC input (frame accurate). Off: cam4prog sends record/stop when code rolls.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Chase") {
                Stepper(String(format: "Pre-roll %.1f s", model.settings.chase.prerollSeconds),
                        value: $model.settings.chase.prerollSeconds, in: 0.5...5, step: 0.25)
                Stepper(String(format: "Cue settle %.2f s", model.settings.chase.cueSettleSeconds),
                        value: $model.settings.chase.cueSettleSeconds, in: 0.1...2, step: 0.05)
                Stepper(String(format: "Tolerance ±%.1f frames", model.settings.chase.toleranceFrames),
                        value: $model.settings.chase.toleranceFrames, in: 0.5...10, step: 0.5)
                Stepper("Re-lock after \(model.settings.chase.driftStrikes) bad readings",
                        value: $model.settings.chase.driftStrikes, in: 1...20)
                Toggle("Deck timecode counts at video rate (e.g. 0–59 at 59.94)", isOn: $model.settings.deckTimecodeAtVideoRate)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}
