import Crypto
import Foundation

/// A stable identifier for the replay identity of a stroke.
public struct StrokeFingerprint: Hashable, Sendable, Codable {
    /// The canonical encoding version used to produce the digest.
    public let encodingVersion: UInt8

    /// Lowercase hexadecimal SHA-256 digest of the canonical bytes.
    public let hexDigest: String

    /// Whether this fingerprint may be used to deduplicate across sources.
    ///
    /// A stroke without a reliable pen-origin start time is preserved but must
    /// not be collapsed with a stroke from another source.
    public let allowsCrossSourceDeduplication: Bool

    public init(encodingVersion: UInt8, hexDigest: String, allowsCrossSourceDeduplication: Bool) {
        self.encodingVersion = encodingVersion
        self.hexDigest = hexDigest
        self.allowsCrossSourceDeduplication = allowsCrossSourceDeduplication
    }
}

/// Derives replay-safe stroke fingerprints.
public enum StrokeIdentity {
    /// Computes the fingerprint of a completed stroke.
    ///
    /// The digest covers the full page tuple, the pen-origin start time, and the
    /// ordered normalized points. It excludes host arrival time, live/offline
    /// source, and transport chunking, so the same physical stroke produces the
    /// same digest from live and offline input.
    public static func fingerprint(of stroke: Stroke) -> StrokeFingerprint {
        let bytes = CanonicalStrokeEncoding.encode(stroke)
        let digest = SHA256.hash(data: bytes)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return StrokeFingerprint(
            encodingVersion: CanonicalStrokeEncoding.version,
            hexDigest: hex,
            allowsCrossSourceDeduplication: stroke.originTime.isReliable
        )
    }

    /// Computes the fingerprint of a stroke that the assembler retained without
    /// an up event.
    ///
    /// The digest is computed the same way, but the result is never marked as
    /// safe for cross-source deduplication, because an unfinished stroke may
    /// still gain points.
    public static func fingerprint(ofIncomplete stroke: Stroke) -> StrokeFingerprint {
        let fingerprint = fingerprint(of: stroke)
        return StrokeFingerprint(
            encodingVersion: fingerprint.encodingVersion,
            hexDigest: fingerprint.hexDigest,
            allowsCrossSourceDeduplication: false
        )
    }
}
