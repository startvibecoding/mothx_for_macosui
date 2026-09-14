import SwiftUI

/// 数据检查与修复模式。
///
/// 启动环境检测发现同步数据异常 / 会话库损坏时打开；也可从
/// 设置 → 数据与备份进入。修复优先路径：从备份恢复 → WAL/SHM 修复 →
/// 深度恢复 (.recover)。
struct SessionDBRepairSheet: View {
    @EnvironmentObject private var languageStore: LanguageStore
    @StateObject private var model: SessionDBRepairModel
    let reason: String
    @Binding var isPresented: Bool

    @State private var confirmRestore: SessionDBBackup?
    @State private var confirmRepair = false
    @State private var confirmDeepRecover = false
    @State private var resyncing = false

    init(mothx: MothxServiceManager, reason: String, isPresented: Binding<Bool>) {
        _model = StateObject(wrappedValue: SessionDBRepairModel(mothx: mothx))
        self.reason = reason
        self._isPresented = isPresented
    }

    private var c: Copy { languageStore.copy }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    healthCard
                    actionRow
                    backupsCard
                    hintText
                    logCard
                }
            }
            footer
        }
        .padding(20)
        .frame(width: 680, height: 640)
        .background(Color.codexBackground)
        .task { model.refresh() }
        .confirmationDialog(
            c.dataRestoreDialogTitle,
            isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button(c.dataRestoreAction, role: .destructive) {
                guard let backup = confirmRestore else { return }
                confirmRestore = nil
                Task { await model.restore(from: backup) }
            }
            Button(c.cancel, role: .cancel) { confirmRestore = nil }
        } message: {
            Text(confirmRestore.map { c.dataRestoreDialogMessage($0.displayName) } ?? "")
        }
        .confirmationDialog(c.dataRepairNow, isPresented: $confirmRepair, titleVisibility: .visible) {
            Button(c.dataRepairNow) {
                confirmRepair = false
                Task { await model.repairFiles() }
            }
            Button(c.cancel, role: .cancel) { confirmRepair = false }
        } message: {
            Text(c.dataRepairDialogMessage)
        }
        .confirmationDialog(c.dataDeepRecover, isPresented: $confirmDeepRecover, titleVisibility: .visible) {
            Button(c.dataDeepRecover, role: .destructive) {
                confirmDeepRecover = false
                Task { await model.deepRecover() }
            }
            Button(c.cancel, role: .cancel) { confirmDeepRecover = false }
        } message: {
            Text(c.dataDeepRecoverDialogMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(c.dataRepairLongTitle, systemImage: "externaldrive.badge.checkmark")
                    .font(.title3.bold())
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.clearLog()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Clear log")
                Button(c.dataClose) { close() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Health

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(c.dataStatus).font(.headline)
                Spacer()
                verdictBadge
            }
            if let health = model.health {
                VStack(alignment: .leading, spacing: 5) {
                    healthRow(c.dataDBPath, health.databaseURL.path, monospaced: true)
                    if health.journalMode.isEmpty == false {
                        healthRow(c.dataJournal, health.journalMode)
                    }
                    healthRow(c.dataIntegrity, health.integrity, ok: health.integrity == "ok")
                    healthRow(
                        c.dataWal,
                        health.hasWalFrames
                            ? "\(bytes(health.walBytes))（\(c.dataWalPending)）"
                            : (health.walBytes > 0 ? bytes(health.walBytes) : c.dataNone),
                        ok: !health.hasWalFrames
                    )
                    healthRow(
                        c.dataShm,
                        health.shmIrregular ? c.dataShmIrregular : (health.shmBytes > 0 ? "\(bytes(health.shmBytes))（\(c.dataShmNormal)）" : c.dataNone),
                        ok: !health.shmIrregular
                    )
                    if !health.activeOpeners.isEmpty {
                        healthRow(c.dataOpeners, health.activeOpeners.joined(separator: " "), ok: false)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .padding(14)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
    }

    private var verdictBadge: some View {
        let (tint, title): (Color, String) = {
            switch model.health?.verdict {
            case .none: return (.secondary, "…")
            case .healthy: return (.green, c.dataStatusHealthy)
            case .residue: return (.orange, c.dataStatusResidue)
            case .corrupted: return (.red, c.dataStatusCorrupted)
            case .missing: return (.orange, c.dataStatusMissing)
            }
        }()
        return HStack(spacing: 6) {
            Image(systemName: verdictIcon).font(.system(size: 12))
            Text(title).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }

    private var verdictIcon: String {
        switch model.health?.verdict {
        case .none: return "ellipsis"
        case .healthy: return "checkmark.circle.fill"
        case .residue: return "exclamationmark.triangle.fill"
        case .corrupted: return "xmark.octagon.fill"
        case .missing: return "questionmark.circle.fill"
        }
    }

    private func healthRow(_ label: String, _ value: String, ok: Bool = true, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Image(systemName: ok ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(ok ? .green : .red)
            Text(value)
                .font(.caption)
                .font(monospaced ? .system(.caption, design: .monospaced) : .system(.caption))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                guard let backup = model.backups.first(where: { $0.valid }) else { return }
                confirmRestore = backup
            } label: {
                Label(c.dataRestore, systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(model.busy || !model.backups.contains(where: { $0.valid }))

            Button {
                Task { await model.backupNow() }
            } label: {
                Label(c.dataBackupNow, systemImage: "externaldrive.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(model.busy)

            Button { confirmRepair = true } label: {
                Label(c.dataRepairNow, systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.bordered)
            .disabled(model.busy)

            Button(role: .destructive) { confirmDeepRecover = true } label: {
                Label(c.dataDeepRecover, systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .disabled(model.busy)

            Spacer()

            Button {
                Task { await model.refresh() }
            } label: {
                Label(c.dataRecheck, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.busy)
        }
    }

    // MARK: - Backups

    private var backupsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(c.dataBackups).font(.headline)
            if model.backups.isEmpty {
                Text(c.dataNoBackups)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let shown = Array(model.backups.prefix(6))
                ForEach(shown) { backup in
                    HStack(spacing: 8) {
                        Image(systemName: backup.valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(backup.valid ? .green : .red)
                            .font(.system(size: 13))
                        Text(backup.displayName)
                            .font(.caption)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(dateString(backup.date)) · \(bytes(backup.size))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !backup.valid {
                            Text(c.dataUnusableBadge)
                                .font(.caption2.bold())
                                .foregroundStyle(.red)
                        }
                        Spacer()
                        if backup.valid {
                            Button(c.dataRestore) { confirmRestore = backup }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .disabled(model.busy)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(14)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
    }

    private var hintText: some View {
        Text(model.mothx.ownsRunningProcess ? c.dataRestoreHint : c.dataExternalServiceHint)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Log

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(c.dataLogTitle).font(.headline)
            ScrollView {
                Text(model.log.isEmpty ? c.dataEmptyLog : model.log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(model.log.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                    .padding(8)
            }
            .frame(height: 120)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if model.health?.verdict == .corrupted {
                Button(role: .destructive) { quitApplication() } label: {
                    Label(c.text("退出应用", "Quit App"), systemImage: "power")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Button {
                Task {
                    resyncing = true
                    await model.resync()
                    resyncing = false
                }
            } label: {
                if resyncing {
                    ProgressView().controlSize(.small)
                    Text(c.dataResync).font(.body)
                } else {
                    Label(c.dataResync, systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.busy || resyncing)

            Button {
                Task {
                    resyncing = true
                    await model.resync()
                    resyncing = false
                    if model.mothx.workspaceSyncState == .passed {
                        close()
                    }
                }
            } label: {
                if resyncing {
                    ProgressView().controlSize(.small)
                    Text(c.dataContinue).font(.body)
                } else {
                    Label(c.dataContinue, systemImage: "checkmark")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(model.busy || resyncing)
        }
    }

    // MARK: - Helpers

    private func close() {
        isPresented = false
    }

    private func quitApplication() {
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            exit(0)
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}