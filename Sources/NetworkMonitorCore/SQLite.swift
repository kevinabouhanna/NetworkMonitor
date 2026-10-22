import Foundation
import SQLite3

/// The few calls `UsageHistory` makes into SQLite, and nothing more.
///
/// SQLite rather than another JSON file because history is the one thing in
/// this app that only grows: a year of hourly per-app rows is around a hundred
/// thousand of them, and every view of it is a range query and a `SUM`. The
/// library ships with macOS, so this costs no dependency.
///
/// Not thread-safe by itself. `UsageHistory` confines each connection to one
/// serial queue.
final class SQLiteDatabase {

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private var handle: OpaquePointer?

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            handle = nil
            throw Failure(description: message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw Failure(description: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw Failure(description: lastError) }
        return SQLiteStatement(statement, database: self)
    }

    /// Runs `body` inside one transaction, rolled back if it throws.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs a query that returns one integer, such as a `MAX` or a pragma.
    func scalar(_ sql: String) throws -> Int64? {
        let statement = try prepare(sql)
        guard try statement.step(), !statement.isNull(0) else { return nil }
        return statement.int64(0)
    }

    var lastError: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }
}

final class SQLiteStatement {

    private let statement: OpaquePointer
    private let database: SQLiteDatabase

    /// Tells SQLite to copy bound text, since Swift strings do not outlive the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate init(_ statement: OpaquePointer, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit {
        sqlite3_finalize(statement)
    }

    enum Value {
        case int(Int64)
        case real(Double)
        case text(String)
        case null
    }

    /// Clears the previous run and binds `values` to `?1`, `?2`, … in order.
    @discardableResult
    func bind(_ values: [Value]) -> SQLiteStatement {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let number):  sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .text(let text):   sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .null:             sqlite3_bind_null(statement, index)
            }
        }
        return self
    }

    /// True while there is a row to read; false once the statement is done.
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:  return true
        case SQLITE_DONE: return false
        default: throw SQLiteDatabase.Failure(description: database.lastError)
        }
    }

    /// Steps a statement that returns no rows.
    func run(_ values: [Value]) throws {
        bind(values)
        _ = try step()
    }

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }
}
