import AppKit
import SwiftUI
import XCTest
import HookFeedCore
@testable import HookFeedApp

final class DisclosureAccessibilityTests: XCTestCase {
    @MainActor
    func testRemoteDisclosuresHaveLabelsCopyActionsAndKeyboardToggle() throws {
        try checkKeyboardToggle(RemoteTokenSheet(url: "http://localhost:8787", token: "test-token", done: {}),
                                label: "Codex (MCP)") { elements in
            let model = RemoteTokenSheetModel(url: "http://localhost:8787", token: "test-token")
            let labels = elements.compactMap { $0.accessibilityLabel?() }
            for example in model.examples {
                XCTAssertTrue(labels.contains("Copy \(example.title)"))
                if example.collapsible {
                    let disclosure = try XCTUnwrap(elements.first { $0.accessibilityLabel?() == example.title })
                    XCTAssertEqual(disclosure.accessibilityRole?(), .disclosureTriangle)
                    let value: Any? = disclosure.accessibilityValue?()
                    XCTAssertEqual(value as? Int, 0)
                }
            }
        }
    }

    @MainActor
    func testIntegrationDisclosureHasLabelAndKeyboardToggle() throws {
        try checkKeyboardToggle(IntegrationCardView(integration: Integration.named("codex")!, cliPath: "/tmp/hookfeed",
                                                    lastUpdate: nil, install: {}, remove: {}, status: .needsUpdate),
                                label: "Codex") { elements in
            let values: [String] = elements.compactMap {
                let value: Any? = $0.accessibilityValue?()
                return value as? String
            }
            XCTAssertTrue(values.contains("Needs update"))
        }
    }

    @MainActor
    private func checkKeyboardToggle<V: View>(_ view: V, label: String, check: ([AnyObject]) throws -> Void) throws {
        _ = NSApplication.shared
        // SwiftUI builds its accessibility nodes lazily until accessibility is requested.
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(attribute)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func elements(_ element: AnyObject) -> [AnyObject] {
            [element] + (element.accessibilityChildren?() ?? []).flatMap { elements($0 as AnyObject) }
        }
        try check(elements(host))
        let disclosure = try XCTUnwrap(elements(host).first {
            $0.accessibilityRole?() == .disclosureTriangle && ($0.accessibilityLabel?() ?? "").hasPrefix(label)
        })
        XCTAssertEqual(disclosure.accessibilityRole?(), .disclosureTriangle)
        window.makeFirstResponder(host)
        disclosure.setAccessibilityFocused?(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(disclosure.isAccessibilityFocused?(), true)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: " ",
                                                  charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        for expected in [1, 0] {
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let value: Any? = disclosure.accessibilityValue?()
            XCTAssertEqual(value as? Int, expected)
            if label == "Codex", expected == 1 {
                let labels = elements(host).compactMap { $0.accessibilityLabel?() }
                XCTAssertTrue(labels.contains("Copy setup prompt"))
                XCTAssertTrue(labels.contains("Setup details for Codex"))
            }
        }
    }
}
