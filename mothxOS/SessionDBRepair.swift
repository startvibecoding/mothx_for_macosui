import Combine
import Foundation
import SQLite3

// =============================================================================
// SessionDBRepair — 会话库 (sessions.db) 的应用内「数据检查与修复」协调器。
//
// 背景（详见 docs/session-db-wal-shm.md 与 tools/session_db_guard.sh）：
//   ~/.mothx/sessions/sessions.db 是 WAL 模式，mothxOS App / mothx TUI /
//   服务器进程会并发打开。并发 + 不同 SQLite 版本可能把 -shm（WAL 索引）搞成
//   半损坏状态，进而让撕裂的 WAL 帧并入主库，出现 "database disk image is
//   malformed"。
//
// 原则：
//   * 只读操作（healthCheck / listBackups）随时可跑；备份使用
//     SQLite 一致性快照（sqlite3_backup），对并发写者也安全。备份会以
//     读写方式短暂打开源库（含 quick_check 自检），让 SQLite 在 WAL
//     (-shm) 索引被并发进程打断时自我重建（见 BUG-0020）；
//   * 写操作（restore / repairFiles / deepRecover）要求没有其他进程占用，
//     调用方应先把本应用启动的 mothx 服务停下来（见 SessionDBRepairModel）；
//   * 修复路径：先尝试从备份恢复 → 再尝试 WAL/SHM 类修复 → 最后 .recover 深度恢复。
// =============================================================================

struct SessionDBBackup: Identifiable, Equatable, Sendable {
    let url: URL
    let date: Date
    let size: Int64
    let valid: Bool

    var id: String { url.lastPathComponent }
    var displayName: String { url.lastPathComponent }
}

struct SessionDBHealth: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        case missing      // sessions.db 不存在
        case healthy      // quick_check ok，无残留
        case residue      // quick_check ok，但有异常 shm / 遗留 WAL，可清理
        case corrupted    // quick_check 失败，数据处于风险中
    }

    let databaseURL: URL
    let dbExists: Bool
    let integrity: String
    let journalMode: String
    let walBytes: Int64
    let shmBytes: Int64
    let activeOpeners: [String]

    var verdict: Verdict {
        guard dbExists else { return .missing }
        guard integrity == "ok" else { return .corrupted }
        if shmIrregular || walResidueWithoutOpeners { return .residue }
        return .healthy
    }

    /// SHM 是 32 KB 整倍数的索引文件；尺寸非法说明是残留的旧世代索引。
    var shmIrregular: Bool { shmBytes > 0 && shmBytes % 32768 != 0 }

    /// WAL 头固定 32 字节，其后每帧 4096+24 字节；超过头说明有待合并帧。
    var hasWalFrames: Bool { walBytes > 32 }

    /// 有待合并帧且当前没有任何进程打开库 → 上次进程非正常退出留下的残留。
    var walResidueWithoutOpeners: Bool { hasWalFrames && activeOpeners.isEmpty }

    var diagnosisLine: String {
        switch verdict {
        case .missing: return "sessions.db 不存在"
        case .healthy: return "数据正常"
        case .residue: return "有可清理的残留文件（SHM 索引 / 未合并 WAL）"
        case .corrupted: return "完整性检查未通过，数据存在损坏风险"
        }
    }
}

enum SessionDBRepairError: LocalizedError {
    case databaseMissing(String)
    case unhealthySource(String)
    case backupInvalid(String)
    case backupMissing(String)
    case activeOpeners([String])
    case sqlite(String)
    case cliUnavailable
    case recoverFailed(String)
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseMissing(let path):
            return "数据库不存在: \(path) (database not found)"
        case .unhealthySource(let detail):
            return "数据库不健康，拒绝备份: \(detail) (refusing to back up an unhealthy database)"
        case .backupInvalid(let path):
            return "备份文件未通过完整性检查: \(path) (backup failed integrity check)"
        case .backupMissing(let path):
            return "备份文件不存在: \(path) (backup not found)"
        case .activeOpeners(let openers):
            return "仍有进程占用会话库 (\(openers.joined(separator: ", ")))。请先关闭 mothx TUI / 外部服务再重试。 (database still in use — close the mothx TUI or external server first)"
        case .sqlite(let message):
            return "SQLite 错误: \(message)"
        case .cliUnavailable:
            return "未找到 /usr/bin/sqlite3 命令行工具 (sqlite3 CLI not found)"
        case .recoverFailed(let message):
            return "深度恢复失败: \(message)"
        case .restoreFailed(let message):
            return "恢复失败: \(message)"
        }
    }
}

