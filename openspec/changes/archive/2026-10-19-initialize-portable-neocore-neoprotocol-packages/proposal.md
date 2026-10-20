## Why

NeoBridge needs a portable foundation so pen data can be modeled and protocol traces can be tested on the primary Linux development host before macOS UI work begins. The current repository has no Swift packages or fixture tests, so this change establishes the first verifiable boundary.

## What Changes

- Add `Packages/NeoCore` with portable page identity, normalized pen event and stroke types, stroke assembly, SHA-256 replay fingerprints, and domain interfaces.
- Add `Packages/NeoProtocol` with transport-independent framing and packet codec interfaces for the A1's Neo protocol 2.x family, version-aware fixture decoding, and a platform-neutral `PenTransport` contract with a fake implementation for tests. Support for a specific minor version requires device evidence.
- Add sanitized protocol fixtures and Linux `swift test` coverage for valid, malformed, and replayed input.
- Document the M0 A1 protocol spike and require physical A1 proof of offline stroke retrieval before UI implementation. Protocol commands without official SDK evidence or hardware proof remain unsupported; provisional mappings are inspection-only.

## Capabilities

### New Capabilities

- `portable-pen-domain`: Portable page, event, stroke, and replay identity behavior.
- `protocol-fixture-testing`: Transport-neutral protocol parsing and repeatable fixture tests on Linux.

### Modified Capabilities

None.

## Impact

Adds Swift packages under `Packages/NeoCore` and `Packages/NeoProtocol`, fixtures under `Tests/Fixtures`, and a portable test script. Linux is the primary test host; a remote macOS runner remains necessary for Xcode and physical A1 validation. This change does not add UI, cloud sync, OCR, or concurrent multi-pen handling.
