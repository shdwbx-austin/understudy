// Network harness: checks that each protocol's traffic leaves through the chosen network port.
// Runs only against this Mac (localhost listeners and 10.255.255.x, which nothing answers), with a
// temp UNDERSTUDY_STORE. Run it with scripts/network-harness.sh.
import CNDI
import Darwin
import Foundation
import Network
import UnderstudyCore

setvbuf(stdout, nil, _IOLBF, 0)

guard let store = ProcessInfo.processInfo.environment["UNDERSTUDY_STORE"], !store.isEmpty,
      store.hasPrefix(NSTemporaryDirectory()) || store.hasPrefix("/tmp") || store.hasPrefix("/private/") else {
    print("Set UNDERSTUDY_STORE to a temp folder first."); exit(2)
}

// MARK: - NDI child mode: start NDI on one port and advertise a source for the parent to find.

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "ndi-send" {
    let bsd = CommandLine.arguments[2]
    let route = NDILibrary.prepareAdapters(bsd)
    print("child route \(route.summary) NDI_CONFIG_DIR=\(ProcessInfo.processInfo.environment["NDI_CONFIG_DIR"] ?? "-")")
    guard NDILibrary.shared.isAvailable, let sender = NDISender(name: "NIC Harness \(bsd)") else { print("child: no NDI"); exit(3) }
    print("child sending \(sender.name)")
    sleep(UInt32(CommandLine.arguments.count >= 4 ? Int(CommandLine.arguments[3]) ?? 8 : 8))
    exit(0)
}

// MARK: - Bookkeeping

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failed += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(detail().isEmpty ? "" : ": \(detail())")")
}
func note(_ s: String) { print("  · \(s)") }

/// Bytes sent by an interface so far (getifaddrs' AF_LINK if_data; 32-bit, so compare deltas mod 2^32).
func outBytes(_ bsd: String) -> UInt32 {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return 0 }
    defer { freeifaddrs(list) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = ptr.pointee
        guard String(cString: ifa.ifa_name) == bsd, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
              let data = ifa.ifa_data else { continue }
        return data.assumingMemoryBound(to: if_data.self).pointee.ifi_obytes
    }
    return 0
}

/// A UDP socket on 127.0.0.1 (or any address) that counts what arrives.
final class UDPCounter: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    init(port: UInt16, address: String = "127.0.0.1") {
        self.port = port
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        sin.sin_addr.s_addr = inet_addr(address)
        let r = withUnsafePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        precondition(r == 0, "bind \(address):\(port) failed: \(errno)")
    }
    /// Datagrams received within `seconds`.
    func drain(for seconds: Double) -> Int {
        var n = 0
        var buf = [UInt8](repeating: 0, count: 65_536)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if recv(fd, &buf, buf.count, 0) > 0 { n += 1 }
        }
        return n
    }
    deinit { close(fd) }
}

/// Sends a datagram from a plain socket (the harness's own, unpinned).
func sendUDP(_ data: Data, to host: String, port: UInt16) {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    defer { close(fd) }
    var sin = sockaddr_in()
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = port.bigEndian
    sin.sin_addr.s_addr = inet_addr(host)
    _ = data.withUnsafeBytes { raw in
        withUnsafePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }
    }
}

// MARK: - Stand-ins: a HyperDeck on 127.0.0.1:9993 and Designer's API on 127.0.0.1

/// Accepts TCP on 127.0.0.1:port and answers with `respond` (per connection).
final class FakeTCPServer: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var _accepted = 0
    var accepted: Int { lock.withLock { _accepted } }

    init(port: UInt16, onConnection: @escaping @Sendable (NWConnection) -> Void) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] c in
            self?.lock.withLock { self?._accepted += 1 }
            c.start(queue: .global())
            onConnection(c)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() }; if case .failed = $0 { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 3)
    }
    deinit { listener.cancel() }
}

func fakeHyperDeck() throws -> FakeTCPServer {
    try FakeTCPServer(port: 9993) { c in
        c.send(content: Data("500 connection info:\r\nprotocol version: 1.11\r\nmodel: HyperDeck Stand-in\r\n\r\n".utf8), completion: .idempotent)
        @Sendable func loop() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
                if let data, !data.isEmpty {
                    let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").filter { !$0.isEmpty }
                    for _ in lines { c.send(content: Data("200 ok\r\n".utf8), completion: .idempotent) }
                }
                if done || error != nil { c.cancel() } else { loop() }
            }
        }
        loop()
    }
}

