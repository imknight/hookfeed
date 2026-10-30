import Foundation

public enum ReachRoute: String, CaseIterable, Codable, Sendable {
    case thisMachine, tailscaleIP, tailscaleHTTPS
}

public struct ReachAddresses: Equatable, Sendable {
    public var tailscaleIP: String?
    public var tailscaleHost: String?

    public init(tailscaleIP: String?, tailscaleHost: String?) {
        self.tailscaleIP = tailscaleIP
        self.tailscaleHost = tailscaleHost
    }

    public static func isTailscaleIP(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        return UInt8(parts[0]) == 100 && (64...127).contains(Int(parts[1])!)
    }

    public static func detect(interfaces: [(name: String, ipv4: String)], tailscaleDNSName: String?) -> ReachAddresses {
        ReachAddresses(tailscaleIP: interfaces.first { isTailscaleIP($0.ipv4) }?.ipv4,
                       tailscaleHost: tailscaleDNSName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    }

    public func baseURL(for route: ReachRoute, port: Int) -> URL? {
        guard (1...65535).contains(port) else { return nil }
        switch route {
        case .thisMachine: return URL(string: "http://127.0.0.1:\(port)")
        case .tailscaleIP:
            guard let tailscaleIP, Self.isTailscaleIP(tailscaleIP) else { return nil }
            return URL(string: "http://\(tailscaleIP):\(port)")
        case .tailscaleHTTPS:
            guard let host = tailscaleHost, host.hasSuffix(".ts.net"),
                  host.utf8.allSatisfy({ (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
                  host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else { return nil }
            return URL(string: "https://\(host)")
        }
    }
}
