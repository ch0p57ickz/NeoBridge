## Context

See `proposal.md` for motivation. The constraints the design must respect:

- The evidence is one pen: model `NWP-F151`, firmware `3.00`, reported protocol `2.23`,
  captured 2026-10-18. Raw bytes are in the git-ignored `Tests/Fixtures/raw/`.
- The authoritative classification of which commands carry an error code is the SDK's
  `PenCommParser.parsePenDataPacket`, whose own comment reads
  `Complet Packet [CMD, (error), length, Data]`. Every `RES*` case does `pos += 1` before
  reading the length at `data[2..3]`; every `EVENT*` case, and the `0x24` offline data
  case (`REQ2_OFFLINE_DATA`), does not.
- `PenFrameDecoder` is a portable, dependency-free value type. It cannot learn the layout
  from a platform transport.
- All six existing fixtures were built on the wrong assumption, so none of them can act as
  a regression anchor for this fix.
- The initializing change is still in progress and `openspec/specs/` is empty, so this
  change's delta is written as additions against the same capability path.

## Goals / Non-Goals

**Goals:**

- Frame both layouts correctly, from a single authoritative classification.
- Make a failed response observable instead of silently parsed as data.
- Anchor the corrected framing to bytes the physical pen actually sent.
- Remove two version-payload claims that the capture disproved.

**Non-Goals:**

- Modelling pen authentication or connection codes.
- Completing the offline stroke transfer; that stays with the M0 gate.
- Introducing a general evidence model in the type system, or a request-building API for
  commands this change does not send.

## Decisions

### Carry the error code on the packet, and fail at the token layer

`PenFrame` gains `errorCode: UInt8?`, populated only for response commands. The framing
layer stays faithful: it reports the bytes the pen sent, including a failing response, so
diagnostics and the evidence record keep the raw exchange.

The layer that turns frames into device tokens and domain results treats a non-zero code
as `PenProtocolError.commandFailed(command:code:)` and produces no events for that frame.

- *Alternative considered:* make the framing decoder emit an error outcome and drop the
  payload. Rejected because it destroys the raw evidence, and the raw exchange is the
  artifact this change exists to capture.
- *Alternative considered:* encode the error as a separate frame variant type. Rejected as
  more churn for no behavioral gain; only one field differs.

### Classify response versus event in the existing command table

Add a frame-kind classification (`.event` or `.response`) to the command metadata that
already lives next to the evidence levels, and have the decoder consult it. A command the
table does not classify produces the existing unsupported result rather than a guessed
layout.

- *Alternative considered:* derive the rule from identifier ranges (`0x8x`, `0xAx`).
  Rejected: the offline pair breaks a pure range rule, because `0x24` carries no error
  code while its partner `0xA4` does, so the rule needs the same per-command table anyway.
- *Alternative considered:* infer the layout by testing which length interpretation yields
  a plausible frame. Rejected: it guesses on adversarial input and cannot report failure
  deterministically.

### Keep the validated minor list, document provenance beside it

`validatedMinors` becomes `[18, 23]`: 18 is the SDK-declared value the fixtures already
used, and 23 is what the physical pen reports. Provenance is recorded in the doc comment
and in `docs/protocol-a1.md`, which the M0 gate already requires to carry the model,
firmware, observed version, and capture date.

- *Alternative considered:* a per-minor evidence-source type. Rejected as speculative: the
  spec requires the evidence to exist and be recorded, not to be encoded in the type
  system, and no behavior branches on provenance.
- *Alternative considered:* drop 18 and validate only 23. Rejected: the SDK documents 2.18,
  and removing it would discard evidence rather than add it.

### Anchor the fix to a sanitized capture, regenerate the rest

Add one fixture built from the real handshake exchange, byte-exact apart from redaction,
created by hand rather than by the generator so the generator cannot reproduce its own
mistake. Regenerate the six existing fixtures through the generator, which gains a
frame-kind parameter.

Redaction for the new fixture: zero the Bluetooth address bytes in the version payload,
omit the Device Information serial entirely, and keep the connection code at the zeros the
request already had.

- *Alternative considered:* commit the raw capture. Rejected: it carries the serial, the
  pen's public MAC, and a random advertising address.
- *Alternative considered:* keep the existing synthetic fixtures and only fix the decoder.
  Rejected: the suite would still have no evidence-linked anchor.

## Risks / Trade-offs

- [A command we classify as an event is really a response, so it stays mis-parsed] →
  Classify from the SDK's enumerated case list rather than by pattern, cover both layouts
  per command family in tests, record the classification in `docs/protocol-a1.md`, and
  reject unclassified commands instead of guessing.
- [Regenerating the fixtures launders the old mistake instead of proving the fix] → The
  capture-derived fixture is the anchor; it is not generator-produced and its expected
  output is asserted byte-for-byte.
- [Two in-progress changes add requirements to the same capability] → Record the sync
  order in the proposal, and validate the capability once the initializing change is
  archived.
- [Validated minor 23 rests on one pen and firmware] → Record model, firmware, and capture
  date with the claim, and keep the policy a positive list so unvalidated minors stay
  unsupported.

## Migration Plan

Nothing is released and no consumer outside these packages exists, so this lands as one
commit: decoder and packet type, the command classification, the version-payload and
policy corrections, the regenerated fixtures plus the capture-derived fixture, and the
`docs/protocol-a1.md` updates. Rollback is a revert; the portable verification script is
the gate either way.

## Open Questions

- Does firmware `3.00` accept protocol minors above `2.23`? Deferrable: the policy is a
  positive list, so an unvalidated minor stays unsupported until it is observed.
- Does the host-to-pen `0xA4` acknowledgement carry an error code? Resolved by the
  2026-10-18 capture: yes. The acknowledgement was sent as
  `a4 00 03 00 <packet id> <transfer op>`, that is command, error code, then a declared
  length of 3, and the pen accepted all 604 of them and completed the transfer. `0xA4` is
  therefore a response frame, consistent with its `RES2_OFFLINE_DATA` name, and only the
  pen's `0x24` data frame omits the error code.
