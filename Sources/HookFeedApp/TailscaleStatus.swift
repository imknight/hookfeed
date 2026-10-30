import Darwin
import Foundation
import HookFeedCore

struct TailscaleStatus: Sendable {
    let addresses: ReachAddresses
    let reason: String?

    static func detect(executable: URL? = nil) -> TailscaleStatus {
        func unavailable(_ reason: String) -> TailscaleStatus {
            TailscaleStatus(addresses: ReachAddresses(tailscaleIP: nil, tailscaleHost: nil), reason: reason)
        }
        let environment = ProcessInfo.processInfo.environment
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/tailscale" }
            + ["/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let executable = executable ?? paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map({ URL(fileURLWithPath: $0) }) else {
            return unavailable("Tailscale CLI not found.")
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
