import ArgumentParser
import HookFeedCore

struct Drain: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Move queued hook updates into the inbox.")
    func run() throws {
        let store = try InboxStore()
        let spool = Spool(storePath: store.path)
        var moved = 0
        var result: DrainResult
        repeat {
            result = try spool.drain(into: store)
            moved += result.inserted
        } while result.remaining > 0
        print("Moved \(moved) queued updates into the inbox.")
    }
}
