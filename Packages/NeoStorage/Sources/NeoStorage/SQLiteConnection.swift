import CSQLite
import Foundation
import NeoCore

/// A failure raised by the storage layer.
public enum StorageError: Error, Hashable, Sendable {
    /// The database file could not be opened.
    case cannotOpenDatabase(path: String, message: String)

    /// A statement could not be prepared, bound, or stepped.
    case statementFailed(sql: String, message: String)

    /// The schema on disk is newer than this build understands.
    ///
    /// The database is left untouched: a newer file may hold columns this build
    /// would drop.
    case unsupportedSchemaVersion(found: Int, supported: Int)

    /// The recorded schema version is not a number.
    ///
    /// The database is left untouched: a version this build cannot read is
    /// refused rather than treated as an older file, because reading it as
    /// "older" would migrate a file whose schema is unknown.
    case unreadableSchemaVersion(found: String, supported: Int)

    /// A batch is unknown, or is not in a state that allows the requested step.
    case batchNotReady(batchID: UUID, state: ImportBatchState?)

    /// A batch's collected strokes are no longer in memory.
    ///
    /// The process restarted between collection and commit, so the read must be
    /// taken from the pen again rather than committed from a partial buffer.
    case collectedStrokesUnavailable(batchID: UUID)

    /// A recorded cleanup scope could not be read back.
    ///
    /// The row holds a value this build does not understand, so the request's
    /// scope cannot be trusted and no deletion may be sent for it.
    case unreadableCleanupScope(batchID: UUID)

    /// A recorded cleanup state could not be read back.
    ///
    /// The row holds a state this build does not understand, so whether the
    /// request was already sent cannot be known. It is refused rather than read
    /// as "never requested", which would risk sending a second deletion for the
    /// same scope.
    case unreadableCleanupState(batchID: UUID)

    /// The pre-migration backup could not be created or verified.
    ///
    /// The original database is left untouched and the migration is aborted, so a
    /// build that cannot back up never writes a new schema over data it could not
    /// copy first.
    case migrationBackupFailed(path: String, message: String)

    /// A recorded batch state could not be read back.
    ///
    /// The row holds a state this build does not understand, so it is refused
    /// rather than mapped to a state that would misreport what happened to the
    /// batch.
    case unreadableBatchState(batchID: UUID)

    /// A recorded batch completion could not be read back.
    case unreadableBatchCompletion(batchID: UUID)

    /// Deleting reads are unavailable in this library.
    ///
    /// Either the migration that adds the streaming tables could not be backed
    /// up, or this configuration disables the deleting route.
    case deletingReadsUnavailable(reason: String)

    /// A human-readable message for the app's error row.
    public var message: String {
        switch self {
        case .cannotOpenDatabase(let path, let message):
            return "The stroke library at \(path) could not be opened: \(message)"
        case .statementFailed(_, let message):
            return "The stroke library rejected a write: \(message)"
        case .unsupportedSchemaVersion(let found, let supported):
            return "The stroke library was written by a newer version of NeoBridge"
                + " (schema \(found), this build understands \(supported))."
        case .unreadableSchemaVersion(let found, let supported):
            return "The stroke library records a schema version this build cannot read"
                + " (\(found), this build understands \(supported)), so it was left as it was."
        case .batchNotReady(_, let state):
            let described = state.map { " in state \($0.rawValue)" } ?? " that is unknown"
            return "This read cannot be exported again: its stored batch is\(described)."
        case .collectedStrokesUnavailable:
            return "The pen read was interrupted before it was stored. Read the pen again."
        case .unreadableCleanupScope:
            return "A recorded cleanup request could not be read back, so no deletion was sent."
        case .unreadableCleanupState:
            return "A recorded cleanup request has a state this build cannot read,"
                + " so no deletion was sent for it."
        case .migrationBackupFailed(let path, let message):
            return "The stroke library at \(path) could not be backed up before it was"
                + " upgraded (\(message)), so it was left as it was and deleting reads stay off."
        case .unreadableBatchState(let batchID):
            return "The stored read \(batchID.uuidString) has a state this build cannot read,"
                + " so it is refused rather than reported as another state."
        case .unreadableBatchCompletion(let batchID):
            return "The stored read \(batchID.uuidString) has a completion this build cannot read,"
                + " so it is refused rather than reported as a completed read."
        case .deletingReadsUnavailable(let reason):
            return "Deleting reads are unavailable: \(reason)"
        }
    }
}

/// One SQLite connection.
///
/// The type is deliberately not `Sendable`: it belongs to the actor that owns it
/// and is never shared across isolation domains. Serializing access through one
/// actor is also what keeps a transaction from interleaving with another write.
final class SQLiteConnection {
    /// The open database handle.
    private let handle: OpaquePointer

    /// Opens a database file, creating it when it does not exist.
    ///
    /// - Parameter path: The file path, or `:memory:` for an in-memory database.
    convenience init(path: String) throws {
        try self.init(
            path: path,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        )
    }

    /// Opens an existing database file for reading only, treating it as immutable.
    ///
    /// The file is named through a URI with `immutable=1`, so SQLite reads the file
    /// itself and neither looks for a write-ahead log nor creates one. That matters
    /// for a copy of a WAL-mode database: the copy carries the source's WAL header,
    /// and such a file cannot be opened read-only any other way. Nothing is written,
    /// which is what makes this the right way to verify a backup.
    ///
    /// - Parameter path: The file path. It must already exist.
    convenience init(immutableReadingOnly path: String) throws {
        try self.init(
            path: "file:" + SQLiteConnection.uriEncoded(path) + "?immutable=1",
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        )
    }

