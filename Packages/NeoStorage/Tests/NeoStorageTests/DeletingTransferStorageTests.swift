import Foundation
import NeoCore
import XCTest

@testable import NeoStorage

/// Tests for the durable side of a deleting transfer: the additive schema
/// migration and its pre-migration backup, the packet commit barrier, fresh-read
/// recovery, and the publication and cleanup predicates that keep a deleting
/// batch out of the separate command path.
final class DeletingTransferStorageTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory.remove()
        directory = nil
    }

    // MARK: - Helpers

    private let page = PageIdentity(section: 3, owner: 27, book: 700, page: 36)
    private let secondPage = PageIdentity(section: 3, owner: 27, book: 700, page: 37)
    private let note = PenDeletingReadNote(sectionOwnerID: 27, noteID: 700)

    private func stroke(
        offset: Int64,
        page: PageIdentity? = nil,
        origin: PenOriginTime = .reliable(milliseconds: 1_700_000_000_000)
    ) -> Stroke {
        Stroke(
            page: page ?? self.page,
            originTime: origin,
            points: [
                PenPoint(x: Int32(offset), y: 0, penTimeOffsetMilliseconds: offset, pressure: 3)
            ],
            source: .offline
        )
    }

    private func packet(
        batchID: UUID,
        strokes: [Stroke],
        packetID: UInt16 = 1,
        isEndPacket: Bool = true
    ) -> PenDeletingPacket {
        PenDeletingPacket(
            batchID: batchID,
            sectionOwnerID: 27,
            noteID: 700,
            packetID: packetID,
            strokes: strokes,
            isEndPacket: isEndPacket
        )
    }

    private func exportRequest(pages: [PageIdentity]? = nil) -> PenExportRequest {
        PenExportRequest(
            pages: pages ?? [page, secondPage],
            destinationDirectory: "/tmp/exports"
        )
    }

    private func makeImporter(
        library: SQLitePenLibrary,
        publisher: StubExportPublisher = StubExportPublisher(),
        policy: PenCleanupPolicy = PenCleanupPolicy()
    ) -> PenLibraryImporter {
        PenLibraryImporter(
            store: library,
            batches: library,
            journal: library,
            publisher: publisher,
            policy: policy
        )
    }

    /// The evidence record that opens the separate command gate.
    private func openEvidence(target: PenDeletionTarget = .note) -> PenDeletionEvidence {
        PenDeletionEvidence(
            target: target,
            verdicts: Dictionary(
                uniqueKeysWithValues: PenDeletionCondition.allCases.map { ($0, .safe) }
            )
        )
    }

    /// The schema version recorded in a database file.
    private func schemaVersion(of connection: SQLiteConnection) throws -> Int? {
        let statement = try connection.prepare(
            "SELECT value FROM metadata WHERE key = 'schema_version'"
        )
        guard try statement.step() else { return nil }
        return Int(statement.int64(0))
    }

    /// The column names of a table.
    private func columnNames(of table: String, in connection: SQLiteConnection) throws -> Set<String> {
        let statement = try connection.prepare("PRAGMA table_info(\(table))")
        var names = Set<String>()
        while try statement.step() {
            if let name = statement.text(1) { names.insert(name) }
        }
        return names
    }

    /// The row count of a table.
    private func rowCount(of table: String, in connection: SQLiteConnection) throws -> Int {
        let statement = try connection.prepare("SELECT COUNT(*) FROM \(table)")
        guard try statement.step() else { return 0 }
        return Int(statement.int64(0))
    }

    /// Whether a table exists in a database file.
    private func hasTable(_ table: String, in connection: SQLiteConnection) throws -> Bool {
        let statement = try connection.prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
        )
        try statement.bind(1, table)
        return try statement.step()
    }

    /// Creates a database file at the pre-streaming schema version 1.
    ///
    /// The tables are written by hand, without `kind`, `completion`, or
    /// `packet_count` and without `batch_packets`, so the upgrade path runs against
    /// a real legacy file rather than a simulated one. The file carries one stored
    /// stroke, one committed batch, and one requested cleanup, so the migration's
    /// effect on existing rows is observable.
    ///
    /// - Parameter recordingVersion: Whether the file records its version. A
    ///   version-1 build wrote the tables and the version row as separate
    ///   auto-committing statements, so an interrupted first open leaves the tables
    ///   with no version row at all; `false` builds that state.
    private func makeLegacyDatabase(
        at url: URL,
        batchID: UUID,
        recordingVersion: Bool = true
    ) throws {
        let connection = try SQLiteConnection(path: url.path)
        try connection.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        if recordingVersion {
            try connection.execute("INSERT INTO metadata (key, value) VALUES ('schema_version', '1')")
        }
        try connection.execute(
            """
            CREATE TABLE pages (
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
            CREATE TABLE strokes (
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
        try connection.execute(
            """
            CREATE TABLE points (
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
            CREATE TABLE batches (
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
            CREATE TABLE batch_pages (
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
            CREATE TABLE cleanup_journal (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                batch_id TEXT NOT NULL,
                state TEXT NOT NULL
            )
            """
        )
        try connection.execute(
            """
            CREATE TABLE cleanup_requests (
                batch_id TEXT PRIMARY KEY,
                target TEXT NOT NULL,
                pages TEXT NOT NULL
            )
            """
        )

        try connection.execute("INSERT INTO pages (section, owner, book, page) VALUES (3, 27, 700, 36)")
        try connection.execute(
            """
            INSERT INTO strokes (
                page_id, encoding_version, fingerprint, allows_cross_source_deduplication,
                origin_reliable, origin_milliseconds, source, canonical
            ) VALUES (1, 1, 'legacy-fingerprint', 1, 1, 1700000000000, 'offline', X'00')
            """
        )
        try connection.execute(
            "INSERT INTO points (stroke_id, ordinal, x, y, time_offset, pressure) VALUES (1, 0, 1, 2, 3, 4)"
        )

        let identifier = batchID.uuidString
        try connection.execute(
            """
            INSERT INTO batches (id, state, stroke_count, dot_count, ordinal)
            VALUES ('\(identifier)', 'committed', 1, 1, 1)
            """
        )
        try connection.execute(
            """
            INSERT INTO batch_pages (batch_id, section, owner, book, page)
            VALUES ('\(identifier)', 3, 27, 700, 36)
            """
        )
        try connection.execute(
            "INSERT INTO cleanup_journal (batch_id, state) VALUES ('\(identifier)', 'requested')"
        )
        let pagesJSON = String(
            decoding: try JSONEncoder().encode([page]),
            as: UTF8.self
        )
        try connection.execute(
            """
            INSERT INTO cleanup_requests (batch_id, target, pages)
            VALUES ('\(identifier)', 'note', '\(pagesJSON)')
            """
        )
    }

    // MARK: - Schema migration and pre-migration backup

    func testAFreshDatabaseReportsTheStreamingSchemaAndAllowsDeletingReads() throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let report = library.openReport

        XCTAssertEqual(report.schemaVersion, SQLitePenLibrary.schemaVersion)
        XCTAssertEqual(report.schemaVersion, 2)
        XCTAssertNil(report.migratedFrom)
        XCTAssertNil(report.backupPath)
        XCTAssertTrue(report.deletingReadsAllowed)
        XCTAssertNil(report.deletingReadsUnavailableReason)
    }

    func testOpeningALegacyDatabaseBacksItUpPrivatelyAndMigratesIt() async throws {
        let url = directory.file("library.sqlite")
        let legacyBatchID = UUID()
        try makeLegacyDatabase(at: url, batchID: legacyBatchID)

        let library = try SQLitePenLibrary(url: url)
        let report = library.openReport

        XCTAssertEqual(report.schemaVersion, 2)
        XCTAssertEqual(report.migratedFrom, 1)
        XCTAssertEqual(report.backupPath, url.path + ".backup-v1")
        XCTAssertTrue(report.deletingReadsAllowed)
        XCTAssertNil(report.deletingReadsUnavailableReason)

        // The backup is a private copy of the file exactly as it was: taken before
        // the first write, so it holds the legacy shape and no version-2 table.
        let backupPath = try XCTUnwrap(report.backupPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: backupPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
        let backup = try SQLiteConnection(immutableReadingOnly: backupPath)
        XCTAssertEqual(try schemaVersion(of: backup), 1)
        XCTAssertEqual(try rowCount(of: "strokes", in: backup), 1)
        XCTAssertFalse(try columnNames(of: "batches", in: backup).contains("kind"))
        XCTAssertEqual(
            try hasTable("batch_packets", in: backup),
            false,
            "the backup is the file as it was, not a file the schema step already touched"
        )

        // A legacy batch becomes an ordinary, complete read.
        let record = try await library.batch(id: legacyBatchID)
        XCTAssertEqual(record?.state, .committed)
        XCTAssertEqual(record?.kind, .ordinary)
        XCTAssertEqual(record?.completion, .complete)
        XCTAssertFalse(record?.isDeletingTransfer ?? true)
        XCTAssertTrue(record?.isTransferComplete ?? false)
        XCTAssertEqual(record?.packets, [])

        // The stored stroke and the command-journal row survived.
        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(
            stored.first?.originTime,
            PenOriginTime.reliable(milliseconds: 1_700_000_000_000)
        )
        let states = try await library.recordedStates(batchID: legacyBatchID)
        XCTAssertEqual(states, [.requested])
        let latest = try await library.latestState(batchID: legacyBatchID)
        XCTAssertEqual(latest, .requested)
        let recorded = try await library.recordedScope(batchID: legacyBatchID)
        XCTAssertEqual(recorded?.pages, [page])

        // The migration opened the deleting route, and the new packet table works.
        let deletingBatch = try await library.beginDeletingRead(notes: [note])
        let commit = try await library.commitDeletingPacket(
            packet(batchID: deletingBatch, strokes: [stroke(offset: 1)])
        )
        XCTAssertEqual(commit.committedPacketCount, 1)
        let migrated = try await library.batch(id: deletingBatch)
        XCTAssertEqual(migrated?.kind, .deleting)
        XCTAssertEqual(migrated?.packets.count, 1)
    }

    func testALegacyFileWithoutAVersionRowIsMigratedAndBackedUp() async throws {
        let url = directory.file("library.sqlite")
        let legacyBatchID = UUID()
        // An interrupted first open of a version-1 build leaves the old tables with
        // no version row, because the tables and the row were separate statements.
        try makeLegacyDatabase(at: url, batchID: legacyBatchID, recordingVersion: false)

        let library = try SQLitePenLibrary(url: url)
        let report = library.openReport

        // The upgrade verifies rather than trusts the recorded version: the file is
        // treated as the version-1 shape it has, backed up, and migrated.
        XCTAssertEqual(report.schemaVersion, 2)
        XCTAssertEqual(report.migratedFrom, 1)
        XCTAssertEqual(report.backupPath, url.path + ".backup-v1")
        XCTAssertTrue(report.deletingReadsAllowed)
        XCTAssertNil(report.deletingReadsUnavailableReason)

        // The backup holds the legacy shape, including its missing version row.
        let backupPath = try XCTUnwrap(report.backupPath)
        let backup = try SQLiteConnection(immutableReadingOnly: backupPath)
        XCTAssertNil(try schemaVersion(of: backup))
        XCTAssertFalse(try columnNames(of: "batches", in: backup).contains("kind"))
        XCTAssertEqual(try rowCount(of: "strokes", in: backup), 1)

        // The migrated library is usable: a batch reads back, and a batch writes.
        let record = try await library.batch(id: legacyBatchID)
        XCTAssertEqual(record?.state, .committed)
        XCTAssertEqual(record?.kind, .ordinary)
        XCTAssertEqual(record?.completion, .complete)

        let written = UUID()
        try await library.save(
            PenImportBatchRecord(
                batchID: written,
                state: .published,
                pages: [secondPage],
                strokeCount: 2,
                dotCount: 4
            )
        )
        let stored = try await library.batch(id: written)
        XCTAssertEqual(stored?.state, .published)
        XCTAssertEqual(stored?.packets, [])

        // The deleting route is open, and the packet table the file did not have
        // works.
        let deletingBatch = try await library.beginDeletingRead(notes: [note])
        let commit = try await library.commitDeletingPacket(
            packet(batchID: deletingBatch, strokes: [stroke(offset: 3)])
        )
        XCTAssertEqual(commit.committedPacketCount, 1)
        let migrated = try await library.batch(id: deletingBatch)
        XCTAssertEqual(migrated?.kind, .deleting)
        XCTAssertEqual(migrated?.packets.map(\.strokeCount), [1])
    }

    func testAVersionTwoRowWithoutTheColumnsIsRepairedRatherThanTrusted() async throws {
        let url = directory.file("library.sqlite")
        let legacyBatchID = UUID()
        // A file that records version 2 over the version-1 table shape: the record
        // alone must not make a library claim a schema its columns do not have.
        try makeLegacyDatabase(at: url, batchID: legacyBatchID, recordingVersion: false)
        let seeded = try SQLiteConnection(path: url.path)
        try seeded.execute("INSERT INTO metadata (key, value) VALUES ('schema_version', '2')")

        let library = try SQLitePenLibrary(url: url)
        let report = library.openReport

        XCTAssertEqual(report.schemaVersion, 2)
        XCTAssertEqual(report.migratedFrom, 2, "the columns were missing, so the file was migrated")
        XCTAssertEqual(report.backupPath, url.path + ".backup-v2")
        XCTAssertTrue(report.deletingReadsAllowed)

        // The library works, which it would not if the version row had been trusted.
        let record = try await library.batch(id: legacyBatchID)
        XCTAssertEqual(record?.kind, .ordinary)
        let deletingBatch = try await library.beginDeletingRead(notes: [note])
        let commit = try await library.commitDeletingPacket(
            packet(batchID: deletingBatch, strokes: [stroke(offset: 5)])
        )
        XCTAssertEqual(commit.committedPacketCount, 1)
    }

    func testAnUnreadableVersionRowIsRefusedRatherThanTreatedAsLegacy() throws {
        let url = directory.file("library.sqlite")
        let legacyBatchID = UUID()
        try makeLegacyDatabase(at: url, batchID: legacyBatchID, recordingVersion: false)
        let seeded = try SQLiteConnection(path: url.path)
        try seeded.execute("INSERT INTO metadata (key, value) VALUES ('schema_version', 'two')")

        XCTAssertThrowsError(try SQLitePenLibrary(url: url)) { error in
            guard case .unreadableSchemaVersion(let found, let supported) = error as? StorageError
            else {
                return XCTFail("expected unreadableSchemaVersion, got \(error)")
            }
            XCTAssertEqual(found, "two")
            XCTAssertEqual(supported, SQLitePenLibrary.schemaVersion)
        }

        // Nothing was written: the file is still at its legacy shape.
        let connection = try SQLiteConnection(path: url.path)
        XCTAssertFalse(try columnNames(of: "batches", in: connection).contains("kind"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".backup-v1"))
    }

    func testSavingABatchWithPacketsStoresTheRowsItsCountNames() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let batchID = UUID()
        let packets = [
            PenImportPacketProgress(
                sectionOwnerID: 27,
                noteID: 700,
                packetID: 1,
                strokeCount: 3,
                isEndPacket: false
            ),
            PenImportPacketProgress(
                sectionOwnerID: 27,
                noteID: 700,
                packetID: 2,
                strokeCount: 1,
                isEndPacket: true
            ),
        ]

        try await library.save(
            PenImportBatchRecord(
                batchID: batchID,
                state: .committed,
                kind: .deleting,
                completion: .partial,
                pages: [page],
                strokeCount: 4,
                dotCount: 4,
                packets: packets
            )
        )

        // The stored rows and the stored count agree, so a restart cannot report a
        // packet prefix beside an empty packet list.
        let stored = try await library.batch(id: batchID)
        XCTAssertEqual(stored?.packets, packets)
        XCTAssertEqual(stored?.packets.count, 2)

        // Rewriting the batch replaces its rows rather than appending to them.
        try await library.save(
            PenImportBatchRecord(
                batchID: batchID,
                state: .published,
                kind: .deleting,
                completion: .complete,
                pages: [page],
                strokeCount: 4,
                dotCount: 4,
                packets: [packets[0]]
            )
        )
        let rewritten = try await library.batch(id: batchID)
        XCTAssertEqual(rewritten?.packets, [packets[0]])
        XCTAssertEqual(rewritten?.completion, .complete)
        XCTAssertEqual(rewritten?.state, .published)
    }

    func testALegacyFileInAPathWithReservedCharactersIsStillVerifiedAndMigrated() async throws {
        // The app's real path is `~/Library/Application Support/NeoBridge/library.sqlite`,
        // so a space in the path has to survive the backup check. The copy is reopened
        // through SQLite's URI syntax, where the space is harmless but `#` starts a
        // fragment, so this directory holds both: an unencoded path would name the
        // database as `.../Application Support ` and fail to open the copy.
        let containing = directory.file("Application Support #1")
        try FileManager.default.createDirectory(at: containing, withIntermediateDirectories: true)
        let url = containing.appendingPathComponent("library.sqlite")
        let legacyBatchID = UUID()
        try makeLegacyDatabase(at: url, batchID: legacyBatchID)

        let library = try SQLitePenLibrary(url: url)
        let report = library.openReport

        XCTAssertEqual(report.backupPath, url.path + ".backup-v1")
        XCTAssertTrue(report.deletingReadsAllowed)
        XCTAssertNil(report.deletingReadsUnavailableReason)

        let backup = try SQLiteConnection(immutableReadingOnly: try XCTUnwrap(report.backupPath))
        XCTAssertEqual(try schemaVersion(of: backup), 1)
        XCTAssertEqual(try rowCount(of: "strokes", in: backup), 1)

        let record = try await library.batch(id: legacyBatchID)
        XCTAssertEqual(record?.state, .committed)
        XCTAssertEqual(record?.kind, .ordinary)
    }

    func testAFailedPreMigrationBackupLeavesTheLegacyFileAndDisablesDeletingReads() async throws {
        let url = directory.file("library.sqlite")
        let legacyBatchID = UUID()
        try makeLegacyDatabase(at: url, batchID: legacyBatchID)

        let library = try SQLitePenLibrary(
            url: url,
            backupFaultInjection: { throw InjectedFailure.stopped }
        )
        let report = library.openReport

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertNil(report.migratedFrom)
        XCTAssertNil(report.backupPath)
        XCTAssertFalse(report.deletingReadsAllowed)
        let reason = try XCTUnwrap(report.deletingReadsUnavailableReason)
        XCTAssertTrue(reason.contains("could not be backed up"), reason)

        // Nothing was copied and the file is still at its recorded version, with no
        // streaming columns.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".backup-v1"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
                .filter { $0.contains(".partial-") },
            [],
            "a failed copy must not leave a temporary behind"
        )
        let connection = try SQLiteConnection(path: url.path)
        XCTAssertEqual(try schemaVersion(of: connection), 1)
        XCTAssertFalse(try columnNames(of: "batches", in: connection).contains("kind"))
        XCTAssertFalse(try columnNames(of: "batches", in: connection).contains("completion"))

        // The deleting route refuses rather than committing into a schema it never
        // migrated.
        do {
            _ = try await library.beginDeletingRead(notes: [note])
            XCTFail("expected the deleting route to be closed")
        } catch let error as StorageError {
            guard case .deletingReadsUnavailable(let refusal) = error else {
                return XCTFail("expected deletingReadsUnavailable, got \(error)")
            }
            XCTAssertTrue(refusal.contains("backup failed"), refusal)
        }

        // Ordinary reads, exports, and writes still work in legacy mode.
        let record = try await library.batch(id: legacyBatchID)
        XCTAssertEqual(record?.kind, .ordinary)
        XCTAssertEqual(record?.completion, .complete)
        let insertion = try await library.insert([stroke(offset: 9)])
        XCTAssertEqual(insertion.addedStrokeCount, 1)
        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored.count, 2)
    }

    func testALeftoverBackupDoesNotBlockTheNextOpen() async throws {
        // `backup(to:)` opens a path that already exists, so an unreadable file left
        // at the backup's name by an earlier failed open would fail every later backup
        // and keep the deleting route closed for a reason that has nothing to do with
        // the file being migrated. The copy is built under a temporary name and moved
        // into place, so a leftover is replaced instead of reused.
        let url = directory.file("library.sqlite")
        let legacyBatchID = UUID()
        try makeLegacyDatabase(at: url, batchID: legacyBatchID)

        // What a copy that failed mid-write, or that verification rejected, leaves.
        let destination = url.path + ".backup-v1"
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: destination))

        let library = try SQLitePenLibrary(url: url)
        let report = library.openReport

        XCTAssertEqual(report.backupPath, destination, "the open still takes its backup")
        XCTAssertTrue(report.deletingReadsAllowed)
        XCTAssertNil(report.deletingReadsUnavailableReason)

        // The leftover was replaced by a copy that verifies as a copy of the legacy
        // file.
        let backup = try SQLiteConnection(immutableReadingOnly: destination)
        XCTAssertEqual(try schemaVersion(of: backup), 1)
        XCTAssertEqual(try rowCount(of: "strokes", in: backup), 1)
        XCTAssertFalse(try columnNames(of: "batches", in: backup).contains("kind"))

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
                .filter { $0.contains(".partial-") },
            [],
            "a temporary copy must not be left behind"
        )

        // The library itself is migrated and usable.
        let record = try await library.batch(id: legacyBatchID)
        XCTAssertEqual(record?.state, .committed)
        XCTAssertEqual(record?.kind, .ordinary)
    }

    func testAnUnknownBatchStateIsRefusedRatherThanReportedAsAnother() async throws {
        let url = directory.file("library.sqlite")
        let batchID = UUID()
        do {
            let library = try SQLitePenLibrary(url: url)
            try await library.save(
                PenImportBatchRecord(
                    batchID: batchID,
                    state: .committed,
                    pages: [page],
                    strokeCount: 1,
                    dotCount: 1
                )
            )
        }
        do {
            let connection = try SQLiteConnection(path: url.path)
            try connection.execute(
                "UPDATE batches SET state = 'teleported' WHERE id = '\(batchID.uuidString)'"
            )
        }

        let reopened = try SQLitePenLibrary(url: url)
        do {
            _ = try await reopened.batch(id: batchID)
            XCTFail("expected an unknown state to be refused")
        } catch {
            XCTAssertEqual(error as? StorageError, .unreadableBatchState(batchID: batchID))
        }
    }

    func testAnUnknownBatchKindIsRefusedRatherThanReportedAsOrdinary() async throws {
        let url = directory.file("library.sqlite")
        let batchID = UUID()
        do {
            let library = try SQLitePenLibrary(url: url)
            try await library.save(
                PenImportBatchRecord(
                    batchID: batchID,
                    state: .committed,
                    pages: [page],
                    strokeCount: 1,
                    dotCount: 1
                )
            )
        }
        do {
            let connection = try SQLiteConnection(path: url.path)
            try connection.execute(
                "UPDATE batches SET kind = 'teleported' WHERE id = '\(batchID.uuidString)'"
            )
        }

        let reopened = try SQLitePenLibrary(url: url)
        do {
            _ = try await reopened.batch(id: batchID)
            XCTFail("expected an unknown kind to be refused")
        } catch {
            XCTAssertEqual(error as? StorageError, .unreadableBatchState(batchID: batchID))
        }
    }

    func testAnUnknownBatchCompletionIsRefusedRatherThanReportedAsComplete() async throws {
        let url = directory.file("library.sqlite")
        let batchID = UUID()
        do {
            let library = try SQLitePenLibrary(url: url)
            try await library.save(
                PenImportBatchRecord(
                    batchID: batchID,
                    state: .committed,
                    pages: [page],
                    strokeCount: 1,
                    dotCount: 1
                )
            )
        }
        do {
            let connection = try SQLiteConnection(path: url.path)
            try connection.execute(
                "UPDATE batches SET completion = 'maybe' WHERE id = '\(batchID.uuidString)'"
            )
        }

        let reopened = try SQLitePenLibrary(url: url)
        do {
            _ = try await reopened.batch(id: batchID)
            XCTFail("expected an unknown completion to be refused")
        } catch {
            XCTAssertEqual(error as? StorageError, .unreadableBatchCompletion(batchID: batchID))
        }

        // A listing reads the same durable values, so it refuses the row too.
        do {
            _ = try await reopened.batches(in: .committed)
            XCTFail("expected the listing to refuse the same row")
        } catch {
            XCTAssertEqual(error as? StorageError, .unreadableBatchCompletion(batchID: batchID))
        }
    }

    // MARK: - Packet commit durability

    func testCommittedDeletingPacketsSurviveAReopen() async throws {
        let url = directory.file("library.sqlite")
        let batchID: UUID
        do {
            let library = try SQLitePenLibrary(url: url)
            batchID = try await library.beginDeletingRead(notes: [note])

            // The batch exists before the first 0x23, as a deleting transfer that is
            // committed and still in progress.
            let started = try await library.batch(id: batchID)
            XCTAssertEqual(started?.state, .committed)
            XCTAssertEqual(started?.kind, .deleting)
            XCTAssertEqual(started?.completion, .inProgress)
            XCTAssertEqual(started?.strokeCount, 0)
            XCTAssertEqual(started?.packets, [])

            let first = try await library.commitDeletingPacket(
                packet(
                    batchID: batchID,
                    strokes: [stroke(offset: 1), stroke(offset: 2)],
                    packetID: 1,
                    isEndPacket: false
                )
            )
            XCTAssertEqual(first.committedPacketCount, 1)
            XCTAssertEqual(first.committedStrokeCount, 2)
            XCTAssertEqual(first.committedDotCount, 2)
            XCTAssertEqual(first.addedStrokeCount, 2)
            XCTAssertEqual(first.duplicateStrokeCount, 0)
            XCTAssertFalse(first.isEndPacket)

            let second = try await library.commitDeletingPacket(
                packet(
                    batchID: batchID,
                    strokes: [stroke(offset: 3, page: secondPage)],
                    packetID: 2
                )
            )
            XCTAssertEqual(second.committedPacketCount, 2)
            XCTAssertEqual(second.committedStrokeCount, 3)
            XCTAssertEqual(second.committedDotCount, 3)
            XCTAssertTrue(second.isEndPacket)
        }

        let reopened = try SQLitePenLibrary(url: url)
        let record = try await reopened.batch(id: batchID)
        XCTAssertEqual(record?.state, .committed)
        XCTAssertEqual(record?.kind, .deleting)
        XCTAssertEqual(record?.completion, .inProgress)
        XCTAssertEqual(record?.strokeCount, 3)
        XCTAssertEqual(record?.dotCount, 3)
        XCTAssertEqual(
            record?.packets,
            [
                PenImportPacketProgress(
                    sectionOwnerID: 27,
                    noteID: 700,
                    packetID: 1,
                    strokeCount: 2,
                    isEndPacket: false
                ),
                PenImportPacketProgress(
                    sectionOwnerID: 27,
                    noteID: 700,
                    packetID: 2,
                    strokeCount: 1,
                    isEndPacket: true
                ),
            ]
        )
        XCTAssertEqual(record?.pages, [page, secondPage])
        let firstPage = try await reopened.strokes(on: page)
        XCTAssertEqual(firstPage.count, 2)
        let second = try await reopened.strokes(on: secondPage)
        XCTAssertEqual(second.count, 1)
    }

    func testFinishingADeletingReadRecordsCompletionWithoutChangingPublication() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let batchID = try await library.beginDeletingRead(notes: [note])
        _ = try await library.commitDeletingPacket(
            packet(batchID: batchID, strokes: [stroke(offset: 1)], isEndPacket: true)
        )

        try await library.finishDeletingRead(batchID: batchID, isComplete: true)

        let record = try await library.batch(id: batchID)
        XCTAssertEqual(record?.completion, .complete)
        XCTAssertEqual(record?.state, .committed, "completion is independent of publication")
        XCTAssertTrue(record?.isTransferComplete ?? false)
        XCTAssertEqual(record?.packets.count, 1)
    }

    func testAReadThatEndsBeforeItsFirstPacketLeavesAFailedBatchThatStaysVisible() async throws {
        let url = directory.file("library.sqlite")
        let library = try SQLitePenLibrary(url: url)
        let batchID = try await library.beginDeletingRead(notes: [note])

        // The batch is opened before the first `0x23`, so the read that opened it
        // must be able to mark it failed when it ends without a durable packet.
        try await library.failDeletingRead(batchID: batchID)

        // The row stays: it is the durable record that a read was attempted, which
        // the journal and a later diagnosis need.
        let record = try await library.batch(id: batchID)
        XCTAssertEqual(record?.kind, .deleting)
        XCTAssertEqual(record?.state, .failed)
        XCTAssertEqual(record?.completion, .partial)
        XCTAssertEqual(record?.packets, [])
        XCTAssertEqual(record?.pages, [])
        XCTAssertEqual(record?.strokeCount, 0)
        XCTAssertEqual(record?.dotCount, 0)

        // It is visible as a failed batch rather than as one still in progress, and
        // it can never publish, because publication needs a durable packet.
        let failed = try await library.batches(in: .failed)
        XCTAssertEqual(failed.map(\.batchID), [batchID])
        let committed = try await library.batches(in: .committed)
        XCTAssertEqual(committed, [])
        XCTAssertFalse(record?.isPublicationRetryable ?? true)
        XCTAssertFalse(record?.isTransferComplete ?? true)

        // A second call writes nothing: the marking is idempotent.
        try await library.failDeletingRead(batchID: batchID)
        let again = try await library.batch(id: batchID)
        XCTAssertEqual(again?.state, .failed)
        XCTAssertEqual(again?.completion, .partial)

        // And the failure is durable, so a later open reads it rather than an
        // in-progress transfer.
        let reopened = try SQLitePenLibrary(url: url)
        let afterReopen = try await reopened.batch(id: batchID)
        XCTAssertEqual(afterReopen?.state, .failed)
        XCTAssertEqual(afterReopen?.completion, .partial)
        XCTAssertEqual(afterReopen?.packets, [])
    }

    func testMarkingAnEmptyDeletingBatchFailedLeavesEveryOtherBatchAlone() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))

        // An ordinary batch, which this call must never reinterpret.
        let ordinary = UUID()
        try await library.save(
            PenImportBatchRecord(
                batchID: ordinary,
                state: .published,
                pages: [page],
                strokeCount: 1,
                dotCount: 1
            )
        )

        // A deleting batch with a durable prefix: its state is what its own record
        // already says, so the marking must leave it alone.
        let withPacket = try await library.beginDeletingRead(notes: [note])
        _ = try await library.commitDeletingPacket(
            packet(batchID: withPacket, strokes: [stroke(offset: 1)], packetID: 1, isEndPacket: false)
        )

        // A deleting batch whose read already finished.
        let finished = try await library.beginDeletingRead(notes: [note])
        _ = try await library.commitDeletingPacket(
            packet(batchID: finished, strokes: [stroke(offset: 2)])
        )
        try await library.finishDeletingRead(batchID: finished, isComplete: true)

        for batchID in [ordinary, withPacket, finished] {
            try await library.failDeletingRead(batchID: batchID)
        }
        // An identifier no batch holds is a no-op as well.
        try await library.failDeletingRead(batchID: UUID())

        let published = try await library.batch(id: ordinary)
        XCTAssertEqual(published?.state, .published)
        XCTAssertEqual(published?.kind, .ordinary)
        XCTAssertEqual(published?.completion, .complete)

        let prefix = try await library.batch(id: withPacket)
        XCTAssertEqual(prefix?.state, .committed)
        XCTAssertEqual(prefix?.completion, .inProgress)
        XCTAssertEqual(prefix?.packets.count, 1)
        XCTAssertTrue(prefix?.isPublicationRetryable ?? false, "a durable prefix stays publishable")

        let completed = try await library.batch(id: finished)
        XCTAssertEqual(completed?.state, .committed)
        XCTAssertEqual(completed?.completion, .complete)
        XCTAssertEqual(completed?.packets.count, 1)
    }

    func testAFailedPacketCommitRollsThePacketBackAndKeepsEarlierPackets() async throws {
        let url = directory.file("library.sqlite")
        let library = try SQLitePenLibrary(
            url: url,
            packetFaultInjection: { ordinal in
                if ordinal == 1 { throw InjectedFailure.stopped }
            }
        )
        let batchID = try await library.beginDeletingRead(notes: [note])
        _ = try await library.commitDeletingPacket(
            packet(batchID: batchID, strokes: [stroke(offset: 1)], packetID: 1, isEndPacket: false)
        )

        let second = packet(
            batchID: batchID,
            strokes: [stroke(offset: 2), stroke(offset: 3)],
            packetID: 2
        )
        do {
            _ = try await library.commitDeletingPacket(second)
            XCTFail("expected the injected failure to surface")
        } catch {
            XCTAssertEqual(error as? InjectedFailure, .stopped)
        }

        // The first packet is durable; the failed packet left nothing behind, so
        // nothing was acknowledged for it.
        let record = try await library.batch(id: batchID)
        XCTAssertEqual(record?.strokeCount, 1)
        XCTAssertEqual(record?.packets.count, 1)
        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored.count, 1)

        // The library is still usable, so the read can be replayed after a restart.
        let reopened = try SQLitePenLibrary(url: url)
        let retried = try await reopened.commitDeletingPacket(second)
        XCTAssertEqual(retried.committedPacketCount, 2)
        XCTAssertEqual(retried.addedStrokeCount, 2)
        let afterRetry = try await reopened.strokes(on: page)
        XCTAssertEqual(afterRetry.count, 3)
    }

    func testABatchCountsOnlyTheStrokesItAdded() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        // The pen already handed this stroke over in an earlier read, so the library
        // holds it before the deleting batch commits it.
        let replayed = stroke(offset: 1)
        _ = try await library.insert([replayed])

        let batchID = try await library.beginDeletingRead(notes: [note])
        let fresh = stroke(offset: 2)
        let result = try await library.commitDeletingPacket(
            packet(batchID: batchID, strokes: [replayed, fresh])
        )

        XCTAssertEqual(result.addedStrokeCount, 1)
        XCTAssertEqual(result.duplicateStrokeCount, 1)
        XCTAssertEqual(result.committedStrokeCount, 1, "the batch reports only its own strokes")
        XCTAssertEqual(result.committedDotCount, 1)
        let record = try await library.batch(id: batchID)
        XCTAssertEqual(record?.strokeCount, 1)
        XCTAssertEqual(record?.dotCount, 1)
        XCTAssertEqual(record?.packets.first?.strokeCount, 2, "the packet handed over both strokes")
    }

    // MARK: - Fresh-read recovery

    func testAFreshReadStartsANewBatchWithoutDuplicatingReliableStrokes() async throws {
        let url = directory.file("library.sqlite")
        let strokes = [stroke(offset: 1), stroke(offset: 2)]

        let library = try SQLitePenLibrary(url: url)
        let crashed = try await library.beginDeletingRead(notes: [note])
        _ = try await library.commitDeletingPacket(
            packet(batchID: crashed, strokes: strokes, packetID: 1, isEndPacket: false)
        )

        // A restart re-reads the pen, which hands the same packet over again.
        let reopened = try SQLitePenLibrary(url: url)
        let recovered = try await reopened.beginDeletingRead(notes: [note])
        XCTAssertNotEqual(recovered, crashed)
        let result = try await reopened.commitDeletingPacket(
            packet(batchID: recovered, strokes: strokes, packetID: 1)
        )

        XCTAssertEqual(result.addedStrokeCount, 0)
        XCTAssertEqual(result.duplicateStrokeCount, 2)
        XCTAssertEqual(result.committedStrokeCount, 0)
        let stored = try await reopened.strokes(on: page)
        XCTAssertEqual(stored.count, 2, "a replay must not duplicate a reliable stroke")

        // The interrupted batch keeps its durable prefix and stays partial.
        let old = try await reopened.batch(id: crashed)
        XCTAssertEqual(old?.strokeCount, 2)
        XCTAssertEqual(old?.completion, .inProgress)
        XCTAssertEqual(old?.packets.count, 1)
    }

    func testAmbiguousUnreliableStrokesKeepTheirMultiplicityAcrossDeletingReads() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let ambiguous = stroke(offset: 1, origin: .unreliable(reportedMilliseconds: nil))

        let first = try await library.beginDeletingRead(notes: [note])
        let firstResult = try await library.commitDeletingPacket(
            packet(batchID: first, strokes: [ambiguous], packetID: 1, isEndPacket: false)
        )
        let second = try await library.beginDeletingRead(notes: [note])
        let secondResult = try await library.commitDeletingPacket(
            packet(batchID: second, strokes: [ambiguous])
        )

        XCTAssertEqual(firstResult.addedStrokeCount, 1)
        XCTAssertEqual(secondResult.addedStrokeCount, 1, "an unreliable replay must not collapse")
        XCTAssertEqual(secondResult.duplicateStrokeCount, 0)
        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored.count, 2)
    }

    // MARK: - Publication of a partial deleting batch

    func testAPartialDeletingBatchPublishesWithoutChangingCompletion() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let publisher = StubExportPublisher()
        let importer = makeImporter(library: library, publisher: publisher)

        let batchID = try await library.beginDeletingRead(notes: [note])
        _ = try await library.commitDeletingPacket(
            packet(batchID: batchID, strokes: [stroke(offset: 1)], packetID: 1, isEndPacket: false)
        )
        try await library.finishDeletingRead(batchID: batchID, isComplete: false)

        let report = try await importer.publish(batchID, request: exportRequest())
        XCTAssertTrue(report.succeeded)

        let record = try await library.batch(id: batchID)
        XCTAssertEqual(record?.state, .published)
        XCTAssertEqual(record?.kind, .deleting)
        XCTAssertEqual(record?.completion, .partial, "publication must not complete a partial read")

        // The rendered content came from the durable rows, not a buffer.
        let content = await publisher.calls.allContent
        XCTAssertEqual(content.last?.map(\.page), [page])
        XCTAssertEqual(content.last?.first?.strokes.count, 1)
    }

    func testAFailedDeletingBatchPublicationLeavesItCommittedAndPartial() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let importer = makeImporter(
            library: library,
            publisher: StubExportPublisher(failures: [.svg: "disk full"])
        )

        let batchID = try await library.beginDeletingRead(notes: [note])
        _ = try await library.commitDeletingPacket(
            packet(batchID: batchID, strokes: [stroke(offset: 1)], packetID: 1, isEndPacket: false)
        )
        try await library.finishDeletingRead(batchID: batchID, isComplete: false)

        let report = try await importer.publish(batchID, request: exportRequest())
        XCTAssertFalse(report.succeeded)

        let record = try await library.batch(id: batchID)
        XCTAssertEqual(record?.state, .committed)
        XCTAssertEqual(record?.completion, .partial)
        XCTAssertTrue(record?.isPublicationRetryable ?? false)
    }

    func testARestartedProcessRetriesPublicationOfAPartialDeletingBatch() async throws {
        let url = directory.file("library.sqlite")
        let batchID: UUID
        do {
            let library = try SQLitePenLibrary(url: url)
            batchID = try await library.beginDeletingRead(notes: [note])
            _ = try await library.commitDeletingPacket(
                packet(batchID: batchID, strokes: [stroke(offset: 1)], packetID: 1, isEndPacket: false)
            )
            try await library.finishDeletingRead(batchID: batchID, isComplete: false)
        }

        let reopened = try SQLitePenLibrary(url: url)
        let publisher = StubExportPublisher()
        let importer = makeImporter(library: reopened, publisher: publisher)

        let report = try await importer.retryExport(batchID: batchID, request: exportRequest())
        XCTAssertTrue(report.succeeded)

        let record = try await reopened.batch(id: batchID)
        XCTAssertEqual(record?.state, .published)
        XCTAssertEqual(record?.completion, .partial)
        let content = await publisher.calls.allContent
        XCTAssertEqual(content.last?.first?.strokes.count, 1)
    }

    // MARK: - Cleanup predicates

    func testRequestCleanupRefusesEveryDeletingBatch() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )

        // A published, complete deleting batch.
        let complete = try await library.beginDeletingRead(notes: [note])
        _ = try await library.commitDeletingPacket(
            packet(batchID: complete, strokes: [stroke(offset: 1)], isEndPacket: true)
        )
        try await library.finishDeletingRead(batchID: complete, isComplete: true)
        _ = try await importer.publish(complete, request: exportRequest(pages: [page]))

        // A published, partial deleting batch.
        let partial = try await library.beginDeletingRead(notes: [note])
        _ = try await library.commitDeletingPacket(
            packet(
                batchID: partial,
                strokes: [stroke(offset: 2, page: secondPage)],
                packetID: 1,
                isEndPacket: false
            )
        )
        try await library.finishDeletingRead(batchID: partial, isComplete: false)
        _ = try await importer.publish(partial, request: exportRequest(pages: [secondPage]))

        for batchID in [complete, partial] {
            let outcome = try await importer.requestCleanup(
                batchID,
                request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
            )
            guard case .skipped(let reason) = outcome else {
                return XCTFail("expected the deleting batch to be skipped, got \(outcome)")
            }
            XCTAssertTrue(reason.contains("transfer cleanup"), reason)
            let states = try await library.recordedStates(batchID: batchID)
            XCTAssertEqual(states, [], "a deleting batch must journal no command scope")
        }

        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "a deleting batch must never reach the pen as a command")
    }

    func testAPublishedPartialDeletingBatchBlocksASharedPageFromASeparateCommand() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )

        // The deleting read committed page 36 and stopped before its end packet.
        let deleting = try await library.beginDeletingRead(notes: [note])
        _ = try await library.commitDeletingPacket(
            packet(batchID: deleting, strokes: [stroke(offset: 1)], packetID: 1, isEndPacket: false)
        )
        try await library.finishDeletingRead(batchID: deleting, isComplete: false)
        _ = try await importer.publish(deleting, request: exportRequest(pages: [page]))

        // An ordinary read over the same page publishes in full.
        let outcome = try await importer.importRead(
            PenReadTransfer(strokes: [stroke(offset: 5)], noteCount: 1),
            export: exportRequest(pages: [page])
        )
        let ordinaryID = try XCTUnwrap(outcome.save?.batchID)

        let cleanup = try await importer.requestCleanup(
            ordinaryID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        guard case .skipped(let reason) = cleanup else {
            return XCTFail("expected the shared page to block the command, got \(cleanup)")
        }
        XCTAssertTrue(reason.contains("has not completed"), reason)
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "a page a deleting read still covers must stay on the pen")
    }

    func testAPublishedCompleteOrdinaryBatchDoesNotBlockASharedPage() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )

        for offset in Int64(1)...2 {
            let outcome = try await importer.importRead(
                PenReadTransfer(strokes: [stroke(offset: offset)], noteCount: 1),
                export: exportRequest(pages: [page])
            )
            XCTAssertTrue(outcome.export?.succeeded ?? false)
        }

        let target = try await importer.importRead(
            PenReadTransfer(strokes: [stroke(offset: 3)], noteCount: 1),
            export: exportRequest(pages: [page])
        )
        let batchID = try XCTUnwrap(target.save?.batchID)

        let cleanup = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        XCTAssertEqual(cleanup, .reclaimed(pageCount: 1))
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(states, [.prepared, .requested, .confirmed])
    }

    func testAnOrdinaryPublishedCompleteBatchStillReclaimsThroughTheCommandGate() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )

        let outcome = try await importer.importRead(
            PenReadTransfer(strokes: [stroke(offset: 1)], noteCount: 1),
            export: exportRequest(pages: [page])
        )
        let batchID = try XCTUnwrap(outcome.save?.batchID)

        let cleanup = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        XCTAssertEqual(cleanup, .reclaimed(pageCount: 1))
    }

    // MARK: - Rollback configuration

    func testARollbackConfigurationRefusesDeletingReadsButStillReadsAndExports() async throws {
        let url = directory.file("library.sqlite")
        let batchID: UUID
        do {
            let library = try SQLitePenLibrary(url: url)
            batchID = try await library.beginDeletingRead(notes: [note])
            _ = try await library.commitDeletingPacket(
                packet(batchID: batchID, strokes: [stroke(offset: 1)], packetID: 1, isEndPacket: false)
            )
            try await library.finishDeletingRead(batchID: batchID, isComplete: false)
            _ = try await makeImporter(library: library).publish(
                batchID,
                request: exportRequest(pages: [page])
            )
        }

        let rollback = try SQLitePenLibrary(url: url, deletingReadsEnabled: false)
        XCTAssertEqual(rollback.openReport.schemaVersion, 2)
        XCTAssertFalse(rollback.openReport.deletingReadsAllowed)
        XCTAssertEqual(
            rollback.openReport.deletingReadsUnavailableReason,
            "this configuration disables the deleting-transfer route"
        )

        // The partial + published batch survives the rollback configuration.
        let record = try await rollback.batch(id: batchID)
        XCTAssertEqual(record?.kind, .deleting)
        XCTAssertEqual(record?.state, .published)
        XCTAssertEqual(record?.completion, .partial)
        XCTAssertEqual(record?.packets.count, 1)
        XCTAssertEqual(record?.strokeCount, 1)
        XCTAssertEqual(record?.pages, [page])

        // And it can still be exported from its durable rows.
        let publisher = StubExportPublisher()
        let importer = makeImporter(library: rollback, publisher: publisher)
        let report = try await importer.retryExport(batchID: batchID, request: exportRequest(pages: [page]))
        XCTAssertTrue(report.succeeded)
        let content = await publisher.calls.allContent
        XCTAssertEqual(content.last?.first?.strokes.count, 1)

        // A new deleting read is refused.
        do {
            _ = try await rollback.beginDeletingRead(notes: [note])
            XCTFail("expected the rollback configuration to refuse a deleting read")
        } catch let error as StorageError {
            guard case .deletingReadsUnavailable(let reason) = error else {
                return XCTFail("expected deletingReadsUnavailable, got \(error)")
            }
            XCTAssertTrue(reason.contains("disables"), reason)
        }

        // So is a packet commit, and the refused commit writes nothing.
        do {
            _ = try await rollback.commitDeletingPacket(
                packet(batchID: batchID, strokes: [stroke(offset: 9)], packetID: 2)
            )
            XCTFail("expected the rollback configuration to refuse a packet commit")
        } catch let error as StorageError {
            guard case .deletingReadsUnavailable = error else {
                return XCTFail("expected deletingReadsUnavailable, got \(error)")
            }
        }
        let stored = try await rollback.strokes(on: page)
        XCTAssertEqual(stored.count, 1, "a refused commit must write nothing")
    }

    func testTheMigratedDatabaseIsRefusedByASchemaUnawareBuild() async throws {
        let url = directory.file("library.sqlite")
        try makeLegacyDatabase(at: url, batchID: UUID())
        _ = try SQLitePenLibrary(url: url)

        // The migrated file records the streaming version, so a build that
        // understands only the legacy version meets the version guard.
        let connection = try SQLiteConnection(path: url.path)
        XCTAssertEqual(try schemaVersion(of: connection), 2)

        try connection.execute("UPDATE metadata SET value = '3' WHERE key = 'schema_version'")
        XCTAssertThrowsError(try SQLitePenLibrary(url: url)) { error in
            XCTAssertEqual(
                error as? StorageError,
                .unsupportedSchemaVersion(found: 3, supported: SQLitePenLibrary.schemaVersion)
            )
        }
    }
}
