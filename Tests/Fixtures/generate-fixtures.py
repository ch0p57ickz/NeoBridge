#!/usr/bin/env python3
"""Generate the sanitized NeoProtocol fixtures.

This script builds the fixture bytes with an implementation that is independent
of the Swift codec, so the Swift tests cross-check the wire format rather than
re-deriving it. Run it only when a fixture must change, then review the diff.

Usage: python3 Tests/Fixtures/generate-fixtures.py
"""

import json
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))

PACKET_START = 0xC0
PACKET_END = 0xC1
PACKET_DLE = 0x7D


def stuff(body):
    out = [PACKET_START]
    for byte in body:
        if byte in (PACKET_START, PACKET_END, PACKET_DLE):
            out.append(PACKET_DLE)
            out.append(byte ^ 0x20)
        else:
            out.append(byte)
    out.append(PACKET_END)
    return bytes(out)


def frame(command, payload, kind=None, error_code=0):
    """One byte-stuffed frame.

    `kind` defaults to the framing recorded for the command, so a fixture cannot
    silently use the wrong body layout. A response body is
    `command, error code, length, payload`; every other body is
    `command, length, payload`.
    """
    if kind is None:
        kind = frame_kind(command)
    body = [command]
    if kind == "response":
        body.append(error_code)
    body += list(struct.pack("<H", len(payload)))
    body += list(payload)
    return stuff(body)


def hexs(data):
    return data.hex()


# The framing recorded for each command this generator uses, from the same
# evidence the Swift classification records: the SDK's parsePenDataPacket case
# list, plus 0xA4, which the capture shows the pen accepting with an error code.
RESPONSE_COMMANDS = {
    0x81,  # RES_VERSION_INFO
    0xA1,  # RES1_OFFLINE_NOTE_LIST
    0xA2,  # RES2_OFFLINE_PAGE_LIST
    0xA3,  # RES1_OFFLINE_DATA_INFO
    0xA4,  # RES2_OFFLINE_DATA (the host's acknowledgement; no fixture frames one)
}
EVENT_COMMANDS = {
    0x24,  # REQ2_OFFLINE_DATA (the pen's data stream)
    0x63,  # EVENT_PEN_UPDOWN
    0x6B,  # EVENT_NEW_PEN_NEWID
    0x6C,  # EVENT_NEW_PEN_DOT
}


def frame_kind(command):
    """The framing recorded for a command."""
    if command in RESPONSE_COMMANDS:
        return "response"
    assert command in EVENT_COMMANDS, "unclassified command 0x%02X" % command
    return "event"


def packet_outcome(command, payload, kind=None, error_code=0):
    """An expected packet.

    A response packet declares the error code the pen reported; an event packet
    omits it, because an event body has no error-code position.
    """
    if kind is None:
        kind = frame_kind(command)
    outcome = {
        "kind": "packet",
        "commandByte": "0x%02X" % command,
        "payloadHex": hexs(bytes(payload)),
    }
    if kind == "response":
        outcome["errorCode"] = error_code
    return outcome


def error_outcome(kind):
    return {"kind": "error", "error": kind}


def text16(value):
    raw = value.encode("utf-8")
    return raw + b"\x00" * (16 - len(raw))


def text8(value):
    raw = value.encode("utf-8")
    return raw + b"\x00" * (8 - len(raw))


def version_info_payload(protocol_version="2.18"):
    payload = bytearray()
    payload += text16("Neo smartpen A1")
    payload += text16("1.0.0")
    payload += text8(protocol_version)
    payload += b"\x00" * 16
    payload += struct.pack("<H", 0x0001)
    payload += b"\x00" * 6  # sanitized Bluetooth address
    payload += b"\x00"  # FSR pressure sensor
    assert len(payload) == 65, len(payload)
    return bytes(payload)


