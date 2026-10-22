# Tasks

## 1. Portable protocol

- [x] 1.1 Register the verified `0x04` and `0x84` evidence, request frame, and 64-byte decoder; verify focused NeoProtocol tests cover framing, bit decoding, and malformed payloads.
- [x] 1.2 Add a bounded optional pen-state step after handshake and return its reading with the session result; verify a fake-transport session checks request order and rejection behavior.
- [x] 1.3 Record the physical A1 pen-state layout in `docs/protocol-a1.md`; verify it distinguishes measured facts from pending hardware acceptance.

## 2. macOS presentation

- [x] 2.1 Enable the query in the A1 runner and carry its result through read models and controller, clearing old values on a new read; verify controller tests cover the lifecycle.
- [x] 2.2 Show battery, charging, and storage used in Connection Details; verify app build and UI behavior on the Mac runner. The later compact-menu decision supersedes the original menu placement.

  Note: verified on 2026-10-21 against a physical A1 on `Jamess-MacBook-Pro-M4.local` (macOS 27.2, Xcode 27.1). A completed automatic Retain read displayed "Battery: 92% · Not charging" and "Pen storage used: 1%" in Connection Details, and a fresh sanitized `0x84` probe taken immediately afterwards reported `battery 92% charging false storageUsed 1%`. The state query follows the handshake: the sanitized transcript's `outboundCommands` is `0x01,0x04,0x21,0x22,0x23,0xA4`, so `0x04` precedes discovery.

  Note: the menu surface is superseded by the newer `simplify-menu-sync-actions` change, which reduces the menu to one compact status line. The owner decided on 2026-10-21 that the newer design wins, so the health values are verified in Connection Details only and no battery line is restored to the menu. The earlier "no A1 advertised" blocker is cleared: the pen advertised and every read in this run completed.

## 3. Integration gates

- [x] 3.1 Run `Scripts/test-portable.sh` and `Scripts/remote-mac-build.sh`; record any unavailable Xcode or physical-A1 gates without treating a skipped gate as passed.
