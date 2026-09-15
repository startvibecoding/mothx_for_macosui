import AppKit
import SwiftUI

struct AboutSection: View {
    @EnvironmentObject private var languageStore: LanguageStore
    @EnvironmentObject private var mothx: MothxServiceManager
    @State private var mothxVersion: String?
    @State private var latestVersion: String?
    @State private var isChecking = false
    @State private var isUpdating = false
    @State private var errorHint: String?

    @State private var showUpdateProgress = false
    @State private var updateStage: MothxUpdateStage = .stoppingService
    @State private var updateLog = ""

    private let appDisplayName = "Mothx UI for MacOS"

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var recommendedRuntimeVersion: String {
        MothxRuntimeCompatibility.recommendedVersion
    }

    private var runtimeStatus: MothxRuntimeVersionStatus {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MOTHXOS_SIMULATE_UPDATE_AVAILABLE"] == "1" {
            return .needsUpgrade
        }
        #endif
        return RuntimeInstall.runtimeVersionStatus(current: mothxVersion)
    }

    private var runtimeActionAvailable: Bool {
        runtimeStatus == .needsUpgrade
            || runtimeStatus == .updateAvailable
            || runtimeStatus == .newerCanDowngrade
            || onlineUpdateVersion != nil
    }

    /// Non-nil when npm publishes a build strictly newer than the installed
    /// runtime, so the About page can offer an in-place online update to it.
    ///
    /// Compatibility-driven up/downgrades (outside the supported 1.3.x line)
    /// keep their own button and target the recommended patch; the online
    /// update only fills the gap where the installed runtime is already
    /// compatible but still behind the published release (e.g. 1.3.100 vs
    /// 1.3.101).
    private var onlineUpdateVersion: String? {
        switch runtimeStatus {
        case .needsUpgrade, .newerCanDowngrade:
            return nil
        default:
            return RuntimeInstall.onlineUpdateTarget(current: mothxVersion, latest: latestVersion)
        }
    }

    /// Version the update button installs: the newer published build when one
    /// is available, otherwise the app's recommended compatibility patch.
    private var updateTargetVersion: String {
        onlineUpdateVersion ?? recommendedRuntimeVersion
    }

    private var actionButtonTitle: String {
        if onlineUpdateVersion != nil { return languageStore.copy.updateButton }
        switch runtimeStatus {
        case .newerCanDowngrade: return languageStore.copy.downgradeToRecommended
        default: return languageStore.copy.upgradeToRecommended
        }
    }

    var body: some View {
        let c = languageStore.copy
        return SettingsCard(title: c.about, subtitle: c.aboutSubtitle) {
            VStack(alignment: .leading, spacing: 14) {
                infoRow(c.appNameLabel, appDisplayName)
                infoRow(c.appVersionLabel, appVersion)
                infoRow(c.mothxVersionLabel, mothxVersion ?? c.versionUnknown)
                infoRow(c.recommendedVersionLabel, recommendedRuntimeVersion)
                HStack {
                    Text(c.latestVersionLabel)
                    Spacer()
                    if isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(latestVersion ?? c.versionUnknown).foregroundStyle(.secondary)
                    }
                }

                if !isChecking {
                    if onlineUpdateVersion != nil {
                        Text(c.updateAvailableHint)
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        switch runtimeStatus {
                        case .needsUpgrade:
                            Text(c.runtimeNeedsUpgradeHint(recommendedRuntimeVersion))
                                .font(.caption).foregroundStyle(.orange)
                        case .updateAvailable:
                            Text(c.runtimeUpdateAvailableHint(recommendedRuntimeVersion))
                                .font(.caption).foregroundStyle(.orange)
                        case .newerCanDowngrade:
                            Text(c.runtimeNewerCanDowngradeHint(recommendedRuntimeVersion))
                                .font(.caption).foregroundStyle(.orange)
                        case .compatible:
                            Text(c.runtimeCompatibleHint).font(.caption).foregroundStyle(.secondary)
                        case .missing:
                            Text(c.runtimeMissingHint).font(.caption).foregroundStyle(.secondary)
                        case .invalid:
                            Text(c.runtimeVersionInvalidHint).font(.caption).foregroundStyle(.red)
                        }
                    }
                    if latestVersion == nil {
                        Text(c.npmUnavailableHint).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let errorHint {
                    Text(errorHint).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    Button(c.refreshVersion) { Task { await checkVersions() } }
                        .buttonStyle(.bordered)
                        .disabled(isChecking || isUpdating)
                    if runtimeActionAvailable {
                        Button(isUpdating ? c.updating : actionButtonTitle) { Task { await runUpdate(asAdmin: false) } }
                            .buttonStyle(.borderedProminent).tint(.orange)
                            .disabled(isUpdating)
                    }
                }
            }
        }
        .task { await checkVersions() }
        .sheet(isPresented: $showUpdateProgress) {
            UpdateProgressSheet(
                stage: updateStage,
                log: updateLog,
                targetVersion: updateTargetVersion,
                onClose: { showUpdateProgress = false },
                onInstallAsAdmin: { Task { await runUpdate(asAdmin: true) } }
            )
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }
    }

    private func checkVersions() async {
        isChecking = true
        errorHint = nil
        async let mothxResult = fetchMothxVersion()
        async let npmResult = fetchLatestNpmVersion()
        let (mv, lv) = await (mothxResult, npmResult)
        mothxVersion = mv
        latestVersion = lv
        isChecking = false
    }

    private func fetchMothxVersion() async -> String? {
        // e.g. "v1.2.95-dirty" → "1.2.95-dirty"
        await RuntimeInstall.mothxVersionString().map(Self.normalizeVersion)
    }

    private func fetchLatestNpmVersion() async -> String? {
        await RuntimeInstall.latestNpmVersion()
    }

    /// Runs the shared update flow (stop service → npm install → restart) in
    /// the progress sheet, mapping its outcome onto stages/hints. `asAdmin`
    /// retries the install through the system authorization prompt.
    private func runUpdate(asAdmin: Bool) async {
        let c = languageStore.copy
        isUpdating = true
        errorHint = nil
        updateLog = ""
        updateStage = .stoppingService
        showUpdateProgress = true

        let target = updateTargetVersion
        let result = await mothx.performMothxUpdate(targetVersion: target, asAdmin: asAdmin, onStage: { stage in
            updateStage = stage
            let line = UpdateFlowSupport.stageLogLine(stage, c: c, targetVersion: target)
            if !line.isEmpty { appendUpdateLog(line) }
            if stage == .stoppingService && !mothx.ownsRunningProcess {
                appendUpdateLog(c.updateLogExternalServiceSkipped)
            }
        }, onLog: { chunk in
            updateLog += chunk
        })

        switch result {
        case .succeeded(let version):
            if let version { mothxVersion = version }
            updateStage = .succeeded
            appendUpdateLog(c.updateLogSucceeded)
        case .needsAdmin, .canceled:
            // Canceled authorization prompt — park at the choices again.
            updateStage = .needsAdmin
            appendUpdateLog(c.updateLogNeedsAdmin)
            errorHint = c.updateNeedsAdminHint
        case .failed(let detail):
            updateStage = .failed
            appendUpdateLog(c.updateLogFailedDetail(detail))
            errorHint = c.updateFailedPrefix(detail)
        }

        isUpdating = false
    }

    private func appendUpdateLog(_ line: String) {
        updateLog += (updateLog.isEmpty ? "" : "\n") + line
    }

    private static func normalizeVersion(_ version: String) -> String {
        version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
    }
}