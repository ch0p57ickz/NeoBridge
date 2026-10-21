import Foundation
import NeoCore

/// What opening a library did, and whether its deleting route is available.
///
/// The report is the honest shape of an upgrade: which schema was found, whether
/// a pre-migration backup was written, and whether the deleting-transfer route
/// may be used. A build that could not back the database up before upgrading it
/// keeps the deleting route closed rather than risking data it could not copy.
public struct PenLibraryOpenReport: Hashable, Sendable {
    /// The schema version this library is now reading and writing.
    public let schemaVersion: Int

    /// The schema version the file held before this open, when it was upgraded.
    ///
    /// The number is the version the file *recorded*, which is not always the shape it
    /// actually had: a file that recorded the current version without the columns that
    /// version implies is repaired here and reported as that same version, so the
    /// report can name one version twice. A file with no version row is reported as the
    /// version whose table shape it had, because that is the shape the upgrade migrated
    /// from. A file that already carried the current shape is not reported as migrated
    /// at all, even though its version is rewritten.
    public let migratedFrom: Int?

    /// The pre-migration backup's path, when one was written.
    public let backupPath: String?

    /// Whether the deleting-transfer route may be used in this library.
    public let deletingReadsAllowed: Bool

    /// Why the deleting route is closed, or `nil` when it is open.
    public let deletingReadsUnavailableReason: String?

    public init(
        schemaVersion: Int,
        migratedFrom: Int? = nil,
        backupPath: String? = nil,
        deletingReadsAllowed: Bool,
        deletingReadsUnavailableReason: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.migratedFrom = migratedFrom
        self.backupPath = backupPath
        self.deletingReadsAllowed = deletingReadsAllowed
        self.deletingReadsUnavailableReason = deletingReadsUnavailableReason
    }
}

