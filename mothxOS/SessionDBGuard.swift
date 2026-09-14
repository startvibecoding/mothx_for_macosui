import Foundation
import SQLite3

/// 会话库 (sessions.db) 的只读健康守卫。
///
/// 背景：`~/.mothx/sessions/sessions.db` 是 WAL 模式，mothxOS App 与 mothx TUI
/// 会并发打开同一个库。并发 + 不同 SQLite 版本会让 `-shm`（WAL 索引）出现
/// 半损坏状态，进而可能把撕裂的 WAL 帧并入主库，导致
/// `database disk image is malformed`。
///
/// 实测结论（详见 docs/session-db-wal-shm.md）：
///   - `-shm` 纯索引、不含用户数据，100% 可再生，删除永远安全；
///   - 真正的损坏来自 WAL 帧撕裂，SQLite 自身行为不确定，需要外部保护；
///   - 完整保护/备份/恢复由 tools/session_db_guard.sh 承担（check / checkpoint
///     / repair / backup / recover）。
///
/// App 是 sessions.db 的**只读**消费者，原则：不写库、不主动 checkpoint，
/// 只在打开时做快速自检与更宽容的超时，减少与 TUI 的冲突窗口。
enum SessionDBGuard {

    /// 打开只读连接并设置较宽松的 busy timeout（App 侧为 5000ms）。
    /// 失败时返回 nil。
    static func openReadOnly(databaseURL: URL, busyTimeoutMs: Int32 = 5000) -> OpaquePointer? {
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

    /// 对已打开连接做快速完整性自检（`PRAGMA quick_check`，只读、开销小）。
    /// 返回 false 表示库已损坏：本次读取应放弃，由
    /// `tools/session_db_guard.sh recover` 兜底恢复，不要在本进程内尝试写修复。
    static func quickCheck(_ database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            return false
        }
        return String(cString: text) == "ok"
    }

    /// 打开 + 自检一步到位。健康返回连接（需调用方负责 close），否则返回 nil。
    static func openHealthyReadOnly(databaseURL: URL, busyTimeoutMs: Int32 = 5000) -> OpaquePointer? {
        guard let database = openReadOnly(databaseURL: databaseURL, busyTimeoutMs: busyTimeoutMs) else {
            return nil
        }
        if quickCheck(database) {
            return database
        }
        sqlite3_close(database)
        return nil
    }
}