# The version response the physical A1 sent on 2026-10-18, with the Bluetooth
# address field zeroed. It is the payload `a1-handshake-version-2.23` carries, so
# a fixture that opens with a handshake reports the same device facts as the
# capture rather than a reconstruction.
CAPTURED_VERSION_PAYLOAD_HEX = (
    "4e57502d463135310000000000000000"
    "332e3030000000000000000000000000"
    "322e323300000000"
    "4e656f736d61727470656e5f41310000"
    "0100"
    "000000000000"
    "04"
    "0000000000"
)


def captured_version_payload():
    payload = bytearray()
    payload += text16("NWP-F151")
    payload += text16("3.00")
    payload += text8("2.23")
    payload += text16("Neosmartpen_A1")
    payload += struct.pack("<H", 0x0001)
    payload += b"\x00" * 6  # sanitized Bluetooth address
    payload += bytes([0x04])  # FSR pressure sensor
    payload += b"\x00" * 5  # protocol 2.22+ compression capability byte is clear
    assert len(payload) == 70, len(payload)
    assert payload.hex() == CAPTURED_VERSION_PAYLOAD_HEX, payload.hex()
    return bytes(payload)


def note_list_payload(notes):
    """One 0xA1 note list: a count, then a section-owner id and note id per entry."""
    body = bytearray(struct.pack("<H", len(notes)))
    for section, owner, note in notes:
        body += struct.pack("<I", (section << 24) | owner)
        body += struct.pack("<I", note)
    assert len(body) == 2 + 8 * len(notes), len(body)
    return bytes(body)


def page_list_payload(section, owner, note, pages):
    """One 0xA2 page list: section-owner id, note id, count, then page ids."""
    body = bytearray(struct.pack("<I", (section << 24) | owner))
    body += struct.pack("<I", note)
    body += struct.pack("<H", len(pages))
    for page in pages:
        body += struct.pack("<I", page)
    assert len(body) == 10 + 4 * len(pages), len(body)
    return bytes(body)


def offline_info_payload(stroke_count, size, is_zip=0):
    """One 0xA3 offline data info summary: strokes, size, compression flag."""
    body = struct.pack("<I", stroke_count) + struct.pack("<I", size) + bytes([is_zip])
    assert len(body) == 9, len(body)
    return bytes(body)


def page_payload(section, owner, book, page, event_count=0):
    payload = bytearray([event_count])
    payload += struct.pack("<I", owner)[:3]
    payload += bytes([section])
    payload += struct.pack("<I", book)
    payload += struct.pack("<I", page)
    assert len(payload) == 13, len(payload)
    return bytes(payload)


def updown_payload(direction, time_ms, tip_type=0):
    payload = bytearray([direction])
    payload += struct.pack("<q", time_ms)
    payload += bytes([tip_type])
    payload += b"\x00\x00\x00\x00"
    assert len(payload) == 14, len(payload)
    return bytes(payload)


def dot_payload(delta, force, x_int, x_frac, y_int, y_frac, event_count=0, offline=False):
    payload = bytearray([event_count])
    payload += bytes([delta])
    payload += struct.pack("<H", force)
    payload += struct.pack("<H", x_int)
    payload += struct.pack("<H", y_int)
    payload += bytes([x_frac, y_frac, 90, 90])
    payload += struct.pack("<H", 0)
    assert len(payload) == 14, len(payload)
    if offline:
        body = bytearray(payload[1:]) + b"\x00\x00"
        body.append(sum(body) & 0xFF)
        assert len(body) == 16, len(body)
        return bytes(body)
    return bytes(payload)


def offline_stroke(page, down_time, up_time, dots):
    """One offline stroke record (27 bytes) followed by its 16-byte dots."""
    record = bytearray()
    record += struct.pack("<I", page)
    record += struct.pack("<q", down_time)
    record += struct.pack("<q", up_time)
    record += bytes([0])  # pen tip type
    record += b"\x00\x00\x00\x00"  # pen colour
    record += struct.pack("<H", len(dots))
    for dot in dots:
        record += dot
    assert len(record) == 27 + 16 * len(dots), len(record)
    return bytes(record)


