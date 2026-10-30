import AppKit
import SwiftUI
import XCTest
import HookFeedCore
@testable import HookFeedApp

private struct ListSnapshot: View {
    @ObservedObject var model: InboxModel
    @FocusState private var searchFocused: Bool
    var body: some View {
        InboxThreadList(model: model, searchFocused: $searchFocused)
    }
}

final class SnapshotTests: XCTestCase {
    @MainActor
    func testConnectAllSheet() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("hermes")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let model = ConnectAllModel(home: home, searchPath: { bin.path }, cliPath: "/Applications/HookFeed.app/Contents/Helpers/hookfeed",
                                    runner: RecordingRunner(), configPath: { home.appendingPathComponent($0.relativeConfigPath) },
                                    integrations: [Integration.all[1], syntheticMCPIntegration()], fallbackDirectories: [])
        await model.refresh()
        try snapshot(ConnectAllSheet(model: model), name: "connect-all-sheet", width: 560)
    }

    @MainActor
    func testIntegrationCards() throws {
        try snapshot(VStack(spacing: 16) {
            ForEach(Integration.all) { integration in
                IntegrationCardView(integration: integration, cliPath: "/Applications/HookFeed.app/Contents/Helpers/hookfeed",
                                    lastUpdate: nil, install: integration.id == "hermes" ? nil : {},
                                    remove: integration.id == "hermes" ? nil : {},
                                    status: integration.id == "codex" ? .needsUpdate : .detected)
            }
        }.padding(20), name: "integration-cards", width: 680, height: 1000)
    }

    @MainActor
    func testIntegrationCardExpanded() throws {
        try snapshot(IntegrationCardView(integration: Integration.named("codex")!,
                                         cliPath: "/Applications/HookFeed.app/Contents/Helpers/hookfeed",
                                         lastUpdate: nil, install: {}, remove: {}, status: .needsUpdate, initiallyExpanded: true)
            .padding(20), name: "integration-card-expanded", width: 680, height: 800)
    }

    @MainActor
    func testIntegrationSetupDetails() throws {
        try snapshot(IntegrationSetupDetails(integration: Integration.named("codex")!,
                                             cliPath: "/Applications/HookFeed.app/Contents/Helpers/hookfeed", done: {}),
                     name: "integration-setup-details", width: 640, height: 540)
    }

    @MainActor
    func testRemoteTokenSheetCollapsed() throws {
        try snapshot(RemoteTokenSheet(url: "https://mac.tailnet.ts.net", token: "hf_example_token", done: {}),
                     name: "remote-token-collapsed", width: 620)
    }

    @MainActor
    func testRemoteTokenSheetExpanded() throws {
        try snapshot(RemoteTokenSheet(url: "https://mac.tailnet.ts.net", token: "hf_example_token", expanded: ["codex"], done: {}),
                     name: "remote-token-expanded", width: 620)
    }

    @MainActor
    func testRemoteTab() throws {
        let clock = Date(timeIntervalSince1970: 1_792_800_000)
        let connections = try RemoteConnections(store: MemoryRemoteSecrets())
        let created = try connections.create(name: "Home server", route: .tailscaleIP, now: clock)
        connections.markUsed(id: created.connection.id, now: clock)
        let remote = RemoteAccessModel(connections: connections,
                                       addresses: ReachAddresses(tailscaleIP: "100.101.2.3", tailscaleHost: "mac.tailnet.ts.net"),
                                       now: { clock })
        try snapshot(RemoteAccessView(model: remote), name: "remote-tab", width: 720)
    }

    @MainActor
    func testSidebarWithBots() throws {
        let store = try InboxStore(path: ":memory:")
        _ = try store.send(.init(title: "Checks complete", source: "grokbot", project: "A", bot: "Grokbot"))
        let selected = try store.send(.init(title: "Build ready", source: "grokbot", project: "A", bot: "Charname"))
        let model = InboxModel(store: store, observesChanges: false)
        model.select("message:" + selected.id)
        try snapshot(HStack(spacing: 0) {
            InboxView(model: model).sidebar.frame(width: 220)
            Divider()
            ListSnapshot(model: model).frame(width: 460)
        }, name: "sidebarWithBots", width: 681)
    }

    @MainActor
    func testEmptyInboxList() throws {
        let model = InboxModel(store: try InboxStore(path: ":memory:"), observesChanges: false)
        try snapshot(ListSnapshot(model: model), name: "empty-inbox", width: 360)
    }

    @MainActor
    func testStorageErrorDetail() throws {
        let model = InboxModel(store: try InboxStore(path: ":memory:"), observesChanges: false)
        try snapshot(StorageErrorView(model: model, error: "SQLite error 26: file is not a database"),
                     name: "storage-error", width: 640)
    }

    @MainActor
    func testMarkdownThreadDetail() throws {
        let model = InboxModel(store: try InboxStore(path: ":memory:"), observesChanges: false)
        let message = Message(id: "markdown", seq: 1, title: "## Review: **ready**",
                              body: "## Review: **ready**\n\n### Checks\nUse `swift test` before shipping.\n\n| Check | Result |\n|---|---|\n| Tests | Pass |\n\n```sh\nswift test\n```",
                              source: "codex", project: "HookFeed", bot: "Charname",
                              receivedAt: Date(timeIntervalSince1970: 0))
        try snapshot(ThreadDetail(model: model, thread: MessageThread.group([message])[0]),
                     name: "markdown-thread", width: 720)
    }

    @MainActor
    func testAttentionPinnedReadSelection() throws {
        let store = try InboxStore(path: ":memory:")
        let receipt = try store.send(MessageDraft(title: "Approval needed", body: "Review the deployment.",
                                                 source: "claude-code", project: "HookFeed", bot: "Charname",
                                                 kind: .needsAttention, threadKey: "approval"))
        let model = InboxModel(store: store, observesChanges: false)
        model.filter = .attention
        model.select("thread:approval")
        XCTAssertFalse(try XCTUnwrap(model.selectedThread).isUnread)
        XCTAssertEqual(model.filteredThreads.count, 1)
        XCTAssertEqual(model.selectedThread?.latest.id, receipt.id)
        try snapshot(ListSnapshot(model: model), name: "attention-pinned-read", width: 360)
    }

    @MainActor
    private func snapshot<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat = 640,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        _ = NSApplication.shared
        let content = view
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .tint(Color(red: 0.102, green: 0.455, blue: 0.192))
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        if name == "sidebarWithBots" {
            func prepareSelection(_ view: NSView) {
                // Offscreen cacheDisplay cannot composite the native sidebar selection material.
                if let table = view as? NSTableView, table.effectiveStyle == .sourceList {
                    table.deselectAll(nil)
                }
                for child in view.subviews { prepareSelection(child) }
            }
            prepareSelection(hosting)
            hosting.displayIfNeeded()
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * 2,
                                                 pixelsHigh: Int(height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let actual = try XCTUnwrap(rep.cgImage, file: file, line: line)
        let reference = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__/\(name).png")
        let bitmap = NSBitmapImageRep(cgImage: actual)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        if ProcessInfo.processInfo.environment["HOOKFEED_RECORD_SNAPSHOTS"] == "1" {
            try png.write(to: reference)
            return
        }
        let expected = try XCTUnwrap(NSImage(contentsOf: reference)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                                     "Missing reference; run HOOKFEED_RECORD_SNAPSHOTS=1 swift test --filter SnapshotTests", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        guard actual.width == expected.width, actual.height == expected.height else { return }
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes {
                let context = CGContext(data: $0.baseAddress, width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        let a = pixels(actual), b = pixels(expected)
        let changed = stride(from: 0, to: a.count, by: 4).filter { offset in
            (0..<4).contains { abs(Int(a[offset + $0]) - Int(b[offset + $0])) > 8 }
        }.count
        // Permit tiny rasterization differences, but fail displaced controls or text.
        if Double(changed) / Double(actual.width * actual.height) > 0.001 {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("hookfeed-\(name)-actual.png")
            try png.write(to: output)
            XCTFail("\(changed) pixels differ; actual: \(output.path)", file: file, line: line)
        }
    }
}
