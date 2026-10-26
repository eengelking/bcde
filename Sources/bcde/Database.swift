import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The `cards` table. Safe to call from multiple threads; writes are serialized.
final class Database {
    private var db: OpaquePointer?
    private var upsert: OpaquePointer?
    private let lock = NSLock()

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CLIError("cannot open database \(path)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        let cols = Schema.columns.map { c -> String in
            if c == "card_key" { return "card_key TEXT NOT NULL UNIQUE" }
            if Schema.integerColumns.contains(c) { return "\(c) INTEGER" }
            if Schema.realColumns.contains(c) { return "\(c) REAL" }
            return "\(c) TEXT"
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS cards (id INTEGER PRIMARY KEY, \(cols.joined(separator: ", ")));
            CREATE INDEX IF NOT EXISTS cards_company ON cards(company);
            CREATE INDEX IF NOT EXISTS cards_email ON cards(email);
            CREATE INDEX IF NOT EXISTS cards_last_name ON cards(last_name);
            CREATE INDEX IF NOT EXISTS cards_needs_review ON cards(needs_review);
            """)
        let names = Schema.columns.joined(separator: ", ")
        let params = Schema.columns.map { _ in "?" }.joined(separator: ", ")
        let updates = Schema.columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        let sql = "INSERT INTO cards (\(names)) VALUES (\(params)) ON CONFLICT(card_key) DO UPDATE SET \(updates)"
        guard sqlite3_prepare_v2(db, sql, -1, &upsert, nil) == SQLITE_OK else { throw CLIError(lastError) }
    }

    deinit {
        sqlite3_finalize(upsert)
        sqlite3_close(db)
    }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CLIError(lastError) }
    }

    func save(_ r: CardRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_reset(upsert)
        sqlite3_clear_bindings(upsert)
        for (i, col) in Schema.columns.enumerated() {
            let idx = Int32(i + 1)
            guard let v = r[col], !v.isEmpty else { sqlite3_bind_null(upsert, idx); continue }
            if Schema.integerColumns.contains(col), let n = Int64(v) {
                sqlite3_bind_int64(upsert, idx, n)
            } else if Schema.realColumns.contains(col), let d = Double(v) {
                sqlite3_bind_double(upsert, idx, d)
            } else {
                sqlite3_bind_text(upsert, idx, v, -1, SQLITE_TRANSIENT)
            }
        }
        guard sqlite3_step(upsert) == SQLITE_DONE else { throw CLIError(lastError) }
    }

    /// card_key → content_hash for cards that were processed without error.
    func processedHashes() -> [String: String] {
        var out: [String: String] = [:]
        for row in query("SELECT card_key, content_hash FROM cards WHERE error IS NULL") where row.count == 2 {
            out[row[0]] = row[1]
        }
        return out
    }

    /// All rows in `Schema.columns` order, NULLs as empty strings.
    func allRows() -> [[String]] {
        query("SELECT \(Schema.columns.joined(separator: ", ")) FROM cards ORDER BY card_key")
    }

    private func query(_ sql: String) -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String]] = []
        let n = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((0..<n).map { i in
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_NULL: return ""
                case SQLITE_FLOAT: return String(format: "%.2f", sqlite3_column_double(stmt, i))
                default: return sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
                }
            })
        }
        return rows
    }
}