enum SessionDBRepair {

    // MARK: - 路径

    /// 解析 mothx 实际的会话库路径。`configuredDir` 为空时回退到默认
    /// `~/.mothx/sessions`。
    nonisolated static func sessionDatabaseURL(configuredDir: String) -> URL {
        let trimmed = configuredDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory: URL
        if trimmed.isEmpty {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".mothx", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        } else {
            directory = URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        return directory.appendingPathComponent("sessions.db")
    }

    nonisolated static func backupDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mothx", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
    }

    private nonisolated static func walURL(for databaseURL: URL) -> URL {
        URL(fileURLWithPath: databaseURL.path + "-wal")
    }

    private nonisolated static func shmURL(for databaseURL: URL) -> URL {
        URL(fileURLWithPath: databaseURL.path + "-shm")
    }

    private nonisolated static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    private nonisolated static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    // MARK: - 只读诊断

    /// 全量健康检查（只读，安全）。完全在后台队列执行，不接触任何 UI。
    nonisolated static func healthCheck(databaseURL: URL) -> SessionDBHealth {
        let exists = FileManager.default.fileExists(atPath: databaseURL.path)
        var integrity = "missing"
        var journalMode = ""
        if exists {
            integrity = quickCheckResult(databaseURL: databaseURL) ?? "unreadable"
            journalMode = journalModeOf(databaseURL: databaseURL) ?? ""
        }
        return SessionDBHealth(
            databaseURL: databaseURL,
            dbExists: exists,
            integrity: integrity,
            journalMode: journalMode,
            walBytes: fileSize(walURL(for: databaseURL)),
            shmBytes: fileSize(shmURL(for: databaseURL)),
            activeOpeners: activeOpeners(of: databaseURL)
        )
    }

    /// 列出备份目录里的快照（新→旧），逐个做只读校验。
    nonisolated static func listBackups(backupDir: URL) -> [SessionDBBackup] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return files
            .filter { $0.lastPathComponent.hasPrefix("sessions-") && $0.pathExtension == "db" }
            .compactMap { url -> SessionDBBackup? in
                let standardized = url.standardizedFileURL
                guard let values = try? standardized.resourceValues(forKeys: [.contentModificationDateKey]),
                      let date = values.contentModificationDate else { return nil }
                return SessionDBBackup(
                    url: standardized,
                    date: date,
                    size: fileSize(standardized),
                    valid: verifyIntegrity(databaseURL: standardized)
                )
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - 备份

    /// 一致性快照 + 轮转保留。备份前先确认源库健康，快照生成后再自校验。
    /// 使用 sqlite 离线备份 API（等效 `sqlite3 .backup`），对并发写者也安全。
    ///
    /// 可靠性加固（BUG-0020）：
    ///   * 源库自检与备份都以**读写**方式打开——WAL 模式在 -shm 索引异常时
    ///     需要写权限自我重建，只读连接可能读到不一致的页面组合；
    ///   * 快照未通过 quick_check 时**不删除**，改名保留为 `.invalid-N` 证据，
    ///     并换新文件名重试（最多 3 次），每次重试前重新确认源库健康；
    ///   * 全部失败后把 quick_check 诊断与保留的证据路径一并抛出。
    nonisolated static func backupNow(databaseURL: URL, backupDir: URL, keep: Int = 20) throws -> SessionDBBackup {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw SessionDBRepairError.databaseMissing(databaseURL.path)
        }
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let maxAttempts = 3
        var diagnosis = "unreadable"
        var evidenceURL: URL?
        for attempt in 1...maxAttempts {
            // 源库自检：读写方式打开，允许 SQLite 顺手重建异常的 WAL 索引
            guard verifyIntegrity(databaseURL: databaseURL, readWritable: true) else {
                throw SessionDBRepairError.unhealthySource(quickCheckResult(databaseURL: databaseURL) ?? "unknown")
            }

            let destination = backupDir.appendingPathComponent("sessions-\(timestamp()).db")
            do {
                try performSQLiteBackup(from: databaseURL, to: destination)
            } catch {
                try? fileManager.removeItem(at: destination)
                if attempt < maxAttempts { continue }   // 瞬时忙/锁 → 换新文件重试
                throw error
            }

            // BUG-0021：快照已重置为 DELETE 日志格式（自包含），
            // 顺带清掉日志模式改写过程中可能残留的伴生文件。
            try? fileManager.removeItem(at: URL(fileURLWithPath: destination.path + "-wal"))
            try? fileManager.removeItem(at: URL(fileURLWithPath: destination.path + "-shm"))

            guard verifyIntegrity(databaseURL: destination) else {
                diagnosis = quickCheckResult(databaseURL: destination) ?? "unreadable"
                // 保留异常快照供排查（.invalid-N 后缀不会进备份列表），再换新文件重试
                let evidence = URL(fileURLWithPath: destination.path + ".invalid-\(attempt)")
                try? fileManager.moveItem(at: destination, to: evidence)
                evidenceURL = evidence
                if attempt < maxAttempts {
                    Thread.sleep(forTimeInterval: 0.2)   // 给 WAL 索引一个稳定窗口
                    continue
                }
                break
            }

            rotateBackups(backupDir: backupDir, keep: keep)
            return SessionDBBackup(url: destination, date: Date(), size: fileSize(destination), valid: true)
        }

        // 全部尝试失败：指出证据文件与 quick_check 诊断，便于排查。
        throw SessionDBRepairError.backupInvalid(
            "\(evidenceURL?.path ?? databaseURL.path)（快照 quick_check: \(diagnosis)）"
        )
    }

