# Design

## Context

See the proposal. The A1 has no standard BLE Battery Service. The physical probe established a zero-length `0x04` request and a 64-byte `0x84` payload. Byte 15 is storage percentage; byte 20 contains the charging bit and battery percentage. The existing session and fake transport are portable; SwiftUI stays in the app package.

## Goals / Non-Goals

**Goals:** Decode the verified response in NeoProtocol, pass the reading through the read result to the controller, and show it after a successful read.

**Non-Goals:** Poll while disconnected, infer bytes or free storage capacity, or use `0xA3` summary counts as an exact live storage measure.

## Decisions

- Make pen-state querying an explicit session option, enabled by the macOS A1 runner. Existing portable offline callers retain their established command sequence; the app obtains a fresh reading for each attempt.
- Treat an enabled query as a bounded, required step. A rejected or malformed response fails the attempt instead of displaying an old value.
- Keep the decoded value in the session result and carry it through the runner and read outcome. The controller clears its displayed reading at the start of an attempt.
- Validate the full 64-byte payload and percentage ranges. Mask byte 20 with `0x7F` for battery and test bit `0x80` for charging.

## Risks / Trade-offs

- [A1 firmware may respond differently] → Restrict this path to the established version gate and fail with a clear protocol error; physical acceptance on the Mac runner remains required.
- [A state timeout adds latency] → Use a bounded wait equal to other response steps.
- [Concurrent sync/storage work changes nearby files] → Preserve existing edits and make a focused additive patch.
