import Foundation
import SQLite3

/// A minimal SQLite connection. Confined to the actor that owns it.
final class Database {
    enum Value {
        case text(String)
        case real(Double)
        case integer(Int64)
        case blob(Data)
        case null
    }

    struct Failure: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite \(code): \(message)" }
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }

        func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

        func blob(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    private var handle: OpaquePointer?

    init(url: URL) throws {
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        self.handle = handle
        guard code == SQLITE_OK else { throw failure(code) }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String, _ values: [Value] = []) throws {
        try withStatement(sql, values) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE || code == SQLITE_ROW else { throw failure(code) }
        }
    }

    func rows<T>(_ sql: String, _ values: [Value] = [], _ read: (Row) throws -> T?) throws -> [T] {
        try withStatement(sql, values) { statement in
            var results: [T] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return results }
                guard code == SQLITE_ROW else { throw failure(code) }
                if let value = try read(Row(statement: statement)) { results.append(value) }
            }
        }
    }

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

    private func withStatement<T>(_ sql: String, _ values: [Value], _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw failure(code) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let .text(text): sqlite3_bind_text(statement, position, text, -1, transient)
            case let .real(number): sqlite3_bind_double(statement, position, number)
            case let .integer(number): sqlite3_bind_int64(statement, position, number)
            case let .blob(data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), transient) }
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        return try body(statement)
    }

    private func failure(_ code: Int32) -> Failure {
        Failure(code: code, message: handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown")
    }
}

/// SQLite copies bound values before `sqlite3_bind_*` returns.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
