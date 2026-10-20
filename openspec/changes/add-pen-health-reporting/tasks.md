# Tasks

## 1. Portable protocol

- [x] 1.1 Register the verified `0x04` and `0x84` evidence, request frame, and 64-byte decoder; verify focused NeoProtocol tests cover framing, bit decoding, and malformed payloads.
- [x] 1.2 Add a bounded optional pen-state step after handshake and return its reading with the session result; verify a fake-transport session checks request order and rejection behavior.
- [x] 1.3 Record the physical A1 pen-state layout in `docs/protocol-a1.md`; verify it distinguishes measured facts from pending hardware acceptance.

## 2. macOS presentation

- [x] 2.1 Enable the query in the A1 runner and carry its result through read models and controller, clearing old values on a new read; verify controller tests cover the lifecycle.
- [ ] 2.2 Show battery, charging, and storage used in the menu and details window; verify app build and UI behavior on the Mac runner. SwiftPM and Xcode builds pass; physical UI comparison is pending because no A1 advertised during the acceptance attempt.

## 3. Integration gates

- [x] 3.1 Run `Scripts/test-portable.sh` and `Scripts/remote-mac-build.sh`; record any unavailable Xcode or physical-A1 gates without treating a skipped gate as passed.
