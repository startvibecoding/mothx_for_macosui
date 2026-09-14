#!/bin/bash
# =============================================================================
# session_db_guard.sh — mothx 会话库 (sessions.db) 保护 / 备份 / 恢复脚本
#
# 背景
#   ~/.mothx/sessions/sessions.db 使用 SQLite WAL 模式，同一时刻可能被
#   mothxOS App / mothx TUI / 服务器进程并发打开。并发 + 不同 SQLite 版本
#   会让 sessions.db-shm（WAL 索引共享内存文件）进入半损坏状态，进而让
#   后续进程看到"看似有效实则撕裂"的 WAL 帧（实测两轮结果不一致：一次被
#   SQLite 静默截断丢弃、一次把脏帧直接写进库导致 "database disk image is
#   malformed"）。因此不能依赖 SQLite 自行兜底，需要外部保护。
#
# 核心结论（均已在 /tmp 拷贝上实测验证）
#   1. sessions.db-shm 只是 WAL 索引 + 锁，不含任何用户数据，100% 可再生。
#      删除/破坏它，SQLite 下一次打开时会用 WAL 自动重建（实测数据无损）。
#   2. 数据真正在两个文件里：sessions.db + sessions.db-wal。
#      备份必须用 SQLite 的一致性快照（.backup / VACUUM INTO），
#      绝不能只 cp 裸文件（会得到 db 与 wal 互不同步的副本）。
#   3. 损坏兜底：sqlite3 ".recover" 能从打不开的库里导出可抢救的数据。
#
# 用法
#   session_db_guard.sh check      只读诊断（无副作用，随时可跑）
#   session_db_guard.sh checkpoint 把 WAL 合并回主库并截断（收窄并发窗口）
#   session_db_guard.sh repair     检测并修复 shm / wal 不一致（无活跃写者时）
#   session_db_guard.sh backup     一致性快照 + 轮转保留（可 cron / launchd）
#   session_db_guard.sh recover    损坏库兜底：归档现场、.recover 导出、重建
#
# 选项
#   -d DIR    数据库目录（默认 ~/.mothx/sessions）
#   -b DIR    备份目录（默认 ~/.mothx/backups）
#   -n N      备份保留份数（默认 20）
#   -t MS     busy timeout 毫秒（默认 5000）
#   -f        强制（repair/recover 在检测到其他进程仍打开库时也执行写操作）
#   -q        安静模式（只输出关键行）
#
# 示例
#   tools/session_db_guard.sh check
#   tools/session_db_guard.sh checkpoint -f        # 明知 TUI 还开着也执行
#   tools/session_db_guard.sh backup -n 50         # 保留最近 50 份快照
#   tools/session_db_guard.sh recover              # 库已 malformed 时
#
# 推荐集成
#   * App 每次读取 sessions.db 前先跑 check（只读，便宜）
#   * TUI / 服务器每次会话轮次结束后执行 checkpoint（把 WAL 收窄到最小）
#   * launchd 每小时 backup + 每日 repair（示例见 docs/session-db-wal-shm.md）
# =============================================================================

set -u
# 不用 set -e：多数子命令的"失败"是正常分支（如 integrity 失败），需显式处理

# ---------- 默认值与全局状态 -------------------------------------------------
DB_DIR="${HOME}/.mothx/sessions"
BACKUP_DIR="${HOME}/.mothx/backups"
KEEP=20
BUSY_MS=5000
FORCE=0
QUIET=0
CMD=""

log()  { [ "$QUIET" -eq 1 ] || echo "$*"; }
err()  { echo "[guard] 错误: $*" >&2; }
info() { log "[guard] $*"; }

# ---------- 参数解析 ---------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        check|checkpoint|repair|backup|recover) CMD="$1"; shift ;;
        -d) DB_DIR="$2"; shift 2 ;;
        -b) BACKUP_DIR="$2"; shift 2 ;;
        -n) KEEP="$2"; shift 2 ;;
        -t) BUSY_MS="$2"; shift 2 ;;
        -f) FORCE=1; shift ;;
        -q) QUIET=1; shift ;;
        -h|--help) sed -n '1,60p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^=' | head -60; exit 0 ;;
        *) err "未知参数: $1 (见 $0 -h)"; exit 2 ;;
    esac
done

[ -n "$CMD" ] || { err "缺少子命令 (check|checkpoint|repair|backup|recover)"; exit 2; }
command -v sqlite3 >/dev/null 2>&1 || { err "未找到 sqlite3 CLI"; exit 2; }

DB="$DB_DIR/sessions.db"
WAL="$DB_DIR/sessions.db-wal"
SHM="$DB_DIR/sessions.db-shm"

# ---------- 工具函数 ---------------------------------------------------------

# 是否有其他进程正在打开该库（lsof 列出持有者）。返回 0=有活跃进程,1=无。
active_openers() {
    command -v lsof >/dev/null 2>&1 || return 1
    lsof "$DB" >/dev/null 2>&1 && return 0
    return 1
}