func fakeDesigner(port: UInt16) throws -> FakeTCPServer {
    try FakeTCPServer(port: port) { c in
        let buffer = LockedData()
        @Sendable func loop() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, error in
                if let data { buffer.append(data) }
                let text = String(decoding: buffer.value, as: UTF8.self)
                if let headEnd = text.range(of: "\r\n\r\n") {
                    let head = text[..<headEnd.lowerBound]
                    let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                    if text.utf8.count - text.distance(from: text.startIndex, to: headEnd.upperBound) >= length {
                        let reply: String
                        if head.hasPrefix("GET /api/session/transport/tracks") {
                            // Chunked, as some servers answer.
                            let body = #"{"result":[{"name":"Track 1"},{"name":"Song 2"}]}"#
                            let half = body.index(body.startIndex, offsetBy: 20)
                            let a = String(body[..<half]), b = String(body[half...])
                            reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
                                + String(a.utf8.count, radix: 16) + "\r\n" + a + "\r\n" + String(b.utf8.count, radix: 16) + "\r\n" + b + "\r\n0\r\n\r\n"
                        } else if head.hasPrefix("POST /api/session/python/execute") {
                            let body = #"{"status":{"code":0},"returnValue":"{\"placed\":3,\"track\":\"Track 1\"}"}"#
                            reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
                        } else {
                            reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                        }
                        c.send(content: Data(reply.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
                        return
                    }
                }
                if done || error != nil { c.cancel() } else { loop() }
            }
        }
        loop()
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var value: Data { lock.withLock { data } }
}

// MARK: - 1. Ports and routes

print("== Ports on this Mac")
let states = NetworkPorts.states()
for s in states where !s.addresses.isEmpty { note("\(s.label): \(s.summary)") }
guard let en0 = states.first(where: { $0.bsd == "en0" }), let en0IP = en0.bindAddress?.dottedAddress else {
    print("This harness needs en0 with an IPv4 address."); exit(2)
}
check("lo0 resolves to 127.0.0.1", NetworkPorts.route("lo0") == .pinned(bsd: "lo0", address: "127.0.0.1"))
check("en0 resolves to its address", NetworkPorts.route("en0") == .pinned(bsd: "en0", address: en0IP), NetworkPorts.route("en0").summary)
check("a missing port falls back", NetworkPorts.route("en99") == .fallback(bsd: "en99", problem: .missing))
check("no choice is automatic", NetworkPorts.route(nil) == .automatic)
check("NWInterface for lo0 and en0", NetworkPorts.nwInterface("lo0")?.type == .loopback && NetworkPorts.nwInterface("en0") != nil)
check("no NWInterface for a missing port", NetworkPorts.nwInterface("en99") == nil)
check("warning: deck off en0's subnet", PortWarning.check("en0", ports: states, targets: ["10.255.255.7"]).count == 1,
      PortWarning.check("en0", ports: states, targets: ["10.255.255.7"]).first?.text ?? "")
check("no warning for a target on lo0's subnet", PortWarning.check("lo0", ports: states, targets: ["127.0.0.9"]).isEmpty)

// MARK: - 2. OSC out (grandMA3)

print("== OSC out (grandMA3 sender)")
let oscSink = UDPCounter(port: 19101)
func oscSend(_ interface: String?, to host: String, port: Int, count: Int = 1, padding: Int = 0) async -> (route: PortRoute, errors: Int) {
    guard let sender = OSCSender(host: host, port: port, interface: interface) else { return (.automatic, count) }
    let arg = String(repeating: "x", count: padding)
    var errors = 0
    for i in 0..<count {
        do {
            try await sender.send(OSCMessage("/gma3/cmd", [.string("Go+ \(i) \(arg)")]), timeout: 1.5)
        } catch { errors += 1; if errors == 1 { note("send via \(interface ?? "auto") to \(host): \(error.localizedDescription)") } }
    }
    return (sender.route, errors)
}
var r = await oscSend("lo0", to: "127.0.0.1", port: 19101)
var got = oscSink.drain(for: 0.5)
check("pinned to lo0 reaches 127.0.0.1", got == 1 && r.route.interface == "lo0", "\(got) received, \(r.route.summary)")
r = await oscSend("en0", to: "127.0.0.1", port: 19101)
got = oscSink.drain(for: 0.8)
check("pinned to en0 can't reach 127.0.0.1", got == 0, "\(got) received, \(r.errors) send errors, \(r.route.summary)")
r = await oscSend(nil, to: "127.0.0.1", port: 19101)
got = oscSink.drain(for: 0.5)
check("automatic reaches 127.0.0.1", got == 1 && r.route == .automatic, "\(got) received")
r = await oscSend("en99", to: "127.0.0.1", port: 19101)
got = oscSink.drain(for: 0.5)
check("missing port falls back to system routing", got == 1 && r.route == .fallback(bsd: "en99", problem: .missing), "\(got) received, \(r.route.summary)")

// Other apps use lo0 and en0 too (about 1 MB in a few seconds here), so each run is compared
// with the same interval measured idle just before it, and sends 4 MB.
let payload: Int64 = 4_000_000
print("== Byte counters (\(payload / 1_000_000) MB of OSC per run, against an idle baseline)")
let bulkSink = UDPCounter(port: 19102)
func counters(during work: () async -> Int) async -> (lo0: Int64, en0: Int64, errors: Int, seconds: Double) {
    let lo = outBytes("lo0"), en = outBytes("en0"), t = Date()
    let errors = await work()
    try? await Task.sleep(nanoseconds: 300_000_000)
    return (Int64(outBytes("lo0") &- lo), Int64(outBytes("en0") &- en), errors, Date().timeIntervalSince(t))
}
func measure(_ interface: String, to host: String) async -> (lo0: Int64, en0: Int64, baseLo0: Int64, baseEn0: Int64, errors: Int) {
    let run = await counters { await oscSend(interface, to: host, port: 19102, count: Int(payload / 1000), padding: 980).errors }
    let idle = await counters { try? await Task.sleep(nanoseconds: UInt64(max(0, run.seconds - 0.3) * 1e9)); return 0 }
    return (run.lo0, run.en0, idle.lo0, idle.en0, run.errors)
}
var m = await measure("en0", to: "10.255.255.1")
check("pinned to en0: the bytes leave en0, not lo0",
      m.en0 - m.baseEn0 > payload * 9 / 10 && m.lo0 - m.baseLo0 < payload / 2 && m.errors == 0,
      "en0 +\(m.en0) B (idle +\(m.baseEn0)), lo0 +\(m.lo0) B (idle +\(m.baseLo0))")
_ = bulkSink.drain(for: 0.1)
m = await measure("lo0", to: "127.0.0.1")
let arrived = bulkSink.drain(for: 0.5)
check("pinned to lo0: the bytes leave lo0, not en0",
      m.lo0 - m.baseLo0 > payload * 9 / 10 && m.en0 - m.baseEn0 < payload / 2 && m.errors == 0,
      "lo0 +\(m.lo0) B (idle +\(m.baseLo0)), en0 +\(m.en0) B (idle +\(m.baseEn0)); \(arrived) datagrams arrived on 127.0.0.1")
let un = await oscSend("lo0", to: "10.255.255.1", port: 19102, count: 200, padding: 980)
check("pinned to lo0: 10.255.255.1 is unreachable, every send refused", un.errors == 200, "\(un.errors)/200 refused")

// MARK: - 3. OSC in

print("== OSC in (listener)")
let oscIn = await MainActor.run { OSCServer() }
final class Counter: @unchecked Sendable { var n = 0 }
let heard = Counter()
await MainActor.run { oscIn.onMessage = { _, _ in heard.n += 1 } }
func oscInTrial(_ interface: String?, sendTo host: String) async -> (Int, PortRoute, String?) {
    await MainActor.run { oscIn.stop(); oscIn.listen(on: 19103, interface: interface) }
    try? await Task.sleep(nanoseconds: 400_000_000)
    heard.n = 0
    for _ in 0..<3 { sendUDP(OSCMessage("/understudy/play").encoded(), to: host, port: 19103) }
    try? await Task.sleep(nanoseconds: 600_000_000)
    return await MainActor.run { (heard.n, oscIn.route, oscIn.problem) }
}
var (n, route, problem) = await oscInTrial("lo0", sendTo: "127.0.0.1")
check("listening on lo0 hears 127.0.0.1", n == 3 && route.interface == "lo0", "\(n)/3, \(route.summary) \(problem ?? "")")
(n, route, problem) = await oscInTrial("en0", sendTo: "127.0.0.1")
check("listening on en0 ignores 127.0.0.1", n == 0 && route.interface == "en0", "\(n)/3, \(route.summary) \(problem ?? "")")
(n, route, problem) = await oscInTrial("en0", sendTo: en0IP)
note("listening on en0, sent from this Mac to en0's own address \(en0IP): \(n)/3 heard (macOS counts a packet to a port's address as arriving on that port)")
(n, route, problem) = await oscInTrial(nil, sendTo: "127.0.0.1")
check("listening on all ports hears 127.0.0.1", n == 3 && route == .automatic, "\(n)/3")
await MainActor.run { oscIn.stop() }

// MARK: - 4. Deck control (HyperDeck stand-in on 127.0.0.1:9993)

print("== Deck control (HyperDeck stand-in on 127.0.0.1:9993)")
let deck = try fakeHyperDeck()
final class DeckLog: @unchecked Sendable { var states: [HyperDeckClient.State] = []; var routes: [PortRoute] = [] }
func deckTrial(_ interface: String?) async -> DeckLog {
    let log = DeckLog()
    let client = HyperDeckClient(host: "127.0.0.1", interface: interface)
    client.onState = { s in log.states.append(s) }
    client.onRoute = { r in log.routes.append(r) }
    client.connect()
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    client.disconnect()
    try? await Task.sleep(nanoseconds: 200_000_000)
    return log
}
let before = deck.accepted
var log = await deckTrial("lo0")
check("control pinned to lo0 connects", log.states.contains(.connected) && log.routes.first?.interface == "lo0",
      "\(log.states) via \(log.routes.first?.summary ?? "-")")
let afterLo = deck.accepted
log = await deckTrial("en0")
let failure = log.states.compactMap { if case .failed(let m) = $0 { return m } else { return nil } }.first ?? "-"
check("control pinned to en0 can't reach 127.0.0.1", !log.states.contains(.connected) && deck.accepted == afterLo,
      "\(failure); stand-in accepted \(deck.accepted - afterLo)")
check("stand-in saw exactly the lo0 connection", afterLo - before == 1, "\(afterLo - before)")
log = await deckTrial("en99")
check("missing deck port falls back and connects", log.states.contains(.connected) && log.routes.first == .fallback(bsd: "en99", problem: .missing),
      log.routes.first?.summary ?? "-")
let greetLo = await DeckDiscovery.probe("127.0.0.1", interface: "lo0")
let greetEn = await DeckDiscovery.probe("127.0.0.1", interface: "en0")
check("discovery probe follows the port", greetLo?.model == "HyperDeck Stand-in" && greetEn == nil,
      "lo0: \(greetLo?.model ?? "nil"), en0: \(greetEn?.model ?? "nil")")

print("== Bonjour browsing (a throwaway _understudy-nic._tcp service, not a deck type)")
let advertiser = Process()
advertiser.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
advertiser.arguments = ["-R", "NIC Harness", "_understudy-nic._tcp", "local", "19105"]
advertiser.standardOutput = FileHandle.nullDevice
try advertiser.run()
try? await Task.sleep(nanoseconds: 1_500_000_000)
final class Found: @unchecked Sendable { var interfaces: Set<String> = [] }
func browse(_ interface: String?) async -> (Set<String>, PortRoute) {
    let params = NWParameters.tcp
    let route = params.pin(to: interface)
    let browser = NWBrowser(for: .bonjour(type: "_understudy-nic._tcp", domain: nil), using: params)
    let found = Found()
    let q = DispatchQueue(label: "harness.browse")
    browser.browseResultsChangedHandler = { results, _ in
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint, name == "NIC Harness" else { continue }
            found.interfaces.formUnion(result.interfaces.map(\.name))
        }
    }
    browser.start(queue: q)
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    browser.cancel()
    return (q.sync { found.interfaces }, route)
}
var (seen, browseRoute) = await browse(nil)
check("automatic browsing sees the service on lo0 and en0", seen.isSuperset(of: ["lo0", "en0"]), "\(seen.sorted())")
(seen, browseRoute) = await browse("en0")
check("browsing pinned to en0 sees it only on en0", seen == ["en0"], "\(seen.sorted()) via \(browseRoute.summary)")
(seen, browseRoute) = await browse("lo0")
check("browsing pinned to lo0 sees it only on lo0", seen == ["lo0"], "\(seen.sorted()) via \(browseRoute.summary)")
advertiser.terminate()

