## Why

The first trace against a physical A1 (2026-10-18, raw capture in the git-ignored
`Tests/Fixtures/raw/`) proved that the portable packet decoder models the frame body
incorrectly. The real response frame is `0x81 00 46 00 <70 bytes>`, carrying an error
code byte between the command and the length, but `PenFrameDecoder` reads the frame as
`command, length, payload`. It therefore mis-parses every response frame, and the test
suite passed anyway because the synthetic fixtures encoded the same wrong assumption.

The M0 protocol spike gate exists to catch exactly this class of defect before UI work
begins. The codec must be corrected, and the real bytes must be covered by tests, so the
gate can be closed on evidence rather than on fixtures that agree with the code.

## What Changes

- **BREAKING** (internal API): the packet body becomes `command, optional error code,
  length, payload`. Response frames (`RES*`, including the host's `0xA4` acknowledgement)
  carry an error code byte between the command and the length field; event frames, host
  requests, and the pen's `0x24` offline data stream do not.
- `PenFrameDecoder` reports the error code alongside the decoded packet instead of
  treating those bytes as part of the length, and rejects a frame whose declared length
  does not fit the buffered body.
- `PenCommand` gains a response/event classification so the decoder knows which body
  layout a command uses, and so an unknown command is still reported as unsupported.
- An explicit protocol error is returned when a response carries a non-zero error code,
  instead of the payload being parsed as data.
- `PenVersionInfo` already reads compression support from the pen's reported flag byte at
  index 69 for protocol 2.22 and later, matching the SDK's own parser, so this part needed
  no source change; the change adds the tests that pin the clear, set, absent, and boundary
  cases. This pen reports the flag as clear while running protocol 2.23.
- The validated protocol minor range records the minor observed on real hardware (`2.23`)
  and keeps the SDK-declared minor (`2.18`), with the provenance of each recorded in the
  documentation and the M0 evidence rather than encoded in the type system, so the range
  reflects what has actually been validated rather than an SDK release number.
- `OfflineDataParser` decodes one offline data packet instead of insisting on a
  single-packet transfer, and a transfer assembler assembles a whole transfer: it reports
  completion only when the pen's end packet arrives, accepts a transfer that resumes
  mid-stream, and rejects a packet that does not continue the identifier sequence instead
  of importing a hole.
- Fixtures are regenerated with the corrected framing, and a sanitized capture of the
  physical handshake is added as a fixture so real pen bytes are covered.
- `docs/protocol-a1.md` records the A1 device details taken from the trace and corrects
  the offline retrieval procedure to request `0x23`, expect an `0xA3` info response, then
  acknowledge each `0x24` data packet with `0xA4`.

Out of scope: connection codes and authentication (`0x02`, `0x03`), which stay at
evidence level "none"; deletion commands, which stay blocked; and the M0 gate
documentation in `docs/protocol-a1.md`, which the initializing change tracks.

## Capabilities

### New Capabilities

None. Every requirement change lands in the existing capability below.

### Modified Capabilities

- `protocol-fixture-testing`: gains three requirements. One defines the frame body
  structure and the response/event error-code rule, including that a non-zero response
  error code is reported as an explicit failure. One defines compression support as coming
  from the pen's reported capability byte. One defines multi-packet offline transfer
  assembly. The validated-minor rule itself already lives in the initializing change's
  delta for the same capability, so this change extends the policy with the
  hardware-observed minor rather than restating the rule.

## Impact

Affected code:

- `Packages/NeoProtocol/Sources/NeoProtocol/PenFrameDecoder.swift`: frame body parsing,
  the decoded packet type, and the encoder used by fixture builders.
- `Packages/NeoProtocol/Sources/NeoProtocol/PenCommand.swift`: response/event
  classification, which the decoder and the evidence table both consume.
- `Packages/NeoProtocol/Sources/NeoProtocol/PenProtocolError.swift`: a failure case for a
  non-zero response error code.
- `Packages/NeoProtocol/Sources/NeoProtocol/PenEventDecoder.swift`: consumes the corrected
  packet type, and must not treat a failed response as a payload.
- `Packages/NeoProtocol/Sources/NeoProtocol/OfflineData.swift`: the per-packet decoder and
  the new transfer assembler, plus the error labels, which named the host's `0xA4`
  acknowledgement for a payload the pen sends as `0x24`.
- `Packages/NeoProtocol/Sources/NeoProtocol/PenWire.swift`: `PenVersionInfo` already
  derived compression support from the pen's capability byte and already matched the SDK's
  parser, so this change adds the tests that pin it rather than editing the parser.
- `Packages/NeoProtocol/Sources/NeoProtocol/ProtocolVersion.swift` and the version policy:
  the validated minor range and its evidence source.
- `Tests/Fixtures/`: the seven generated fixtures, `generate-fixtures.py`, and a new
  capture-derived handshake fixture, eight in total. The raw capture stays git-ignored; the
  committed fixtures must have the serial number, Bluetooth addresses, connection code, and
  handwriting content removed.

Affected behaviour and systems:

- `Scripts/test-portable.sh` is unaffected and continues to be the verification entry
  point.
- No new dependencies are introduced.
- Two changes now write delta specs for the same capability path
  (`protocol-fixture-testing`). The initializing change is still in progress and its
  deltas have not been synced into `openspec/specs/`, which is empty. This change must be
  synced or archived after that one, and its delta is written against the same path so the
  two sets of requirements merge rather than duplicate.
