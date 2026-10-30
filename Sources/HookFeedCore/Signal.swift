import Darwin

// notify.h is not exported by Darwin's Swift module on every supported SDK.
@_silgen_name("notify_post")
private func darwinNotifyPost(_ name: UnsafePointer<CChar>) -> UInt32

public enum Signal {
    public static let name = "app.hookfeed.inbox.changed"

    public static func post() {
        // The receipt describes persistence. A best-effort wakeup cannot undo it.
        name.withCString { _ = darwinNotifyPost($0) }
    }
}
