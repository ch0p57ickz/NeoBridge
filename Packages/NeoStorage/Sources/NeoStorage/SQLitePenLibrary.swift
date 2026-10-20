import Foundation
import NeoCore

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
public actor SQLitePenLibrary: PenStrokeStore, PenImportBatchStore, PenCleanupJournal {
    /// The schema version this build writes and understands.
    public static let schemaVersion = 1

    private let connection: SQLiteConnection
    private let faultInjection: (@Sendable (Int) throws -> Void)?

    /// Opens or creates a library.
    ///
    /// - Parameters:
    ///   - path: The database file path, or `:memory:` for a throwaway library.
    ///   - faultInjection: A test seam called with each stroke's index just
    ///     before it is written, so a test can prove that a failed import leaves
    ///     the library untouched. Production callers leave it `nil`.
    /// - Throws: `StorageError` when the file cannot be opened or its schema is
    ///   newer than this build.
    public init(path: String, faultInjection: (@Sendable (Int) throws -> Void)? = nil) throws {
        self.connection = try SQLiteConnection(path: path)
        self.faultInjection = faultInjection
        try Self.configure(connection)
        try Self.migrate(connection)
    }

    /// Opens or creates a library at a file URL, creating its directory.
    ///
    /// - Parameters:
    ///   - url: The database file URL.
    ///   - faultInjection: A test seam, as in ``init(path:faultInjection:)``.
    public init(url: URL, faultInjection: (@Sendable (Int) throws -> Void)? = nil) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try self.init(path: url.path, faultInjection: faultInjection)
    }

    // MARK: - Schema

    /// Applies the connection settings the library relies on.
    private static func configure(_ connection: SQLiteConnection) throws {
        // WAL survives an interrupted writer and lets a reader run alongside a
        // writer. It needs a real file, so an in-memory library stays in the
        // default journal mode.
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA synchronous = FULL")
    }

    /// Creates the schema, or verifies the one on disk.
    private static func migrate(_ connection: SQLiteConnection) throws {
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """
        )

        let versionStatement = try connection.prepare(
            "SELECT value FROM metadata WHERE key = 'schema_version'"
        )
        let recorded: Int?
        if try versionStatement.step() {
            recorded = Int(versionStatement.int64(0))
        } else {
            recorded = nil
        }

        if let recorded {
            guard recorded <= schemaVersion else {
                throw StorageError.unsupportedSchemaVersion(
                    found: recorded,
                    supported: schemaVersion
                )
            }
        }

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
                ordinal INTEGER NOT NULL
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

        if recorded == nil {
            let insert = try connection.prepare(
                "INSERT INTO metadata (key, value) VALUES ('schema_version', ?)"
            )
            try insert.bind(1, Int64(schemaVersion))
            try insert.run()
        }
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

    public func save(_ record: PenImportBatchRecord) async throws {
        try connection.withTransaction {
            let existing = try batchOrdinal(batchID: record.batchID)
            let ordinal = try existing ?? nextBatchOrdinal()

            let upsert = try connection.prepare(
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
        }
    }

    public func batch(id: UUID) async throws -> PenImportBatchRecord? {
        let statement = try connection.prepare(
            "SELECT state, stroke_count, dot_count FROM batches WHERE id = ?"
        )
        try statement.bind(1, id.uuidString)
        guard try statement.step() else { return nil }

        let state = statement.text(0).flatMap(ImportBatchState.init(rawValue:)) ?? .collecting
        return PenImportBatchRecord(
            batchID: id,
            state: state,
            pages: try batchPages(batchID: id),
            strokeCount: Int(statement.int64(1)),
            dotCount: Int(statement.int64(2))
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
                PenImportBatchRecord(
                    batchID: identifier,
                    state: state,
                    pages: try batchPages(batchID: identifier),
                    strokeCount: Int(statement.int64(1)),
                    dotCount: Int(statement.int64(2))
                )
            )
        }
        return records
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

