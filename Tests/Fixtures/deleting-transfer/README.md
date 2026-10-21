# Deleting-transfer fixtures, 2026-10-21

Committed, sanitized, paired transcripts of the deleting `0x23` transfer option
(`0x01`, `NextAndDelete`) measured against a physical Neo Smartpen A1 on
2026-10-21. They are the portable form of the evidence recorded in
`docs/protocol-a1.md`, section "Deleting transfer option, 2026-10-21", and the
fixtures the tests read when the git-ignored raw captures are absent.

## Layout

| Path | What it is |
| --- | --- |
| `provenance.json` | The pairing, the identity the trace covers, and the expected inventory per pair. |
| `baseline.txt` | A non-destructive read of note 700 (section 3, owner 27) before any deleting transfer: 18 strokes over pages 36 and 37. |
| `withheld-packet-1/deleting.txt` | A deleting transfer that received packet 1 (13 strokes) and withheld its acknowledgement. |
| `withheld-packet-1/read-after.txt` | The read that followed: all 18 strokes still on the pen. |
| `withheld-packet-2/deleting.txt` | A deleting transfer that acknowledged packet 1 (13 strokes) and withheld packet 2's acknowledgement (5 strokes). |
| `withheld-packet-2/read-after.txt` | The read that followed: exactly packet 2's 5 strokes still on the pen. |

The pen streams a note's strokes in transfer order, so packet 1 is the first 13
entries of `baseline.txt` and packet 2 is the remaining 5. A test derives the two
packets from the baseline rather than restating them, so the pair and the baseline
cannot drift apart.

## Derivation

Each file is the sanitized transcript of one run, taken verbatim from
`Tests/Fixtures/raw/acceptance-2026-10-21-next-delete-rerun/`, which is
git-ignored. Nothing was redacted because nothing needed to be: the app
transcripts record outbound frames and inbound chunk sizes, and the PenLab
transcripts record the framed bytes the host sent plus the decoded response
fields.

No Bluetooth address, serial number, or authentication material appears in either
shape. The Bluetooth address is zeroed in the host's handshake request, which the
PenLab transcript reproduces; the version response is not reproduced at all, only
its error code. Each `stroke` line does keep its page, index, dot count, bounding
box, origin time, time span, and fingerprint — per-stroke bounding boxes, dot counts,
and origin times are present, as they are in the repository's other sanitized
fixtures. What is absent is the handwriting itself: the point-by-point path behind
each bounding box.

## What the pair establishes

- Withholding packet 1's acknowledgement removed nothing: all 18 starting strokes
  were still readable afterwards, including the 13 the pen had already handed
  over.
- Acknowledging packet 1 and withholding packet 2 removed exactly packet 1's 13
  strokes: only packet 2's 5 strokes were still readable afterwards.
- The pen's `0xA3` accepted option `0x01` with error `0x00` and
  `compressed=false`, and one `0x24` followed each `0xA4`.

The bound the fixtures prove is the acknowledgement bound. They say nothing about
the pen's internal removal trigger, so no report may claim whole-note removal from
them.