opener_list() {
    lsof "$DB" 2>/dev/null | awk 'NR>1 {print $1"("$2")"}' | sort -u | tr '\n' ' '
}

# 运行一条 SQLite 命令，统一注入 busy timeout；返回其退出码
run_sql() { # run_sql <sql...>
    sqlite3 "$DB" ".timeout $BUSY_MS" "$@" 2>&1
}

# 一致性快照：用 .backup 生成（对并发写者也安全）
make_snapshot() { # make_snapshot <dest-db-path>
    sqlite3 "$DB" ".timeout $BUSY_MS" ".backup '$1'" 2>&1
}

# journal 模式（delete/wal）：空库时可能是空串
journal_mode() {
    local m
    m="$(run_sql "PRAGMA journal_mode;" | head -1)"
    echo "${m:-unknown}"
}

# integrity 检查，输出到 stdout，返回 0=ok
integrity() {
    run_sql "PRAGMA integrity_check;"
}

# ---------- 子命令: check（只读诊断） ---------------------------------------
cmd_check() {
    info "数据库目录: $DB_DIR"
    [ -f "$DB" ] || { err "找不到 $DB"; exit 1; }

    local jm integrity_out
    jm="$(journal_mode)"
    integrity_out="$(integrity)"
    local ikey; ikey="$(echo "$integrity_out" | head -1)"

    local wal_sz=0 shm_sz=0 wal_frames=0
    [ -f "$WAL" ] && wal_sz="$(stat -f '%z' "$WAL")"
    [ -f "$SHM" ] && shm_sz="$(stat -f '%z' "$SHM")"
    if [ "$wal_sz" -gt 32 ]; then
        wal_frames=$(( (wal_sz - 32) / (4096 + 24) ))
    fi

    local opener=""
    if active_openers; then opener="$(opener_list)"; else opener="(无)"; fi

    info "journal_mode   : $jm"
    info "integrity      : $ikey"
    info "sessions.db    : $(stat -f '%z' "$DB") bytes"
    info "sessions.db-wal: $wal_sz bytes (待合并帧数 ≈ $wal_frames)"
    info "sessions.db-shm: $shm_sz bytes"
    info "活跃打开进程   : $opener"

    local verdict="健康"
    [ "$ikey" = "ok" ] || verdict="损坏(需要 recover)"
    info "结论           : $verdict"
    [ "$ikey" = "ok" ]
}

# ---------- 子命令: checkpoint（合并 WAL 并截断） ----------------------------
cmd_checkpoint() {
    info "执行 wal_checkpoint(TRUNCATE) ..."
    if active_openers && [ "$FORCE" -eq 0 ]; then
        err "检测到其他进程仍在打开 $DB: $(opener_list)"
        err "并发 checkpoint 可能干扰对方。确认后请加 -f 强制执行，"
        err "或等对方退出后重试（或先跑 backup 再回来自动 checkpoint）。"
        return 3
    fi
    local out
    out="$(run_sql "PRAGMA wal_checkpoint(TRUNCATE);")"
    info "checkpoint 结果: $out"
}

# ---------- 子命令: repair（修复 shm / wal 不一致） --------------------------
cmd_repair() {
    info "开始修复检查 ..."
    [ -f "$DB" ] || { err "找不到 $DB"; exit 1; }

    local ikey integrity_out
    integrity_out="$(integrity)"
    ikey="$(echo "$integrity_out" | head -1)"

    if [ "$ikey" != "ok" ]; then
        err "integrity_check 失败，不能自动修复："
        echo "$integrity_out" | head -5 >&2
        err "请先运行: $0 -d $DB_DIR recover"
        return 1
    fi

    local wal_sz shm_sz
    wal_sz=0; [ -f "$WAL" ] && wal_sz="$(stat -f '%z' "$WAL")"
    shm_sz=0; [ -f "$SHM" ] && shm_sz="$(stat -f '%z' "$SHM")"

    if active_openers && [ "$FORCE" -eq 0 ]; then
        err "检测到其他进程仍在打开 $DB: $(opener_list)，跳过写操作。"
        err "当前仅完成只读完整性校验（结果: ok）。"
        return 3
    fi

    local changed=0

    # 1) 若 wal 已被合并/截断但 shm 仍是旧世代残留（size 不合规等）→ 删除重建。
    #    实验验证：删 shm 是安全的，SQLite 下次打开自动重建索引。
    if [ -f "$SHM" ] && [ $((shm_sz % 32768)) -ne 0 ]; then
        info "shm 尺寸异常 ($shm_sz bytes)，删除让 SQLite 重建索引 ..."
        mv "$SHM" "$SHM.orphan-$(date +%Y%m%d-%H%M%S)" && changed=1
    fi

    # 2) 有残留 WAL 帧 → checkpoint 合并进主库并截断，收窄并发窗口
    if [ -f "$WAL" ] && [ "$wal_sz" -gt 32 ]; then
        info "WAL 有 $(( (wal_sz - 32) / (4096 + 24) )) 帧待合并，执行 checkpoint(TRUNCATE) ..."
        run_sql "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null && changed=1
    fi

    # 3) 主动打开一次，强制 SQLite 重建/校验 wal-index（覆盖坏 shm 的场景）
    info "触发 SQLite 重建 wal-index（打开 + quick_check）..."
    local qk
    qk="$(run_sql "PRAGMA quick_check;")"
    info "quick_check: $(echo "$qk" | head -1)"

    if [ "$changed" -eq 1 ]; then
        info "修复完成：残留文件已清理，索引已重建。"
    else
        info "无需修复（一切一致）。"
    fi
}