    /// Percent-encodes a file path for SQLite's URI filename syntax.
    ///
    /// Only the unreserved characters and `/` are left as they are; every other
    /// byte becomes `%XX`. A path holding `?`, `#`, `%`, or a space then names one
    /// file instead of being read as URI syntax.
    private static func uriEncoded(_ path: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        var encoded = ""
        for byte in path.utf8 {
            if byte < 0x80, let scalar = UnicodeScalar(UInt32(byte)), unreserved.contains(Character(scalar)) {
                encoded.append(Character(scalar))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    private init(path: String, flags: Int32) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, flags, nil)

        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 failed with code \(result)"
            if let handle {
                sqlite3_close_v2(handle)
            }
            throw StorageError.cannotOpenDatabase(path: path, message: message)
        }

        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// The last error message SQLite reported.
    var lastMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    /// The database handle, for statement preparation.
    var rawHandle: OpaquePointer { handle }

    /// Runs one or more statements that return no rows.
    func execute(_ sql: String) throws {
        let statement = try prepare(sql)
        try statement.run()
    }

    /// Prepares one statement.
    func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(database: handle, sql: sql)
    }

    /// Runs a block inside one immediate transaction.
    ///
    /// An immediate transaction takes the write lock up front, so two writers
    /// cannot both believe they hold the lock. A failure rolls the whole block
    /// back, which is what makes a complete-batch import all-or-nothing.
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Copies the whole database into a new file with SQLite's online backup API.
    ///
    /// The backup reads the source through the same connection the library uses,
    /// so it captures committed WAL content and cannot see a half-written
    /// transaction. That is what makes it a consistent pre-migration copy rather
    /// than a file copy that might miss the write-ahead log.
    ///
    /// - Parameter path: The destination file path. An existing file is replaced.
    func backup(to path: String) throws {
        var destination: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let opened = sqlite3_open_v2(path, &destination, flags, nil)
        guard opened == SQLITE_OK, let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 failed with code \(opened)"
            if let destination { sqlite3_close_v2(destination) }
            throw StorageError.statementFailed(sql: "backup", message: message)
        }
        defer { sqlite3_close_v2(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", handle, "main") else {
            throw StorageError.statementFailed(
                sql: "backup",
                message: String(cString: sqlite3_errmsg(destination))
            )
        }
        defer { sqlite3_backup_finish(backup) }

        let step = sqlite3_backup_step(backup, -1)
        guard step == SQLITE_DONE else {
            throw StorageError.statementFailed(
                sql: "backup",
                message: String(cString: sqlite3_errmsg(destination))
            )
        }
    }
}

/// A prepared statement, bound and stepped by the caller.
final class SQLiteStatement {
    private let database: OpaquePointer
    private let handle: OpaquePointer
    private let sql: String

    fileprivate init(database: OpaquePointer, sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK, let handle else {
            let message = String(cString: sqlite3_errmsg(database))
            throw StorageError.statementFailed(sql: sql, message: message)
        }
        self.database = database
        self.handle = handle
        self.sql = sql
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// Binds an integer to a parameter.
    func bind(_ index: Int32, _ value: Int64) throws {
        try require(sqlite3_bind_int64(handle, index, value) == SQLITE_OK)
    }

    /// Binds text to a parameter.
    func bind(_ index: Int32, _ value: String) throws {
        try require(
            sqlite3_bind_text(handle, index, value, -1, Self.transientDestructor) == SQLITE_OK
        )
    }

    /// Binds a byte string to a parameter.
    func bind(_ index: Int32, _ value: [UInt8]) throws {
        guard !value.isEmpty else {
            try require(sqlite3_bind_zeroblob(handle, index, 0) == SQLITE_OK)
            return
        }
        try value.withUnsafeBufferPointer { buffer in
            let result = sqlite3_bind_blob(
                handle,
                index,
                buffer.baseAddress,
                Int32(buffer.count),
                Self.transientDestructor
            )
            try require(result == SQLITE_OK)
        }
    }

    /// Binds a null to a parameter.
    func bindNull(_ index: Int32) throws {
        try require(sqlite3_bind_null(handle, index) == SQLITE_OK)
    }

    /// Steps the statement once.
    ///
    /// - Returns: `true` when a row is available, `false` when the statement is
    ///   done.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            try require(false)
            return false
        }
    }

    /// Steps the statement to completion.
    func run() throws {
        _ = try step()
    }

    /// Resets the statement so it can be stepped again.
    func reset() throws {
        try require(sqlite3_reset(handle) == SQLITE_OK)
    }

    /// An integer column value.
    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    /// A text column value.
    func text(_ column: Int32) -> String? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: bytes)
    }

    /// A byte-string column value.
    func blob(_ column: Int32) -> [UInt8]? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(handle, column) else { return [] }
        let count = Int(sqlite3_column_bytes(handle, column))
        return Array(UnsafeRawBufferPointer(start: bytes, count: count))
    }

    /// Whether a column is null.
    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }

    /// The row identifier of the row the last insert created.
    var lastInsertedRowID: Int64 {
        sqlite3_last_insert_rowid(database)
    }

    /// Fails with the connection's current message.
    private func require(_ condition: Bool) throws {
        guard condition else {
            throw StorageError.statementFailed(
                sql: sql,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
    }

    /// The destructor SQLite must use for a value it keeps a copy of.
    private static let transientDestructor = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
}
