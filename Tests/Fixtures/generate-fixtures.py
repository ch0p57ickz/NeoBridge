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

    for body in fixtures:
        path = os.path.join(HERE, body["id"] + ".json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(body, handle, indent=2, sort_keys=True)
            handle.write("\n")
        print("wrote", path)


if __name__ == "__main__":
    build()
