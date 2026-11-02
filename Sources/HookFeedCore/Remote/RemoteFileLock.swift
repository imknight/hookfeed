import Darwin
import Foundation

public final class RemoteFileLock {
    private let descriptor: Int32

    public init(path: String, wait: Bool = false) throws {
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        guard flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code)!)
        }
    }

    deinit { Darwin.close(descriptor) }
}
