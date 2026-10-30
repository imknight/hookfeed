import Darwin
import Foundation
import Network

protocol RemoteTCPConnection: AnyObject, Sendable {
    func start(on queue: DispatchQueue, failed: @escaping () -> Void)
    func read(_ completion: @escaping (Data?, Bool, Error?) -> Void)
    func write(_ data: Data?, final: Bool, completion: @escaping (Error?) -> Void)
    func cancel()
}

extension NWConnection: RemoteTCPConnection {
    func start(on queue: DispatchQueue, failed: @escaping () -> Void) {
        stateUpdateHandler = { if case .failed = $0 { failed() } }
        start(queue: queue)
    }
    func read(_ completion: @escaping (Data?, Bool, Error?) -> Void) {
        receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
            completion(data, complete, error)
        }
    }
    func write(_ data: Data?, final: Bool, completion: @escaping (Error?) -> Void) {
        send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
             completion: .contentProcessed { completion($0) })
    }
}

final class RemoteSocketListener {
    private let source: DispatchSourceRead

    init(address: String, port: Int, queue: DispatchQueue, accept: @escaping (RemoteSocketConnection) -> Void) throws {
        _ = try RemoteServer.endpoint(address: address, port: port)
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        do {
            var enabled: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno)!)
            }
            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            local.sin_port = UInt16(port).bigEndian
            local.sin_addr.s_addr = inet_addr(address)
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, Darwin.listen(fd, 64) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        } catch { Darwin.close(fd); throw error }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.source.isCancelled else { return }
            // Yield after a bounded batch so existing clients and shutdown can run.
            for _ in 0..<64 {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                do { accept(try RemoteSocketConnection(fd: client, queue: queue)) }
                catch { Darwin.close(client) }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    func cancel(completion: @escaping () -> Void) {
        let fd = Int32(source.handle)
        source.setCancelHandler { Darwin.close(fd); completion() }
        source.cancel()
    }
}

// Socket state and all callbacks stay on the server's serial queue.
final class RemoteSocketConnection: RemoteTCPConnection, @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private var cancelled = false
    private let cancellations = DispatchGroup()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var reading: ((Data?, Bool, Error?) -> Void)?
    private var writing: ((Error?) -> Void)?
    private var output = Data()
    private var offset = 0

    init(fd: Int32, queue: DispatchQueue) throws {
        self.fd = fd; self.queue = queue
        var enabled: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
    }

    func start(on queue: DispatchQueue, failed: @escaping () -> Void) {}

    func read(_ completion: @escaping (Data?, Bool, Error?) -> Void) {
        guard !cancelled else { completion(nil, false, POSIXError(.ECANCELED)); return }
        reading = completion
        receive()
    }

    private func receive() {
        guard !cancelled, let completion = reading else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(fd, &bytes, bytes.count, 0)
        if count < 0, errno == EAGAIN || errno == EINTR {
            if readSource == nil {
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                cancellations.enter()
                source.setCancelHandler { [cancellations] in cancellations.leave() }
                source.setEventHandler { [weak self] in self?.receive() }
                readSource = source; source.resume()
            }
            return
        }
        readSource?.cancel(); readSource = nil; reading = nil
        completion(count > 0 ? Data(bytes.prefix(count)) : nil, count == 0,
                   count < 0 ? POSIXError(POSIXErrorCode(rawValue: errno)!) : nil)
    }

    func write(_ data: Data?, final: Bool, completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            guard !cancelled else { completion(POSIXError(.ECANCELED)); return }
            if final {
                let result = Darwin.shutdown(fd, SHUT_WR)
                completion(result == 0 ? nil : POSIXError(POSIXErrorCode(rawValue: errno)!))
                return
            }
            output = data ?? Data(); offset = 0; writing = completion
            flush()
        }
    }

    private func flush() {
        guard !cancelled, let completion = writing else { return }
        while offset < output.count {
            let count = output.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0) }
            if count < 0, errno == EAGAIN || errno == EINTR {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    cancellations.enter()
                    source.setCancelHandler { [cancellations] in cancellations.leave() }
                    source.setEventHandler { [weak self] in self?.flush() }
                    writeSource = source; source.resume()
                }
                return
            }
            if count <= 0 {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                writeSource?.cancel(); writeSource = nil; writing = nil; output = Data()
                completion(error); return
            }
            offset += count
        }
        writeSource?.cancel(); writeSource = nil; writing = nil; output = Data()
        completion(nil)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        readSource?.cancel(); readSource = nil
        writeSource?.cancel(); writeSource = nil
        cancellations.notify(queue: queue) { [fd] in Darwin.close(fd) }
        let read = reading; reading = nil
        let write = writing; writing = nil; output = Data()
        read?(nil, false, POSIXError(.ECANCELED))
        write?(POSIXError(.ECANCELED))
    }
}
