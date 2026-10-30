import Darwin
import Foundation
import GRDB

public struct SpooledMessage: Codable, Equatable, Sendable {
    public let draft: MessageDraft
    public let receivedAt: Date
    public let key: String
}

public enum SpoolError: Error, Equatable { case full }

public struct Spool: Sendable {
    public static let cap = 10_000
    public let directory: URL

    public init(storePath: String = InboxStore.defaultPath) {
        directory = URL(fileURLWithPath: storePath).deletingLastPathComponent().appendingPathComponent("spool")
    }

    @discardableResult
    public func enqueue(_ draft: MessageDraft, receivedAt: Date = Date()) throws -> URL {
        let draft = try draft.normalizedAndValidated()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(directory.appendingPathComponent(".enqueue.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw POSIXError(.EWOULDBLOCK) }
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard try manager.contentsOfDirectory(atPath: directory.path).lazy.filter({ $0.hasSuffix(".json") }).prefix(Self.cap).count < Self.cap else { throw SpoolError.full }
        let uuid = UUID().uuidString.lowercased()
        let name = "\(Int64(receivedAt.timeIntervalSince1970 * 1000))-\(uuid)"
        let temporary = directory.appendingPathComponent(name + ".tmp")
        let destination = directory.appendingPathComponent(name + ".json")
        let message = SpooledMessage(draft: draft, receivedAt: receivedAt, key: draft.idempotencyKey ?? "spool:\(uuid)")
        let data = try JSONEncoder().encode(message)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? manager.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try manager.moveItem(at: temporary, to: destination)
        return destination
    }

    public func pending(limit: Int) throws -> [URL] {
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        return Array(files.filter { $0.pathExtension == "json" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(max(0, limit)))
    }
}

extension Error {
    public var isStoreBusy: Bool {
        if let error = self as? DatabaseError { return error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED }
        if let error = self as? HookFeedError, case .migrationLockTimeout = error { return true }
        return false
    }
}

public struct DrainResult: Equatable, Sendable {
    public var inserted = 0, duplicates = 0, rejected = 0, remaining = 0
    public init() {}
}

extension Spool {
    public func drain(into store: InboxStore, limit: Int = 500) throws -> DrainResult {
        let manager = FileManager.default
        var result = DrainResult()
        var queued: [(URL, SpooledMessage)] = []
        for file in try pending(limit: limit) {
            do {
                let decoded = try JSONDecoder().decode(SpooledMessage.self, from: Data(contentsOf: file))
                var draft = try decoded.draft.normalizedAndValidated()
                draft.idempotencyKey = decoded.key
                _ = try draft.normalizedAndValidated()
                queued.append((file, SpooledMessage(draft: draft, receivedAt: decoded.receivedAt, key: decoded.key)))
            } catch CocoaError.fileReadNoSuchFile { continue }
            catch {
                let rejected = directory.appendingPathComponent("rejected")
                try manager.createDirectory(at: rejected, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                do { try manager.moveItem(at: file, to: rejected.appendingPathComponent(file.lastPathComponent)); result.rejected += 1 }
                catch CocoaError.fileNoSuchFile { continue }
            }
        }
        if !queued.isEmpty {
            let duplicates = try store.insertSpooled(queued.map { $0.1 })
            for ((file, _), duplicate) in zip(queued, duplicates) {
                if duplicate { result.duplicates += 1 } else { result.inserted += 1 }
                do { try manager.removeItem(at: file) }
                catch CocoaError.fileNoSuchFile {}
            }
            if result.inserted > 0 { Signal.post() }
        }
        result.remaining = try pending(limit: Int.max).count
        return result
    }
}