// MARK: - 5. disguise HTTP (Designer stand-in)

print("== disguise (Designer stand-in on 127.0.0.1:19104)")
let designer = try fakeDesigner(port: 19104)
do {
    let tracks = try await D3Client.tracks(host: "127.0.0.1:19104", interface: "lo0")
    check("tracks pinned to lo0 (chunked reply)", tracks == ["Track 1", "Song 2"], "\(tracks)")
} catch { check("tracks pinned to lo0 (chunked reply)", false, error.localizedDescription) }
do {
    let result = try await D3Client.execute(host: "http://127.0.0.1:19104", script: "return 1", interface: "lo0")
    check("execute pinned to lo0", D3Client.resultDictionary(result.returnValue)?["placed"] as? Int == 3, result.returnValue ?? "nil")
} catch { check("execute pinned to lo0", false, error.localizedDescription) }
let acceptedBefore = designer.accepted
do {
    let tracks = try await D3Client.tracks(host: "127.0.0.1:19104", interface: "en0")
    check("tracks pinned to en0 can't reach 127.0.0.1", false, "got \(tracks)")
} catch { check("tracks pinned to en0 can't reach 127.0.0.1", designer.accepted == acceptedBefore, error.localizedDescription) }
do {
    let tracks = try await D3Client.tracks(host: "127.0.0.1:19104", interface: nil)
    check("tracks automatic (URLSession)", tracks == ["Track 1", "Song 2"], "\(tracks)")
} catch { check("tracks automatic (URLSession)", false, error.localizedDescription) }