# ---------- 子命令: backup（一致性快照 + 轮转） ------------------------------
cmd_backup() {
    [ -f "$DB" ] || { err "找不到 $DB"; exit 1; }

    # 备份前先确认库是健康的，避免把坏快照当宝贝留着
    local ikey
    ikey="$(integrity | head -1)"
    if [ "$ikey" != "ok" ]; then
        err "integrity_check 失败（$ikey），拒绝备份损坏库。"
        err "请先: $0 -d $DB_DIR recover  或手动排查。"
        return 1
    fi

    mkdir -p "$BACKUP_DIR" || { err "无法创建备份目录 $BACKUP_DIR"; exit 1; }

    local ts stamp dest
    ts="$(date +%Y%m%d-%H%M%S)"
    stamp="sessions-${ts}.db"
    dest="$BACKUP_DIR/$stamp"

    info "一致性快照 → $dest"
    local out
    out="$(make_snapshot "$dest")"
    if [ -n "$out" ]; then
        err "快照失败: $out"
        rm -f "$dest"
        return 1
    fi

    # 快照本身做一次只读验证（通过后再进入轮转）
    if sqlite3 "$dest" "PRAGMA quick_check;" 2>/dev/null | grep -q '^ok'; then
        info "快照验证: ok ($(stat -f '%z' "$dest") bytes)"
    else
        err "警告: 快照 $dest 验证未通过，已保留待人工检查"
    fi

    # 轮转：保留最近 KEEP 份
    local removed=0 f
    while [ "$(ls -1t "$BACKUP_DIR"/sessions-*.db 2>/dev/null | wc -l | tr -d ' ')" -gt "$KEEP" ]; do
        f="$(ls -1t "$BACKUP_DIR"/sessions-*.db 2>/dev/null | tail -1)"
        rm -f "$f" && removed=$((removed + 1))
    done
    info "轮转: 删除 $removed 份旧快照，保留最近 $KEEP 份"
    info "备份完成。"
}

# ---------- 子命令: recover（损坏兜底：归档 → .recover → 重建） --------------
cmd_recover() {
    [ -f "$DB" ] || { err "找不到 $DB"; exit 1; }

    if active_openers && [ "$FORCE" -eq 0 ]; then
        err "检测到其他进程仍在打开 $DB: $(opener_list)"
        err "恢复会改名/替换库文件，请先停止相关进程，或加 -f 强制。"
        return 3
    fi

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local base="$DB_DIR/sessions.corrupt-$ts"

    info "归档损坏现场 → ${base}.*"
    mv "$DB"   "$base.db"   || { err "无法归档 $DB"; return 1; }
    [ -f "$WAL" ] && mv "$WAL" "$base.db-wal"
    [ -f "$SHM" ] && mv "$SHM" "$base.db-shm"

    info "用 .recover 导出可抢救数据 ..."
    local sql="$base.recovered.sql"
    if sqlite3 "$base.db" ".recover" > "$sql" 2>"$base.recover.err"; then
        info "导出成功: $sql ($(wc -l < "$sql" | tr -d ' ') 行)"
    else
        err ".recover 有告警（见 $base.recover.err），继续尝试重建"
    fi

    # 重建新库
    local newdb="$DB_DIR/sessions.rebuilt-$ts.db"
    info "重建 → $newdb"
    if sqlite3 "$newdb" < "$sql" 2>"$base.rebuild.err"; then
        info "重建成功。请人工核对 $newdb 数据后替换回 sessions.db："
        info "  mv $newdb $DB"
        info "  rm -f $DB_DIR/sessions.db-wal $DB_DIR/sessions.db-shm"
    else
        err "重建失败，见 $base.rebuild.err；原始现场保留在 ${base}.* 可继续抢救。"
        return 1
    fi
    info "恢复流程结束。原始损坏文件保留在 ${base}.*（勿删除，可留证/二次抢救）。"
}

# ---------- 入口 -------------------------------------------------------------
case "$CMD" in
    check)      cmd_check ;;
    checkpoint) cmd_checkpoint ;;
    repair)     cmd_repair ;;
    backup)     cmd_backup ;;
    recover)    cmd_recover ;;
    *) err "未知子命令: $CMD"; exit 2 ;;
esac