    // MARK: - 从备份恢复（首选修复途径）

    /// 从一致性快照恢复：校验备份 → 归档当前现场 → 替换 sessions.db →
    /// 删除残留 -wal/-shm → 复检。库当前不能被其他进程占用（除非 `force`）。
    nonisolated static func restore(
        from backup: SessionDBBackup,
        databaseURL: URL,
        force: Bool = false
    ) throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backup.url.path) else {
            throw SessionDBRepairError.backupMissing(backup.url.path)
        }
        guard verifyIntegrity(databaseURL: backup.url) else {
            throw SessionDBRepairError.backupInvalid(backup.url.path)
        }

        let openers = activeOpeners(of: databaseURL)
        guard force || openers.isEmpty else { throw SessionDBRepairError.activeOpeners(openers) }

        let directory = databaseURL.deletingLastPathComponent()
        let sceneBase = directory.appendingPathComponent("sessions.corrupt-\(timestamp())")
        let wal = walURL(for: databaseURL)
        let shm = shmURL(for: databaseURL)

        // 1) 归档现场（原库 + 伴生文件），万一恢复失败还有退路
        var archivedCount = 0
        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.moveItem(at: databaseURL, to: URL(fileURLWithPath: sceneBase.path + ".db"))
            archivedCount += 1
        }
        if fileManager.fileExists(atPath: wal.path) {
            try? fileManager.moveItem(at: wal, to: URL(fileURLWithPath: sceneBase.path + ".db-wal"))
            archivedCount += 1
        }
        if fileManager.fileExists(atPath: shm.path) {
            try? fileManager.moveItem(at: shm, to: URL(fileURLWithPath: sceneBase.path + ".db-shm"))
            archivedCount += 1
        }

        // 2) 用快照替换
        do {
            try fileManager.copyItem(at: backup.url, to: databaseURL)
        } catch {
            // 回滚归档，避免留下半坏状态
            try? fileManager.moveItem(at: URL(fileURLWithPath: sceneBase.path + ".db"), to: databaseURL)
            try? fileManager.moveItem(at: URL(fileURLWithPath: sceneBase.path + ".db-wal"), to: wal)
            try? fileManager.moveItem(at: URL(fileURLWithPath: sceneBase.path + ".db-shm"), to: shm)
            throw SessionDBRepairError.restoreFailed("无法写入恢复后的数据库: \(error.localizedDescription)")
        }
        try? fileManager.removeItem(at: wal)
        try? fileManager.removeItem(at: shm)

        // 3) 复检
        guard verifyIntegrity(databaseURL: databaseURL) else {
            throw SessionDBRepairError.restoreFailed("恢复后的数据库未通过完整性检查；原文件已归档到 \(sceneBase.path).db")
        }

        let archivedNote = archivedCount > 0 ? "原文件已归档到 \(sceneBase.path).db" : "（原库不存在，直接重建）"
        return "从 \(backup.displayName) 恢复完成，恢复后完整性检查通过；\(archivedNote)"
    }

    // MARK: - WAL / SHM 修复

    /// 常规修复：仅当 integrity ok 才进行。
    /// 1) SHM 尺寸异常 → 改名留证，交给 SQLite 重建索引；
    /// 2) WAL 有待合并帧 → wal_checkpoint(TRUNCATE)；
    /// 3) 复检 quick_check。
    nonisolated static func repairFiles(databaseURL: URL, force: Bool = false) throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw SessionDBRepairError.databaseMissing(databaseURL.path)
        }

        let initialQuick = quickCheckResult(databaseURL: databaseURL) ?? "unknown"
        guard initialQuick == "ok" else {
            throw SessionDBRepairError.restoreFailed(
                "完整性检查未通过（\(initialQuick)）：请先尝试「从备份恢复」或用「深度恢复 (.recover)」抢救数据。"
            )
        }

        let openers = activeOpeners(of: databaseURL)
        let wal = walURL(for: databaseURL)
        let shm = shmURL(for: databaseURL)
        let walBytes = fileSize(wal)
        let shmBytes = fileSize(shm)
        var lines: [String] = []

        // 只做「需要写」的动作时才要求独占；否则仅报告。
        let needsWrite = (shmBytes > 0 && shmBytes % 32768 != 0) || walBytes > 32
        if needsWrite && openers.isEmpty == false {
            throw SessionDBRepairError.activeOpeners(openers)
        }

        if shmBytes > 0 && shmBytes % 32768 != 0 {
            let orphan = URL(fileURLWithPath: shm.path + ".orphan-\(timestamp())")
            try fileManager.moveItem(at: shm, to: orphan)
            lines.append("SHM 尺寸异常（\(shmBytes) 字节），已迁移为 \(orphan.lastPathComponent)，SQLite 下次打开时自动重建索引。")
        } else if shmBytes > 0 {
            lines.append("SHM 索引正常（\(shmBytes) 字节）。")
        } else {
            lines.append("SHM 索引不存在（WAL 模式未激活或已由 SQLite 清理）。")
        }

        if walBytes > 32 {
            try checkpoint(databaseURL: databaseURL)
            lines.append("WAL 含未合并帧（\(walBytes) 字节），已执行 wal_checkpoint(TRUNCATE) 合并并截断。")
        } else if walBytes > 0 {
            lines.append("WAL 无待合并帧（\(walBytes) 字节），已是最新。")
        }

        let finalQuick = quickCheckResult(databaseURL: databaseURL) ?? "unknown"
        lines.append("修复后 quick_check: \(finalQuick)")
        return lines.joined(separator: "\n")
    }

    // MARK: - 深度恢复（最后一招）

    /// 兜底恢复：归档现场 → sqlite3 ".recover" 导出可抢救数据 → 重建新库 →
    /// 校验 → 替换回 sessions.db。部分撕裂帧可能缺失，属预期行为。
    nonisolated static func deepRecover(databaseURL: URL, force: Bool = false) throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw SessionDBRepairError.databaseMissing(databaseURL.path)
        }

        let cli = "/usr/bin/sqlite3"
        guard fileManager.isExecutableFile(atPath: cli) else {
            throw SessionDBRepairError.cliUnavailable
        }

        let openers = activeOpeners(of: databaseURL)
        guard force || openers.isEmpty else { throw SessionDBRepairError.activeOpeners(openers) }

        let directory = databaseURL.deletingLastPathComponent()
        let timestamp = timestamp()
        let sceneBase = directory.appendingPathComponent("sessions.corrupt-\(timestamp)")
        let corruptDB = URL(fileURLWithPath: sceneBase.path + ".db")
        let sqlPath = URL(fileURLWithPath: sceneBase.path + ".recovered.sql")
        let rebuiltPath = directory.appendingPathComponent("sessions.rebuilt-\(timestamp).db")

        // 1) 归档现场
        try fileManager.moveItem(at: databaseURL, to: corruptDB)
        try? fileManager.moveItem(at: walURL(for: databaseURL), to: URL(fileURLWithPath: sceneBase.path + ".db-wal"))
        try? fileManager.moveItem(at: shmURL(for: databaseURL), to: URL(fileURLWithPath: sceneBase.path + ".db-shm"))

        // 2) .recover 导出可抢救数据（输出到 SQL 文件）
        let export = try runCLI(executable: cli, arguments: [corruptDB.path, ".recover"])
        guard export.status == 0 else {
            throw SessionDBRepairError.recoverFailed(
                "sqlite3 .recover 退出码 \(export.status): \(String(data: export.stderr, encoding: .utf8) ?? "")"
            )
        }
        try export.stdout.write(to: sqlPath)

        // 3) 用导出的 SQL 重建新库
        let rebuild = try runCLI(executable: cli, arguments: [rebuiltPath.path], stdinData: export.stdout)
        guard rebuild.status == 0 else {
            throw SessionDBRepairError.recoverFailed(
                "重建失败（退出码 \(rebuild.status)）：\(String(data: rebuild.stderr, encoding: .utf8) ?? "")"
            )
        }

        // 4) 校验重建库，通过后才替换
        guard verifyIntegrity(databaseURL: rebuiltPath) else {
            throw SessionDBRepairError.recoverFailed("重建后的数据库未通过完整性检查（\(rebuiltPath.path)），已保留待人工处理")
        }
        try fileManager.moveItem(at: rebuiltPath, to: databaseURL)
        try? fileManager.removeItem(at: walURL(for: databaseURL))
        try? fileManager.removeItem(at: shmURL(for: databaseURL))

        let lineCount = export.stdout.split(separator: 0x0A).count
        return "深度恢复完成：从损坏现场导出 \(lineCount) 行并重建（SQL 存于 \(sqlPath.lastPathComponent)）。原文件归档在 \(corruptDB.lastPathComponent)。重建库已替换为 sessions.db 并通过完整性检查。"
    }

    // MARK: - SQLite 底层辅助

    /// 只读打开：healthCheck / 备份文件与恢复后的校验。
    private nonisolated static func openReadOnly(_ databaseURL: URL, busyTimeoutMs: Int32 = 5000) -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        sqlite3_busy_timeout(database, busyTimeoutMs)
        return database
    }

    /// 读写打开：仅用于我们自己的用户目录里的源库。WAL 模式需要写权限才能
    /// 在 -shm 索引异常时自我重建；除打开期的标准恢复外不做任何写操作。
    private nonisolated static func openWritable(_ databaseURL: URL, busyTimeoutMs: Int32 = 5000) -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        sqlite3_busy_timeout(database, busyTimeoutMs)
        return database
    }

    private nonisolated static func executeScalar(_ database: OpaquePointer, _ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private nonisolated static func quickCheckResult(databaseURL: URL) -> String? {
        guard let database = openReadOnly(databaseURL) else { return nil }
        defer { sqlite3_close(database) }
        return executeScalar(database, "PRAGMA quick_check;")
    }

    private nonisolated static func journalModeOf(databaseURL: URL) -> String? {
        guard let database = openReadOnly(databaseURL) else { return nil }
        defer { sqlite3_close(database) }
        return executeScalar(database, "PRAGMA journal_mode;")
    }

    /// 打开 + quick_check 一步到位；健康返回 true。
    /// `readWritable` 用于 WAL 模式的**源库**：读写方式打开允许 SQLite 在
    /// -shm 索引被并发进程搞乱时自我重建，规避只读连接读到不一致页面的情况。
    private nonisolated static func verifyIntegrity(databaseURL: URL, readWritable: Bool = false) -> Bool {
        guard let database = readWritable ? openWritable(databaseURL) : openReadOnly(databaseURL) else { return false }
        defer { sqlite3_close(database) }
        return executeScalar(database, "PRAGMA quick_check;") == "ok"
    }

    private nonisolated static func checkpoint(databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw SessionDBRepairError.sqlite("无法以读写方式打开数据库执行 checkpoint")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA wal_checkpoint(TRUNCATE);", -1, &statement, nil) == SQLITE_OK else {
            throw SessionDBRepairError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw SessionDBRepairError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    /// SQLite 离线备份 API：从源库生成一致性快照到目标文件。
    /// 源库以**读写**方式打开：WAL 模式在 -shm 索引异常时需要写权限自愈
    /// （BUG-0020），配合 busy_timeout 对并发写者仍然安全。
    ///
    /// BUG-0021：online backup 会把源库第 1 页（含 WAL 文件格式字节
    /// 18/19 = 02 02）原样拷入目标文件，但不会为目标生成 -wal/-shm 伴生文件。
    /// 之后任何**只读**打开都会因为无法重建 wal-index 报 SQLITE_CANTOPEN
    /// （“unable to open database file”，即备份校验时的 quick_check: unreadable），
    /// 快照被误判损坏。因此备份完成后要把目标日志模式显式重置为 DELETE：
    /// SQLite 会重建页头格式字节（回到 01 01）并完成检查点，使快照成为
    /// 自包含的普通库文件，只读校验可稳定通过。
    private nonisolated static func performSQLiteBackup(from sourceURL: URL, to destURL: URL) throws {
        var source: OpaquePointer?
        var destination: OpaquePointer?
        guard sqlite3_open_v2(
            sourceURL.path,
            &source,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let source else {
            if source != nil { sqlite3_close(source) }
            throw SessionDBRepairError.sqlite("无法打开源数据库 \(sourceURL.lastPathComponent)")
        }
        defer { sqlite3_close(source) }
        guard sqlite3_open_v2(
            destURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let destination else {
            if destination != nil { sqlite3_close(destination) }
            throw SessionDBRepairError.sqlite("无法创建备份目标 \(destURL.lastPathComponent)")
        }
        defer { sqlite3_close(destination) }
        sqlite3_busy_timeout(source, 5000)

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw SessionDBRepairError.sqlite(String(cString: sqlite3_errmsg(destination)))
        }
        let result = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE && finishResult == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(destination))
            throw SessionDBRepairError.sqlite("快照中断（backup code \(result), finish code \(finishResult)）: \(message)")
        }

        // BUG-0021：把快照从 WAL 页头格式改写为普通 DELETE 格式，
        // 否则只读校验（openReadOnly）会以 SQLITE_CANTOPEN 失败。
        var errMessage: UnsafeMutablePointer<CChar>?
        let journalRC = sqlite3_exec(destination, "PRAGMA journal_mode=DELETE;", nil, nil, &errMessage)
        guard journalRC == SQLITE_OK else {
            let detail = errMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMessage)
            throw SessionDBRepairError.sqlite("快照日志模式重置失败: \(detail)")
        }
        sqlite3_free(errMessage)
    }

    private nonisolated static func rotateBackups(backupDir: URL, keep: Int) {
        guard keep > 0 else { return }
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let dated = files
            .filter { $0.lastPathComponent.hasPrefix("sessions-") && $0.pathExtension == "db" }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let date = values.contentModificationDate else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        guard dated.count > keep else { return }
        for stale in dated.dropFirst(keep) {
            try? fileManager.removeItem(at: stale.0)
        }
    }

    // MARK: - 进程辅助

    /// 通过 lsof 找出现在正打开该库的进程（COMMAND + PID）。
    nonisolated static func activeOpeners(of databaseURL: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = [databaseURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .dropFirst() // header: COMMAND PID ...
        var openers: [String] = []
        for line in lines ?? [] {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let name = "\(parts[0])(\(parts[1]))"
            if !openers.contains(name) { openers.append(name) }
        }
        return Array(openers.prefix(8))
    }

    private nonisolated static func runCLI(
        executable: String,
        arguments: [String],
        stdinData: Data? = nil
    ) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let stdinData {
            let stdin = Pipe()
            process.standardInput = stdin
            try stdin.fileHandleForWriting.write(contentsOf: stdinData)
            try stdin.fileHandleForWriting.close()
        }
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, outData, errData)
    }
}