# Transfer positions, from ResponseStruct.swift (OfflineTransPosition).
TRANSFER_START, TRANSFER_MIDDLE, TRANSFER_END = 0, 1, 2


def offline_payload(section, owner, book, strokes, packet_id, position):
    """One offline data packet: an 18-byte header followed by stroke records.

    The pen sends one of these per host acknowledgement, so a multi-packet
    fixture is a sequence of these with contiguous packet identifiers and
    positions start, middle*, end.
    """
    body = bytearray()
    for stroke in strokes:
        body += stroke

    header = bytearray()
    header += struct.pack("<H", packet_id)
    header += bytes([0])  # not compressed
    header += struct.pack("<H", len(body))  # size before compression
    header += struct.pack("<H", 0)  # size after compression: unused when uncompressed
    header += bytes([position])
    header += struct.pack("<I", owner)[:3]
    header += bytes([section])
    header += struct.pack("<I", book)
    header += struct.pack("<H", len(strokes))  # stroke count in this packet
    assert len(header) == 18, len(header)
    return bytes(header + body)


PROVENANCE = {
    "source": "Neo iOS SDK 3.0 (github.com/NeoSmartpen/iOS-SDK3.0)",
    "deviceModel": "A1 (F151)",
    "firmware": "unverified",
    "observedProtocolVersion": "2.18",
    "captureDate": "2026-10-18",
}

SANITIZATION = {
    "removed": [
        "bluetoothAddress",
        "serialNumber",
        "authenticationMaterial",
        "handwritingContent",
    ],
    "notes": (
        "Bluetooth address bytes are zeroed. Connection codes, serial numbers, "
        "and password material are absent. Coordinates are synthetic and do not "
        "reproduce personal handwriting."
    ),
}

# Provenance for the fixtures whose content comes from the physical A1 capture
# rather than from a synthetic reading of the SDK layouts.
CAPTURE_PROVENANCE = {
    "source": (
        "Physical A1 capture of 2026-10-18 (docs/protocol-a1.md) for the device "
        "facts, note identity, and summary values, re-encoded with the Neo iOS SDK "
        "3.0 offline list and info layouts"
    ),
    "deviceModel": "NWP-F151",
    "firmware": "3.00",
    "observedProtocolVersion": "2.23",
    "captureDate": "2026-10-18",
}

SECTION, OWNER, BOOK, PAGE = 3, 0x000ABC, 7, 12
DOWN_TIME = 1_700_000_000_000


def fixture(fixture_id, comment, chunks, expected, **extra):
    body = {
        "fixtureVersion": 1,
        "id": fixture_id,
        "evidenceLevel": "officialSDK",
        "provenance": PROVENANCE,
        "sanitization": SANITIZATION,
        "comment": comment,
        "chunks": chunks,
        "expected": expected,
    }
    body.update(extra)
    return body


