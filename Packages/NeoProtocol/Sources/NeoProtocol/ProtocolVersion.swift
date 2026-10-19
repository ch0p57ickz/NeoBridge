/// A Neo pen protocol version.
public struct ProtocolVersion: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    /// Major version. The A1 family is major version 2.
    public let major: Int

    /// Minor version.
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Parses a version string such as `"2.18"`.
    ///
    /// The pen pads its version field with NUL bytes, so NULs and surrounding
    /// whitespace are ignored.
    ///
    /// - Parameter string: The raw version text.
    public init?(_ string: String) {
        let trimmed = string
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              major >= 0,
              minor >= 0
        else {
            return nil
        }
        self.init(major: major, minor: minor)
    }

    public var description: String {
        "\(major).\(minor)"
    }

    public static func < (lhs: ProtocolVersion, rhs: ProtocolVersion) -> Bool {
        lhs.major == rhs.major ? lhs.minor < rhs.minor : lhs.major < rhs.major
    }
}

/// Whether the decoder supports an observed protocol version.
public enum ProtocolVersionSupport: Hashable, Sendable {
    /// The version is in the supported family and its minor version is
    /// validated by evidence.
    case supported(ProtocolVersion)

    /// The version is outside the supported family or its minor version has no
    /// evidence yet.
    case unsupported(ProtocolVersion)

    /// No version has been observed.
    case unknown

    /// The supported version, when there is one.
    public var version: ProtocolVersion? {
        switch self {
        case .supported(let version), .unsupported(let version):
            return version
        case .unknown:
            return nil
        }
    }

    /// Whether the version may be used for production decoding.
    public var isSupported: Bool {
        if case .supported = self {
            return true
        }
        return false
    }
}

/// Decides which protocol versions this build supports.
///
/// The A1-capable SDKs use the Neo pen protocol 2.x family. A minor version is
/// supported only when evidence names it: either official SDK wire evidence or a
/// physical A1 capture recorded in `docs/protocol-a1.md`.
public struct ProtocolVersionPolicy: Hashable, Sendable {
    /// The protocol family this package targets.
    public static let familyMajor = 2

    /// The default policy.
    ///
    /// The name follows the package's other `neoSDK3` defaults, which build on the
    /// Neo iOS SDK 3.0 command table. This policy also carries the minor a
    /// physical A1 reported, so it is not purely SDK-derived.
    public static let neoSDK3 = ProtocolVersionPolicy()

    /// Minor versions with wire evidence.
    ///
    /// Provenance, one line per minor:
    ///
    /// - `18`: the protocol version the official Neo iOS SDK 3.0 declares in its
    ///   `VERSION_INFO` request. That is a host-declared value rather than one a
    ///   pen reported, so it records what the SDK's wire format covers.
    /// - `23`: the protocol version a physical A1 reported in its version
    ///   response on 2026-10-18 (model `NWP-F151`, firmware `3.00`), recorded in
    ///   `docs/protocol-a1.md` and carried by the `a1-handshake-version-2.23`
    ///   fixture.
    ///
    /// A minor above the highest entry is not supported by being newer: a version
    /// is supported only when the evidence names it.
    public let validatedMinors: Set<Int>

    public init(validatedMinors: Set<Int> = [18, 23]) {
        self.validatedMinors = validatedMinors
    }

    /// Returns the support level for an observed version.
    public func support(for version: ProtocolVersion?) -> ProtocolVersionSupport {
        guard let version else {
            return .unknown
        }
        guard version.major == Self.familyMajor, validatedMinors.contains(version.minor) else {
            return .unsupported(version)
        }
        return .supported(version)
    }
}
