## 1. Packet framing

- [x] 1.1 Add a frame-kind classification (event or response) to the command metadata for every identifier in the evidence table, derived from `PenCommParser.parsePenDataPacket`; verify each known command resolves to exactly one kind, that the pen's `0x24` data frame resolves to an event, and that its `0xA4` acknowledgement resolves to a response

  _`PenFrameKind` with `PenCommand.frameKind` in `CommandEvidence.swift`, derived from the SDK's parser case list. The SDK splits the `SOUND_RES_*` family (`0x73`/`0x76`/`0x77` are parsed without an error code, `0xF4`/`0xF5` with one), so the classification is a table rather than a range or naming rule. `0xA4` is classified from the capture, because the SDK parses only pen-to-host frames and never sees it. The 13 identifiers with no framing evidence resolve to `nil`, so the decoder can reject them rather than guess. `CommandFrameKindTests` pins the table and fails if a classification lands without a recorded source._
- [x] 1.2 Decode the frame body as `command, optional error code, length, payload` using the command's kind, and expose the error code on the decoded packet; verify against the real captured response bytes `0x81 00 46 00` that the declared length reads as 70 and the payload is recovered

  _`PenFrame.errorCode` carries the code, and `PenFrameDecoder` reads a three-byte header for an event and a four-byte one for a response. `testResponseHeaderMatchesTheCapturedResponseBytes` replays `81 00 46 00` and asserts an error code of 0 and a 70-byte payload; `testResponseHeaderShorterThanFourBytesIsRejected` pins the longer header minimum._
- [x] 1.3 Confirm event frames read the length immediately after the command; verify a test asserts that an event frame reports no error code and that the pen's offline data frame (`0x24`) recovers its declared payload

  _`testEventFrameReadsTheLengthImmediatelyAfterTheCommand` asserts a nil error code, and `testOfflineDataFrameRecoversItsDeclaredPayload` replays `0x24` and asserts its declared payload returns intact. `testAResponseBodyIsOneByteLongerThanAnEventBody` pins the one-byte difference between the layouts._
- [x] 1.4 Add a protocol error for a failed response carrying the command and the error code, and raise it in the layer that produces device tokens so no events are emitted for that frame; verify with a test that a non-zero error code yields the failure and no events

  _`PenProtocolError.commandFailed(command:code:)`, raised in `PenEventDecoder.decode` before the version and evidence gates. The framing layer still reports the packet with its error code, so a failed exchange stays diagnosable. `FailedResponseTests` covers both the non-zero code and the zero-code case._
- [x] 1.5 Reject an unclassified command identifier instead of guessing a body layout; verify a test that an unknown identifier reports an unknown-command error

  _The decoder consults `PenCommand.frameKind` before reading any length, so an identifier outside the command table and one inside it with no framing evidence both produce `unknownCommand`. `testUnknownCommandIsRejected`, `testUnclassifiedCommandIsRejected`, and `testARejectedFrameDoesNotStopTheNextFrame` cover it, the last proving the decoder still resynchronizes. This changes existing behaviour: an unrecognised command used to produce a frame._
- [x] 1.6 Update the frame encoder so fixture builders can emit both frame kinds; verify encode/decode round-trip tests pass for each kind

  _`PenFrameEncoder.encode(command:payload:errorCode:)` derives the kind from the command and returns `nil` when there is no framing evidence, so a production caller cannot invent a layout. `encode(command:payload:kind:errorCode:)` states the framing explicitly and is internal rather than public, so the layout a caller can state by hand is not part of the module's API. `testEncodedFrameRoundTrips` and `testResponseFrameRoundTripsWithItsErrorCode` cover the round trip for each kind._

## 2. Version payload and protocol policy

- [x] 2.1 Read compression support from the reported capability byte at index 69 when the protocol version is 2.22 or later, instead of inferring it from payload length and version; verify tests for the clear, set, and short-payload cases

  _No source change was needed. `PenVersionInfo` already reads `payload[69]` when the payload reaches 70 bytes and the reported version is at least 2.22, and the SDK's own `PenVersionInfo` does the same thing: it guards on `d.count >= 70` and `protocolVerValue >= 2.22`, then sets `isSupportCompress = d[69] == 0 ? false : true`. The task therefore reduced to verification, so `PenVersionInfoTests` now covers the clear, set, below-the-supporting-minor, absent, and too-short cases._
- [x] 2.2 Add the hardware-observed minor 23 to the validated minors, with the provenance of each minor recorded beside the list; verify a test that a 2.23 report is supported and that an unlisted minor is still reported unsupported

  _`ProtocolVersionPolicy.validatedMinors` defaults to `[18, 23]`, with a provenance line per minor: `18` from the SDK's own `VERSION_INFO` request, `23` from the physical A1's version response on 2026-10-18. `testDefaultPolicySupportsEveryValidatedMinor` and `testUnvalidatedMinorIsUnsupported` cover both directions, including that 2.25 is not supported merely by being newer than 2.23._
- [x] 2.3 Verify the corrected parser against the real 70-byte version payload: device name `NWP-F151`, firmware `3.00`, protocol `2.23`, sub-name `Neosmartpen_A1`, device type `0x0001`, pressure sensor type `0x04`, compression support clear

  _`testHandshakeFixtureMatchesTheCapturedDeviceFacts` decodes the captured payload and asserts every recorded field, including the compression flag being clear. The payload is byte-derived from the capture, so this checks against the pen rather than against a reconstruction of what the pen should send._

## 3. Fixtures and tests

