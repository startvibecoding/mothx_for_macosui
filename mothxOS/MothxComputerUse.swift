import Foundation
import AppKit

/// Installs and manages the Computer Use MCP server (方案 B).
///
/// The server bundle resource (`Resources/ComputerUse/server.js`) is copied to
/// `~/Library/Application Support/mothx/computer-use/server.js` and registered
/// in the project's `.mothx/mcp.json` (via the existing project-scoped MCP
/// API) with `MOTHX_CU_WORKDIR` pointing at the project workDir, so both the
/// serve and ACP transports pick it up automatically (mothx >= the version
/// that natively merges global + project MCP config).
///
/// This type owns no state beyond what the UI reads; every operation is
/// explicit so the Settings section can show a live status panel.
@MainActor
final class MothxComputerUse {
    /// The MCP server name registered in `mcp.json` (tool prefix `mcp_computer_`).
    static let serverName = "computer"
    static let envWorkDirKey = "MOTHX_CU_WORKDIR"

    // MARK: - Paths

    /// `~/Library/Application Support/mothx/computer-use/` — where the server
    /// script lives. Keep this in sync with where mothx resolves its own data
    /// directory (the app-owned `mothx serve` runs with that cwd).
    static var installDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("mothx/computer-use", isDirectory: true)
    }

    static var serverFileURL: URL {
        installDirectory.appendingPathComponent("server.js")
    }

    /// The bundle ships the server under `Resources/ComputerUse/server.js`.
    /// Because the Xcode file-system-synchronized group flattens resources
    /// into `Contents/Resources/`, always resolve via `Bundle.main.url(forResource:)`
    /// rather than constructing a directory path.
    static func bundledServerURL() -> URL? {
        Bundle.main.url(forResource: "server", withExtension: "js")
    }

    /// Version marker parsed from the top of the server script (`// VERSION: N`).
    static func serverVersion(at url: URL) -> String? {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let prefix = data.prefix(200)
        if let range = prefix.range(of: #"VERSION:\s*(\d+)"#, options: .regularExpression) {
            let line = prefix[range]
            if let number = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) {
                return number
            }
        }
        return nil
    }

    // MARK: - Node resolution

    /// Resolves the node executable the same way the app resolves mothx:
    /// through an interactive login shell, so nvm/homebrew PATH entries are
    /// honored. Returns nil when node is missing (the UI then routes to the
    /// existing environment-check onboarding).
    static func resolvedNodeExecutable() async -> URL? {
        guard let path = await MothxServiceManager.shellCapturedPath("which node"),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Permission probes (observational, never prompts)

    enum PermissionState: Equatable {
        case ok
        case denied
        case unknown
    }

    /// Probes screen recording by taking one real screenshot to a temp file.
    /// `screencapture` prints `could not create image from display` (or exits
    /// non-zero / writes an all-black image) when the responsible process
    /// lacks the Screen Recording TCC grant.
    static func probeScreenRecording() -> PermissionState {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mothx-cu-probe-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", url.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists {
                // All-black capture means the permission prompt was bypassed
                // with an empty frame on some macOS versions.
                if let data = try? Data(contentsOf: url),
                   let rep = NSBitmapImageRep(data: data), isAllBlack(rep) {
                    try? FileManager.default.removeItem(at: url)
                    return .denied
                }
                try? FileManager.default.removeItem(at: url)
                return .ok
            }
            if stderr.localizedCaseInsensitiveContains("could not create image")
                || stderr.localizedCaseInsensitiveContains("not authorized") {
                return .denied
            }
            return .unknown
        } catch {
            return .unknown
        }
    }

    private static func isAllBlack(_ rep: NSBitmapImageRep) -> Bool {
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return true }
        // Sample a few pixels instead of walking the whole image.
        let samples: [(Int, Int)] = [(0, 0), (rep.pixelsWide / 2, rep.pixelsHigh / 2),
                                     (rep.pixelsWide - 1, rep.pixelsHigh - 1),
                                     (rep.pixelsWide / 4, rep.pixelsHigh / 4)]
        for (x, y) in samples {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let brightness = color.redComponent * 0.299 + color.greenComponent * 0.587 + color.blueComponent * 0.114
            if brightness > 0.02 { return false }
        }
        return true
    }

    /// Probes accessibility by asking System Events for the frontmost process
    /// name. `-1719 not allowed assistive access` means the grant is missing.
    static func probeAccessibility() -> PermissionState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", #"tell application "System Events" to get name of first process"#]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            if process.terminationStatus == 0 { return .ok }
            if stderr.contains("-1719") || stderr.localizedCaseInsensitiveContains("not allowed assistive access") {
                return .denied
            }
            return .unknown
        } catch {
            return .unknown
        }
    }

    /// Opens the matching System Settings privacy pane.
    static func openPrivacyPane(screenRecording: Bool) {
        let urlString = screenRecording
            ? "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Status

    struct Status {
        var serverInstalled = false
        var installedVersion: String?
        var bundledVersion: String?
        var nodeFound = false
        var nodePath: String?
        var screenRecording: PermissionState = .unknown
        var accessibility: PermissionState = .unknown
        var shotsDirectoryExists = false
        var configuredInProject = false

        var installedIsCurrent: Bool {
            guard let installedVersion, let bundledVersion else { return false }
            return installedVersion == bundledVersion
        }
    }

    /// Reads the current on-disk / configured state without mutating anything.
    static func status(workDir: String, projectServers: [MothxMCPServer]) async -> Status {
        var status = Status()
        let fm = FileManager.default
        status.serverInstalled = fm.fileExists(atPath: serverFileURL.path)
        status.installedVersion = status.serverInstalled ? serverVersion(at: serverFileURL) : nil
        if let bundled = bundledServerURL() {
            status.bundledVersion = serverVersion(at: bundled)
        }
        status.nodeFound = await resolvedNodeExecutable() != nil
        if status.nodeFound {
            status.nodePath = await MothxServiceManager.shellCapturedPath("which node")
        }
        status.screenRecording = probeScreenRecording()
        status.accessibility = probeAccessibility()
        let shots = URL(fileURLWithPath: workDir).appendingPathComponent(".mothx/computer-use", isDirectory: true)
        status.shotsDirectoryExists = fm.fileExists(atPath: shots.path)
        status.configuredInProject = projectServers.contains { $0.name == serverName }
        return status
    }

    // MARK: - Install / uninstall

    /// Installs the bundled server script (only when the installed version
    /// differs, so a running server's file handle is not replaced) and upserts
    /// the `computer` entry in the project's `.mothx/mcp.json`, preserving all
    /// other entries and fields (including the newer `enabled` boolean).
    static func install(workDir: String, projectServers: [MothxMCPServer], saveServers: ([MothxMCPServer]) async throws -> [MothxMCPServer]) async throws -> [MothxMCPServer] {
        let fm = FileManager.default
        try fm.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        guard let bundled = bundledServerURL() else {
            throw MothxComputerUseError.bundleMissing
        }
        let installedVersion = fm.fileExists(atPath: serverFileURL.path) ? serverVersion(at: serverFileURL) : nil
        let bundledVersion = serverVersion(at: bundled)
        if !fm.fileExists(atPath: serverFileURL.path) || installedVersion != bundledVersion {
            if fm.fileExists(atPath: serverFileURL.path) { try? fm.removeItem(at: serverFileURL) }
            try fm.copyItem(at: bundled, to: serverFileURL)
        }

        let workDirAbsolute = URL(fileURLWithPath: workDir).standardizedFileURL.path
        var entry = MothxMCPServer()
        entry.name = Self.serverName
        entry.type = MothxMCPServer.stdioType
        entry.command = "node"
        entry.args = [serverFileURL.path]
        entry.env = [MothxMCPPair(name: Self.envWorkDirKey, value: workDirAbsolute)]
        entry.enabled = true

        var servers = projectServers
        if let index = servers.firstIndex(where: { $0.name == Self.serverName }) {
            // Preserve the existing entry's transport fields, but refresh the
            // command/env so a moved workDir or updated script path applies.
            var existing = servers[index]
            existing.command = entry.command
            existing.args = entry.args
            existing.env = entry.env
            existing.enabled = true
            servers[index] = existing
        } else {
            servers.append(entry)
        }
        return try await saveServers(servers)
    }

    /// Removes the `computer` entry from the project's `.mothx/mcp.json`.
    /// Screenshots and the installed script are kept unless the user asks for
    /// a full cleanup.
    static func uninstall(projectServers: [MothxMCPServer], saveServers: ([MothxMCPServer]) async throws -> [MothxMCPServer]) async throws -> [MothxMCPServer] {
        let servers = projectServers.filter { $0.name != Self.serverName }
        return try await saveServers(servers)
    }

    /// Deletes the installed script (used by "彻底清理"). Screenshots under
    /// the project stay untouched.
    static func removeInstalledServer() {
        try? FileManager.default.removeItem(at: serverFileURL)
    }
}

enum MothxComputerUseError: LocalizedError {
    case bundleMissing
    case notConnected

    var errorDescription: String? {
        switch self {
        case .bundleMissing:
            return "找不到内置的 computer-use server.js 资源（构建可能不完整）。"
        case .notConnected:
            return "尚未连接 mothx 服务。"
        }
    }
}
