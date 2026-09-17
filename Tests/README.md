# Regression checks

Run from the repository root with Xcode installed:

```sh
zsh Tests/run-regressions.sh
zsh Tests/run-explorer-regressions.sh
```

The explorer suite uses a local SFTP subprocess and injected directory responses;
no saved server profiles or credentials are used. It covers filename/type parsing,
stale responses, link resolution, native selection and double-click actions,
10,000-row virtualization, resizing, and file promises. AppKit tests need a macOS
WindowServer session. The click fixture uses an off-screen window with a simulated
key-window state; it does not activate the app or move the pointer.

A restricted process sandbox can prevent the SSH fixture and NSItemProvider from
creating their temporary sharing permissions. Run these tests in a normal local
terminal in that case. The explorer runner keeps compiler caches in its temporary
build directory and requires the final PASS marker, in addition to a zero exit.

To render the fixture:

```sh
ORNITHOPTER_TEST_SNAPSHOT=/tmp/ornithopter-explorer.png zsh Tests/run-explorer-regressions.sh
```

## September 2026 hang investigation

`report1.rtf` records a 47.71-second hang, with 1.893 seconds of main-thread CPU
in the 2-second sample, predominantly in SwiftUI/AttributeGraph updates.
The former tree put a recursive, non-lazy child `ForEach` inside each root's
`VStack` and installed two application event monitors per instantiated row.

With the same 10,000-child fixture, the former row implementation from Git HEAD
did not finish layout before a 30-second execution limit. The native outline
materialized 25 row views in a 300 × 600-point viewport and completed the fixture
update/layout in approximately 0.10–0.12 seconds (including a 100 ms settling
wait). Listing parsing and sorting took approximately 0.07 seconds. These are
local fixture measurements, not network transfer timings.
