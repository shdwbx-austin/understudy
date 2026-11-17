import Foundation
import Testing
@testable import UnderstudyCore

@Suite("Network ports")
struct NetworkPortsTests {
    let show = NetworkPortState(bsd: "en8", name: "Thunderbolt Ethernet", hasLink: true,
                                addresses: [IPv4Subnet("10.0.0.5", mask: "255.255.255.0")!])
    let dante = NetworkPortState(bsd: "en9", name: "USB 10/100/1000 LAN", hasLink: true,
                                 addresses: [IPv4Subnet("169.254.12.7", mask: "255.255.0.0")!,
                                             IPv4Subnet("192.168.50.20", mask: "255.255.255.0")!])
    let unplugged = NetworkPortState(bsd: "en10", name: "Ethernet (en10)", hasLink: false, addresses: [])
    let noAddress = NetworkPortState(bsd: "en11", name: "Ethernet", hasLink: true, addresses: [])
    var ports: [NetworkPortState] { [show, dante, unplugged, noAddress] }

    // MARK: Settings

    @Test func oldSettingsDecodeWithAutomaticPorts() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"ma3Host":"10.0.0.50","discoveryInterface":"en7"}"#.utf8))
        #expect(old.interfaces == NetworkInterfaceSettings())
        #expect(old.interface(for: .ma3) == nil && old.interface(for: .d3) == nil)
        #expect(old.interface(for: .ndi) == nil && old.interface(for: .oscIn) == nil)
        // The deck port is the one discovery already used.
        #expect(old.interface(for: .decks) == "en7")
        #expect(old.ma3Host == "10.0.0.50")
    }

    @Test func portsRoundTrip() throws {
        var s = AppSettings()
        for (i, traffic) in NetworkTraffic.allCases.enumerated() { s.setInterface("en\(i + 1)", for: traffic) }
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        for (i, traffic) in NetworkTraffic.allCases.enumerated() { #expect(back.interface(for: traffic) == "en\(i + 1)") }
        #expect(back.discoveryInterface == "en1")
        s.setInterface("", for: .ndi)
        #expect(s.interface(for: .ndi) == nil)
    }

    @Test func partialAndBrokenInterfaceBlocksDecode() throws {
        let partial = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"interfaces":{"ndi":"en9"}}"#.utf8))
        #expect(partial.interfaces == NetworkInterfaceSettings(ndi: "en9"))
        let wrongType = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"interfaces":{"ma3":5,"d3":"en8"},"oscPort":9001}"#.utf8))
        #expect(wrongType.interfaces == NetworkInterfaceSettings(d3: "en8"))
        #expect(wrongType.oscPort == 9001)
        let garbage = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"interfaces":"en8","oscPort":9002}"#.utf8))
        #expect(garbage.interfaces == NetworkInterfaceSettings())
        #expect(garbage.oscPort == 9002)
    }

    @Test func targetsPerTraffic() {
        var s = AppSettings()
        s.decks[0].host = " 10.0.0.11 "
        s.decks[1].host = "10.0.0.12"
        s.decks[1].enabled = false
        s.decks[2].kind = .recorder
        s.decks[2].host = "10.0.0.13"
        s.ma3Host = "10.0.0.50"
        s.d3Host = "http://10.0.1.20"
        #expect(s.targets(for: .decks) == ["10.0.0.11"])
        #expect(s.targets(for: .ma3) == ["10.0.0.50"])
        #expect(s.targets(for: .d3) == ["http://10.0.1.20"])
        #expect(s.targets(for: .ndi).isEmpty && s.targets(for: .oscIn).isEmpty)
    }

    // MARK: Subnets

    @Test func parsesAndMatchesSubnets() {
        #expect(IPv4Subnet.parse("10.0.0.5") == 0x0A00_0005)
        #expect(IPv4Subnet.parse("10.0.0") == nil)
        #expect(IPv4Subnet.parse("10.0.0.256") == nil)
        #expect(IPv4Subnet.parse("10..0.5") == nil)
        #expect(IPv4Subnet.parse("10.0.0.5 ") == nil)
        #expect(IPv4Subnet.parse("-1.0.0.5") == nil)
        let net = IPv4Subnet("10.0.0.5", mask: "255.255.255.0")!
        #expect(net.cidr == "10.0.0.0/24" && net.prefixLength == 24)
        #expect(net.contains(IPv4Subnet.parse("10.0.0.200")!))
        #expect(!net.contains(IPv4Subnet.parse("10.0.1.200")!))
        #expect(IPv4Subnet("169.254.1.2", mask: "255.255.0.0")!.isLinkLocal)
        #expect(IPv4Subnet("127.0.0.1", mask: "255.0.0.0")!.isLoopback)
    }

    @Test func readsAddressesFromTargets() {
        #expect(IPv4Subnet.address(inTarget: "10.0.0.5") == IPv4Subnet.parse("10.0.0.5"))
        #expect(IPv4Subnet.address(inTarget: " 10.0.0.5:8000 ") == IPv4Subnet.parse("10.0.0.5"))
        #expect(IPv4Subnet.address(inTarget: "http://10.0.0.5/api") == IPv4Subnet.parse("10.0.0.5"))
        #expect(IPv4Subnet.address(inTarget: "https://10.0.0.5:443") == IPv4Subnet.parse("10.0.0.5"))
        #expect(IPv4Subnet.address(inTarget: "director.local") == nil)
        #expect(IPv4Subnet.address(inTarget: "") == nil)
    }

    // MARK: Routes

    @Test func bindAddressPrefersARealAddressOverSelfAssigned() {
        #expect(show.bindAddress?.dottedAddress == "10.0.0.5")
        #expect(dante.bindAddress?.dottedAddress == "192.168.50.20")
        let onlyLinkLocal = NetworkPortState(bsd: "en9", name: "Dante", hasLink: true,
                                             addresses: [IPv4Subnet("169.254.12.7", mask: "255.255.0.0")!])
        #expect(onlyLinkLocal.bindAddress?.dottedAddress == "169.254.12.7")
        #expect(noAddress.bindAddress == nil)
    }

    @Test func resolvesRoutes() {
        #expect(PortRoute.resolve(nil, ports: ports) == .automatic)
        #expect(PortRoute.resolve("", ports: ports) == .automatic)
        #expect(PortRoute.resolve("en8", ports: ports) == .pinned(bsd: "en8", address: "10.0.0.5"))
        #expect(PortRoute.resolve("en8", ports: ports).interface == "en8")
        #expect(PortRoute.resolve("en7", ports: ports) == .fallback(bsd: "en7", problem: .missing))
        #expect(PortRoute.resolve("en10", ports: ports) == .fallback(bsd: "en10", problem: .noLink))
        #expect(PortRoute.resolve("en11", ports: ports) == .fallback(bsd: "en11", problem: .noIPv4))
        #expect(PortRoute.resolve("en10", ports: ports).interface == nil)
        #expect(PortRoute.resolve("en10", ports: ports).isProblem)
        #expect(!PortRoute.automatic.isProblem)
    }

    @Test func routeSummaries() {
        #expect(PortRoute.automatic.summary == "system routing")
        #expect(PortRoute.pinned(bsd: "en8", address: "10.0.0.5").summary == "en8 · 10.0.0.5")
        #expect(PortRoute.fallback(bsd: "en10", problem: .noLink).summary == "en10 has no link: using system routing")
        #expect(show.summary == "10.0.0.5/24")
        #expect(dante.summary == "169.254.12.7/16, 192.168.50.20/24")
        #expect(unplugged.summary == "no link")
        #expect(noAddress.summary == "no IPv4 address")
        #expect(unplugged.label == "Ethernet (en10)")
        #expect(show.label == "Thunderbolt Ethernet (en8)")
    }

    @Test func warnings() {
        #expect(PortWarning.check(nil, ports: ports, targets: ["1.2.3.4"]).isEmpty)
        #expect(PortWarning.check("en8", ports: ports, targets: ["10.0.0.11", "10.0.0.12"]).isEmpty)
        #expect(PortWarning.check("en8", ports: ports, targets: ["10.0.1.11", " 10.0.1.11", "deck.local"])
                == [.offSubnet(target: "10.0.1.11", bsd: "en8", subnets: ["10.0.0.0/24"])])
        // A target on either of a port's subnets is fine.
        #expect(PortWarning.check("en9", ports: ports, targets: ["169.254.1.1", "192.168.50.9"]).isEmpty)
        #expect(PortWarning.check("en10", ports: ports, targets: ["10.0.1.11"]) == [.problem(bsd: "en10", .noLink)])
        #expect(PortWarning.check("en11", ports: ports, targets: []) == [.problem(bsd: "en11", .noIPv4)])
        #expect(PortWarning.check("en7", ports: ports, targets: []) == [.problem(bsd: "en7", .missing)])
        #expect(PortWarning.offSubnet(target: "10.0.1.11", bsd: "en8", subnets: ["10.0.0.0/24"]).text
                == "10.0.1.11 isn't on en8's subnet (10.0.0.0/24). It's reached only if that network has a router to it.")
        #expect(PortWarning.problem(bsd: "en10", .noLink).text.hasPrefix("en10 has no link"))
    }

    // MARK: NDI, curl

    @Test func ndiConfigKeepsTheUsersSettings() throws {
        let user = Data(#"{"ndi":{"networks":{"ips":"","discovery":"10.0.0.2"},"groups":{"send":"public"},"adapters":{"allowed":["1.1.1.1"],"other":1}},"top":true}"#.utf8)
        let merged = NDIAdapterConfig.merged(user, allowed: ["10.0.0.5"])
        #expect(NDIAdapterConfig.allowed(in: merged) == ["10.0.0.5"])
        let root = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let ndi = try #require(root["ndi"] as? [String: Any])
        #expect((ndi["networks"] as? [String: String])?["discovery"] == "10.0.0.2")
        #expect((ndi["groups"] as? [String: String])?["send"] == "public")
        #expect((ndi["adapters"] as? [String: Any])?["other"] as? Int == 1)
        #expect(root["top"] as? Bool == true)
    }

    @Test func ndiConfigFromNothing() {
        #expect(NDIAdapterConfig.allowed(in: NDIAdapterConfig.merged(nil, allowed: ["10.0.0.5"])) == ["10.0.0.5"])
        #expect(NDIAdapterConfig.allowed(in: NDIAdapterConfig.merged(Data("not json".utf8), allowed: ["10.0.0.5"])) == ["10.0.0.5"])
        #expect(NDIAdapterConfig.allowed(in: Data("{}".utf8)) == nil)
    }

    @Test func curlArguments() {
        #expect(CurlInterface.arguments(nil).isEmpty)
        #expect(CurlInterface.arguments("").isEmpty)
        #expect(CurlInterface.arguments("en8") == ["--interface", "if!en8"])
    }

    // MARK: HTTP

    @Test func buildsRequests() {
        let body = Data(#"{"a":1}"#.utf8)
        let r = String(decoding: HTTP1.request(method: "POST", host: "10.0.0.20", path: "/api/x",
                                               headers: [("Content-Type", "application/json")], body: body), as: UTF8.self)
        #expect(r == "POST /api/x HTTP/1.1\r\nHost: 10.0.0.20\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}")
        let g = String(decoding: HTTP1.request(method: "GET", host: "h", path: ""), as: UTF8.self)
        #expect(g == "GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
    }

    @Test func parsesContentLength() {
        let full = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 5\r\n\r\nhello".utf8)
        #expect(HTTP1.parse(full, closed: false) == .complete(.init(status: 200, headers: ["content-type": "application/json", "content-length": "5"], body: Data("hello".utf8))))
        #expect(HTTP1.parse(full.prefix(full.count - 2), closed: false) == .incomplete)
        #expect(HTTP1.parse(full.prefix(full.count - 2), closed: true) == .invalid)
        #expect(HTTP1.parse(Data("HTTP/1.1 200 OK\r\nContent-".utf8), closed: false) == .incomplete)
    }

    @Test func parsesChunked() {
        let chunked = "HTTP/1.1 404 Not Found\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n6;x=y\r\npedia \r\nE\r\nin \r\n\r\nchunks.\r\n0\r\n\r\n"
        guard case .complete(let r) = HTTP1.parse(Data(chunked.utf8), closed: false) else {
            Issue.record("not complete"); return
        }
        #expect(r.status == 404)
        #expect(String(decoding: r.body, as: UTF8.self) == "Wikipedia in \r\n\r\nchunks.")
        let cut = Data(chunked.utf8).prefix(chunked.utf8.count - 3)
        #expect(HTTP1.parse(cut, closed: false) == .incomplete)
        #expect(HTTP1.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".utf8), closed: false) == .invalid)
    }

    @Test func parsesCloseDelimitedAndBodiless() {
        let open = Data("HTTP/1.0 200 OK\r\n\r\nabc".utf8)
        #expect(HTTP1.parse(open, closed: false) == .incomplete)
        #expect(HTTP1.parse(open, closed: true) == .complete(.init(status: 200, headers: [:], body: Data("abc".utf8))))
        #expect(HTTP1.parse(Data("HTTP/1.1 204 No Content\r\n\r\n".utf8), closed: false) == .complete(.init(status: 204, headers: [:], body: Data())))
        #expect(HTTP1.parse(Data("SSH-2.0-x\r\n\r\n".utf8), closed: false) == .invalid)
    }
}