def build():
    fixtures = []

    version_payload = version_info_payload()
    fixtures.append(
        fixture(
            "a1-version-info-2.18",
            "Version info response 0x81 reporting protocol 2.18 with a zeroed Bluetooth address.",
            [hexs(frame(0x81, version_payload))],
            [packet_outcome(0x81, version_payload)],
            expectedProtocolVersion="2.18",
        )
    )

    dots = [
        dot_payload(10, 512, 1000, 25, 500, 50),
        dot_payload(10, 600, 1001, 30, 501, 60),
        dot_payload(10, 700, 1002, 0, 502, 0),
        dot_payload(10, 800, 1003, 75, 503, 25),
    ]
    stroke_frames = [
        (0x81, version_payload),
        (0x6B, page_payload(SECTION, OWNER, BOOK, PAGE)),
        (0x63, updown_payload(0, DOWN_TIME)),
    ] + [(0x6C, dot) for dot in dots] + [(0x63, updown_payload(1, DOWN_TIME + 50))]
    fixtures.append(
        fixture(
            "a1-realtime-stroke",
            "Realtime down, four dots, and up on one page, preceded by version info.",
            [hexs(frame(command, payload)) for command, payload in stroke_frames],
            [packet_outcome(command, payload) for command, payload in stroke_frames],
            expectedProtocolVersion="2.18",
            expectedPage={
                "section": SECTION,
                "owner": OWNER,
                "book": BOOK,
                "page": PAGE,
            },
            expectedStrokeCount=1,
        )
    )

    offline_dots = [
        dot_payload(0, 500, 1000, 25, 500, 50, offline=True),
        dot_payload(15, 620, 1001, 30, 501, 60, offline=True),
        dot_payload(15, 740, 1002, 0, 502, 0, offline=True),
    ]
    offline = offline_payload(
        SECTION,
        OWNER,
        BOOK,
        [offline_stroke(PAGE, DOWN_TIME, DOWN_TIME + 30, offline_dots)],
        packet_id=1,
        position=TRANSFER_END,
    )
    # A single-packet transfer in the shape the pen sends: the data rides on
    # REQ2_OFFLINE_DATA (0x24). 0xA4 is the host's acknowledgement, never an
    # inbound data frame.
    offline_frames = [(0x81, version_payload), (0x24, offline)]
    fixtures.append(
        fixture(
            "a1-offline-stroke",
            "Offline data packet 0x24 carrying one stroke with three checksummed dots.",
            [hexs(frame(command, payload)) for command, payload in offline_frames],
            [packet_outcome(command, payload) for command, payload in offline_frames],
            expectedProtocolVersion="2.18",
            expectedPage={
                "section": SECTION,
                "owner": OWNER,
                "book": BOOK,
                "page": PAGE,
            },
            expectedStrokeCount=1,
        )
    )

    # A three-packet transfer in the shape the physical A1 sends: one packet per
    # acknowledgement, contiguous packet identifiers, and positions start, middle,
    # end. The data packets use the command the pen actually sends
    # (REQ2_OFFLINE_DATA, 0x24); 0xA4 is the host-side acknowledgement.
    multipacket_dots = [
        [TRANSFER_START, PAGE, [
            dot_payload(0, 500, 2000, 10, 900, 20, offline=True),
            dot_payload(12, 620, 2001, 15, 901, 25, offline=True),
        ]],
        [TRANSFER_MIDDLE, PAGE + 1, [
            dot_payload(0, 480, 2010, 40, 910, 60, offline=True),
            dot_payload(18, 560, 2011, 45, 911, 65, offline=True),
            dot_payload(18, 640, 2012, 50, 912, 70, offline=True),
        ]],
        [TRANSFER_END, PAGE + 2, [
            dot_payload(0, 520, 2020, 80, 920, 90, offline=True),
        ]],
    ]
    multipacket = [
        offline_payload(
            SECTION,
            OWNER,
            BOOK,
            [offline_stroke(page, DOWN_TIME + index * 1000, DOWN_TIME + index * 1000 + 25, dots)],
            packet_id=index,
            position=position,
        )
        for index, (position, page, dots) in enumerate(multipacket_dots, start=1)
    ]
    fixtures.append(
        fixture(
            "a1-offline-multipacket",
            "Three-packet offline transfer (start, middle, end) carried as "
            "REQ2_OFFLINE_DATA 0x24 packets with one stroke each.",
            [hexs(frame(0x24, payload)) for payload in multipacket],
            [packet_outcome(0x24, payload) for payload in multipacket],
            expectedPage={
                "section": SECTION,
                "owner": OWNER,
                "book": BOOK,
                "page": PAGE,
            },
            expectedStrokeCount=3,
        )
    )

    truncated = stuff([0x6C] + list(struct.pack("<H", 14)) + list(dots[0][:4]))
    fixtures.append(
        fixture(
            "a1-truncated-frame",
            "A frame that ends before its declared payload, followed by a valid frame.",
            [hexs(truncated + frame(0x81, version_payload))],
            [
                error_outcome("truncatedPacket"),
                packet_outcome(0x81, version_payload),
            ],
            expectedProtocolVersion="2.18",
        )
    )

    # A response body carries an error code between the command and the length,
    # so these hand-built frames place one there too.
    oversized = stuff([0x81, 0x00] + list(struct.pack("<H", 0x9000)) + [0, 0, 0, 0])
    # The valid version frame below is 69 buffered bytes (1 command + 1 error code
    # + 2 length + 65 payload), so the limit is set to that and the overflowing
    # frame carries more bytes than the limit.
    overflowing = stuff([0x81, 0x00] + list(struct.pack("<H", 200)) + [0] * 70)
    fixtures.append(
        fixture(
            "a1-size-limit-recovery",
            "An oversized declared payload and a frame that overflows the buffer, then a valid frame.",
            [
                hexs(oversized),
                hexs(overflowing + frame(0x81, version_payload)),
            ],
            [
                error_outcome("payloadExceedsLimit"),
                error_outcome("bufferedInputExceedsLimit"),
                packet_outcome(0x81, version_payload),
            ],
            limits={"maxPayloadBytes": 32000, "maxBufferedBytes": 69},
            expectedProtocolVersion="2.18",
        )
    )

    escaped_owner = 0x7DC1C0
    escaped_page = page_payload(SECTION, escaped_owner, BOOK, PAGE)
    escaped_frames = [(0x6B, escaped_page)]
    fixtures.append(
        fixture(
            "a1-escaped-page-identity",
            "A page identity whose owner bytes collide with the framing markers, so the wire bytes are escaped.",
            [hexs(frame(command, payload)) for command, payload in escaped_frames],
            [packet_outcome(command, payload) for command, payload in escaped_frames],
            expectedPage={
                "section": SECTION,
                "owner": escaped_owner,
                "book": BOOK,
                "page": PAGE,
            },
        )
    )

    # Offline discovery. The note identifiers come from the physical A1 capture
    # recorded in docs/protocol-a1.md: note 700, section 3, owner 27.
    SESSION_SECTION, SESSION_OWNER = 3, 27
    SESSION_NOTE, SESSION_NOTE_2 = 700, 701
    second_note = (SESSION_SECTION, SESSION_OWNER, SESSION_NOTE_2)

    note_list = note_list_payload(
        [
            (SESSION_SECTION, SESSION_OWNER, SESSION_NOTE),
            second_note,
        ]
    )
    fixtures.append(
        fixture(
            "a1-offline-note-list",
            "Offline note list 0xA1 reporting two requestable notes, one of them the note 700 the physical A1 capture read.",
            [hexs(frame(0xA1, note_list))],
            [packet_outcome(0xA1, note_list)],
        )
    )

    empty_note_list = note_list_payload([])
    fixtures.append(
        fixture(
            "a1-offline-note-list-empty",
            "Offline note list 0xA1 reporting no notes, so retrieval completes with zero counts.",
            [hexs(frame(0xA1, empty_note_list))],
            [packet_outcome(0xA1, empty_note_list)],
        )
    )

    # A list whose declared count exceeds the entries it carries. The frame's own
    # length stays consistent, so this is a list-shape failure rather than a
    # framing one: a decoder that trusted the count would read past the payload.
    truncated_note_list = struct.pack("<H", 2) + struct.pack("<I", (SESSION_SECTION << 24) | SESSION_OWNER) + struct.pack("<I", SESSION_NOTE)
    assert len(truncated_note_list) == 10, len(truncated_note_list)
    fixtures.append(
        fixture(
            "a1-offline-note-list-malformed",
            "Offline note list 0xA1 whose declared count exceeds the entries it carries, so no retrieval may follow.",
            [hexs(frame(0xA1, truncated_note_list))],
            [packet_outcome(0xA1, truncated_note_list)],
        )
    )

    page_list = page_list_payload(SESSION_SECTION, SESSION_OWNER, SESSION_NOTE, [1, 16])
    fixtures.append(
        fixture(
            "a1-offline-page-list",
            "Offline page list 0xA2 for the captured note 700, reporting pages 1 and 16.",
            [hexs(frame(0xA2, page_list))],
            [packet_outcome(0xA2, page_list)],
        )
    )

    data_info = offline_info_payload(6918, 1309538)
    fixtures.append(
        fixture(
            "a1-offline-data-info",
            "Offline data info 0xA3 carrying the lagging stroke and size summary the physical A1 reported.",
            [hexs(frame(0xA3, data_info))],
            [packet_outcome(0xA3, data_info)],
            provenance=CAPTURE_PROVENANCE,
        )
    )

    # The whole read path in the order the physical A1 trace used: handshake, note
    # list, page list, info, then one data packet per acknowledgement. Each packet
    # is its own chunk so a send-responsive transport can release them one at a
    # time. The 0xA3 summary deliberately under-reports, which is the lagging
    # index the capture recorded: the packet stream, not the summary, is
    # authoritative.
    session_pages = [1, 16, 17]
    session_transfer = [
        offline_payload(
            SESSION_SECTION,
            SESSION_OWNER,
            SESSION_NOTE,
            [
                offline_stroke(
                    page,
                    DOWN_TIME + index * 1000,
                    DOWN_TIME + index * 1000 + 25,
                    [
                        dot_payload(0, 500 + index * 20, 2000 + index, 10, 900 + index, 20, offline=True),
                        dot_payload(14, 620 + index * 20, 2001 + index, 15, 901 + index, 25, offline=True),
                    ],
                )
            ],
            packet_id=index,
            position=position,
        )
        for index, (position, page) in enumerate(
            zip([TRANSFER_START, TRANSFER_MIDDLE, TRANSFER_END], session_pages),
            start=1,
        )
    ]
    second_transfer = [
        offline_payload(
            SESSION_SECTION,
            SESSION_OWNER,
            SESSION_NOTE_2,
            [
                offline_stroke(
                    2,
                    DOWN_TIME + 5000,
                    DOWN_TIME + 5025,
                    [
                        dot_payload(0, 480, 2100, 40, 910, 60, offline=True),
                        dot_payload(18, 560, 2101, 45, 911, 65, offline=True),
                        dot_payload(18, 640, 2102, 50, 912, 70, offline=True),
                    ],
                )
            ],
            packet_id=1,
            position=TRANSFER_END,
        )
    ]

    session_frames = [
        (0x81, captured_version_payload()),
        (0xA1, note_list),
        (0xA2, page_list_payload(SESSION_SECTION, SESSION_OWNER, SESSION_NOTE, session_pages)),
        (0xA3, offline_info_payload(1, 964)),  # lags the three strokes that follow
    ] + [(0x24, payload) for payload in session_transfer] + [
        (0xA2, page_list_payload(SESSION_SECTION, SESSION_OWNER, SESSION_NOTE_2, [2])),
        (0xA3, offline_info_payload(1, 300)),
    ] + [(0x24, payload) for payload in second_transfer]
    fixtures.append(
        fixture(
            "a1-offline-session",
            "The whole offline read path in trace order: the captured 2.23 handshake, a "
            "two-note list, each note's page list and info, and one 0x24 packet per "
            "acknowledgement, with the 0xA3 summary lagging the packet stream.",
            [hexs(frame(command, payload)) for command, payload in session_frames],
            [packet_outcome(command, payload) for command, payload in session_frames],
            provenance=CAPTURE_PROVENANCE,
            expectedProtocolVersion="2.23",
            expectedPage={
                "section": SESSION_SECTION,
                "owner": SESSION_OWNER,
                "book": SESSION_NOTE,
                "page": session_pages[0],
            },
            expectedStrokeCount=4,
        )
    )

    for body in fixtures:
        path = os.path.join(HERE, body["id"] + ".json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(body, handle, indent=2, sort_keys=True)
            handle.write("\n")
        print("wrote", path)


if __name__ == "__main__":
    build()
