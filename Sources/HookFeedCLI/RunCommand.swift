import ArgumentParser
import Darwin
import Foundation
import HookFeedCore

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run argv directly, stream output, then save its exit status and stderr tail.")
    @Option var title: String?
    @Option var project: String?
    @Option(help: "Bot name; defaults to HOOKFEED_BOT.") var bot: String?
    @Option var workdir: String?
    @Flag var onlyFailures = false
    @Argument(parsing: .captureForPassthrough, help: "Command and arguments, after --.") var command: [String]

    mutating func validate() throws {
        if command.first == "--" { command.removeFirst() }
        guard !command.isEmpty, !command[0].isEmpty else { throw ValidationError("Provide a command after --.") }
    }

    mutating func run() throws {
        let start = ContinuousClock.now
        let result = DirectProcess.execute(command)
        let status = result.status
        let elapsed = start.duration(to: .now)
        if !onlyFailures || status != 0 {
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let basename = URL(fileURLWithPath: command[0]).lastPathComponent
            let cwd = FileManager.default.currentDirectoryPath
            // Quoting is for display only; no shell ever evaluates this string.
            let display = command.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            let body = RunRecord.body(status: status, seconds: seconds, command: display, stderr: result.stderr)
            let draft = MessageDraft(
                title: title ?? String((status == 0 ? "\(basename) succeeded" : "\(basename) failed (exit \(status))").prefix(200)),
                body: body, source: "run", origin: RunRecord.origin, project: project ?? String(URL(fileURLWithPath: cwd).lastPathComponent.prefix(80)),
                bot: bot ?? ProcessInfo.processInfo.environment["HOOKFEED_BOT"],
                kind: status == 0 ? .completed : .failed,
                workdir: workdir.map(CLIInput.absolutePath) ?? cwd
            )
            do { _ = try CLIStorage.send(draft) }
            catch { CLIOutput.error("hookfeed: could not save command result: \(error.localizedDescription)") }
        }
        throw WrappedExit(status: status)
    }
}

enum DirectProcess {
    static func execute(_ arguments: [String]) -> (status: Int32, stderr: String) {
        let capture: StderrCapture
        do { capture = try StderrCapture() }
        catch {
            CLIOutput.error("hookfeed: cannot capture stderr: \(error.localizedDescription)")
            return (126, error.localizedDescription)
        }
        defer { _ = capture.finish() }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addclose(&actions, capture.readFD)
        posix_spawn_file_actions_adddup2(&actions, capture.writeFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, capture.writeFD)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        let forwardedSignals: [Int32] = [SIGTERM, SIGHUP]
        let terminalSignals: [Int32] = [SIGINT, SIGQUIT]
        for number in forwardedSignals + terminalSignals { sigaddset(&defaults, number) }
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let state = ChildPID()
        var sources: [DispatchSourceSignal] = []
        var oldHandlers: [(Int32, sig_t?)] = []
        // Like POSIX system(), keep the shell's process group and ignore INT/QUIT
        // only in the waiting parent. The terminal (or killpg) already delivers
        // these to the child; forwarding would deliver them twice. This applies
        // even with redirected stdio. A signal sent ONLY to the wrapper PID is
        // intentionally ignored for INT/QUIT; send it to the job's process group.
        // Spawn resets the child's defaults, and native TTY/job control, pipeline
        // membership, group SIGKILL and intentional background jobs stay intact.
        for number in terminalSignals {
            oldHandlers.append((number, signal(number, SIG_IGN)))
        }
        for number in forwardedSignals {
            // Direct TERM/HUP requests still reach the wrapped command. Target
            // the wrapper PID for these: group delivery also reaches the child
            // directly and cannot be distinguished here from PID-only delivery.
            let old = signal(number, { _ in })
            oldHandlers.append((number, old))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { state.forward(number) }
            source.resume()
            sources.append(source)
        }
        defer {
            state.clear()
            sources.forEach { $0.cancel() }
            oldHandlers.forEach { _ = signal($0.0, $0.1) }
        }

        let argv = arguments.map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { pointer in
            environment.withUnsafeBufferPointer { env in
                posix_spawnp(&pid, arguments[0], &actions, &attributes, pointer.baseAddress!, env.baseAddress!)
            }
        }
        capture.closeWriter()
        guard result == 0 else {
            CLIOutput.error("hookfeed: cannot execute \(arguments[0]): \(String(cString: strerror(result)))")
            return (result == ENOENT ? 127 : 126, "Cannot execute \(arguments[0]): \(String(cString: strerror(result)))")
        }
        state.set(pid)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno == EINTR { continue }
            CLIOutput.error("hookfeed: waitpid failed: \(String(cString: strerror(errno)))")
            return (1, capture.finish())
        }
        state.clear()
        let signalNumber = status & 0x7f
        return (signalNumber == 0 ? (status >> 8) & 0xff : 128 + signalNumber, capture.finish())
    }

    private final class ChildPID: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var pending: [Int32] = []
        func set(_ newPID: pid_t) {
            lock.lock(); defer { lock.unlock() }
            pid = newPID
            for number in pending { Darwin.kill(pid, number) }
            pending.removeAll()
        }
        func clear() { lock.lock(); pid = -1; pending.removeAll(); lock.unlock() }
        func forward(_ number: Int32) {
            lock.lock(); defer { lock.unlock() }
            if pid > 0 { Darwin.kill(pid, number) }
            else if pid == 0 { pending.append(number) }
        }
    }
}

private final class StderrCapture {
    let readFD: Int32
    let writeFD: Int32
    private let queue = DispatchQueue(label: "app.hookfeed.stderr")
    private let source: DispatchSourceRead
    private var tail = RunOutputTail()
    private var finished = false

    init() throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        readFD = descriptors[0]
        writeFD = descriptors[1]
        _ = fcntl(readFD, F_SETFL, O_NONBLOCK)
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
        source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(descriptors[0]) }
        source.resume()
    }

    func closeWriter() { Darwin.close(writeFD) }

    func finish() -> String {
        queue.sync {
            if !finished {
                drain()
                source.cancel()
                finished = true
            }
            return tail.text
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<64 {
            let count = Darwin.read(readFD, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            tail.append(Data(buffer.prefix(count)))
            buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(STDERR_FILENO, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { break }
                    offset += written
                }
            }
        }
    }
}
