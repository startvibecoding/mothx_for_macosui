import Foundation
import AppKit

/// Computer Use — app-wide, single-switch.
///
/// The capability is NOT a per-project MCP server any more. It is delivered by
/// two things that already exist in the runtime:
///
///   1. macOS permissions this Mac grants to *this application* — Screen
///      Recording (screenshots) and Accessibility (simulated input). That is
///      the only thing the Settings switch is responsible for.
///   2. A global skill (`~/.mothx/skills/computer-use/SKILL.md`) that teaches
///      the agent the screenshot → read(image) → click/type → screenshot loop
///      using the built-in `bash` + `read` tools.
///
/// Because it rides on the standard tools, every session can use it in any
/// project: `yolo` runs the actions automatically, `agent`/`plan` ask for the
/// user's approval through the existing tool-approval flow, all decided by the
/// model from the prompt.
@MainActor
final class MothxComputerUse {
    /// Directory name under `~/.mothx/skills` (must match the app's global
    /// skill root so the app-side Skills list and mothx agree).
    static let skillName = "computer-use"

    // MARK: - Skill install / remove

    /// Default global skill root (`~/.mothx/skills`), used when mothx settings
    /// do not override `skillsDir`.
    static var defaultSkillsRoot: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mothx/skills", isDirectory: true)
            .path
    }

    static func skillFileURL(inRoot root: String) -> URL {
        URL(fileURLWithPath: root)
            .appendingPathComponent(skillName, isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    static func skillInstalled(inRoot root: String) -> Bool {
        FileManager.default.fileExists(atPath: skillFileURL(inRoot: root).path)
    }

    /// Writes the bundled recipe so the agent can drive the desktop. Idempotent.
    static func installSkill(inRoot root: String) throws {
        let fm = FileManager.default
        let fileURL = skillFileURL(inRoot: root)
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try skillMarkdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Removes the recipe so the agent stops reaching for the desktop.
    static func removeSkill(inRoot root: String) {
        try? FileManager.default.removeItem(at: skillFileURL(inRoot: root).deletingLastPathComponent())
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

    /// Runs both probes. On first use these trigger the macOS permission
    /// prompts for this application (Screen Recording and Accessibility); when
    /// the user declined earlier, the system shows nothing and we return
    /// `.denied`, which the UI turns into a "open System Settings" affordance.
    static func requestPermissions() async {
        _ = probeScreenRecording()
        _ = probeAccessibility()
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
        var screenRecording: PermissionState = .unknown
        var accessibility: PermissionState = .unknown
        var skillInstalled = false

        var allGranted: Bool { screenRecording == .ok && accessibility == .ok }
    }

    /// Reads the current permission + skill state without mutating anything.
    static func currentStatus(inRoot root: String) async -> Status {
        var status = Status()
        status.screenRecording = probeScreenRecording()
        status.accessibility = probeAccessibility()
        status.skillInstalled = skillInstalled(inRoot: root)
        return status
    }

    // MARK: - Skill content

    /// Recipes for the screenshot → read → act loop. Written verbatim to
    /// `~/.mothx/skills/computer-use/SKILL.md`.
    static let skillMarkdown = #"""
    # Computer Use — 操作本机桌面

    当用户要求「截个图看看 / 看看屏幕上是什么 / 帮我点一下 / 输入… / 打开某个 App 操作」等
    本机桌面操作时使用本技能。用 **bash 截图 → read 看图 → bash 操作 → 再截图确认** 的循环完成。

    前置条件：App「设置 → 电脑控制」开关已打开，且本应用已获得 macOS 的
    **屏幕录制** 与 **辅助功能** 权限。若截图报权限错误（`could not create image` / `-1719`），
    停下来告诉用户去开关里授权，不要反复重试。

    运行模式决定执行方式：`yolo` 直接执行；`agent` 的每次 bash 都会先请你（用户）授权；
    `plan` 只读，不能真正操作。

    ## 1. 观察：截图

    ```bash
    mkdir -p .mothx/computer-use
    screencapture -x -o .mothx/computer-use/shot-001.png
    ```

    然后把图片当作图像读进来（不要只看文字）：

    `read(path=".mothx/computer-use/shot-001.png", imageMode="detail")`

    截图固定落在会话工作目录的 `.mothx/computer-use/`（已在 `.gitignore` 中忽略）。

    ## 2. 坐标换算（最容易出错的地方）

    `screencapture` 输出的是**像素**，而点击使用的是屏幕**点（points）**。先求比例：

    ```bash
    sips -g pixelWidth -g pixelHeight .mothx/computer-use/shot-001.png
    osascript -e 'tell application "Finder" to get bounds of window of desktop'
    ```

    `scale = 像素宽 / 桌面 bounds 宽度`（Retina 通常为 2）。
    **点击点 = 截图里的像素坐标 ÷ scale**，否则会偏到两倍位置。

    多显示器：全屏截图会把所有屏幕拼在一张图里；比例不一致时不要用全屏图算坐标，
    改用区域截图 `-R x,y,w,h`（points，主屏坐标系）只截目标区域。

    ## 3. 操作（坐标单位：屏幕点）

    ```bash
    # 左键单击
    osascript -e 'tell application "System Events" to click at {x, y}'

    # 键入 ASCII 文本
    osascript -e 'tell application "System Events" to keystroke "hello"'

    # 键入中文/非 ASCII：走剪贴板再粘贴
    printf '%s' '你好' | pbcopy
    osascript -e 'tell application "System Events" to keystroke "v" using command down'

    # 按键（key code：return=36, escape=53, tab=48, space=49, delete=51）
    osascript -e 'tell application "System Events" to key code 36'

    # 组合键（例如 ⌘S）
    osascript -e 'tell application "System Events" to keystroke "s" using command down'

    # 激活某个应用
    osascript -e 'tell application "Safari" to activate'

    # 当前前台应用
    osascript -e 'tell application "System Events" to get name of every process whose background only is false'

    # 某应用的窗口 {名称, 位置, 尺寸}（points）
    osascript -e 'tell application "System Events" to tell process "Safari" to get {name, position, size} of every window'
    ```

    安装了 `cliclick`（`brew install cliclick`，可选）时可用：
    `cliclick c:x,y` 单击、`dc:x,y` 双击、`rc:x,y` 右键、`m:x,y` 移动、`dd:x,y du:x,y` 拖拽。

    ## 4. 确认

    每个动作之后都**重新截图并 read 查看**，用新画面确认结果，不要凭想象宣布成功。
    需要让用户看到某张图时，调用 `publish_artifact .mothx/computer-use/shot-NNN.png`。

    ## 边界

    - 只操作本机桌面，不做远程/云端。
    - 截图可能包含密钥或隐私：只放在 `.mothx/computer-use/`，绝不上传或写进日志。
    - 用户随时可以用「停止」中断本次运行。
    """#
}