// MARK: - 6. curl (FTP copies use the same --interface argument)

print("== curl --interface (as FTP copies use it)")
func curlStatus(_ interface: String?) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = CurlInterface.arguments(interface) + ["-s", "-o", "/dev/null", "--connect-timeout", "2", "http://127.0.0.1:19104/api/session/transport/tracks"]
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}
check("curl pinned to lo0 reaches 127.0.0.1", curlStatus("lo0") == 0)
check("curl pinned to en0 can't", curlStatus("en0") == 7, "exit \(curlStatus("en0"))")

// MARK: - 7. NDI

print("== NDI (adapters.allowed via NDI_CONFIG_DIR)")
let configPath = URL(fileURLWithPath: store).appendingPathComponent("ndi/ndi-config.v1.json")
/// Starts a child that runs NDI on `bsd` (from `sourceConfig`'s folder, if given, else ~/.ndi),
/// then looks for its source from this process, which runs NDI with the default config.
func ndiTrial(_ bsd: String, sourceConfig: URL? = nil) async -> (found: Bool, generated: Data?) {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["ndi-send", bsd, "10"]
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "NDI_CONFIG_DIR")
    if let sourceConfig { env["NDI_CONFIG_DIR"] = sourceConfig.path }
    child.environment = env
    try? child.run()
    try? await Task.sleep(nanoseconds: 2_500_000_000)
    let generated = try? Data(contentsOf: configPath)
    var found = false
    if let create = NDILibrary.shared.findCreate, let sources = NDILibrary.shared.findSources {
        var settings = cndi_find_create_t(show_local_sources: true, p_groups: nil, p_extra_ips: nil)
        let finder = create(&settings)
        for _ in 0..<6 where !found {
            _ = NDILibrary.shared.findWait?(finder, 1000)
            var count: UInt32 = 0
            if let list = sources(finder, &count) {
                found = (0..<Int(count)).contains { (list[$0].p_ndi_name.map { String(cString: $0) } ?? "").hasSuffix("(NIC Harness \(bsd))") }
            }
        }
        NDILibrary.shared.findDestroy?(finder)
    }
    child.terminate()
    child.waitUntilExit()
    return (found, generated)
}
if NDILibrary.shared.isAvailable {
    var t = await ndiTrial("en0")
    check("NDI on en0: config allows only en0's address", t.generated.flatMap(NDIAdapterConfig.allowed) == [en0IP],
          "\(t.generated.flatMap(NDIAdapterConfig.allowed) ?? [])")
    check("NDI on en0: source still found", t.found)
    t = await ndiTrial("lo0")
    check("NDI on lo0: config allows only 127.0.0.1", t.generated.flatMap(NDIAdapterConfig.allowed) == ["127.0.0.1"])
    // Proof NDI reads Understudy's generated config: a send group in the user's config is carried
    // into it, and the source then isn't in the public group this process looks in.
    let userDir = URL(fileURLWithPath: store).appendingPathComponent("user-ndi", isDirectory: true)
    try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
    try? Data(#"{"ndi":{"groups":{"send":"understudy-nic-test"}}}"#.utf8).write(to: userDir.appendingPathComponent("ndi-config.v1.json"))
    t = await ndiTrial("en0", sourceConfig: userDir)
    let groups = t.generated.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        .flatMap { ($0["ndi"] as? [String: Any])?["groups"] as? [String: Any] }
    check("NDI keeps the user's settings in its config", groups?["send"] as? String == "understudy-nic-test"
          && t.generated.flatMap(NDIAdapterConfig.allowed) == [en0IP])
    check("NDI reads Understudy's config (its send group hides the source from the public group)", !t.found)
    note("Not observable on one Mac: which port NDI's media leaves by. Bonjour advertises on every interface either way, and a receiver on the same Mac connects over loopback.")
} else {
    note("NDI library not found: skipped")
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
