## 1. Packet framing

- [ ] 1.1 Add a frame-kind classification (event or response) to the command metadata for every identifier in the evidence table, derived from `PenCommParser.parsePenDataPacket`; verify each known command resolves to exactly one kind, that the pen's `0x24` data frame resolves to an event, and that its `0xA4` acknowledgement resolves to a response
- [ ] 1.2 Decode the frame body as `command, optional error code, length, payload` using the command's kind, and expose the error code on the decoded packet; verify against the real captured response bytes `0x81 00 46 00` that the declared length reads as 70 and the payload is recovered
- [ ] 1.3 Confirm event frames read the length immediately after the command; verify a test asserts that an event frame reports no error code and that the pen's offline data frame (`0x24`) recovers its declared payload
- [ ] 1.4 Add a protocol error for a failed response carrying the command and the error code, and raise it in the layer that produces device tokens so no events are emitted for that frame; verify with a test that a non-zero error code yields the failure and no events
- [ ] 1.5 Reject an unclassified command identifier instead of guessing a body layout; verify a test that an unknown identifier reports unsupported
- [ ] 1.6 Update the frame encoder so fixture builders can emit both frame kinds; verify encode/decode round-trip tests pass for each kind

## 2. Version payload and protocol policy

- [ ] 2.1 Read compression support from the reported capability byte at index 69 when the protocol version is 2.22 or later, instead of inferring it from payload length and version; verify tests for the clear, set, and short-payload cases
- [ ] 2.2 Add the hardware-observed minor 23 to the validated minors, with the provenance of each minor recorded beside the list; verify a test that a 2.23 report is supported and that an unlisted minor is still reported unsupported
- [ ] 2.3 Verify the corrected parser against the real 70-byte version payload: device name `NWP-F151`, firmware `3.00`, protocol `2.23`, sub-name `Neosmartpen_A1`, device type `0x0001`, pressure sensor type `0x04`, compression support clear

## 3. Fixtures and tests

- [ ] 3.1 Add a frame-kind parameter to `Tests/Fixtures/generate-fixtures.py` and regenerate all six fixtures; verify re-running the generator is deterministic and the diff contains only framing changes
- [ ] 3.2 Create a capture-derived fixture from the real handshake exchange with the Bluetooth address zeroed and no serial or handwriting content; verify its declared expected packets match a byte-exact decode of the captured request and response
- [ ] 3.3 Verify sanitization: the new fixture and the regenerated set contain no Bluetooth address, serial number, connection code, or personal stroke content, and the raw capture remains git-ignored
- [ ] 3.4 Extend the fixture replay tests to cover both frame kinds; verify the malformed-frame fixtures still report their expected errors and invent no pen events
- [ ] 3.5 Run `Scripts/test-portable.sh` end to end and confirm the forbidden-import check, the pinned-resolution check, and both test suites pass; record the output and the new test counts in `docs/portable-verification.md`

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