- [x] 3.1 Add a frame-kind parameter to `Tests/Fixtures/generate-fixtures.py` and regenerate all six fixtures; verify re-running the generator is deterministic and the diff contains only framing changes

  _`frame()` and `packet_outcome()` take a `kind` that defaults to the framing recorded for the command, and the generator asserts on a command it has no framing for. All seven fixtures were regenerated (the change added `a1-offline-multipacket` after this task was written). Two consecutive runs are byte-identical, and the diff is framing only: response chunks gain an error-code byte, response packets declare `errorCode`, and `a1-size-limit-recovery`'s `maxBufferedBytes` rises from 68 to 69 because the response header it measures grew by one byte. `a1-escaped-page-identity` and `a1-offline-multipacket` are unchanged, both being event frames. `a1-offline-stroke` was also moved from `0xA4` to `0x24`, the command the pen actually sends for offline data, and `FixtureSupport.isOfflineData` no longer accepts `0xA4` as data: both reviews flagged the old shape as modelling an exchange the evidence says never happens, and this task's framing-only constraint was about its own diff rather than about preserving a wrong command._
- [x] 3.2 Create a capture-derived fixture from the real handshake exchange with the Bluetooth address zeroed and no serial or handwriting content; verify its declared expected packets match a byte-exact decode of the captured request and response

  _`Tests/Fixtures/a1-handshake-version-2.23.json`, derived once from `Tests/Fixtures/raw/raw-20261018-204227.log` with the response's Bluetooth address field zeroed. It carries both halves of the exchange: the host's `0x01` request, framed without an error code, and the pen's `0x81` response, framed with one. It is deliberately not generator-produced, so re-running the generator leaves it untouched, and it declares `evidenceLevel: physicalDevice` rather than `officialSDK`._
- [x] 3.3 Verify sanitization: the new fixture and the regenerated set contain no Bluetooth address, serial number, connection code, or personal stroke content, and the raw capture remains git-ignored

  _`git check-ignore` confirms `Tests/Fixtures/raw/` is ignored (`.gitignore` line 64) and no capture is tracked. `testNoFixtureCarriesADeviceAddressInAVersionPayload` reads the address field of every fixture that carries a version response, so the check is on content rather than on declared metadata. The handshake fixture holds no stroke content and no serial, and its request carries the SDK's sixteen zero-byte connection code. Recorded in `docs/portable-verification.md`._
- [x] 3.4 Extend the fixture replay tests to cover both frame kinds; verify the malformed-frame fixtures still report their expected errors and invent no pen events

  _Replay now compares the declared error code against the decoded frame, and `testFixturesCoverBothFrameKinds` cross-checks the generator's framing table against the Swift one: it reads the error code each fixture packet declares and asserts it agrees with `PenCommand.frameKind`, without consulting the decoder, so the two tables cannot drift apart unnoticed. The malformed fixtures still report `truncatedPacket`, `payloadExceedsLimit`, and `bufferedInputExceedsLimit`, and `testMalformedFixturesDoNotInventPenEvents` still holds._
- [x] 3.5 Run `Scripts/test-portable.sh` end to end and confirm the forbidden-import check, the pinned-resolution check, and both test suites pass; record the output and the new test counts in `docs/portable-verification.md`

  _The run exits 0: the forbidden-import check passes for both packages, pinned resolution passes for both, and NeoCore runs 31 tests and NeoProtocol 100 with no failures. `docs/portable-verification.md` now carries the output, a per-suite count table, and the sanitization verification._

## 4. Documentation

- [x] 4.1 Record the A1 device details from the trace in `docs/protocol-a1.md` (model, firmware, reported protocol version 2.23, capture date, capture host); verify every previously pending device row is filled or explicitly still pending
- [x] 4.2 Document the frame body rule and the response/event classification in `docs/protocol-a1.md`; verify the table names the commands that carry an error code and calls out that `0x24` omits it while `0xA4` carries it
- [x] 4.3 Correct the offline retrieval procedure to request `0x23`, expect an `0xA3` info response, then acknowledge each `0x24` data packet with `0xA4`; verify the steps match the request formats in the SDK's `RequestStruct.swift`
- [x] 4.4 Review the M0 gate section and confirm it states what remains outstanding, namely the evidence review, and does not claim the gate is closed

## 5. Multi-packet offline transfers

- [x] 5.1 Decode one offline data packet on its own terms instead of rejecting every packet whose transfer position is not end; verify a start-position packet decodes and reports its position
- [x] 5.2 Assemble a transfer from its packets, reporting completion only on the end packet and tracking packet, stroke, and dot counts; verify a three-packet start/middle/end transfer assembles every stroke and completes only on the last packet
- [x] 5.3 Reject a packet that does not continue the identifier sequence, so a dropped packet cannot be imported as a hole; verify skipping a packet reports an explicit error and leaves the counts unchanged
- [x] 5.4 Accept a transfer whose first assembled packet is a middle packet, so a sync resumed after a reconnect still completes; verify the resumed transfer completes on its end packet
- [x] 5.5 Reject a packet that arrives after the transfer has completed; verify the second packet reports an explicit error
- [x] 5.6 Add a synthetic three-packet fixture in the shape the pen sends, carried on `0x24`, and generate it from `Tests/Fixtures/generate-fixtures.py`; verify regenerating is deterministic and only the compression-size field changes in the existing offline fixture
- [x] 5.7 Drive the sync path through the assembler and require completion before returning strokes; verify an interrupted stream that never reaches its end packet throws instead of importing
- [x] 5.8 Decode the real 604-packet A1 capture end to end through the shipped assembler; verify 604 packets, 6920 strokes, 70,199 dots, 19 pages, no errors, and page 1 reported as 15 strokes with bounds x 1468..3949 y 698..892
