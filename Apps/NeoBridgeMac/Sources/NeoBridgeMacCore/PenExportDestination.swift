import Foundation

/// Supplies the directory exports are published into.
///
/// The app resolves a folder the user chose; the portable publisher only ever
/// receives a resolved path. Keeping the two apart is what lets export be tested
/// on Linux without a security scope.
@MainActor
public protocol PenExportDestinationProviding {
    /// Whether a folder has been chosen.
    var isConfigured: Bool { get }

    /// The directory to publish into, or `nil` when none has been chosen.
    func exportDirectory() -> String?

    /// Stores a folder the user chose.
    func setExportDirectory(_ url: URL) throws
}

/// The user's chosen export folder, reached through a security-scoped bookmark.
///
/// The bookmark is stored in `UserDefaults`, so the folder survives a relaunch and
/// keeps working when the app is sandboxed later. Resolving it starts the security
/// scope, which is what lets the portable publisher write there.
@MainActor
public final class BookmarkedExportDestination: PenExportDestinationProviding {
    /// The `UserDefaults` key the bookmark is stored under.
    public static let bookmarkDefaultsKey = "NeoBridge.exportFolderBookmark"

    private let defaults: UserDefaults
    private var accessed: URL?

    /// Creates a destination backed by stored bookmark data.
    ///
    /// - Parameter defaults: The defaults to read and write. Tests pass a suite of
    ///   their own so they never touch the user's.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        // The scope is released on the next resolve or when the object goes away.
        accessed?.stopAccessingSecurityScopedResource()
    }

    public var isConfigured: Bool {
        defaults.data(forKey: Self.bookmarkDefaultsKey) != nil
    }

    /// Stores a folder, replacing any earlier choice.
    ///
    /// - Parameter url: The folder the user chose.
    /// - Throws: When the bookmark cannot be created, so the app never reports a
    ///   folder it cannot reopen.
    public func setExportDirectory(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: Self.bookmarkDefaultsKey)
        stopAccessing()
        accessed = url
        _ = url.startAccessingSecurityScopedResource()
    }

    public func exportDirectory() -> String? {
        guard let data = defaults.data(forKey: Self.bookmarkDefaultsKey) else { return nil }

        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        else {
            return nil
        }

        if isStale, let refreshed = try? url.bookmarkData(options: .withSecurityScope) {
            defaults.set(refreshed, forKey: Self.bookmarkDefaultsKey)
        }

        if accessed?.path != url.path {
            stopAccessing()
            // A false result means there is no security scope to hold, which is
            // the case outside a sandbox; the path is still usable.
            _ = url.startAccessingSecurityScopedResource()
            accessed = url
        }
        return url.path
    }

    /// Releases the security scope the last resolve started.
    public func stopAccessing() {
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
    }
}

/// An export folder fixed at launch, for the headless acceptance run.
///
/// The acceptance run cannot open a folder picker, so it takes the directory from
/// the environment instead. The bookmark path is what the interface uses.
@MainActor
public final class FixedExportDestination: PenExportDestinationProviding {
    /// The directory to publish into.
    public private(set) var directory: String

    public init(directory: String) {
        self.directory = directory
    }

    public var isConfigured: Bool { true }

    public func exportDirectory() -> String? { directory }

    public func setExportDirectory(_ url: URL) throws {
        directory = url.path
    }
}

/// A destination that has no folder, used when the app is asked to store only.
@MainActor
public struct NoExportDestination: PenExportDestinationProviding {
    public init() {}

    public var isConfigured: Bool { false }

    public func exportDirectory() -> String? { nil }

    public func setExportDirectory(_ url: URL) throws {}
}
