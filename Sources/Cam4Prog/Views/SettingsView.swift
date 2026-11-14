import SwiftUI
import Cam4ProgCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    /// "auto" or a FrameRate raw value.
    private var rateChoice: Binding<String> {
        Binding(
            get: { model.settings.ltcRateAuto ? "auto" : model.settings.ltcRate.rawValue },
            set: { choice in
                if choice == "auto" {
                    model.settings.ltcRateAuto = true
                } else if let rate = FrameRate(rawValue: choice) {
                    model.settings.ltcRateAuto = false
                    model.settings.ltcRate = rate
                }
            }
        )
    }

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
                Picker("Show timecode rate", selection: rateChoice) {
                    Text("Auto-detect").tag("auto")
                    Divider()
                    ForEach(FrameRate.allCases.filter { $0.nominal <= 30 }) { rate in
                        Text(rate.rawValue).tag(rate.rawValue)
                    }
                }
                Text(model.settings.ltcRateAuto
                     ? "cam4prog measures the incoming LTC (\(model.rateLabel.replacingOccurrences(of: "AUTO", with: "now").trimmingCharacters(in: .whitespaces))) and follows it, including drop-frame. Recording logs and playback wait the first couple of seconds of code until the rate is known."
                     : "Fixed rate. The header warns if incoming LTC doesn't match.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Rescan devices") { model.refreshAudioDevices() }
            }

            Section("Recording") {
                Picker("Record", selection: $model.settings.recordMode) {
                    Text("Continuously, REC to STOP (recommended)").tag(RecordMode.continuous)
                    Text("Only while show timecode runs").tag(RecordMode.timecodeRun)
                }
                Text(model.settings.recordMode == .continuous
                     ? "Decks record from REC until STOP, stamped with their own clock. cam4prog logs show code against each take, so LTC dropouts and jumps don't stop or break a recording."
                     : "Each deck records only while its LTC input runs and stamps clips with show code. If LTC drops, the deck stops recording.")
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
                Stepper(model.settings.freewheelSeconds > 0
                            ? String(format: "Coast through LTC dropouts for %.1f s", model.settings.freewheelSeconds)
                            : "Don't coast through LTC dropouts",
                        value: $model.settings.freewheelSeconds, in: 0...10, step: 0.5)
                Toggle("Deck timecode counts at video rate (e.g. 0–59 at 59.94)", isOn: $model.settings.deckTimecodeAtVideoRate)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}
