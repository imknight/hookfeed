import Darwin
import Foundation

public struct TailscaleStatus: Sendable {
    public let addresses: ReachAddresses
    public let reason: String?

    static func cliPaths(loginPath: String, environmentPath: String) -> [String] {
        (loginPath + ":" + environmentPath).split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/tailscale" }
            + ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
    }

    public static func executable() async -> URL? {
        let loginPath = (try? await LoginShell.path()) ?? ""
        return cliPaths(loginPath: loginPath, environmentPath: ProcessInfo.processInfo.environment["PATH"] ?? "")
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    public static func serveArguments(port: Int, reset: Bool) -> [String] {
        reset ? ["serve", "reset"] : ["serve", "--bg", "--https=443", "http://127.0.0.1:\(port)"]
    }

    public static func detect() async -> TailscaleStatus {
        guard let executable = await executable() else {
            return TailscaleStatus(addresses: ReachAddresses(tailscaleIP: nil, tailscaleHost: nil), reason: "Tailscale CLI not found.")
        }
        return await Task.detached { detect(executable: executable) }.value
    }

    static func detect(executable: URL) -> TailscaleStatus {
        func unavailable(_ reason: String) -> TailscaleStatus {
            TailscaleStatus(addresses: ReachAddresses(tailscaleIP: nil, tailscaleHost: nil), reason: reason)
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["status", "--json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return unavailable("Could not run Tailscale status.") }
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var ended = false
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= 64 * 1024 else { return unavailable("Tailscale status response was too large.") }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 { ended = true; break }
            else if errno != EAGAIN && errno != EINTR { return unavailable("Could not read Tailscale status.") }
            else {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 20)
            }
        }
        while ended, process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard ended, !process.isRunning, process.terminationStatus == 0 else {
            return unavailable("Tailscale status timed out or failed.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["BackendState"] as? String == "Running", let local = object["Self"] as? [String: Any] else {
            return unavailable("Tailscale isn't running.")
        }
        let ips = local["TailscaleIPs"] as? [String] ?? []
        let addresses = ReachAddresses.detect(interfaces: ips.map { ("tailscale", $0) }, tailscaleDNSName: local["DNSName"] as? String)
        return TailscaleStatus(addresses: addresses, reason: addresses.tailscaleIP == nil ? "No Tailscale IPv4 address available." : nil)
    }
}
