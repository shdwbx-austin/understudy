import SwiftUI
import UnderstudyCore

/// Settings › Network: which network port each kind of traffic uses.
struct NetworkSettings: View {
    @EnvironmentObject private var model: AppModel
    /// Every port macOS knows, plugged in or not (read when the tab opens).
    @State private var ports: [DeckDiscovery.NetworkPort] = []

    var body: some View {
        Section {
            Text("For a show Mac with several network ports (show network, Dante, internet, NDI). Automatic leaves it to macOS's routing, which sends everything for a network out of the port on that network, and the rest out of the top port in System Settings › Network. A chosen port is used while it has a link and an IPv4 address; until then the traffic follows the system's routing and the status here says so.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(NetworkTraffic.allCases) { traffic in
            Section(traffic.title) {
                NetworkPortPicker(traffic: traffic, ports: ports)
            }
        }
        .onAppear {
            ports = DeckDiscovery.networkPorts()
            model.watchNetworkPorts()
        }
    }
}

/// One kind of traffic: the port picker, where it goes now, and anything wrong.
private struct NetworkPortPicker: View {
    @EnvironmentObject private var model: AppModel
    let traffic: NetworkTraffic
    let ports: [DeckDiscovery.NetworkPort]

    var body: some View {
        let chosen = model.settings.interface(for: traffic)
        let states = model.portStates
        Picker("Network port", selection: Binding(get: { chosen }, set: { model.settings.setInterface($0, for: traffic) })) {
            Text("Automatic (system routing)").tag(String?.none)
            ForEach(choices(chosen)) { port in
                Text(label(port, states)).tag(Optional(port.bsd))
            }
        }
        Text(traffic.detail).font(.caption).foregroundStyle(.secondary)
        LabeledContent("Now") {
            Text(now(chosen, states)).font(Theme.mono(11))
                .foregroundStyle(PortRoute.resolve(chosen, ports: states).isProblem ? Theme.amber : Theme.lock)
        }
        ForEach(PortWarning.check(chosen, ports: states, targets: model.settings.targets(for: traffic)), id: \.self) { warning in
            Text(warning.text).font(.caption).foregroundStyle(Theme.amber)
        }
        if traffic == .ndi, let started = NDILibrary.startedWith, started.interface != chosen {
            Text("NDI started on \(started.interface ?? "Automatic"). Quit and reopen Understudy to use the new port.")
                .font(.caption).foregroundStyle(Theme.amber)
        }
    }

    /// The Mac's ports, plus a chosen one that isn't here now (so the choice still shows).
    private func choices(_ chosen: String?) -> [DeckDiscovery.NetworkPort] {
        var list = ports
        if let chosen, !list.contains(where: { $0.bsd == chosen }) {
            list.append(DeckDiscovery.NetworkPort(bsd: chosen, name: "\(chosen) (not on this Mac)"))
        }
        return list
    }

    /// "Thunderbolt Ethernet (en8) — 10.0.0.5/24".
    private func label(_ port: DeckDiscovery.NetworkPort, _ states: [NetworkPortState]) -> String {
        guard let state = states.first(where: { $0.bsd == port.bsd }) else { return port.label }
        return "\(port.label) — \(state.summary)"
    }

    private func now(_ chosen: String?, _ states: [NetworkPortState]) -> String {
        switch traffic {
        case .ndi:
            // NDI picks its adapters once, when it starts.
            if let started = NDILibrary.startedWith { return started.route.summary + " (since NDI started)" }
            return PortRoute.resolve(chosen, ports: states).summary + " (NDI hasn't started yet)"
        case .oscIn:
            return model.oscStatus
        case .decks:
            let routes = model.decks.filter(\.isConnected).map(\.route)
            let current = PortRoute.resolve(chosen, ports: states)
            if let other = routes.first(where: { $0 != current }) {
                return current.summary + " (a deck still connected via \(other.summary): it moves when it next reconnects)"
            }
            return current.summary
        case .ma3, .d3:
            return PortRoute.resolve(chosen, ports: states).summary
        }
    }
}
