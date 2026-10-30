import Foundation

public enum RunRecord {
    public static let origin = "hookfeed.run"

    public static func body(status: Int32, seconds: Double, command: String, stderr: String) -> String {
        let command = command.precomposedStringWithCanonicalMapping
        var tail = RunOutputTail()
        tail.append(Data(stderr.precomposedStringWithCanonicalMapping.utf8))
        let errorText = status != 0 && !tail.text.isEmpty ? "Stderr (last 20 lines, up to 8 KiB):\n\(tail.text)\n\n" : ""
        let header = "Exit code: \(status)\nDuration: \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)) s\n"
        let budget = 32 * 1024 - (header + "Command bytes: 32768\nCommand truncated: yes\n\n" + errorText + "Command: ").utf8.count
        let stored = prefixUTF8(command, bytes: budget)
        let truncated = stored != command
        return header + "Command bytes: \(stored.utf8.count)\nCommand truncated: \(truncated ? "yes" : "no")\n\n" + errorText + "Command: " + stored
    }

    static func prefixUTF8(_ text: String, bytes: Int) -> String {
        var data = Data(text.utf8.prefix(max(0, bytes)))
        while String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct RunOutputTail {
    private var data = Data()
    public init() {}

    public mutating func append(_ chunk: Data) {
        data.append(chunk.suffix(8192))
        if data.count > 8192 { data.removeFirst(data.count - 8192) }
    }

    public var text: String {
        var bytes = data[...]
        while let first = bytes.first, first & 0xc0 == 0x80 { bytes = bytes.dropFirst() }
        var lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return RunRecord.prefixUTF8(lines.suffix(20).joined(separator: "\n"), bytes: 8192)
    }
}
