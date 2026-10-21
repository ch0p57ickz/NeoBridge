import Foundation
import NeoProtocol

/// One frame as the pen sent it, with the fields already split.
struct PenLabFrame: Equatable {
    /// The command identifier.
    let command: UInt8

    /// The error code, for a frame whose framing has one.
    let errorCode: UInt8?

    /// The payload, or the bytes after the command when the framing is not
    /// established.
    let payload: [UInt8]

    /// Whether the evidence table classified this frame's framing. An unclassified
    /// identifier cannot be split, so its bytes are kept whole and the transcript
    /// says so rather than guessing where a length field starts.
    let framingIsFromEvidence: Bool

    /// The frame's body exactly as it arrived, after unescaping and before the
    /// fields were split.
    ///
    /// The transcript records this rather than a rebuild from the parsed fields: a
    /// rebuilt frame would hide a declared length that disagrees with the bytes that
    /// followed it, which is precisely what the framing evidence has to show.
    let bodyHex: String

    /// The length field the frame declared, or `nil` when the table does not
    /// classify the identifier and there is no known length position.
    let declaredLength: Int?

    /// Whether the body was shorter than the length it declared.
    ///
    /// A truncated frame means the bytes were cut short in transit or while the
    /// chunks were collected, so its payload is not a complete answer.
    var isTruncated: Bool {
        guard let declaredLength else { return false }
        return declaredLength > payload.count
    }
}

/// The frame codec this experiment needs, and why it is not the portable one.
///
/// `PenFrameEncoder` refuses `0x25` and `0x27` on purpose: `PenCommand.frameKind`
/// returns `nil` for both, so no production caller can invent a layout for them, and
/// `PenSessionTests` pins that absence. The deletion evidence the gate waits for can
/// only come from sending them, so this file builds those two frames from the
/// layouts the official SDK documents and leaves the evidence table untouched.
///
/// Their answers are a different case: `0xA5` and `0xA7` are classified as responses
/// by the evidence table, because the SDK parses both with an error code, so the
/// inbound side is split from the table rather than from a local guess.
///
/// The framing rules are the ones `docs/protocol-a1.md` records and the ones the
/// physical A1 was captured speaking:
///
/// - a frame is `0xC0`, a body, and `0xC1`;
/// - a body byte that is `0xC0`, `0xC1`, or `0x7D` travels as `0x7D` followed by
///   the byte with `0x20` toggled;
/// - a request body is the command, a little-endian `UInt16` length, and the
///   payload;
/// - a response body is the command, an error code, the length, and the payload;
/// - every multi-byte field is little-endian.
///
/// The two requests come from Neo iOS SDK 3.0
/// (`NISDK3/Classes/Model/RequestStruct.swift`), which is also where the scope
/// question is answered: `0x25` takes a list of notes, and `0x27` takes one note and
/// a list of pages. Neither takes a page range.
enum PenLabFrames {
    /// The byte that opens a frame.
    static let start: UInt8 = 0xC0

    /// The byte that closes a frame.
    static let end: UInt8 = 0xC1

    /// The byte that escapes a body byte worth escaping.
    static let escape: UInt8 = 0x7D

    /// The commands whose response payload this experiment records.
    ///
    /// Every other inbound frame is recorded by size and identifier only, because
    /// the version response carries the pen's Bluetooth address. The two deletion
    /// answers carry a count and the identifiers the pen removed, which is the
    /// evidence under experiment and contains no device identity.
    static let recordedResponseCommands: Set<UInt8> = [0xA5, 0xA7]

    // MARK: - Building

    /// Builds one request frame.
    static func request(command: UInt8, payload: [UInt8]) -> [UInt8] {
        var body: [UInt8] = [command]
        body.append(contentsOf: littleEndian16(UInt16(payload.count)))
        body.append(contentsOf: payload)
        return framed(body)
    }

    /// Builds a response frame, which is only needed by tests.
    static func response(command: UInt8, errorCode: UInt8, payload: [UInt8]) -> [UInt8] {
        var body: [UInt8] = [command, errorCode]
        body.append(contentsOf: littleEndian16(UInt16(payload.count)))
        body.append(contentsOf: payload)
        return framed(body)
    }

    /// Wraps a body in the start marker, the escaped bytes, and the end marker.
    static func framed(_ body: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [start]
        for byte in body {
            if byte == start || byte == end || byte == escape {
                frame.append(escape)
                frame.append(byte ^ 0x20)
            } else {
                frame.append(byte)
            }
        }
        frame.append(end)
        return frame
    }

    /// A request body naming the notes one `0x25` command removes.
    ///
    /// The layout is the SDK's `REQ.DeleteOfflineDataNote`: a section and owner
    /// packed into one value, a count, and the note identifiers.
    static func deleteNoteRequest(
        section: UInt8,
        owner: UInt32,
        notes: [UInt32]
    ) -> [UInt8] {
        precondition(notes.count <= Int(UInt8.max), "0x25 carries its note count in one byte")
        var payload = littleEndian32(sectionOwnerId(section: section, owner: owner))
        payload.append(UInt8(notes.count))
        for note in notes {
            payload.append(contentsOf: littleEndian32(note))
        }
        return request(command: PenLabCommand.deleteNote, payload: payload)
    }