/// A portable SQLite library of pages, strokes, import batches, and cleanup
/// journal entries.
///
/// The library owns one connection and serializes every operation through its
/// actor, so a write transaction never interleaves with another write. It runs in
/// WAL mode, which keeps a reader (an export) from blocking a writer (an import)
/// and survives an interrupted process without a repair step.
///
/// Identity is `(section, owner, book, page)`; a stroke is identified by the
/// canonical SHA-256 fingerprint of its page, origin time, and ordered points. A
/// stroke whose origin time is not reliable is stored without a deduplication
/// constraint, so a replay cannot collapse two different marks into one.
///
/// The library is also the deleting transfer's storage barrier: a packet's
/// strokes, progress, and end marker are committed in one transaction, and
/// `synchronous = FULL` with WAL means the commit has returned only after a
/// durable sync, which is what lets the session acknowledge a packet safely.
public actor SQLitePenLibrary: PenStrokeStore, PenImportBatchStore, PenCleanupJournal,
    PenDeletingPacketBarrier
{
    /// The schema version this build writes and understands.
    public static let schemaVersion = 2

    /// The schema version that introduced the streaming import tables.
    public static let streamingSchemaVersion = 2

    /// What opening this library did.
    public nonisolated let openReport: PenLibraryOpenReport

    private let connection: SQLiteConnection
    private let faultInjection: (@Sendable (Int) throws -> Void)?
    private let packetFaultInjection: (@Sendable (Int) throws -> Void)?

    /// Whether the file holds the streaming tables and columns.
    private let hasStreamingSchema: Bool

    /// Whether this configuration allows the deleting-transfer route.
    private let deletingReadsEnabled: Bool

    /// Opens or creates a library.
    ///
    /// - Parameters:
    ///   - path: The database file path, or `:memory:` for a throwaway library.
    ///   - deletingReadsEnabled: Whether the deleting-transfer route may be used.
    ///     A rollback configuration sets this to `false` while still reading and
    ///     exporting the batches a newer build stored.
    ///   - faultInjection: A test seam called with each stroke's index just
    ///     before it is written, so a test can prove that a failed import leaves
    ///     the library untouched. Production callers leave it `nil`.
    ///   - packetFaultInjection: A test seam called with the packet's index just
    ///     before a deleting packet's transaction commits, so a test can prove
    ///     that a failed commit acknowledges nothing. Production callers leave it
    ///     `nil`.
    ///   - backupFaultInjection: A test seam called just before a pre-migration
    ///     backup, so a test can prove that a failed backup leaves the original
    ///     untouched. Production callers leave it `nil`.
    /// - Throws: `StorageError` when the file cannot be opened or its schema is
    ///   newer than this build.
    public init(
        path: String,
        deletingReadsEnabled: Bool = true,
        faultInjection: (@Sendable (Int) throws -> Void)? = nil,
        packetFaultInjection: (@Sendable (Int) throws -> Void)? = nil,
        backupFaultInjection: (@Sendable () throws -> Void)? = nil
    ) throws {
        let connection = try SQLiteConnection(path: path)
        self.connection = connection
        self.faultInjection = faultInjection
        self.packetFaultInjection = packetFaultInjection
        try Self.configure(connection)

        let upgrade = try Self.upgrade(
            connection: connection,
            path: path,
            backupFaultInjection: backupFaultInjection
        )
        self.hasStreamingSchema = upgrade.hasStreamingSchema
        self.deletingReadsEnabled = deletingReadsEnabled

        let allowed = deletingReadsEnabled && upgrade.hasStreamingSchema
        self.openReport = PenLibraryOpenReport(
            schemaVersion: upgrade.schemaVersion,
            migratedFrom: upgrade.migratedFrom,
            backupPath: upgrade.backupPath,
            deletingReadsAllowed: allowed,
            deletingReadsUnavailableReason: allowed
                ? nil
                : (upgrade.unavailableReason
                    ?? "this configuration disables the deleting-transfer route")
        )
    }

    /// Opens or creates a library at a file URL, creating its directory.
    ///
    /// - Parameters:
    ///   - url: The database file URL.
    ///   - deletingReadsEnabled: Whether the deleting-transfer route may be used.
    ///   - faultInjection: A test seam, as in ``init(path:deletingReadsEnabled:faultInjection:packetFaultInjection:backupFaultInjection:)``.
    ///   - packetFaultInjection: A test seam, as above.
    ///   - backupFaultInjection: A test seam, as above.
    public init(
        url: URL,
        deletingReadsEnabled: Bool = true,
        faultInjection: (@Sendable (Int) throws -> Void)? = nil,
        packetFaultInjection: (@Sendable (Int) throws -> Void)? = nil,
        backupFaultInjection: (@Sendable () throws -> Void)? = nil
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try self.init(
            path: url.path,
            deletingReadsEnabled: deletingReadsEnabled,
            faultInjection: faultInjection,
            packetFaultInjection: packetFaultInjection,
            backupFaultInjection: backupFaultInjection
        )
    }

    // MARK: - Schema

    /// What one open did to the file.
    private struct Upgrade {
        var schemaVersion: Int
        var migratedFrom: Int?
        var backupPath: String?
        var hasStreamingSchema: Bool
        var unavailableReason: String?
    }

    /// Applies the connection settings the library relies on.
    private static func configure(_ connection: SQLiteConnection) throws {
        // WAL survives an interrupted writer and lets a reader run alongside a
        // writer. It needs a real file, so an in-memory library stays in the
        // default journal mode.
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA synchronous = FULL")
    }

    /// The schema version recorded in the file, or `nil` for a file that records
    /// none.
    ///
    /// - Throws: `StorageError.unreadableSchemaVersion` when the recorded value is
    ///   not a number. Treating unreadable text as version `0` would take the
    ///   legacy path over a schema this build cannot identify.
    private static func recordedVersion(_ connection: SQLiteConnection) throws -> Int? {
        let statement = try connection.prepare(
            "SELECT value FROM metadata WHERE key = 'schema_version'"
        )
        guard try statement.step() else { return nil }
        guard let text = statement.text(0), let version = Int(text) else {
            throw StorageError.unreadableSchemaVersion(
                found: statement.text(0) ?? "an empty value",
                supported: schemaVersion
            )
        }
        return version
    }

    /// The schema version a file with the pre-streaming table shape holds.
    ///
    /// A version-1 build wrote its tables and its version row as separate
    /// auto-committing statements, so an interrupted first open leaves that shape
    /// with no version row at all. That file is treated as version 1, because that
    /// is the shape it actually has.
    private static let legacySchemaVersion = streamingSchemaVersion - 1

    /// Creates the schema, upgrades it, or verifies the one on disk.
    ///
    /// The upgrade is additive and is preceded by a SQLite-consistent backup of a
    /// file-backed database. A backup that cannot be written or read back aborts the
    /// upgrade, leaves the file at its recorded version, and closes the deleting
    /// route.
    ///
    /// The upgrade verifies rather than assumes: the columns are added through the
    /// idempotent step in every branch, and whether the file carries the streaming
    /// schema is read back from the file's own columns rather than inferred from the
    /// version it recorded. A file that recorded version 2 without the columns — or
    /// that holds the version-1 tables and no version at all — is migrated like any
    /// other legacy file instead of being reported as ready and then failing on the
    /// first batch read.
    private static func upgrade(
        connection: SQLiteConnection,
        path: String,
        backupFaultInjection: (@Sendable () throws -> Void)?
    ) throws -> Upgrade {
        // Read before anything is created: the version a file records, or none. A
        // file with no metadata table records none, and the table itself is created
        // below so that the pre-migration backup stays a copy of the file as it was.
        let recorded =
            try tableExists(connection, table: "metadata")
            ? recordedVersion(connection)
            : nil

        if let recorded {
            guard recorded <= schemaVersion else {
                throw StorageError.unsupportedSchemaVersion(
                    found: recorded,
                    supported: schemaVersion
                )
            }
        }

        // Whether the file already holds any of the library's tables, asked before
        // anything else is created so a genuinely new file is never mistaken for a
        // legacy one.
        let hasExistingTables =
            try tableExists(connection, table: "pages") || tableExists(connection, table: "batches")
        let hadStreaming = try streamingSchemaPresent(connection)

        // The version the file is treated as holding: the recorded one, or the
        // version-1 a file with the old tables and no version row actually has.
        let fromVersion = recorded ?? (hasExistingTables ? legacySchemaVersion : nil)

        // Back it up before the first schema write, and only when this open is going
        // to change the schema of a file that already held data. Taking the backup
        // first is what makes it a copy of the file as it was: creating the schema
        // would otherwise put an empty streaming table into the "before" image.
        var writtenBackupPath: String?
        let needsUpgrade = hasExistingTables && !hadStreaming
        if needsUpgrade, path != ":memory:" {
            let destination = backupPath(for: path, version: fromVersion ?? legacySchemaVersion)
            do {
                try backupFaultInjection?()
                try writeVerifiedBackup(
                    from: connection,
                    to: destination,
                    expectedVersion: recorded
                )
                writtenBackupPath = destination
            } catch {
                // The original is untouched and the deleting route stays closed.
                // The failure is reported through the storage error's own message,
                // so a reader sees which file could not be copied and why.
                return Upgrade(
                    schemaVersion: fromVersion ?? legacySchemaVersion,
                    hasStreamingSchema: hadStreaming,
                    unavailableReason: StorageError.migrationBackupFailed(
                        path: destination,
                        message: String(describing: error)
                    ).message
                )
            }
        }

        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """
        )
        try createCoreSchema(connection)
        // Idempotent, and run in every branch: a file that recorded version 2
        // without the columns, and a file that holds the version-1 tables and no
        // version at all, are both repaired here. The first of those reports
        // `migratedFrom == 2` while it is stamped with version 2 as well, because the
        // number is what the file recorded rather than the shape it had.
        try addStreamingColumns(connection)
        let streaming = try streamingSchemaPresent(connection)
        try writeVersion(connection, schemaVersion)

        return Upgrade(
            schemaVersion: schemaVersion,
            // The version the file recorded, or the version its old tables imply, even
            // when that is the version it is stamped with now.
            migratedFrom: needsUpgrade ? (fromVersion ?? legacySchemaVersion) : nil,
            backupPath: writtenBackupPath,
            hasStreamingSchema: streaming
        )
    }

    /// Whether the file carries the streaming schema: the added columns and the
    /// packet table.
    private static func streamingSchemaPresent(_ connection: SQLiteConnection) throws -> Bool {
        let columns = try columnNames(connection, table: "batches")
        guard columns.contains("kind"), columns.contains("completion"),
            columns.contains("packet_count")
        else { return false }
        return try tableExists(connection, table: "batch_packets")
    }

    /// Whether a table exists in the database.
    private static func tableExists(_ connection: SQLiteConnection, table: String) throws -> Bool {
        let statement = try connection.prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
        )
        try statement.bind(1, table)
        return try statement.step()
    }

    /// Writes the pre-migration backup and gives it its name only once it verifies.
    ///
    /// The copy is built under a temporary name beside the database and moved onto
    /// `destination` after it has been reopened and read back. A partial or rejected
    /// copy therefore never sits under the name the next open reads: `backup(to:)`
    /// reuses a path that already exists, so an unreadable file there would fail every
    /// later backup, and the deleting route would stay closed for a reason that has
    /// nothing to do with the file being migrated.
    ///
    /// A leftover at `destination` — a copy from an open whose version stamp failed,
    /// or one written by an older build — does not stop this one. It is a derived copy
    /// of the file, and the file itself is what may not be lost, so it is replaced once
    /// the new copy is verified.
    ///
    /// - Throws: The error the copy step reported, or
    ///   `StorageError.migrationBackupFailed` when the copy cannot be verified or put in
    ///   place, and also when a temporary cannot be removed, so a failure to clean up is
    ///   reported rather than swallowed.
    private static func writeVerifiedBackup(
        from connection: SQLiteConnection,
        to destination: String,
        expectedVersion: Int?
    ) throws {
        let temporary = "\(destination).partial-\(UUID().uuidString)"
        do {
            try connection.backup(to: temporary)
            try makePrivate(temporary)
            // Reopened and read back, because "backup creation or verification
            // fails" is the promise: a copy that cannot be read, or that records a
            // different version, is not a copy of this file.
            try verifyBackup(at: temporary, expectedVersion: expectedVersion)
        } catch {
            let failure = error
            do {
                try removeIfPresent(temporary)
            } catch let cleanupFailure {
                throw StorageError.migrationBackupFailed(
                    path: destination,
                    message: "\(failure); the partial copy at \(temporary) could not be"
                        + " removed either: \(cleanupFailure)"
                )
            }
            throw failure
        }

        try putInPlace(temporary: temporary, destination: destination)
    }

    /// Moves a verified copy onto its final name, replacing any leftover there.
    ///
    /// - Throws: `StorageError.migrationBackupFailed` when the copy cannot be put in
    ///   place, and also when the temporary cannot be removed afterwards, so a failure
    ///   to clean up is reported rather than swallowed.
    private static func putInPlace(temporary: String, destination: String) throws {
        do {
            try removeIfPresent(destination)
            try FileManager.default.moveItem(atPath: temporary, toPath: destination)
        } catch {
            let failure = error
            do {
                try removeIfPresent(temporary)
            } catch let cleanupFailure {
                throw StorageError.migrationBackupFailed(
                    path: destination,
                    message: "the verified copy could not be put in place at \(destination):"
                        + " \(failure); it could not be removed from \(temporary) either:"
                        + " \(cleanupFailure)"
                )
            }
            throw StorageError.migrationBackupFailed(
                path: destination,
                message: "the verified copy could not be put in place at \(destination): \(failure)"
            )
        }
    }

    /// Removes a file when it is there.
    ///
    /// - Throws: Whatever the file system reports for a file that exists but cannot be
    ///   removed, so a failed cleanup is visible instead of being ignored.
    private static func removeIfPresent(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }

    /// Reads a written backup back and checks the version it records.
    ///
    /// - Throws: Whatever reopening the copy reports, and
    ///   `StorageError.migrationBackupFailed` when the copy holds none of the library's
    ///   tables or records a different version than the file it was taken from.
    private static func verifyBackup(at path: String, expectedVersion: Int?) throws {
        // Read-only through `immutable=1`: the check must not be able to change the
        // copy it is verifying, and a WAL-header copy cannot be opened read-only
        // without it.
        let backup = try SQLiteConnection(immutableReadingOnly: path)
        guard
            try tableExists(backup, table: "pages") || tableExists(backup, table: "batches")
        else {
            throw StorageError.migrationBackupFailed(
                path: path,
                message: "the backup holds none of the library's tables"
            )
        }
        let found =
            try tableExists(backup, table: "metadata") ? recordedVersion(backup) : nil
        guard found == expectedVersion else {
            let described = { (version: Int?) in version.map(String.init) ?? "none" }
            throw StorageError.migrationBackupFailed(
                path: path,
                message: "the backup records schema version \(described(found)),"
                    + " not \(described(expectedVersion))"
            )
        }
    }

    /// The tables and columns every version of the schema shares.
    private static func createCoreSchema(_ connection: SQLiteConnection) throws {
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS pages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                section INTEGER NOT NULL,
                owner INTEGER NOT NULL,
                book INTEGER NOT NULL,
                page INTEGER NOT NULL,
                UNIQUE (section, owner, book, page)
            )
            """
        )

        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS strokes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                page_id INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
                encoding_version INTEGER NOT NULL,
                fingerprint TEXT NOT NULL,
                allows_cross_source_deduplication INTEGER NOT NULL,
                origin_reliable INTEGER NOT NULL,
                origin_milliseconds INTEGER,
                source TEXT NOT NULL,
                canonical BLOB NOT NULL
            )
            """
        )

        // Only a stroke whose identity is reliable enough for cross-source
        // deduplication is unique. An unreliable stroke keeps its own row, so its
        // multiplicity survives a replay.
        try connection.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS strokes_reliable_fingerprint
                ON strokes (fingerprint)
                WHERE allows_cross_source_deduplication = 1
            """
        )

        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS points (
                stroke_id INTEGER NOT NULL REFERENCES strokes(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                x INTEGER NOT NULL,
                y INTEGER NOT NULL,
                time_offset INTEGER NOT NULL,
                pressure INTEGER NOT NULL,
                PRIMARY KEY (stroke_id, ordinal)
            )
            """
        )

        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS batches (
                id TEXT PRIMARY KEY,
                state TEXT NOT NULL,
                stroke_count INTEGER NOT NULL,
                dot_count INTEGER NOT NULL,
                ordinal INTEGER NOT NULL,
                kind TEXT NOT NULL DEFAULT 'ordinary',
                completion TEXT NOT NULL DEFAULT 'complete',
                packet_count INTEGER NOT NULL DEFAULT 0
            )
            """
        )

        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS batch_pages (
                batch_id TEXT NOT NULL,
                section INTEGER NOT NULL,
                owner INTEGER NOT NULL,
                book INTEGER NOT NULL,
                page INTEGER NOT NULL,
                PRIMARY KEY (batch_id, section, owner, book, page)
            )
            """
        )

        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS cleanup_journal (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                batch_id TEXT NOT NULL,
                state TEXT NOT NULL
            )
            """
        )

        // The scope is separate from the state history so the journal can hold
        // every state a request passed through while the scope is recorded once,
        // before anything can be sent.
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS cleanup_requests (
                batch_id TEXT PRIMARY KEY,
                target TEXT NOT NULL,
                pages TEXT NOT NULL
            )
            """
        )

        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS batch_packets (
                batch_id TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                section_owner_id INTEGER NOT NULL,
                note_id INTEGER NOT NULL,
                packet_id INTEGER NOT NULL,
                stroke_count INTEGER NOT NULL,
                is_end INTEGER NOT NULL,
                PRIMARY KEY (batch_id, ordinal)
            )
            """
        )
    }

    /// Adds the streaming columns to a database created before them.
    ///
    /// Each column carries a default so existing rows keep their meaning: a legacy
    /// batch is an ordinary, complete read with no durable packets.
    private static func addStreamingColumns(_ connection: SQLiteConnection) throws {
        let existing = try columnNames(connection, table: "batches")
        if !existing.contains("kind") {
            try connection.execute(
                "ALTER TABLE batches ADD COLUMN kind TEXT NOT NULL DEFAULT 'ordinary'"
            )
        }
        if !existing.contains("completion") {
            try connection.execute(
                "ALTER TABLE batches ADD COLUMN completion TEXT NOT NULL DEFAULT 'complete'"
            )
        }
        if !existing.contains("packet_count") {
            try connection.execute(
                "ALTER TABLE batches ADD COLUMN packet_count INTEGER NOT NULL DEFAULT 0"
            )
        }
    }

    /// The column names of a table.
    private static func columnNames(
        _ connection: SQLiteConnection,
        table: String
    ) throws -> Set<String> {
        let statement = try connection.prepare("PRAGMA table_info(\(table))")
        var names = Set<String>()
        while try statement.step() {
            if let name = statement.text(1) { names.insert(name) }
        }
        return names
    }

    /// Records the schema version.
    private static func writeVersion(_ connection: SQLiteConnection, _ version: Int) throws {
        try connection.execute("DELETE FROM metadata WHERE key = 'schema_version'")
        let insert = try connection.prepare(
            "INSERT INTO metadata (key, value) VALUES ('schema_version', ?)"
        )
        try insert.bind(1, Int64(version))
        try insert.run()
    }

    /// The backup file path for a database at a recorded version.
    private static func backupPath(for path: String, version: Int) -> String {
        "\(path).backup-v\(version)"
    }

    /// Restricts a file to its owner.
    ///
    /// The backup holds the user's strokes, so it is written `0o600`. That is stricter
    /// than the library file it copies: SQLite creates that one with the process umask,
    /// so it is readable by the owner's group and by everyone else on a default
    /// umask. Making the two equal is a separate decision, so nothing here chmods the
    /// library.
    private static func makePrivate(_ path: String) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: path
        )
    }

    // MARK: - PenStrokeStore

    public func insert(_ strokes: [Stroke]) async throws -> PenStrokeInsertion {
        var added = 0
        var duplicates = 0

        try connection.withTransaction {
            for (index, stroke) in strokes.enumerated() {
                try faultInjection?(index)

                let fingerprint = StrokeIdentity.fingerprint(of: stroke)
                if fingerprint.allowsCrossSourceDeduplication,
                    try containsReliableStroke(fingerprint: fingerprint)
                {
                    duplicates += 1
                    continue
                }

                try write(stroke, fingerprint: fingerprint)
                added += 1
            }
        }

        return PenStrokeInsertion(addedStrokeCount: added, duplicateStrokeCount: duplicates)
    }

    public func strokes(on page: PageIdentity) async throws -> [Stroke] {
        let pageID = try pageIdentifier(for: page)
        guard let pageID else { return [] }
        return try strokes(pageID: pageID, page: page)
    }

    public func pages() async throws -> [PageIdentity] {
        let statement = try connection.prepare(
            """
            SELECT section, owner, book, page FROM pages
            ORDER BY section, owner, book, page
            """
        )

        var pages: [PageIdentity] = []
        while try statement.step() {
            pages.append(
                PageIdentity(
                    section: UInt8(truncatingIfNeeded: statement.int64(0)),
                    owner: UInt32(truncatingIfNeeded: statement.int64(1)),
                    book: UInt32(truncatingIfNeeded: statement.int64(2)),
                    page: UInt32(truncatingIfNeeded: statement.int64(3))
                )
            )
        }
        return pages
    }

    // MARK: - PenImportBatchStore

    /// Stores a batch record, replacing the batch's page and packet rows.
    ///
    /// The record's `packets` are written to `batch_packets` the way its `pages`
    /// are written to `batch_pages`, and the stored `packet_count` is the number of
    /// those rows, so a caller that constructs a record with packet rows gets them
    /// back from ``batch(id:)`` and the count and the rows cannot drift apart.
    public func save(_ record: PenImportBatchRecord) async throws {
        try connection.withTransaction {
            let existing = try batchOrdinal(batchID: record.batchID)
            let ordinal = try existing ?? nextBatchOrdinal()

            let upsert: SQLiteStatement
            if hasStreamingSchema {
                upsert = try connection.prepare(
                    """
                    INSERT INTO batches (
                        id, state, stroke_count, dot_count, ordinal, kind, completion, packet_count
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        state = excluded.state,
                        stroke_count = excluded.stroke_count,
                        dot_count = excluded.dot_count,
                        kind = excluded.kind,
                        completion = excluded.completion,
                        packet_count = excluded.packet_count
                    """
                )
                try upsert.bind(1, record.batchID.uuidString)
                try upsert.bind(2, record.state.rawValue)
                try upsert.bind(3, Int64(record.strokeCount))
                try upsert.bind(4, Int64(record.dotCount))
                try upsert.bind(5, ordinal)
                try upsert.bind(6, record.kind.rawValue)
                try upsert.bind(7, record.completion.rawValue)
                try upsert.bind(8, Int64(record.packets.count))
            } else {
                upsert = try connection.prepare(
                    """
                    INSERT INTO batches (id, state, stroke_count, dot_count, ordinal)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        state = excluded.state,
                        stroke_count = excluded.stroke_count,
                        dot_count = excluded.dot_count
                    """
                )
                try upsert.bind(1, record.batchID.uuidString)
                try upsert.bind(2, record.state.rawValue)
                try upsert.bind(3, Int64(record.strokeCount))
                try upsert.bind(4, Int64(record.dotCount))
                try upsert.bind(5, ordinal)
            }
            try upsert.run()

            let deletePages = try connection.prepare("DELETE FROM batch_pages WHERE batch_id = ?")
            try deletePages.bind(1, record.batchID.uuidString)
            try deletePages.run()
            let pageInsert = try connection.prepare(
                """
                INSERT OR IGNORE INTO batch_pages (batch_id, section, owner, book, page)
                VALUES (?, ?, ?, ?, ?)
                """
            )
            for page in record.pages {
                try pageInsert.reset()
                try pageInsert.bind(1, record.batchID.uuidString)
                try pageInsert.bind(2, Int64(page.section))
                try pageInsert.bind(3, Int64(page.owner))
                try pageInsert.bind(4, Int64(page.book))
                try pageInsert.bind(5, Int64(page.page))
                try pageInsert.run()
            }

            // The packet rows are rewritten the way the page rows are, so the
            // batch's packet count and its rows cannot drift apart: a record that
            // names packets stores them, and `batch(id:)` reads back what it stored.
            if hasStreamingSchema {
                let deletePackets = try connection.prepare(
                    "DELETE FROM batch_packets WHERE batch_id = ?"
                )
                try deletePackets.bind(1, record.batchID.uuidString)
                try deletePackets.run()
                let packetInsert = try connection.prepare(
                    """
                    INSERT INTO batch_packets (
                        batch_id, ordinal, section_owner_id, note_id, packet_id, stroke_count, is_end
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """
                )
                for (ordinal, packet) in record.packets.enumerated() {
                    try packetInsert.reset()
                    try packetInsert.bind(1, record.batchID.uuidString)
                    try packetInsert.bind(2, Int64(ordinal))
                    try packetInsert.bind(3, Int64(packet.sectionOwnerID))
                    try packetInsert.bind(4, Int64(packet.noteID))
                    try packetInsert.bind(5, Int64(packet.packetID))
                    try packetInsert.bind(6, Int64(packet.strokeCount))
                    try packetInsert.bind(7, packet.isEndPacket ? 1 : 0)
                    try packetInsert.run()
                }
            }
        }
    }

    public func batch(id: UUID) async throws -> PenImportBatchRecord? {
        let statement: SQLiteStatement
        if hasStreamingSchema {
            statement = try connection.prepare(
                """
                SELECT state, stroke_count, dot_count, kind, completion
                FROM batches WHERE id = ?
                """
            )
        } else {
            statement = try connection.prepare(
                "SELECT state, stroke_count, dot_count FROM batches WHERE id = ?"
            )
        }
        try statement.bind(1, id.uuidString)
        guard try statement.step() else { return nil }

        // A row this build cannot decode is refused rather than mapped to a state
        // that would misreport what happened to the batch.
        guard let state = statement.text(0).flatMap(ImportBatchState.init(rawValue:)) else {
            throw StorageError.unreadableBatchState(batchID: id)
        }
        let kind: ImportTransferKind
        let completion: ImportBatchCompletion
        if hasStreamingSchema {
            guard let decodedKind = statement.text(3).flatMap(ImportTransferKind.init(rawValue:)) else {
                throw StorageError.unreadableBatchState(batchID: id)
            }
            guard
                let decodedCompletion = statement.text(4).flatMap(ImportBatchCompletion.init(rawValue:))
            else {
                throw StorageError.unreadableBatchCompletion(batchID: id)
            }
            kind = decodedKind
            completion = decodedCompletion
        } else {
            kind = .ordinary
            completion = .complete
        }

        return PenImportBatchRecord(
            batchID: id,
            state: state,
            kind: kind,
            completion: completion,
            pages: try batchPages(batchID: id),
            strokeCount: Int(statement.int64(1)),
            dotCount: Int(statement.int64(2)),
            packets: try batchPackets(batchID: id)
        )
    }

    public func batches(in state: ImportBatchState) async throws -> [PenImportBatchRecord] {
        let statement = try connection.prepare(
            "SELECT id, stroke_count, dot_count FROM batches WHERE state = ? ORDER BY ordinal"
        )
        try statement.bind(1, state.rawValue)

        var records: [PenImportBatchRecord] = []
        while try statement.step() {
            guard let identifier = statement.text(0).flatMap(UUID.init(uuidString:)) else { continue }
            records.append(
                try await batchRecord(
                    identifier,
                    state: state,
                    strokeCount: Int(statement.int64(1)),
                    dotCount: Int(statement.int64(2))
                )
            )
        }
        return records
    }

    /// Builds a batch record for a row the caller already read.
    ///
    /// The kind and completion are re-read from the row rather than defaulted, so
    /// a listing reports the same durable values as ``batch(id:)``.
    private func batchRecord(
        _ identifier: UUID,
        state: ImportBatchState,
        strokeCount: Int,
        dotCount: Int
    ) async throws -> PenImportBatchRecord {
        let kind: ImportTransferKind
        let completion: ImportBatchCompletion
        if hasStreamingSchema {
            let statement = try connection.prepare(
                "SELECT kind, completion FROM batches WHERE id = ?"
            )
            try statement.bind(1, identifier.uuidString)
            guard try statement.step() else {
                throw StorageError.batchNotReady(batchID: identifier, state: nil)
            }
            guard
                let decodedKind = statement.text(0).flatMap(ImportTransferKind.init(rawValue:))
            else {
                throw StorageError.unreadableBatchState(batchID: identifier)
            }
            guard
                let decodedCompletion = statement.text(1).flatMap(
                    ImportBatchCompletion.init(rawValue:)
                )
            else {
                throw StorageError.unreadableBatchCompletion(batchID: identifier)
            }
            kind = decodedKind
            completion = decodedCompletion
        } else {
            kind = .ordinary
            completion = .complete
        }

        return PenImportBatchRecord(
            batchID: identifier,
            state: state,
            kind: kind,
            completion: completion,
            pages: try batchPages(batchID: identifier),
            strokeCount: strokeCount,
            dotCount: dotCount,
            packets: try batchPackets(batchID: identifier)
        )
    }

    // MARK: - PenDeletingPacketBarrier

    /// Opens a deleting batch for a read.
    ///
    /// The batch is recorded as a deleting transfer that is `committed` and
    /// `inProgress` before the first `0x23`, so every packet has a durable batch
    /// to commit into and a restart can tell it apart from a completed read.
    ///
    /// - Parameter notes: The notes the read discovered. The barrier's contract
    ///   carries them so an implementation can record the plan; this one does not,
    ///   because the note association is stored per packet, from each packet's own
    ///   note identifier, which is what a restart reads.
    public func beginDeletingRead(notes: [PenDeletingReadNote]) async throws -> UUID {
        try requireDeletingReads()
        let batchID = UUID()
        try connection.withTransaction {
            let ordinal = try nextBatchOrdinal()
            let insert = try connection.prepare(
                """
                INSERT INTO batches (
                    id, state, stroke_count, dot_count, ordinal, kind, completion, packet_count
                )
                VALUES (?, ?, 0, 0, ?, ?, ?, 0)
                """
            )
            try insert.bind(1, batchID.uuidString)
            try insert.bind(2, ImportBatchState.committed.rawValue)
            try insert.bind(3, ordinal)
            try insert.bind(4, ImportTransferKind.deleting.rawValue)
            try insert.bind(5, ImportBatchCompletion.inProgress.rawValue)
            try insert.run()
        }
        return batchID
    }

    /// Commits one accepted packet's strokes and progress in one transaction.
    ///
    /// The transaction writes the packet's complete strokes, its canonical pages,
    /// its progress row, and the batch's cumulative counts, then commits. Because
    /// the connection runs WAL with `synchronous = FULL`, the commit has returned
    /// only after a durable sync, which is what lets the session acknowledge the
    /// packet afterwards. A failure rolls the whole packet back, so the packet
    /// stays unacknowledged and the earlier packets stay readable.
    public func commitDeletingPacket(
        _ packet: PenDeletingPacket
    ) async throws -> PenDeletingPacketCommitResult {
        try requireDeletingReads()

        var added = 0
        var duplicates = 0
        var addedDots = 0
        var committedPacketCount = 0
        var committedStrokeCount = 0
        var committedDotCount = 0

        try connection.withTransaction {
            guard let existing = try batchCounts(batchID: packet.batchID) else {
                throw StorageError.batchNotReady(batchID: packet.batchID, state: nil)
            }

            let ordinal = existing.packetCount
            // Called before any write so a test can fail this packet's commit and
            // prove the whole packet rolled back.
            try packetFaultInjection?(ordinal)

            for stroke in packet.strokes {
                let fingerprint = StrokeIdentity.fingerprint(of: stroke)
                if fingerprint.allowsCrossSourceDeduplication,
                    try containsReliableStroke(fingerprint: fingerprint)
                {
                    duplicates += 1
                    continue
                }
                try write(stroke, fingerprint: fingerprint)
                added += 1
                addedDots += stroke.points.count
            }

            let pageInsert = try connection.prepare(
                """
                INSERT OR IGNORE INTO batch_pages (batch_id, section, owner, book, page)
                VALUES (?, ?, ?, ?, ?)
                """
            )
            for page in packet.pages {
                try pageInsert.reset()
                try pageInsert.bind(1, packet.batchID.uuidString)
                try pageInsert.bind(2, Int64(page.section))
                try pageInsert.bind(3, Int64(page.owner))
                try pageInsert.bind(4, Int64(page.book))
                try pageInsert.bind(5, Int64(page.page))
                try pageInsert.run()
            }

            let packetInsert = try connection.prepare(
                """
                INSERT INTO batch_packets (
                    batch_id, ordinal, section_owner_id, note_id, packet_id, stroke_count, is_end
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            )
            try packetInsert.bind(1, packet.batchID.uuidString)
            try packetInsert.bind(2, Int64(ordinal))
            try packetInsert.bind(3, Int64(packet.sectionOwnerID))
            try packetInsert.bind(4, Int64(packet.noteID))
            try packetInsert.bind(5, Int64(packet.packetID))
            try packetInsert.bind(6, Int64(packet.strokes.count))
            try packetInsert.bind(7, packet.isEndPacket ? 1 : 0)
            try packetInsert.run()

            committedPacketCount = ordinal + 1
            // The batch counts what it added, so a replayed packet leaves the
            // batch's own contribution unchanged.
            committedStrokeCount = existing.strokeCount + added
            committedDotCount = existing.dotCount + addedDots

            // The batch is committed on its first packet: the strokes are durable,
            // so the read can be published even while the transfer runs.
            let update = try connection.prepare(
                """
                UPDATE batches
                SET state = ?, completion = ?, packet_count = ?, stroke_count = ?, dot_count = ?
                WHERE id = ?
                """
            )
            try update.bind(1, ImportBatchState.committed.rawValue)
            try update.bind(2, ImportBatchCompletion.inProgress.rawValue)
            try update.bind(3, Int64(committedPacketCount))
            try update.bind(4, Int64(committedStrokeCount))
            try update.bind(5, Int64(committedDotCount))
            try update.bind(6, packet.batchID.uuidString)
            try update.run()
        }

        return PenDeletingPacketCommitResult(
            committedPacketCount: committedPacketCount,
            committedStrokeCount: committedStrokeCount,
            committedDotCount: committedDotCount,
            addedStrokeCount: added,
            duplicateStrokeCount: duplicates,
            isEndPacket: packet.isEndPacket
        )
    }

    /// Marks the batch's completion once the transfer has stopped.
    public func finishDeletingRead(batchID: UUID, isComplete: Bool) async throws {
        try requireDeletingReads()
        try connection.withTransaction {
            let update = try connection.prepare("UPDATE batches SET completion = ? WHERE id = ?")
            try update.bind(
                1,
                (isComplete ? ImportBatchCompletion.complete : ImportBatchCompletion.partial)
                    .rawValue
            )
            try update.bind(2, batchID.uuidString)
            try update.run()
        }
    }

    /// Marks a deleting batch failed because the read that opened it ended before
    /// its first durable packet.
    ///
    /// The row is kept rather than deleted: it is the durable record that a read
    /// was attempted, which the journal and a later diagnosis need. Only a deleting
    /// batch that is still `inProgress` with no packet is touched, so an ordinary
    /// batch, a batch with a durable prefix, a finished batch, and an unknown
    /// identifier are left exactly as they were and a second call writes nothing.
    /// Completion becomes `partial`, because the transfer stopped before every
    /// note's end packet: a batch that ended before its first packet must not keep
    /// claiming an in-progress transfer.
    public func failDeletingRead(batchID: UUID) async throws {
        try requireDeletingReads()
        try connection.withTransaction {
            let update = try connection.prepare(
                """
                UPDATE batches
                SET state = ?, completion = ?
                WHERE id = ? AND kind = ? AND completion = ? AND packet_count = 0
                """
            )
            try update.bind(1, ImportBatchState.failed.rawValue)
            try update.bind(2, ImportBatchCompletion.partial.rawValue)
            try update.bind(3, batchID.uuidString)
            try update.bind(4, ImportTransferKind.deleting.rawValue)
            try update.bind(5, ImportBatchCompletion.inProgress.rawValue)
            try update.run()
        }
    }

    /// Fails when this library may not open a deleting read.
    private func requireDeletingReads() throws {
        guard hasStreamingSchema else {
            throw StorageError.deletingReadsUnavailable(
                reason: "the pre-migration backup failed, so the schema was left as it was"
            )
        }
        guard deletingReadsEnabled else {
            throw StorageError.deletingReadsUnavailable(
                reason: "this configuration disables the deleting-transfer route"
            )
        }
    }

    /// A batch's cumulative counts, or `nil` when the batch is unknown.
    private func batchCounts(
        batchID: UUID
    ) throws -> (packetCount: Int, strokeCount: Int, dotCount: Int)? {
        let statement = try connection.prepare(
            "SELECT packet_count, stroke_count, dot_count FROM batches WHERE id = ?"
        )
        try statement.bind(1, batchID.uuidString)
        guard try statement.step() else { return nil }
        return (
            packetCount: Int(statement.int64(0)),
            strokeCount: Int(statement.int64(1)),
            dotCount: Int(statement.int64(2))
        )
    }

    /// The packets a batch durably committed, in commit order.
    private func batchPackets(batchID: UUID) throws -> [PenImportPacketProgress] {
        guard hasStreamingSchema else { return [] }
        let statement = try connection.prepare(
            """
            SELECT section_owner_id, note_id, packet_id, stroke_count, is_end
            FROM batch_packets WHERE batch_id = ? ORDER BY ordinal
            """
        )
        try statement.bind(1, batchID.uuidString)

        var packets: [PenImportPacketProgress] = []
        while try statement.step() {
            packets.append(
                PenImportPacketProgress(
                    sectionOwnerID: UInt32(truncatingIfNeeded: statement.int64(0)),
                    noteID: UInt32(truncatingIfNeeded: statement.int64(1)),
                    packetID: UInt16(truncatingIfNeeded: statement.int64(2)),
                    strokeCount: Int(statement.int64(3)),
                    isEndPacket: statement.int64(4) != 0
                )
            )
        }
        return packets
    }

    // MARK: - PenCleanupJournal

    /// Records one cleanup state and, for the first record, the exact scope.
    ///
    /// The scope is written before the state, so a process that stops between the
    /// two has a durable scope and a request that is not yet `requested`: a fresh
    /// read can be compared with the recorded scope instead of a deletion being
    /// repeated blindly.
    public func record(_ state: PenCleanupState, scope: PenDeletionScope) async throws {
        let encodedPages = try Self.encode(scope.pages)

        try connection.withTransaction {
            let request = try connection.prepare(
                """
                INSERT INTO cleanup_requests (batch_id, target, pages)
                VALUES (?, ?, ?)
                ON CONFLICT(batch_id) DO NOTHING
                """
            )
            try request.bind(1, scope.batchID.uuidString)
            try request.bind(2, scope.target.rawValue)
            try request.bind(3, encodedPages)
            try request.run()

            let statement = try connection.prepare(
                "INSERT INTO cleanup_journal (batch_id, state) VALUES (?, ?)"
            )
            try statement.bind(1, scope.batchID.uuidString)
            try statement.bind(2, state.rawValue)
            try statement.run()
        }
    }

    public func latestState(batchID: UUID) async throws -> PenCleanupState? {
        let statement = try connection.prepare(
            "SELECT state FROM cleanup_journal WHERE batch_id = ? ORDER BY id DESC LIMIT 1"
        )
        try statement.bind(1, batchID.uuidString)
        guard try statement.step() else { return nil }
        return try Self.state(batchID: batchID, raw: statement.text(0))
    }

    public func recordedScope(batchID: UUID) async throws -> PenDeletionScope? {
        let statement = try connection.prepare(
            "SELECT target, pages FROM cleanup_requests WHERE batch_id = ?"
        )
        try statement.bind(1, batchID.uuidString)
        guard try statement.step() else { return nil }
        return try Self.scope(
            batchID: batchID,
            target: statement.text(0),
            encodedPages: statement.text(1)
        )
    }

    /// Every scope whose latest recorded state is `requested`, oldest first.
    public func outstandingScopes() async throws -> [PenDeletionScope] {
        let statement = try connection.prepare(
            """
            SELECT requests.batch_id, requests.target, requests.pages
            FROM cleanup_requests AS requests
            JOIN (
                SELECT batch_id, state, MAX(id) AS latest
                FROM cleanup_journal
                GROUP BY batch_id
            ) AS journal ON journal.batch_id = requests.batch_id
            WHERE journal.state = ?
            ORDER BY journal.latest
            """
        )
        try statement.bind(1, PenCleanupState.requested.rawValue)

        var scopes: [PenDeletionScope] = []
        while try statement.step() {
            guard let batchID = statement.text(0).flatMap(UUID.init(uuidString:)) else { continue }
            scopes.append(
                try Self.scope(
                    batchID: batchID,
                    target: statement.text(1),
                    encodedPages: statement.text(2)
                )
            )
        }
        return scopes
    }

    /// Every cleanup state recorded for a batch, oldest first.
    ///
    /// The whole history is what shows the ordering the journal enforces: a
    /// request reaches `requested` before any byte is sent, and `confirmed` only
    /// when the pen proved removal of the recorded scope.
    public func recordedStates(batchID: UUID) async throws -> [PenCleanupState] {
        let statement = try connection.prepare(
            "SELECT state FROM cleanup_journal WHERE batch_id = ? ORDER BY id"
        )
        try statement.bind(1, batchID.uuidString)

        var states: [PenCleanupState] = []
        while try statement.step() {
            states.append(try Self.state(batchID: batchID, raw: statement.text(0)))
        }
        return states
    }

    /// Decodes a recorded cleanup state row.
    ///
    /// A row this build cannot read is refused rather than treated as no request:
    /// "never requested" is the one answer that could let the same deletion be
    /// sent a second time.
    private static func state(batchID: UUID, raw: String?) throws -> PenCleanupState {
        guard let raw, let state = PenCleanupState(rawValue: raw) else {
            throw StorageError.unreadableCleanupState(batchID: batchID)
        }
        return state
    }

    /// Decodes a recorded scope row.
    ///
    /// A row this build cannot read is refused rather than treated as an empty
    /// scope: an empty page list would read as "the pen no longer holds these
    /// pages", which is exactly the claim a deletion outcome must not invent.
    private static func scope(
        batchID: UUID,
        target: String?,
        encodedPages: String?
    ) throws -> PenDeletionScope {
        guard let target = target.flatMap(PenDeletionTarget.init(rawValue:)) else {
            throw StorageError.unreadableCleanupScope(batchID: batchID)
        }
        guard let encodedPages, let data = encodedPages.data(using: .utf8) else {
            throw StorageError.unreadableCleanupScope(batchID: batchID)
        }
        let pages: [PageIdentity]
        do {
            pages = try JSONDecoder().decode([PageIdentity].self, from: data)
        } catch {
            throw StorageError.unreadableCleanupScope(batchID: batchID)
        }
        return PenDeletionScope(batchID: batchID, target: target, pages: pages)
    }

    /// Encodes the pages of a scope for storage.
    private static func encode(_ pages: [PageIdentity]) throws -> String {
        let data = try JSONEncoder().encode(pages)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Stroke writes

    /// Whether a reliable stroke with this fingerprint is already stored.
    private func containsReliableStroke(fingerprint: StrokeFingerprint) throws -> Bool {
        let statement = try connection.prepare(
            """
            SELECT 1 FROM strokes
            WHERE fingerprint = ? AND allows_cross_source_deduplication = 1
            LIMIT 1
            """
        )
        try statement.bind(1, fingerprint.hexDigest)
        return try statement.step()
    }

    /// Writes one stroke and its points.
    private func write(_ stroke: Stroke, fingerprint: StrokeFingerprint) throws {
        let pageID = try pageIdentifier(for: stroke.page) ?? insertPage(stroke.page)

        let insert = try connection.prepare(
            """
            INSERT INTO strokes (
                page_id,
                encoding_version,
                fingerprint,
                allows_cross_source_deduplication,
                origin_reliable,
                origin_milliseconds,
                source,
                canonical
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try insert.bind(1, pageID)
        try insert.bind(2, Int64(fingerprint.encodingVersion))
        try insert.bind(3, fingerprint.hexDigest)
        try insert.bind(4, fingerprint.allowsCrossSourceDeduplication ? 1 : 0)
        try insert.bind(5, stroke.originTime.isReliable ? 1 : 0)
        if let milliseconds = stroke.originTime.reportedMilliseconds {
            try insert.bind(6, milliseconds)
        } else {
            try insert.bindNull(6)
        }
        try insert.bind(7, stroke.source.rawValue)
        try insert.bind(8, CanonicalStrokeEncoding.encode(stroke))
        try insert.run()

        let strokeID = insert.lastInsertedRowID
        let pointInsert = try connection.prepare(
            """
            INSERT INTO points (stroke_id, ordinal, x, y, time_offset, pressure)
            VALUES (?, ?, ?, ?, ?, ?)
            """
        )
        for (ordinal, point) in stroke.points.enumerated() {
            try pointInsert.reset()
            try pointInsert.bind(1, strokeID)
            try pointInsert.bind(2, Int64(ordinal))
            try pointInsert.bind(3, Int64(point.x))
            try pointInsert.bind(4, Int64(point.y))
            try pointInsert.bind(5, point.penTimeOffsetMilliseconds)
            try pointInsert.bind(6, Int64(point.pressure))
            try pointInsert.run()
        }
    }

    /// Returns a page's row identifier, or `nil` when the page is unknown.
    private func pageIdentifier(for page: PageIdentity) throws -> Int64? {
        let statement = try connection.prepare(
            """
            SELECT id FROM pages
            WHERE section = ? AND owner = ? AND book = ? AND page = ?
            """
        )
        try statement.bind(1, Int64(page.section))
        try statement.bind(2, Int64(page.owner))
        try statement.bind(3, Int64(page.book))
        try statement.bind(4, Int64(page.page))
        guard try statement.step() else { return nil }
        return statement.int64(0)
    }

    /// Inserts a page and returns its row identifier.
    private func insertPage(_ page: PageIdentity) throws -> Int64 {
        let insert = try connection.prepare(
            "INSERT INTO pages (section, owner, book, page) VALUES (?, ?, ?, ?)"
        )
        try insert.bind(1, Int64(page.section))
        try insert.bind(2, Int64(page.owner))
        try insert.bind(3, Int64(page.book))
        try insert.bind(4, Int64(page.page))
        try insert.run()
        return insert.lastInsertedRowID
    }

    // MARK: - Stroke reads

    /// Reads every stroke stored for a page row.
    private func strokes(pageID: Int64, page: PageIdentity) throws -> [Stroke] {
        let statement = try connection.prepare(
            """
            SELECT id, origin_reliable, origin_milliseconds, source
            FROM strokes
            WHERE page_id = ?
            ORDER BY id
            """
        )
        try statement.bind(1, pageID)

        var strokes: [Stroke] = []
        while try statement.step() {
            let strokeID = statement.int64(0)
            let originTime: PenOriginTime = statement.int64(1) == 1
                ? .reliable(milliseconds: statement.int64(2))
                : .unreliable(
                    reportedMilliseconds: statement.isNull(2) ? nil : statement.int64(2)
                )
            let source = statement.text(3).flatMap(PenSource.init(rawValue:)) ?? .offline

            strokes.append(
                Stroke(
                    page: page,
                    originTime: originTime,
                    points: try points(strokeID: strokeID),
                    source: source
                )
            )
        }
        return strokes
    }

    /// Reads a stroke's points in order.
    private func points(strokeID: Int64) throws -> [PenPoint] {
        let statement = try connection.prepare(
            """
            SELECT x, y, time_offset, pressure FROM points
            WHERE stroke_id = ?
            ORDER BY ordinal
            """
        )
        try statement.bind(1, strokeID)

        var points: [PenPoint] = []
        while try statement.step() {
            points.append(
                PenPoint(
                    x: Int32(truncatingIfNeeded: statement.int64(0)),
                    y: Int32(truncatingIfNeeded: statement.int64(1)),
                    penTimeOffsetMilliseconds: statement.int64(2),
                    pressure: UInt16(truncatingIfNeeded: statement.int64(3))
                )
            )
        }
        return points
    }

    // MARK: - Batch helpers

    /// The insertion ordinal recorded for a batch, or `nil` when it is unknown.
    private func batchOrdinal(batchID: UUID) throws -> Int64? {
        let statement = try connection.prepare("SELECT ordinal FROM batches WHERE id = ?")
        try statement.bind(1, batchID.uuidString)
        guard try statement.step() else { return nil }
        return statement.int64(0)
    }

    /// The ordinal a new batch should take.
    private func nextBatchOrdinal() throws -> Int64 {
        let statement = try connection.prepare("SELECT COALESCE(MAX(ordinal), 0) + 1 FROM batches")
        guard try statement.step() else { return 1 }
        return statement.int64(0)
    }

    /// The pages a batch's strokes belong to, in canonical order.
    private func batchPages(batchID: UUID) throws -> [PageIdentity] {
        let statement = try connection.prepare(
            """
            SELECT section, owner, book, page FROM batch_pages
            WHERE batch_id = ?
            ORDER BY section, owner, book, page
            """
        )
        try statement.bind(1, batchID.uuidString)

        var pages: [PageIdentity] = []
        while try statement.step() {
            pages.append(
                PageIdentity(
                    section: UInt8(truncatingIfNeeded: statement.int64(0)),
                    owner: UInt32(truncatingIfNeeded: statement.int64(1)),
                    book: UInt32(truncatingIfNeeded: statement.int64(2)),
                    page: UInt32(truncatingIfNeeded: statement.int64(3))
                )
            )
        }
        return pages
    }
}

