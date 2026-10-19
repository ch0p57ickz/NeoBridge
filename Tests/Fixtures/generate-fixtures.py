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


def frame(command, payload):
    body = [command] + list(struct.pack("<H", len(payload))) + list(payload)
    return stuff(body)


def hexs(data):
    return data.hex()


def packet_outcome(command, payload):
    return {
        "kind": "packet",
        "commandByte": "0x%02X" % command,
        "payloadHex": hexs(bytes(payload)),
    }


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


def offline_payload(section, owner, book, page, down_time, up_time, dots):
    strokes = bytearray()
    strokes += struct.pack("<I", page)
    strokes += struct.pack("<q", down_time)
    strokes += struct.pack("<q", up_time)
    strokes += bytes([0])  # pen tip type
    strokes += b"\x00\x00\x00\x00"  # pen colour
    strokes += struct.pack("<H", len(dots))
    for dot in dots:
        strokes += dot
    assert len(strokes) == 27 + 16 * len(dots), len(strokes)

    header = bytearray()
    header += struct.pack("<H", 1)  # packet id
    header += bytes([0])  # not compressed
    header += struct.pack("<H", len(strokes))  # size before compression
    header += struct.pack("<H", len(strokes))  # size after compression
    header += bytes([2])  # transfer position: end
    header += struct.pack("<I", owner)[:3]
    header += bytes([section])
    header += struct.pack("<I", book)
    header += struct.pack("<H", 1)  # stroke count
    assert len(header) == 18, len(header)
    return bytes(header + strokes)


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
    offline = offline_payload(SECTION, OWNER, BOOK, PAGE, DOWN_TIME, DOWN_TIME + 30, offline_dots)
    offline_frames = [(0x81, version_payload), (0xA4, offline)]
    fixtures.append(
        fixture(
            "a1-offline-stroke",
            "Offline data packet 0xA4 carrying one stroke with three checksummed dots.",
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

    oversized = stuff([0x81] + list(struct.pack("<H", 0x9000)) + [0, 0, 0, 0])
    # The valid version frame below is 68 buffered bytes (1 command + 2 length +
    # 65 payload), so the limit is set to that and the overflowing frame carries
    # one more byte than the limit.
    overflowing = stuff([0x81] + list(struct.pack("<H", 200)) + [0] * 70)
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
            limits={"maxPayloadBytes": 32000, "maxBufferedBytes": 68},
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
