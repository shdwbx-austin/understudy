import SwiftUI
import UnderstudyCore

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
            Section("Timecode input") {
                Picker("Show code", selection: $model.settings.showCodeSource) {
                    Text("LTC input").tag(ShowCodeSource.input)
                    Text("Song timeline").tag(ShowCodeSource.timeline)
                }
                .pickerStyle(.segmented)
                Text(model.settings.showCodeSource == .timeline
                     ? "Stop and Record take show code from the song timeline (⌘T), so takes log against it with no cable. Play to code still chases the LTC input."
                     : "Show code arrives on an audio input as LTC (e.g. from CuePoints or a timecode DA).")
                    .font(.caption).foregroundStyle(.secondary)
                LTCInputPicker(
                    title: "Show timecode",
                    detail: model.settings.separatePlaybackInput ? "Used in Stop and Record." : "Used in every mode.",
                    deviceUID: $model.settings.audioDeviceUID,
                    channel: $model.settings.audioChannel,
                    inUse: model.inputRole == .show
                )
                Toggle("Use a separate input for Play to code", isOn: $model.settings.separatePlaybackInput)
                if model.settings.separatePlaybackInput {
                    LTCInputPicker(
                        title: "Playback timecode",
                        detail: "Used in Play to code, e.g. a local review source. It must carry the same timecode as the show, so takes line up.",
                        deviceUID: $model.settings.playbackAudioDeviceUID,
                        channel: $model.settings.playbackAudioChannel,
                        inUse: model.inputRole == .playback
                    )
                }
                Picker("Show timecode rate", selection: rateChoice) {
                    Text("Auto-detect").tag("auto")
                    Divider()
                    ForEach(FrameRate.allCases.filter { $0.nominal <= 30 }) { rate in
                        Text(rate.rawValue).tag(rate.rawValue)
                    }
                }
                Text(model.settings.ltcRateAuto
                     ? "Understudy measures the incoming LTC (\(model.rateLabel.hasSuffix("DETECTING") ? "waiting for code" : "now " + model.ltcRate.rawValue)) and follows it, including drop-frame. Recording logs and playback wait the first couple of seconds of code until the rate is known. Each input is measured afresh when it's switched in."
                     : "Fixed rate. The header warns if incoming LTC doesn't match.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Rescan devices") { model.refreshAudioDevices() }
            }

            ConfidenceSettings(monitor: model.confidence)

            TimelineOutputSettings()
            ShowControlSettings()
            Section("Show machine") {
                Toggle("Keep this Mac awake while Understudy is open", isOn: $model.settings.keepAwake)
                ShowMachineAgent(machine: model.showMachine)
                Toggle("After a restart, go back to Record or Play", isOn: $model.settings.resumeLastMode)
                Text("For a dedicated Mac running rehearsals. Also set System Settings › Energy › “Start up automatically after a power failure”, automatic login, and Screen Sharing to watch it from your laptop.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Backup") {
                HStack {
                    Text(model.settings.backupFolder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen")
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Choose…") { model.chooseBackupFolder() }
                }
                Text("Takes are copied off the decks by FTP into dated folders here, one per deck. Choose a folder inside Dropbox and Dropbox syncs them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Recording") {
                Picker("Record", selection: $model.settings.recordMode) {
                    Text("Continuously, REC to STOP (recommended)").tag(RecordMode.continuous)
                    Text("Only while show timecode runs").tag(RecordMode.timecodeRun)
                }
                Text(model.settings.recordMode == .continuous
                     ? "Decks record from REC until STOP, stamped with their own clock. Understudy logs show code against each take, so LTC dropouts and jumps don't stop or break a recording."
                     : "Each deck records only while its LTC input runs and stamps clips with show code. If LTC drops, the deck stops recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Chase") {
                Toggle("Fast pickup", isOn: $model.settings.chase.fastStart)
                    .help("Decks go to the frame and play in one step, rolling about 0.1 s after code starts")
                if model.settings.chase.fastStart {
                    Stepper(String(format: "Deck goto time %.0f ms", model.settings.chase.gotoSeconds * 1000),
                            value: $model.settings.chase.gotoSeconds, in: 0...0.3, step: 0.005)
                    Text("When code starts or jumps, each deck goes to the matching frame and plays at once, so it rolls about 0.1 s later. Its start delay is the play offset in deck Setup (learned automatically, or set by Calibrate).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Stepper(String(format: "Pre-roll %.1f s", model.settings.chase.prerollSeconds),
                            value: $model.settings.chase.prerollSeconds, in: 1...5, step: 0.25)
                    Stepper(String(format: "Cue settle %.2f s", model.settings.chase.cueSettleSeconds),
                            value: $model.settings.chase.cueSettleSeconds, in: 0.1...2, step: 0.05)
                    Text("Decks are parked pre-roll ahead of code, given time to settle, then played: slower to pick up, for decks that locate slowly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
        .font(Theme.grotesk(13))
        .tint(Theme.paper)
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

/// One input channel: name, live level, and whether it carries the LTC in use.
private struct ChannelRow: View {
    let index: Int
    let name: String
    let db: Float
    let selected: Bool
    let ltc: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.paper : Theme.quiet)
                Text("Ch \(index + 1)").monospacedDigit().frame(width: 44, alignment: .leading)
                Text(name).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if ltc {
                    Text("LTC").font(.caption.bold()).foregroundStyle(Theme.live)
                }
                LevelMeter(db: db).frame(width: 150)
                Text(LevelMeter.label(db)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Start at login / relaunch after a crash, through the bundled launch agent.
private struct ShowMachineAgent: View {
    @ObservedObject var machine: ShowMachine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Start at login and relaunch if it quits unexpectedly", isOn: Binding(
                get: { machine.runsAtLogin },
                set: { machine.setRunAtLogin($0) }
            ))
            .disabled(!machine.canManageAgent)
            Text(machine.agentError ?? machine.agentStatusText)
                .font(.caption)
                .foregroundStyle(machine.agentError == nil ? Color.secondary : Theme.signal)
            if machine.agentStatus == .requiresApproval {
                Button("Open Login Items…") { machine.openLoginItemsSettings() }
            }
        }
        .onAppear { machine.refresh() }
    }
}

/// Where the timeline's song audio and generated LTC play.
private struct TimelineOutputSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var devices: [AudioInputDevice] = []
    @State private var ports: [DeckDiscovery.NetworkPort] = []

    var body: some View {
        Section("Dante out") {
            Toggle("Send to Dante (Dante Virtual Soundcard)", isOn: $model.settings.danteOut)
                .help("Song audio left and right on DVS channels 1–2 and timecode on 3, sample-locked on one device")
            if model.settings.danteOut {
                Picker("Network port", selection: $model.settings.danteInterface) {
                    Text("Any (as set in DVS)").tag(String?.none)
                    ForEach(ports) { Text($0.label).tag(Optional($0.bsd)) }
                }
                .help("The port your Dante network is on. Understudy warns when it loses its link; choose the same port in DVS's settings.")
                Text(model.danteStatus.message).font(.caption)
                    .foregroundStyle(model.danteStatus.isProblem ? Theme.amber : Theme.lock)
                Text("Dante Virtual Soundcard (from Audinate, licensed per Mac) sends the channels onto the network; DVS picks the network port itself. Set its channel count to 4 or more, start it, then subscribe receivers to this Mac's channels 1–3 in Dante Controller.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { ports = DeckDiscovery.networkPorts() }
        Section(model.danteStatus.isRouted ? "Timeline output (when Dante out is off)" : "Timeline output") {
            Picker("Song audio", selection: $model.settings.timelineOutputUID) {
                Text("System default").tag(String?.none)
                ForEach(devices) { Text("\($0.name) (\($0.channels) ch)").tag(Optional($0.uid)) }
            }
            Picker("Song audio channels", selection: $model.settings.timelineOutputChannel) {
                ForEach(Array(stride(from: 0, to: max(2, channels(model.settings.timelineOutputUID)), by: 2)), id: \.self) {
                    Text("\($0 + 1)–\($0 + 2)").tag($0)
                }
            }
            Picker("LTC out", selection: $model.settings.ltcOutputChannel) {
                Text("Off").tag(Int?.none)
                ForEach(0..<max(1, channels(model.settings.ltcOutputUID)), id: \.self) { Text("Channel \($0 + 1)").tag(Optional($0)) }
            }
            if model.settings.ltcOutputChannel != nil || model.settings.danteOut {
                Toggle("Use the track's own timecode", isOn: $model.settings.ltcOutUseTrackTimecode)
                    .help("When a song's audio has timecode on a channel, play that to LTC out instead of generated code")
            }
            if model.settings.ltcOutputChannel != nil {
                Picker("LTC device", selection: $model.settings.ltcOutputUID) {
                    Text("System default").tag(String?.none)
                    ForEach(devices) { Text("\($0.name) (\($0.channels) ch)").tag(Optional($0.uid)) }
                }
            }
            Text("In Timeline mode the song timeline is the clock. LTC out follows it at the show rate, so disguise and anything else can chase the reordered playlist.")
                .font(.caption).foregroundStyle(.secondary)
            if let problem = model.timeline.player.problem {
                Text(problem).font(.caption).foregroundStyle(Theme.amber)
            }
        }
        .onAppear { devices = AudioDeviceCatalog.outputDevices() }
    }

    private func channels(_ uid: String?) -> Int {
        guard let uid else { return 2 }
        return devices.first { $0.uid == uid }?.channels ?? 2
    }
}

/// One LTC source: device, then its channels (with live meters when it's the device open now).
private struct LTCInputPicker: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let detail: String
    @Binding var deviceUID: String?
    @Binding var channel: Int
    let inUse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.grotesk(14, .medium))
                if inUse {
                    Text("IN USE").font(Theme.mono(9, bold: true)).tracking(1.2).foregroundStyle(Theme.lock)
                }
                Spacer()
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Picker("Audio device", selection: $deviceUID) {
                Text("System default").tag(String?.none)
                ForEach(model.audioDevices) { device in
                    Text("\(device.name) (\(device.channels) ch)").tag(Optional(device.uid))
                }
            }
            let names = model.channelNames(forDeviceUID: deviceUID)
            let live = model.isOpen(deviceUID)
            if names.isEmpty {
                Text("No channels on this device.").foregroundStyle(.secondary)
            } else {
                Text(live ? "Channel — click to choose" : "Channel — click to choose (meters show for the device in use)")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(names.indices, id: \.self) { index in
                    LiveLevel(readout: model.readout, channel: index) { level in
                        ChannelRow(
                            index: index,
                            name: names[index],
                            db: live ? level : -60,
                            selected: index == channel,
                            ltc: inUse && index == channel && model.ltcInfo != "NO LTC"
                        ) { channel = index }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Confidence monitor: capture device, layout, quadrant per deck, sensitivity.
private struct ConfidenceSettings: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var monitor: ConfidenceMonitor

    var body: some View {
        Section("Confidence monitor") {
            Toggle("Show deck pictures from a capture device", isOn: $model.settings.confidenceEnabled)
            if model.settings.confidenceEnabled {
                Picker("Capture device", selection: $model.settings.confidenceDeviceID) {
                    Text("First available").tag(String?.none)
                    ForEach(monitor.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                Picker("Layout", selection: $model.settings.confidenceLayout) {
                    Text("Quad multiviewer (four decks)").tag(ConfidenceLayout.quad)
                    Text("One deck").tag(ConfidenceLayout.single)
                }
                if model.settings.confidenceLayout == .quad {
                    ForEach(0..<AppSettings.deckCount, id: \.self) { deck in
                        Picker("\(String(format: "%02d", deck + 1))  \(model.settings.decks[deck].name)",
                               selection: $model.settings.confidenceQuadrants[deck]) {
                            ForEach(0..<4, id: \.self) { q in
                                Text(ConfidenceLayout.quadrantNames[q]).tag(q)
                            }
                        }
                    }
                } else {
                    Picker("The image is", selection: $model.settings.confidenceSingleDeck) {
                        ForEach(0..<AppSettings.deckCount, id: \.self) { deck in
                            Text("\(String(format: "%02d", deck + 1))  \(model.settings.decks[deck].name)").tag(deck)
                        }
                    }
                }
                Stepper(String(format: "Flag black after %.0f s", model.settings.pictureCheck.blackSeconds),
                        value: $model.settings.pictureCheck.blackSeconds, in: 1...10, step: 1)
                Stepper(String(format: "Flag a still picture during playback after %.0f s", model.settings.pictureCheck.stillSeconds),
                        value: $model.settings.pictureCheck.stillSeconds, in: 2...20, step: 1)
                HStack {
                    Text(status).font(.caption).foregroundStyle(monitor.error == nil ? Color.secondary : Theme.signal)
                    Spacer()
                    Button("Rescan devices") { monitor.refreshDevices() }
                }
                Text("Feed a quad-split multiviewer of the four deck outputs into any capture device macOS sees as a camera (USB/UVC capture, ATEM Mini webcam out, Web Presenter). Pictures are checked a few times a second at low resolution.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var status: String {
        if let error = monitor.error { return error }
        if let name = monitor.deviceName { return "Watching \(name)." }
        return monitor.devices.isEmpty ? "No capture devices found." : "Not running."
    }
}

/// OSC control in, and where markers go: grandMA3 (over OSC) and disguise (over its session API).
private struct ShowControlSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var d3Tracks: [String] = []
    @State private var d3Problem: String?

    var body: some View {
        Section("Show control: OSC in") {
            Toggle("Accept OSC control", isOn: $model.settings.oscEnabled)
            if model.settings.oscEnabled {
                TextField("UDP port", value: $model.settings.oscPort, format: .number.grouping(.never))
                LabeledContent("Status") {
                    Text(model.oscStatus).foregroundStyle(model.osc.problem == nil ? Theme.lock : Theme.amber)
                }
                LabeledContent("Last received") { Text(model.lastOSC ?? "—").font(Theme.mono(11)).lineLimit(1) }
                Text("""
                /understudy/play · /pause · /toggle · /stop
                /understudy/song/next · /song/prev · /song <n>
                /understudy/marker (last type) · /marker/<1–7 or type> ["label"] · /marker "lx" "Drop"
                /understudy/marker/next · /marker/prev
                Buttons that send 1 on press and 0 on release act on press only.
                """)
                .font(Theme.mono(10)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        Section("Show control: grandMA3") {
            TextField("Console IP", text: $model.settings.ma3Host, prompt: Text("e.g. 192.168.1.50"))
            TextField("OSC port", value: $model.settings.ma3Port, format: .number.grouping(.never))
            TextField("OSC prefix", text: $model.settings.ma3Prefix, prompt: Text("none"))
            Stepper("Markers sequence \(model.settings.ma3Sequence)", value: $model.settings.ma3Sequence, in: 1...9999)
            Stepper("Markers timecode show \(model.settings.ma3Timecode)", value: $model.settings.ma3Timecode, in: 1...9999)
            Text("On the console: Menu › In & Out › OSC, add a line with Destination IP of this Mac, the port and prefix above, Mode UDP, and turn on Enable Input, Receive and Receive Command. Send to grandMA3 replaces the sequence and timecode show numbered here.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Show control: disguise") {
            TextField("Designer IP", text: $model.settings.d3Host, prompt: Text("e.g. 192.168.1.20 (port 80)"))
            HStack {
                TextField("Track", text: $model.settings.d3Track, prompt: Text("the selected track"))
                Menu("Tracks") {
                    if d3Tracks.isEmpty { Text(d3Problem ?? "Fetching…") }
                    ForEach(d3Tracks, id: \.self) { name in Button(name) { model.settings.d3Track = name } }
                }
                .fixedSize()
                .onTapGesture { fetchTracks() }
                Button("Fetch") { fetchTracks() }.disabled(model.settings.d3Host.isEmpty)
            }
            Picker("Write markers as", selection: $model.settings.d3Style) {
                ForEach(D3Push.Style.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("Track start (if it has no TC tags)", text: $model.settings.d3TrackStart)
            Text("Markers are placed on the track through its TC tags when it has them (so each song's markers land on that song), otherwise from the track start above. Designer needs its API reachable on port 80.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fetchTracks() {
        let host = model.settings.d3Host
        guard !host.isEmpty else { return }
        d3Problem = nil
        Task { @MainActor in
            do { d3Tracks = try await D3Client.tracks(host: host); if d3Tracks.isEmpty { d3Problem = "No tracks" } }
            catch { d3Tracks = []; d3Problem = error.localizedDescription }
        }
    }
}