// =============================================================================
// SessionDBRepairModel — 供「数据检查与修复」sheet 与设置页共用的视图模型。
//
// 写操作（恢复/修复/深度恢复）的约定：
//   * 如果是本应用启动的 mothx 服务 → 先 stopOwnedService()，完成后重启；
//   * 如果是外部启动的 mothx → 无法代为停止，操作会因占用报错，
//     提示用户先关闭 TUI / 外部服务。
// =============================================================================

@MainActor
final class SessionDBRepairModel: ObservableObject {
    let mothx: MothxServiceManager

    @Published var health: SessionDBHealth?
    @Published var backups: [SessionDBBackup] = []
    @Published var log = ""
    @Published var busy = false

    init(mothx: MothxServiceManager) {
        self.mothx = mothx
    }

    var databaseURL: URL { SessionDBRepair.sessionDatabaseURL(configuredDir: mothx.sessionDir) }
    var backupDirectory: URL { SessionDBRepair.backupDirectory() }

    /// 只读刷新：健康检查 + 备份列表（后台执行，结果回主线程）。
    func refresh() {
        let databaseURL = databaseURL
        let backupDir = backupDirectory
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                (
                    SessionDBRepair.healthCheck(databaseURL: databaseURL),
                    SessionDBRepair.listBackups(backupDir: backupDir)
                )
            }.value
            health = result.0
            backups = result.1
        }
    }

    /// 立即备份（只读 + 生成快照，安全；mothx 服务无需停止）。
    func backupNow() async {
        guard !busy else { return }
        busy = true
        let databaseURL = databaseURL
        let backupDir = backupDirectory
        do {
            let backup = try await Task.detached(priority: .userInitiated) {
                try SessionDBRepair.backupNow(databaseURL: databaseURL, backupDir: backupDir)
            }.value
            append("✓ 备份完成: \(backup.displayName)（\(formatBytes(backup.size))）")
        } catch {
            append("✗ 备份失败: \(error.localizedDescription)")
        }
        busy = false
        refresh()
    }

    /// 从备份恢复（写操作）：先停止本应用启动的服务，完成后重启并重新同步。
    func restore(from backup: SessionDBBackup) async {
        guard !busy else { return }
        busy = true
        append("▶ 从备份恢复: \(backup.displayName)")
        let owned = mothx.ownsRunningProcess
        if owned {
            append("· 停止 mothx 服务…")
            await mothx.stopOwnedService()
        }
        let databaseURL = databaseURL
        do {
            let output = try await Task.detached(priority: .userInitiated) {
                try SessionDBRepair.restore(from: backup, databaseURL: databaseURL)
            }.value
            append(output)
        } catch {
            append("✗ \(error.localizedDescription)")
        }
        if owned {
            append("· 重启服务并重新同步…")
            await mothx.connect()
            await mothx.loadWorkspace()
        }
        busy = false
        refresh()
    }

    /// 常规 WAL / SHM 修复（写操作，同上的服务停启约定）。
    func repairFiles() async {
        guard !busy else { return }
        busy = true
        append("▶ 修复 WAL / SHM…")
        let owned = mothx.ownsRunningProcess
        if owned {
            append("· 停止 mothx 服务…")
            await mothx.stopOwnedService()
        }
        let databaseURL = databaseURL
        do {
            let output = try await Task.detached(priority: .userInitiated) {
                try SessionDBRepair.repairFiles(databaseURL: databaseURL)
            }.value
            append(output)
        } catch {
            append("✗ \(error.localizedDescription)")
        }
        if owned {
            append("· 重启服务并重新同步…")
            await mothx.connect()
            await mothx.loadWorkspace()
        }
        busy = false
        refresh()
    }

    /// 深度恢复（写操作，最后一招）。
    func deepRecover() async {
        guard !busy else { return }
        busy = true
        append("▶ 深度恢复 (.recover)…")
        let owned = mothx.ownsRunningProcess
        if owned {
            append("· 停止 mothx 服务…")
            await mothx.stopOwnedService()
        }
        let databaseURL = databaseURL
        do {
            let output = try await Task.detached(priority: .userInitiated) {
                try SessionDBRepair.deepRecover(databaseURL: databaseURL)
            }.value
            append(output)
        } catch {
            append("✗ \(error.localizedDescription)")
        }
        if owned {
            append("· 重启服务并重新同步…")
            await mothx.connect()
            await mothx.loadWorkspace()
        }
        busy = false
        refresh()
    }

    /// 重新同步项目与会话（调用方负责触发，这里只暴露便利方法）。
    func resync() async {
        await mothx.loadWorkspace()
        refresh()
    }

    func clearLog() {
        log = ""
    }

    func append(_ line: String) {
        if log.isEmpty {
            log = line
        } else {
            log += "\n" + line
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}