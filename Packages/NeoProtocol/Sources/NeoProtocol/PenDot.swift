import NeoCore

/// A decoded pen dot.
///
/// Wire layout from Neo iOS SDK 3.0 `ResponseStruct.swift` (`Dot`):
/// `nTimeDelta` (1), raw pressure (2), x integer (2), y integer (2), x
/// hundredths (1), y hundredths (1), x tilt (1), y tilt (1), twist (2). The
/// offline variant appends two reserved bytes and a checksum byte.
struct PenDot {
    /// Milliseconds since the previous dot on the pen clock.
    let timeDeltaMilliseconds: UInt8

    /// The sample in the A1's split integer plus hundredths coordinates.
    let sample: RawPenSample

    /// x tilt in degrees.
    let xTilt: UInt8

    /// y tilt in degrees.
    let yTilt: UInt8

    /// Pen twist.
    let twist: UInt16

    /// The pen's event count, present on payloads with a leading event byte.
    let eventCount: UInt8?

    /// Realtime payload sizes: 13 bytes, or 14 with a leading event count.
    static let realtimePayloadBytes = 13

    /// Offline payload size: 13 bytes, two reserved bytes, and a checksum.
    static let offlinePayloadBytes = 16

    init?(payload: [UInt8]) {
        var body = payload
        var eventCount: UInt8?
        if body.count == Self.realtimePayloadBytes + 1 {
            eventCount = body.removeFirst()
        }

        guard body.count == Self.realtimePayloadBytes || body.count == Self.offlinePayloadBytes else {
            return nil
        }

        if body.count == Self.offlinePayloadBytes {
            let expected = PenWire.checksum(body[0..<15])
            guard body[15] == expected else {
                return nil
            }
        }

        timeDeltaMilliseconds = body[0]
        xTilt = body[9]
        yTilt = body[10]
        twist = PenWire.uint16(body, at: 11)
        self.eventCount = eventCount

        sample = RawPenSample(
            integerX: PenWire.uint16(body, at: 3),
            hundredthsX: body[7],
            integerY: PenWire.uint16(body, at: 5),
            hundredthsY: body[8],
            penTimeOffsetMilliseconds: 0,
            pressure: PenWire.uint16(body, at: 1)
        )
    }
}

/// A pen up/down event (`0x63`).
///
/// Wire layout: direction (1), pen time in milliseconds (8), pen tip type (1),
/// pen colour (4).
struct PenUpDownEvent {
    /// Pen direction codes. Values come from the SDK's `DotType`.
    enum Direction: UInt8 {
        case down = 0
        case up = 1
        case move = 2
    }

    let direction: Direction
    let timeMilliseconds: Int64
    let tipType: UInt8

    static let payloadBytes = 14

    init?(payload: [UInt8]) {
        guard payload.count >= Self.payloadBytes,
              let direction = Direction(rawValue: payload[0])
        else {
            return nil
        }
        self.direction = direction
        timeMilliseconds = PenWire.int64(payload, at: 1)
        tipType = payload[9]
    }
}

/// A pen down event (`0x69`).
///
/// Wire layout: event count (1), pen time in milliseconds (8), pen tip type (1),
/// pen colour (4).
struct PenDownEvent {
    let eventCount: UInt8
    let timeMilliseconds: Int64
    let tipType: UInt8

    static let payloadBytes = 14

    init?(payload: [UInt8]) {
        guard payload.count >= Self.payloadBytes else {
            return nil
        }
        eventCount = payload[0]
        timeMilliseconds = PenWire.int64(payload, at: 1)
        tipType = payload[9]
    }
}

/// A pen up event (`0x6A`).
///
/// Wire layout: event count (1), pen time in milliseconds (8), then five 16-bit
/// counters.
struct PenUpEvent {
    let eventCount: UInt8
    let timeMilliseconds: Int64
    let dotCount: UInt16

    static let payloadBytes = 19

    init?(payload: [UInt8]) {
        guard payload.count >= Self.payloadBytes else {
            return nil
        }
        eventCount = payload[0]
        timeMilliseconds = PenWire.int64(payload, at: 1)
        dotCount = PenWire.uint16(payload, at: 9)
    }
}
