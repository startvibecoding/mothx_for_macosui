import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Client-owned store for the file changes shown by the review sidebar.
///
/// mothx remains the source of truth for runs, but its Serve tool results never
/// expose a structured `oldText`/`newText` pair, so a Serve edit could only be
/// previewed. The client now captures the before/after file contents itself
/// (snapshotting the file while a write-like tool runs, reading it again when
/// the tool finishes) and persists the resulting diff here. A pair supplied by
/// the server is always preferred; these rows are the fallback used when the
/// server has none.
///
/// The store replaces the earlier `changes.json` file. Existing installations
/// are migrated once on first launch, and the legacy file is renamed so the
/// migration cannot run twice.
nonisolated final class LocalChangeStore: @unchecked Sendable {
    private static let currentVersion = 2

    /// Legacy `changes.json` envelope, kept only for the one-time migration.
    private struct LegacyEnvelope: Codable {
        let version: Int
        let turns: [String: MothxTurnChanges]
        let toolChanges: [String: MothxToolChangeRecord]
    }

    private struct StoredRow {
        let ownerType: String
        let ownerID: String
        let sessionID: String
        let change: MothxFileChange
        let capturedAt: Date
    }

    private var database: OpaquePointer?
    private let lock = NSLock()
    private var lastSavedGeneration = 0

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mothxOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("changes.sqlite")
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            database = nil
            return
        }
        createSchema()
        migrateLegacyJSON(in: directory)
    }

    deinit { sqlite3_close(database) }

    // MARK: - Loading

    func load() -> MothxChangeStoreState {
        lock.lock()
        defer { lock.unlock() }
        guard database != nil else { return MothxChangeStoreState(turns: [:], toolChanges: [:]) }

        var turnFiles: [String: [MothxFileChange]] = [:]
        var turnCaptured: [String: Date] = [:]
        var toolFiles: [String: [MothxFileChange]] = [:]
        var toolSessions: [String: String] = [:]
        var toolCaptured: [String: Date] = [:]

        for row in readAllRows() {
            switch row.ownerType {
            case "tool":
                toolFiles[row.ownerID, default: []].append(row.change)
                toolSessions[row.ownerID] = row.sessionID
                toolCaptured[row.ownerID] = max(toolCaptured[row.ownerID] ?? .distantPast, row.capturedAt)
            default:
                turnFiles[row.ownerID, default: []].append(row.change)
                turnCaptured[row.ownerID] = max(turnCaptured[row.ownerID] ?? .distantPast, row.capturedAt)
            }
        }

        let turns = Dictionary(uniqueKeysWithValues: turnFiles.map { runID, files in
            (runID, MothxTurnChanges(
                id: runID,
                runID: runID,
                files: Self.sorted(files),
                capturedAt: turnCaptured[runID] ?? Date()
            ))
        })

        var toolChanges: [String: MothxToolChangeRecord] = [:]
        for (toolCallID, files) in toolFiles {
            let sessionID = toolSessions[toolCallID] ?? ""
            let key = "\(sessionID)\u{0}\(toolCallID)"
            toolChanges[key] = MothxToolChangeRecord(
                sessionID: sessionID,
                toolCallID: toolCallID,
                files: Self.sorted(files),
                capturedAt: toolCaptured[toolCallID] ?? Date()
            )
        }
        return MothxChangeStoreState(turns: turns, toolChanges: toolChanges)
    }

    // MARK: - Saving

    /// Reconciles the on-disk snapshot with the in-memory one. Meant to be called
    /// from a background task; the generation guard ensures an older snapshot
    /// that finishes late never clobbers a newer one.
    func save(turns: [String: MothxTurnChanges], toolChanges: [String: MothxToolChangeRecord], generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard database != nil else { return }
        guard generation >= lastSavedGeneration else { return }
        lastSavedGeneration = generation

        execute("BEGIN IMMEDIATE")
        guard execute("DELETE FROM change_files") else {
            execute("ROLLBACK")
            return
        }
        var ok = true
        for (runID, turn) in turns where ok {
            for file in turn.files {
                ok = insert(ownerType: "turn", ownerID: runID, sessionID: nil, file: file, capturedAt: turn.capturedAt)
                if !ok { break }
            }
        }
        for record in toolChanges.values where ok {
            for file in record.files {
                ok = insert(ownerType: "tool", ownerID: record.toolCallID, sessionID: record.sessionID, file: file, capturedAt: record.capturedAt)
                if !ok { break }
            }
        }
        execute(ok ? "COMMIT" : "ROLLBACK")
    }

    // MARK: - Schema

    private func createSchema() {
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA synchronous=NORMAL")
        execute("""
            CREATE TABLE IF NOT EXISTS change_files (
                owner_type TEXT NOT NULL,
                owner_id TEXT NOT NULL,
                session_id TEXT,
                path TEXT NOT NULL,
                kind TEXT NOT NULL,
                added INTEGER NOT NULL,
                deleted INTEGER NOT NULL,
                unified_diff TEXT NOT NULL,
                old_text TEXT,
                new_text TEXT,
                truncated INTEGER NOT NULL,
                captured_at REAL NOT NULL,
                PRIMARY KEY (owner_type, owner_id, path)
            )
        """)
    }

    // MARK: - Legacy migration

    private func migrateLegacyJSON(in directory: URL) {
        let jsonURL = directory.appendingPathComponent("changes.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return }

        // Only import when the database has no rows yet. If it already does, the
        // migration ran before; just retire the stale file.
        if hasRows() {
            try? FileManager.default.removeItem(at: jsonURL)
            return
        }
        guard let data = try? Data(contentsOf: jsonURL) else { return }
        let decoder = JSONDecoder()

        var turns: [String: MothxTurnChanges] = [:]
        var toolChanges: [String: MothxToolChangeRecord] = [:]
        if let envelope = try? decoder.decode(LegacyEnvelope.self, from: data),
           envelope.version >= Self.currentVersion {
            turns = envelope.turns
            toolChanges = envelope.toolChanges
        } else if let legacy = try? decoder.decode([String: MothxTurnChanges].self, from: data) {
            // Legacy files were keyed only by the temporary Run ID and may carry
            // an older format without a stable ACP tool-call key, so downgrade
            // them to preview-only rather than trusting their before/after data.
            turns = legacy.mapValues { turn in
                MothxTurnChanges(
                    id: turn.id,
                    runID: turn.runID,
                    files: turn.files.map { file in
                        MothxFileChange(
                            previewPath: file.path,
                            unifiedDiff: "历史运行已完成，详细 Diff 未持久化。",
                            added: file.added,
                            deleted: file.deleted
                        )
                    },
                    capturedAt: turn.capturedAt
                )
            }
        } else {
            return
        }

        save(turns: turns, toolChanges: toolChanges, generation: 0)
        try? FileManager.default.moveItem(at: jsonURL, to: directory.appendingPathComponent("changes.json.migrated"))
    }

    private func hasRows() -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM change_files LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    // MARK: - Reading

    private func readAllRows() -> [StoredRow] {
        let sql = "SELECT owner_type, owner_id, session_id, path, kind, added, deleted, unified_diff, old_text, new_text, truncated, captured_at FROM change_files"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [StoredRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let kind = MothxFileChangeKind(rawValue: text(statement, column: 4)) ?? .modified
            let change = MothxFileChange(
                path: text(statement, column: 3),
                kind: kind,
                added: Int(sqlite3_column_int(statement, 5)),
                deleted: Int(sqlite3_column_int(statement, 6)),
                unifiedDiff: text(statement, column: 7),
                oldText: optionalText(statement, column: 8),
                newText: optionalText(statement, column: 9),
                truncated: sqlite3_column_int(statement, 10) != 0
            )
            rows.append(StoredRow(
                ownerType: text(statement, column: 0),
                ownerID: text(statement, column: 1),
                sessionID: text(statement, column: 2),
                change: change,
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
            ))
        }
        return rows
    }

    // MARK: - Writing

    @discardableResult
    private func insert(ownerType: String, ownerID: String, sessionID: String?, file: MothxFileChange, capturedAt: Date) -> Bool {
        let sql = """
            INSERT OR REPLACE INTO change_files
            (owner_type, owner_id, session_id, path, kind, added, deleted, unified_diff, old_text, new_text, truncated, captured_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, ownerType, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, ownerID, -1, sqliteTransient)
        if let sessionID {
            sqlite3_bind_text(statement, 3, sessionID, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, file.path, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, file.kind.rawValue, -1, sqliteTransient)
        sqlite3_bind_int(statement, 6, Int32(file.added))
        sqlite3_bind_int(statement, 7, Int32(file.deleted))
        sqlite3_bind_text(statement, 8, file.unifiedDiff, -1, sqliteTransient)
        if let oldText = file.oldText {
            sqlite3_bind_text(statement, 9, oldText, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 9)
        }
        if let newText = file.newText {
            sqlite3_bind_text(statement, 10, newText, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        sqlite3_bind_int(statement, 11, file.truncated ? 1 : 0)
        sqlite3_bind_double(statement, 12, capturedAt.timeIntervalSince1970)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func execute(_ sql: String) -> Bool {
        guard let database else { return false }
        return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    private func text(_ statement: OpaquePointer?, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private static func sorted(_ files: [MothxFileChange]) -> [MothxFileChange] {
        files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
