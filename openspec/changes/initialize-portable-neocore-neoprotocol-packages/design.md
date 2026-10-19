## Context

The repository has OpenSpec configuration but no Swift source. The primary host is Linux; macOS compilation and physical A1 validation use a remote runner. See `proposal.md` for motivation and the two capability specs for behavior.

## Goals / Non-Goals

**Goals:** Establish buildable SwiftPM packages, deterministic domain identity, an isolated protocol boundary, and fixture tests that run on Linux.

**Non-Goals:** Implement a macOS app, assert unverified A1 commands, persist or export user data in this change, or enable pen deletion.

## Decisions

### Package boundaries

Create independent `Packages/NeoCore` and `Packages/NeoProtocol` SwiftPM manifests. NeoCore owns Ncode identity `(section, owner, book, page)`, normalized events, stroke assembly, and SHA-256 fingerprint construction. NeoProtocol owns byte framing, packet encoding/decoding, version dispatch, and protocol errors. Neither package imports `SwiftUI`, `AppKit`, or `CoreBluetooth`; the same prohibition will apply to future NeoStorage and NeoExport packages. Separate manifests make `swift test` work on Linux and expose accidental platform coupling. A single app target was rejected because it would defer portable verification until the Mac runner.

### Transport and evidence boundary

Define `PenTransport` as an asynchronous byte send/receive contract at the protocol edge, with a deterministic fixture/fake implementation for Linux. A future `CoreBluetoothPenTransport` belongs in `Apps/NeoBridgeMac` and adapts BLE callbacks to this contract. Neo's official iOS SDK 3.0 lists A1 (F151) and its request model uses a 2.18 protocol version; the SDK generation is not the wire protocol version. Target the protocol 2.x family, then record the connected A1's reported minor version and accept only validated behavior for that version. Fixture metadata records source, sanitization, device model, firmware, observed protocol version, capture date, expected frames, and evidence level. Supported commands require official SDK wire evidence or physical A1 validation plus a fixture test. Provisional mappings are inspection-only; unknown commands and versions are unsupported. A BLE-specific transport in NeoProtocol was rejected because it would break Linux builds.

Evidence: Neo's [iOS SDK 3.0 README](https://github.com/NeoSmartpen/iOS-SDK3.0/blob/master/README.md) lists A1 (F151), and its [request structure](https://github.com/NeoSmartpen/iOS-SDK3.0/blob/master/NISDK3/Classes/Model/RequestStruct.swift) sets a protocol version of `2.18`. This establishes the protocol family, not the exact firmware version of the user's A1.

### Canonical replay identity

Serialize the complete page tuple, pen-origin stroke start time, and every ordered point's integer coordinates, pen-time offset, and pressure in a versioned, unambiguous byte format, then hash with SHA-256. Normalize live and offline values into the same integer units before encoding. Exclude host arrival time, live/offline source, and transport chunking. Do not round normalized values. If the pen-origin stroke time is absent or unreliable, retain the stroke without cross-source deduplication so two identical marks are not silently collapsed. A random UUID was rejected because it cannot identify replay duplicates; geometry-only hashing was rejected because distinct identical marks would collide by design.

### Future import and export contract

The portable interfaces prepare for a two-phase verified import: collect and validate a batch, commit SQLite records, and atomically publish deterministic JSON/SVG/Markdown exports through sibling temporary files and renames before acknowledging the batch. Any later pen cleanup uses a durable journal with `prepared -> requested -> confirmed` states and defaults to `keepOnPen`; it remains disabled until physical A1 acceptance. These operations are documented here as downstream contracts, not implemented by this package initialization. They keep fixture and transport APIs compatible with safe recovery work.

## Risks / Trade-offs

- [Public fixture scarcity] → Keep fixtures sanitized, label evidence level, and avoid claims about unsupported commands.
- [A1 firmware differences] → Record model, firmware, and observed protocol version in M0 evidence; validate the command sequence on the actual device before production support.
- [Fingerprint format changes] → Version the canonical encoding and use golden vectors before persisted dedup relies on it.
- [Linux and Mac compiler differences] → Run portable tests on Linux first, then compile on the remote Mac runner; physical A1 proof gates UI work.
- [Crypto dependency portability] → Choose a SHA-256 implementation that builds on Linux and macOS, and pin its version.

## Migration Plan

This is an additive first implementation with no stored data to migrate. If the packages fail portable verification, remove the new manifests and sources before app integration. Do not advance to UI implementation until `docs/protocol-a1.md` records real A1 offline stroke retrieval.