    /// A request body naming the pages of one note that `0x27` removes.
    ///
    /// The layout is the SDK's `REQ.DeleteOfflineDataPage`: a section and owner, the
    /// note identifier, a count, and the page identifiers.
    static func deletePageRequest(
        section: UInt8,
        owner: UInt32,
        note: UInt32,
        pages: [UInt32]
    ) -> [UInt8] {
        precondition(pages.count <= Int(UInt8.max), "0x27 carries its page count in one byte")
        var payload = littleEndian32(sectionOwnerId(section: section, owner: owner))
        payload.append(contentsOf: littleEndian32(note))
        payload.append(UInt8(pages.count))
        for page in pages {
            payload.append(contentsOf: littleEndian32(page))
        }
        return request(command: PenLabCommand.deletePage, payload: payload)
    }

    /// The value `0x25`, `0x27`, and `0x23` all pack a section and owner into.
    static func sectionOwnerId(section: UInt8, owner: UInt32) -> UInt32 {
        (UInt32(section) << 24) | (owner & 0x00FF_FFFF)
    }

    /// A little-endian pair of bytes.
    static func littleEndian16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    /// A little-endian run of four bytes.
    static func littleEndian32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    // MARK: - Reading

    /// The identifiers a deletion response enumerates.
    ///
    /// The SDK's parser reads the payload as a count followed by that many
    /// little-endian identifiers. A payload that does not have that shape returns
    /// `nil`, so a caller records the mismatch instead of inventing a reading.
    static func deletedIdentifiers(in payload: [UInt8]) -> [UInt32]? {
        guard let count = payload.first else { return nil }
        let identifiers = payload.dropFirst()
        guard identifiers.count == Int(count) * 4 else { return nil }
        var values: [UInt32] = []
        values.reserveCapacity(Int(count))
        for index in 0 ..< Int(count) {
            let start = identifiers.startIndex + index * 4
            let bytes = Array(identifiers[start ..< start + 4])
            values.append(
                UInt32(bytes[0])
                    | (UInt32(bytes[1]) << 8)
                    | (UInt32(bytes[2]) << 16)
                    | (UInt32(bytes[3]) << 24)
            )
        }
        return values
    }

    /// Extracts every complete frame from a run of inbound bytes.
    ///
    /// The whole run is parsed at once rather than chunk by chunk: a deletion
    /// experiment exchanges a handful of frames, so there is no need for the
    /// incremental decoder the read path uses, and a pure function is easier to test
    /// than a streaming one.
    static func extract(from bytes: [UInt8]) -> [PenLabFrame] {
        var frames: [PenLabFrame] = []
        var body: [UInt8] = []
        var isInFrame = false
        var isEscaped = false

        for byte in bytes {
            if isEscaped {
                body.append(byte ^ 0x20)
                isEscaped = false
                continue
            }
            switch byte {
            case start:
                body.removeAll()
                isInFrame = true
            case end:
                if isInFrame, let frame = frame(from: body) {
                    frames.append(frame)
                }
                body.removeAll()
                isInFrame = false
            case escape:
                if isInFrame {
                    isEscaped = true
                }
            default:
                if isInFrame {
                    body.append(byte)
                }
            }
        }
        return frames
    }

    /// Splits one frame body into its fields.
    ///
    /// The evidence table decides the framing wherever it has an answer, which
    /// includes both deletion responses. An identifier the table does not classify
    /// keeps its bytes whole, so a frame from an unvalidated command is recorded
    /// rather than mis-parsed as a payload.
    static func frame(from body: [UInt8]) -> PenLabFrame? {
        guard let command = body.first else { return nil }

        guard let kind = PenCommand(rawValue: command)?.frameKind else {
            return PenLabFrame(
                command: command,
                errorCode: nil,
                payload: Array(body.dropFirst()),
                framingIsFromEvidence: false,
                bodyHex: hex(body),
                declaredLength: nil
            )
        }

        let lengthIndex = kind == .response ? 2 : 1
        guard body.count >= lengthIndex + 2 else { return nil }
        let length = Int(body[lengthIndex]) | (Int(body[lengthIndex + 1]) << 8)
        let payloadStart = lengthIndex + 2
        let payload = Array(body[payloadStart ..< min(body.count, payloadStart + length)])
        return PenLabFrame(
            command: command,
            errorCode: kind == .response ? body[1] : nil,
            payload: payload,
            framingIsFromEvidence: true,
            bodyHex: hex(body),
            declaredLength: length
        )
    }

    // MARK: - Rendering

    /// A run of bytes as one hexadecimal string.
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}

/// The command identifiers this experiment sends.
enum PenLabCommand {
    /// `REQ_DEL_OFFLINE_DATA_NOTE`
    static let deleteNote: UInt8 = 0x25

    /// `REQ_DEL_OFFLINE_DATA_PAGE`
    static let deletePage: UInt8 = 0x27

    /// `RES_DEL_OFFLINE_DATA_NOTE`
    static let deleteNoteResponse: UInt8 = 0xA5

    /// `RES_DEL_OFFLINE_DATA_PAGE`
    static let deletePageResponse: UInt8 = 0xA7
}
