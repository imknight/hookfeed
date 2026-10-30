# UI snapshots

Run `swift test --filter SnapshotTests` on macOS with the full Xcode toolchain.
Re-record intentionally with `HOOKFEED_RECORD_SNAPSHOTS=1 swift test --filter SnapshotTests`,
then inspect all affected PNGs and run again without record mode.

References use NSHostingView cacheDisplay at a fixed 2× scale, light scheme, en_US locale, UTC,
fixed 640-point height and explicit widths. Foundation-formatted footer dates
follow the runner time zone; these references were recorded in Asia/Kuala_Lumpur
on macOS 27.0.1 (26A434), Xcode 27.1 (27A9275). Tests import the executable's HookFeedApp
module directly; no library split or package dependency is needed.
Models use isolated in-memory stores without notifications, timers or workspace observers.
The pinned case exercises selection marking the actual store thread read.

Comparison allows channel differences up to 8/255 and at most 0.1% changed pixels.
Failures write the actual image to the temporary directory. References depend on
the macOS/SwiftUI/font rendering version; review changes when upgrading the runner.
These are view snapshots, not native window, menu bar, notification or interaction tests.

Regression proof: increasing the list header padding from 16 to 40 failed both list
snapshots; increasing detail padding from 26 to 56 failed Markdown; changing the
storage-error heading failed its snapshot. All four passed after restoring the views.

24 October improvements: only `markdown-thread.png` was re-recorded to remove the
newest timeline title repeated by the header and left-align its timestamp. The
other three reference images are unchanged.

24 October bots: added `sidebarWithBots.png`; re-recorded
`attention-pinned-read.png` and `markdown-thread.png` for bot-first metadata,
and `empty-inbox.png` and `attention-pinned-read.png` for the search placeholder
that now includes bot. `storage-error.png` is unchanged.

The sidebar fixture renders the actual sidebar beside a selected content row.
On this runner, offscreen `cacheDisplay` paints native source-list selection as a
solid black rectangle with invisible text (also with a NavigationSplitView and
within-window selection blending). Only this fixture clears the native sidebar
table selection before capture. It retains the selected content row, both bot
names, and normal sidebar styling. Native sidebar selection appearance is not
verified by this baseline; production styling and system appearance are unchanged.

The sidebar label is **Bots**; `bot` remains the wire/schema/API name. The
fixture filename `sidebarWithBots.png` retains that technical name.

27 October integration disclosures: `integration-cards.png` now shows collapsed
agent cards with detected/needs-update status and setup actions visible.
`integration-card-expanded.png` shows the Codex details. `remote-token-collapsed.png`
and `remote-token-expanded.png` cover the 620×640 token sheet with all examples
collapsed and Codex expanded, respectively. Only these four references changed.
`DisclosureAccessibilityTests` checks native disclosure labels, collapsed header
Copy actions, visible card status, and Space-key expansion/collapse after focus.
