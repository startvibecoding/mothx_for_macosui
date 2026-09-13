#!/usr/bin/env node
// VERSION: 1
//
// mothxOS Computer Use MCP server — zero-dependency macOS desktop automation.
//
// Implements the Model Context Protocol (stdio transport, newline-delimited
// JSON-RPC 2.0) so a mothx agent can screenshot the screen, click, type, press
// keys, activate apps, and inspect windows / accessibility trees.
//
// Coordinate contract (the most important design decision):
//   - `screenshot` produces shot-NNN.png (original pixels) and
//     shot-NNN.view.png (long edge scaled to <= viewLongEdge, default 1568).
//     `latest.png` / `latest.view.png` mirror the most recent capture.
//   - All click/move/drag coordinates default to VIEW-IMAGE PIXELS so the model
//     reasons in the space of the image it actually sees. The server converts
//     to screen points with pointsPerViewPx = screenPointsWidth / viewWidth.
//   - Every result carries `geometry` so the model can self-check.
//
// Zero dependencies: screencapture, sips, osascript, pbcopy, cliclick (optional).
// No screen content is ever written to logs (stderr carries only action types
// and dimensions).
"use strict";

const { spawnSync, spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const readline = require("readline");

const SERVER_VERSION = "1";
const SERVER_NAME = "computer";
const DEFAULT_VIEW_LONG_EDGE = 1568; // between read fast(1024) and detail(2048)
const MIN_VIEW_LONG_EDGE = 1024;
const MAX_VIEW_LONG_EDGE = 2048;
const DEFAULT_KEEP = 40;
const SHOT_DIR_NAME = "computer-use";

// ---------------------------------------------------------------------------
// CLI arguments
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = { workdir: null, selftest: false, viewLongEdge: DEFAULT_VIEW_LONG_EDGE, keep: DEFAULT_KEEP, showVersion: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--workdir" && argv[i + 1]) { args.workdir = argv[++i]; }
    else if (a.startsWith("--workdir=")) { args.workdir = a.slice("--workdir=".length); }
    else if (a === "--selftest") { args.selftest = true; }
    else if (a === "--version" || a === "-v") { args.showVersion = true; }
    else if (a === "--view-long-edge" && argv[i + 1]) { args.viewLongEdge = parseInt(argv[++i], 10); }
    else if (a.startsWith("--view-long-edge=")) { args.viewLongEdge = parseInt(a.slice("--view-long-edge=".length), 10); }
    else if (a === "--keep" && argv[i + 1]) { args.keep = parseInt(argv[++i], 10); }
    else if (a.startsWith("--keep=")) { args.keep = parseInt(a.slice("--keep=".length), 10); }
  }
  if (!Number.isFinite(args.viewLongEdge)) args.viewLongEdge = DEFAULT_VIEW_LONG_EDGE;
  args.viewLongEdge = Math.max(MIN_VIEW_LONG_EDGE, Math.min(MAX_VIEW_LONG_EDGE, args.viewLongEdge));
  if (!Number.isFinite(args.keep) || args.keep < 1) args.keep = DEFAULT_KEEP;
  return args;
}

// ---------------------------------------------------------------------------
// Logging (stderr only; never log screen content or typed text)
// ---------------------------------------------------------------------------

function log(...parts) {
  try {
    process.stderr.write(`[${SERVER_NAME}] ${parts.join(" ")}\n`);
  } catch (_) { /* ignore */ }
}

// ---------------------------------------------------------------------------
// WorkDir handling
// ---------------------------------------------------------------------------

function resolveWorkDir(args) {
  const raw = args.workdir || process.env.MOTHX_CU_WORKDIR || "";
  const trimmed = raw.trim();
  if (!trimmed) {
    return { error: "no workdir: set MOTHX_CU_WORKDIR or pass --workdir. Screenshots must land inside the session workDir so the built-in read tool can open them." };
  }
  const abs = path.resolve(trimmed);
  try {
    const st = fs.statSync(abs);
    if (!st.isDirectory()) {
      return { error: `workdir is not a directory: ${abs}` };
    }
  } catch (_) {
    return { error: `workdir does not exist: ${abs} (create it before starting the server)` };
  }
  return { workdir: abs };
}

function shotsDir(workdir) {
  return path.join(workdir, ".mothx", SHOT_DIR_NAME);
}

function ensureShotsDir(workdir) {
  const dir = shotsDir(workdir);
  fs.mkdirSync(dir, { recursive: true });
  const gi = path.join(dir, ".gitignore");
  if (!fs.existsSync(gi)) {
    try { fs.writeFileSync(gi, "*\n"); } catch (_) { /* best effort */ }
  }
  return dir;
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

let lastGeometry = null; // geometry of the most recent screenshot

function screenPointsForMainDisplay() {
  // Finder's desktop window bounds return the visible screen area in points
  // (e.g. {0, 0, 1512, 982}). Fast and dependency-free.
  try {
    const r = runAppleScript('tell application "Finder" to get bounds of window of desktop');
    const nums = (r.stdout || "").trim().match(/-?\d+/g);
    if (nums && nums.length >= 4) {
      const w = Math.abs(parseInt(nums[2], 10) - parseInt(nums[0], 10));
      const h = Math.abs(parseInt(nums[3], 10) - parseInt(nums[1], 10));
      if (w > 0 && h > 0) return { x: parseInt(nums[0], 10), y: parseInt(nums[1], 10), width: w, height: h };
    }
  } catch (_) { /* fall through */ }
  return null;
}

function imagePixelSize(file) {
  const r = spawnSync("sips", ["-g", "pixelWidth", "-g", "pixelHeight", file], { encoding: "utf8" });
  if (r.status !== 0) return null;
  const w = parseInt((r.stdout.match(/pixelWidth:\s*(\d+)/) || [])[1], 10);
  const h = parseInt((r.stdout.match(/pixelHeight:\s*(\d+)/) || [])[1], 10);
  if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) return null;
  return { width: w, height: h };
}

function makeViewImage(fullPath, viewPath, longEdge) {
  const r = spawnSync("sips", ["-Z", String(longEdge), fullPath, "--out", viewPath], { encoding: "utf8" });
  if (r.status !== 0) return { error: `sips failed: ${(r.stderr || "").trim() || "unknown error"}` };
  return { ok: true };
}

function nextShotNumber(dir) {
  let max = 0;
  try {
    for (const name of fs.readdirSync(dir)) {
      const m = /^shot-(\d+)\.png$/.exec(name);
      if (m) max = Math.max(max, parseInt(m[1], 10));
    }
  } catch (_) { /* ignore */ }
  return max + 1;
}

function cleanupOldShots(dir, keep) {
  try {
    const shots = fs.readdirSync(dir)
      .filter((n) => /^shot-\d+\.png$/.test(n))
      .sort();
    while (shots.length > keep) {
      const old = shots.shift();
      try { fs.unlinkSync(path.join(dir, old)); } catch (_) { /* ignore */ }
      const view = old.replace(/\.png$/, ".view.png");
      try { fs.unlinkSync(path.join(dir, view)); } catch (_) { /* ignore */ }
    }
  } catch (_) { /* ignore */ }
}

// ---------------------------------------------------------------------------
// AppleScript / shell helpers
// ---------------------------------------------------------------------------

function runAppleScript(script, timeoutMs = 15000) {
  return spawnSync("osascript", ["-e", script], { encoding: "utf8", timeout: timeoutMs });
}

function appleScriptEscape(str) {
  return String(str).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function runCLIClick(args, timeoutMs = 10000) {
  return spawnSync("cliclick", args, { encoding: "utf8", timeout: timeoutMs });
}

function cliclickAvailable() {
  const r = spawnSync("which", ["cliclick"], { encoding: "utf8" });
  return r.status === 0 && (r.stdout || "").trim().length > 0;
}

const cliclickCache = { checked: false, available: false };
function cliclickReady() {
  if (!cliclickCache.checked) {
    cliclickCache.available = cliclickAvailable();
    cliclickCache.checked = true;
  }
  return cliclickCache.available;
}

function keyCodeTable() {
  return {
    return: 36, enter: 36, ret: 36, "\r": 36, "\n": 36,
    tab: 48, "\t": 48, space: 49, " ": 49,
    delete: 51, backspace: 51, "forward-delete": 117, "forward delete": 117,
    home: 115, end: 119, "page-up": 116, "page up": 116, "page-down": 121, "page down": 121,
    up: 126, down: 125, left: 123, right: 124,
    escape: 53, esc: 53,
    f1: 122, f2: 120, f3: 99, f4: 118, f5: 96, f6: 97, f7: 98, f8: 100,
    f9: 101, f10: 109, f11: 103, f12: 111, f13: 105, f14: 107, f15: 113, f16: 106,
  };
}

const MODIFIER_APPLESCRIPT = {
  command: "command down", cmd: "command down", "⌘": "command down",
  shift: "shift down", "⇧": "shift down",
  option: "option down", alt: "option down", opt: "option down", "⌥": "option down",
  control: "control down", ctrl: "control down", "⌃": "control down",
  fn: "fn down",
};

function modifierScript(modifiers) {
  if (!Array.isArray(modifiers) || modifiers.length === 0) return "";
  const parts = [];
  for (const m of modifiers) {
    const mapped = MODIFIER_APPLESCRIPT[String(m).toLowerCase()];
    if (mapped) parts.push(mapped);
  }
  if (parts.length === 0) return "";
  return ` using {${parts.join(", ")}}`;
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

/**
 * screenshot — capture the main display (or -D display / -R region / -l window).
 * Returns JSON plus a trailing `publish_artifact` line for the M0 timeline
 * preview pipeline (a pure client-side text regex).
 */
function toolScreenshot(workdir, args) {
  const dir = ensureShotsDir(workdir);
  const number = nextShotNumber(dir);
  const fullPath = path.join(dir, `shot-${String(number).padStart(3, "0")}.png`);
  const viewPath = fullPath.replace(/\.png$/, ".view.png");

  const captureArgs = ["-x", "-o"];
  const mode = { kind: "display", display: 1 };
  if (args && args.window_id != null && String(args.window_id) !== "") {
    captureArgs.push("-l", String(args.window_id));
    mode.kind = "window";
    mode.windowID = String(args.window_id);
  } else if (args && args.region && typeof args.region === "object") {
    const r = args.region;
    const x = Math.round(Number(r.x) || 0), y = Math.round(Number(r.y) || 0);
    const w = Math.round(Number(r.w) || 0), h = Math.round(Number(r.h) || 0);
    if (w <= 0 || h <= 0) {
      return errResult("screenshot", "region must be {x, y, w, h} in screen points with w>0 and h>0");
    }
    captureArgs.push("-R", `${x},${y},${w},${h}`);
    mode.kind = "region";
    mode.region = { x, y, w, h };
  } else if (args && args.display != null && String(args.display) !== "") {
    captureArgs.push("-D", String(args.display));
    mode.kind = "display";
    mode.display = Number(args.display);
  }
  captureArgs.push(fullPath);

  const shot = spawnSync("screencapture", captureArgs, { encoding: "utf8", timeout: 20000 });
  const stderrText = (shot.stderr || "").trim();
  if (shot.status !== 0 || !fs.existsSync(fullPath)) {
    const isPermission = /could not create image/i.test(stderrText) || /not authorized/i.test(stderrText);
    return errResult(
      "screenshot",
      isPermission
        ? "截图失败：没有屏幕录制权限。请到 系统设置 → 隐私与安全性 → 屏幕录制 勾选本应用（或列表中出现的进程），然后完全退出并重开 App。"
        : `截图失败：${stderrText || "screencapture 退出码 " + shot.status}`,
      { stderr: stderrText }
    );
  }

  const fullSize = imagePixelSize(fullPath);
  if (!fullSize) {
    return errResult("screenshot", "截图失败：无法读取截图尺寸（sips 不可用或文件损坏）");
  }

  const viewRes = makeViewImage(fullPath, viewPath, viewLongEdge);
  if (!viewRes.ok) {
    return errResult("screenshot", `生成查看图失败：${viewRes.error}`);
  }
  const viewSize = imagePixelSize(viewPath) || fullSize;

  // Geometry: convert to screen points. Full-display captures use Finder
  // desktop bounds; region captures already carry their points rect; window
  // captures use window bounds via System Events (best effort).
  let geometry;
  if (mode.kind === "region") {
    const r = mode.region;
    const scaleX = r.w > 0 ? fullSize.width / r.w : 1;
    const scaleY = r.h > 0 ? fullSize.height / r.h : 1;
    geometry = {
      view_size: [viewSize.width, viewSize.height],
      full_size: [fullSize.width, fullSize.height],
      screen_points: [r.w, r.h],
      scale: Math.round((scaleX + scaleY) / 2 * 100) / 100,
      points_per_view_px: r.w > 0 ? Math.round(r.w / viewSize.width * 10000) / 10000 : 1,
      display_id: mode.display || 1,
      origin: [r.x, r.y],
    };
  } else if (mode.kind === "window") {
    // Best-effort window bounds from System Events; without it the geometry
    // is relative to the window's own top-left corner.
    let bounds = null;
    if (args && args.window_bounds) {
      bounds = args.window_bounds;
    } else if (args && args.app) {
      bounds = windowBounds(args.app, args.window_id);
    }
    const w = bounds ? Math.max(1, Number(bounds.w) || 1) : fullSize.width;
    const h = bounds ? Math.max(1, Number(bounds.h) || 1) : fullSize.height;
    geometry = {
      view_size: [viewSize.width, viewSize.height],
      full_size: [fullSize.width, fullSize.height],
      screen_points: [w, h],
      scale: w > 0 ? Math.round(fullSize.width / w * 100) / 100 : 1,
      points_per_view_px: w > 0 ? Math.round(w / viewSize.width * 10000) / 10000 : 1,
      display_id: mode.display || 1,
      window_id: mode.windowID,
      window_bounds: bounds || null,
    };
  } else {
    const pts = screenPointsForMainDisplay();
    const w = pts ? pts.width : fullSize.width;
    const h = pts ? pts.height : fullSize.height;
    geometry = {
      view_size: [viewSize.width, viewSize.height],
      full_size: [fullSize.width, fullSize.height],
      screen_points: [w, h],
      scale: w > 0 ? Math.round(fullSize.width / w * 100) / 100 : 1,
      points_per_view_px: w > 0 ? Math.round(w / viewSize.width * 10000) / 10000 : 1,
      display_id: mode.display || 1,
    };
  }
  lastGeometry = geometry;

  try { fs.copyFileSync(fullPath, path.join(dir, "latest.png")); } catch (_) { /* ignore */ }
  try { fs.copyFileSync(viewPath, path.join(dir, "latest.view.png")); } catch (_) { /* ignore */ }
  cleanupOldShots(dir, keep);

  const relView = path.relative(workdir, viewPath);
  const relFull = path.relative(workdir, fullPath);
  const result = {
    ok: true,
    action: "screenshot",
    shot: number,
    image_path: relView,
    full_path: relFull,
    abs_path: viewPath,
    geometry,
    hint: `read(image_path, imageMode="detail") to view`,
  };
  const text = JSON.stringify(result, null, 2) + "\npublish_artifact " + relView;
  log(`screenshot kind=${mode.kind} → ${fullSize.width}x${fullSize.height} view=${viewSize.width}x${viewSize.height}`);
  return { ok: true, text };
}

function requireGeometry(action) {
  if (!lastGeometry) {
    return { error: `${action} 需要先截图：先调用 screenshot 建立坐标基准，再对坐标进行换算。` };
  }
  return { geometry: lastGeometry };
}

/**
 * Converts an (x, y) pair in view-image pixels to screen points using the
 * geometry of the most recent screenshot. `space: "screen"` passes through.
 */
function toScreenPoint(action, args) {
  const geoRes = requireGeometry(action);
  if (geoRes.error) return geoRes;
  const geometry = geoRes.geometry;
  const space = args && args.space === "screen" ? "screen" : "view";
  const x = Number(args && args.x);
  const y = Number(args && args.y);
  if (!Number.isFinite(x) || !Number.isFinite(y)) {
    return { error: `${action} 需要数值参数 x 和 y` };
  }
  if (space === "screen") {
    return { geometry, x, y, space };
  }
  const ppp = geometry.points_per_view_px || 1;
  const sx = x * ppp;
  const sy = y * ppp;
  // Region captures have an origin offset.
  const ox = geometry.origin ? geometry.origin[0] : 0;
  const oy = geometry.origin ? geometry.origin[1] : 0;
  return { geometry, x: sx + ox, y: sy + oy, space };
}

function toolClick(workdir, args) {
  const pt = toScreenPoint("click", args);
  if (pt.error) return errResult("click", pt.error);

  const count = Math.max(1, Math.min(5, Number(args && args.count) || 1));
  const button = String((args && args.button) || "left").toLowerCase();
  const useCLIClick = cliclickReady() && button === "left";

  let script;
  if (useCLIClick) {
    const clickCmd = count === 1 ? "c" : count === 2 ? "dc" : count === 3 ? "tc" : "c";
    const r = runCLIClick([`${clickCmd}:${Math.round(pt.x)},${Math.round(pt.y)}`]);
    if (r.status !== 0) {
      return errResult("click", `cliclick 失败：${(r.stderr || r.stdout || "").trim() || "退出码 " + r.status}`);
    }
    log(`click cliclick x=${Math.round(pt.x)} y=${Math.round(pt.y)} count=${count}`);
    return okResult("click", { x: Math.round(pt.x), y: Math.round(pt.y), space: pt.space, count, backend: "cliclick", geometry: pt.geometry });
  }

  if (button !== "left") {
    return errResult("click", `暂不支持 ${button} 键点击（无 cliclick 时 System Events 只能左键；安装 cliclick 后支持右键/中键）`, { hint: "brew install cliclick" });
  }

  const mods = modifierScript(args && args.modifiers);
  if (count === 1) {
    script = `tell application "System Events" to click at {${Math.round(pt.x)}, ${Math.round(pt.y)}}${mods}`;
  } else {
    const lines = [`tell application "System Events"`];
    for (let i = 0; i < count; i++) lines.push(`  click at {${Math.round(pt.x)}, ${Math.round(pt.y)}}${mods}`);
    lines.push("end tell");
    script = lines.join("\n");
  }
  const r = runAppleScript(script);
  const stderrText = (r.stderr || "").trim();
  if (r.status !== 0) {
    if (/not allowed assistive access|-1719/i.test(stderrText)) {
      return errResult(
        "click",
        `点击失败：System Events 报 -1719 not allowed assistive access，请到 系统设置 → 隐私与安全性 → 辅助功能 授权本应用。`,
        { stderr: stderrText }
      );
    }
    return errResult("click", `点击失败：${stderrText || "osascript 退出码 " + r.status}`, { stderr: stderrText });
  }
  log(`click x=${Math.round(pt.x)} y=${Math.round(pt.y)} count=${count} space=${pt.space}`);
  return okResult("click", { x: Math.round(pt.x), y: Math.round(pt.y), space: pt.space, count, backend: "osascript", geometry: pt.geometry });
}

function toolMove(workdir, args) {
  const pt = toScreenPoint("move", args);
  if (pt.error) return errResult("move", pt.error);

  if (cliclickReady()) {
    const r = runCLIClick([`m:${Math.round(pt.x)},${Math.round(pt.y)}`]);
    if (r.status !== 0) {
      return errResult("move", `cliclick 失败：${(r.stderr || r.stdout || "").trim() || "退出码 " + r.status}`);
    }
    log(`move x=${Math.round(pt.x)} y=${Math.round(pt.y)}`);
    return okResult("move", { x: Math.round(pt.x), y: Math.round(pt.y), space: pt.space, backend: "cliclick", geometry: pt.geometry });
  }

  // Degrade: without cliclick, System Events cannot move the cursor without
  // clicking. Click at the target and report degraded so the model knows.
  const r = runAppleScript(`tell application "System Events" to click at {${Math.round(pt.x)}, ${Math.round(pt.y)}}`);
  if (r.status !== 0) {
    return errResult("move", `移动失败：${(r.stderr || "").trim() || "osascript 退出码 " + r.status}（建议安装 cliclick：brew install cliclick）`);
  }
  log(`move degraded=click x=${Math.round(pt.x)} y=${Math.round(pt.y)}`);
  return okResult("move", { x: Math.round(pt.x), y: Math.round(pt.y), space: pt.space, backend: "osascript-click", degraded: true, hint: "无 cliclick，move 已降级为点击（安装 cliclick 后可真正移动指针）", geometry: pt.geometry });
}

function toolDrag(workdir, args) {
  const fromPt = toScreenPoint("drag", args && args.from ? { ...args, ...args.from } : args);
  if (fromPt.error) return errResult("drag", `from: ${fromPt.error}`);
  const toPt = toScreenPoint("drag", args && args.to ? { ...args, ...args.to } : args);
  if (toPt.error) return errResult("drag", `to: ${toPt.error}`);

  if (cliclickReady()) {
    const r = runCLIClick([`dd:${Math.round(fromPt.x)},${Math.round(fromPt.y)}`, `du:${Math.round(toPt.x)},${Math.round(toPt.y)}`]);
    if (r.status !== 0) {
      return errResult("drag", `cliclick 失败：${(r.stderr || r.stdout || "").trim() || "退出码 " + r.status}`);
    }
    log(`drag ${Math.round(fromPt.x)},${Math.round(fromPt.y)} → ${Math.round(toPt.x)},${Math.round(toPt.y)}`);
    return okResult("drag", { from: { x: Math.round(fromPt.x), y: Math.round(fromPt.y) }, to: { x: Math.round(toPt.x), y: Math.round(toPt.y) }, backend: "cliclick", geometry: fromPt.geometry });
  }

  return errResult(
    "drag",
    "拖拽需要 cliclick（brew install cliclick）。当前未安装，无法可靠合成鼠标按下/移动/抬起序列。",
    { hint: "brew install cliclick" }
  );
}

function toolTypeText(workdir, args) {
  const text = String((args && args.text) ?? "");
  if (text.length === 0) return errResult("type_text", "text 不能为空");
  const method = String((args && args.method) || "auto").toLowerCase();
  const hasNonAscii = /[^\x20-\x7E]/.test(text);
  const useClipboard = method === "clipboard" || (method === "auto" && hasNonAscii);

  if (useClipboard) {
    const pb = spawnSync("pbcopy", [], { input: text, encoding: "utf8", timeout: 10000 });
    if (pb.status !== 0) {
      return errResult("type_text", `pbcopy 失败：${(pb.stderr || "").trim() || "退出码 " + pb.status}`);
    }
    const r = runAppleScript('tell application "System Events" to keystroke "v" using command down');
    if (r.status !== 0) {
      const stderrText = (r.stderr || "").trim();
      if (/not allowed assistive access|-1719/i.test(stderrText)) {
        return errResult("type_text", `粘贴失败：System Events 报 -1719 not allowed assistive access，请到 系统设置 → 隐私与安全性 → 辅助功能 授权本应用。`, { stderr: stderrText });
      }
      return errResult("type_text", `粘贴失败：${stderrText || "osascript 退出码 " + r.status}`);
    }
    log(`type_text method=clipboard chars=${text.length}`);
    return okResult("type_text", { method: "clipboard", chars: text.length, hint: "非 ASCII 文本经剪贴板 + ⌘V 输入，避开输入法拦截" });
  }

  // keystroke path — split on newlines so multi-line text presses Return.
  const lines = text.split("\n");
  const scriptParts = ["tell application \"System Events\""];
  for (const line of lines) {
    if (line.length > 0) {
      scriptParts.push(`  keystroke "${appleScriptEscape(line)}"`);
    }
    scriptParts.push(`  key code 36`); // return
  }
  scriptParts.push("end tell");
  const r = runAppleScript(scriptParts.join("\n"));
  if (r.status !== 0) {
    const stderrText = (r.stderr || "").trim();
    if (/not allowed assistive access|-1719/i.test(stderrText)) {
      return errResult("type_text", `键入失败：System Events 报 -1719 not allowed assistive access，请到 系统设置 → 隐私与安全性 → 辅助功能 授权本应用。`, { stderr: stderrText });
    }
    return errResult("type_text", `键入失败：${stderrText || "osascript 退出码 " + r.status}`);
  }
  log(`type_text method=keystroke chars=${text.length}`);
  return okResult("type_text", { method: "keystroke", chars: text.length });
}

function toolKey(workdir, args) {
  const key = String((args && args.key) ?? "");
  let code = Number(args && args.code);
  if (!Number.isFinite(code)) {
    const table = keyCodeTable();
    const normalized = key.toLowerCase().trim();
    if (table[normalized] == null) {
      return errResult("key", `未知按键 "${key}"。支持：${Object.keys(table).slice(0, 24).join(", ")}… 或传 code（key code 数字）`);
    }
    code = table[normalized];
  }
  const mods = modifierScript(args && args.modifiers);
  const r = runAppleScript(`tell application "System Events" to key code ${code}${mods}`);
  if (r.status !== 0) {
    const stderrText = (r.stderr || "").trim();
    if (/not allowed assistive access|-1719/i.test(stderrText)) {
      return errResult("key", `按键失败：System Events 报 -1719 not allowed assistive access，请到 系统设置 → 隐私与安全性 → 辅助功能 授权本应用。`, { stderr: stderrText });
    }
    return errResult("key", `按键失败：${stderrText || "osascript 退出码 " + r.status}`);
  }
  log(`key code=${code} mods=${(args && args.modifiers) || ""}`);
  return okResult("key", { key: key || code, code });
}

function toolActivate(workdir, args) {
  const app = String((args && args.app) ?? "").trim();
  if (!app) return errResult("activate", "app 不能为空（应用名称或 bundle id）");
  const isBundleID = app.includes(".") && !app.includes(" ");
  const script = isBundleID
    ? `tell application id "${appleScriptEscape(app)}" to activate`
    : `tell application "${appleScriptEscape(app)}" to activate`;
  const r = runAppleScript(script);
  if (r.status !== 0) {
    const stderrText = (r.stderr || "").trim();
    return errResult("activate", `激活 ${app} 失败：${stderrText || "osascript 退出码 " + r.status}`, { stderr: stderrText });
  }
  log(`activate ${app}`);
  return okResult("activate", { app });
}

function toolApps(workdir, args) {
  const r = runAppleScript('tell application "System Events" to get name of every process whose background only is false', 20000);
  if (r.status !== 0) {
    return errResult("apps", `获取应用列表失败：${(r.stderr || "").trim() || "osascript 退出码 " + r.status}`);
  }
  const raw = (r.stdout || "").trim();
  const names = raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  log(`apps count=${names.length}`);
  return okResult("apps", { apps: names });
}

function windowBounds(app, windowID) {
  const target = app ? `process "${appleScriptEscape(String(app))}"` : "process 1";
  const script = `tell application "System Events" to tell ${target} to get {position, size} of window ${windowID || 1}`;
  const r = runAppleScript(script, 10000);
  if (r.status !== 0) return null;
  const nums = (r.stdout || "").match(/-?\d+/g);
  if (!nums || nums.length < 4) return null;
  return { x: parseInt(nums[0], 10), y: parseInt(nums[1], 10), w: parseInt(nums[2], 10), h: parseInt(nums[3], 10) };
}

function toolWindows(workdir, args) {
  const app = String((args && args.app) ?? "").trim();
  const limit = Math.max(1, Math.min(50, Number(args && args.limit) || 20));
  let script;
  if (app) {
    script = `tell application "System Events" to tell process "${appleScriptEscape(app)}" to get {name, position, size} of every window`;
  } else {
    script = `tell application "System Events" to tell (first process whose frontmost is true) to get {name, position, size} of every window`;
  }
  const r = runAppleScript(script, 20000);
  if (r.status !== 0) {
    return errResult("windows", `获取窗口列表失败：${(r.stderr || "").trim() || "osascript 退出码 " + r.status}`, { stderr: (r.stderr || "").trim() });
  }
  // AppleScript returns interleaved lists: name1, pos1, size1, name2, pos2…
  const raw = (r.stdout || "").trim();
  const tokens = raw.split(",").map((s) => s.trim());
  const windows = [];
  // AppleScript prints nested lists as e.g. "name, {x, y}, {w, h}, name2, …"
  // Parse by scanning tokens: a bare string is a name, "{x, y}" is a position,
  // "{w, h}" is a size. Group them in order.
  let i = 0;
  let pending = null;
  while (i < tokens.length && windows.length < limit) {
    const t = tokens[i];
    const listMatch = /^\{\s*(-?\d+),\s*(-?\d+)\s*\}$/.exec(t);
    if (listMatch) {
      const pair = { x: parseInt(listMatch[1], 10), y: parseInt(listMatch[2], 10) };
      if (pending && !pending.position) pending.position = pair;
      else if (pending && !pending.size) { pending.size = pair; windows.push(pending); pending = null; }
      else pending = { position: pair };
    } else if (t.startsWith("{") || t.endsWith("}")) {
      // multi-token list; skip to closing brace
      let depth = (t.match(/\{/g) || []).length - (t.match(/\}/g) || []).length;
      let j = i;
      while (depth > 0 && j + 1 < tokens.length) {
        j++;
        depth += (tokens[j].match(/\{/g) || []).length - (tokens[j].match(/\}/g) || []).length;
      }
      i = j;
    } else if (t !== "") {
      if (pending && pending.name != null && pending.position && !pending.size) {
        // missing size; keep going
      }
      if (!pending || (pending.name == null)) {
        pending = { name: t };
      } else if (pending && !pending.position) {
        pending = { name: t };
      }
    }
    i++;
  }
  if (pending && pending.name != null && pending.position && !pending.size) {
    windows.push({ ...pending, size: null });
  }
  log(`windows count=${windows.length}`);
  return okResult("windows", { windows: windows.slice(0, limit) });
}

/**
 * ax — best-effort accessibility tree dump. Uses a recursive System Events
 * walk with depth/limit guards because `entire contents` is extremely slow and
 * unbounded on complex apps.
 */
function toolAX(workdir, args) {
  const app = String((args && args.app) ?? "").trim();
  const depth = Math.max(1, Math.min(6, Number(args && args.depth) || 3));
  const limit = Math.max(1, Math.min(500, Number(args && args.limit) || 200));
  const windowID = Number(args && args.window) || 1;

  const script = `
on axLine(el, depth)
  try
    set r to role of el
  on error
    set r to ""
  end try
  try
    set t to title of el
    if t is missing value then set t to ""
  on error
    set t to ""
  end try
  try
    set d to description of el
    if d is missing value then set d to ""
  on error
    set d to ""
  end try
  try
    set {px, py} to position of el
  on error
    set px to -1
    set py to -1
  end try
  try
    set {sx, sy} to size of el
  on error
    set sx to -1
    set sy to -1
  end try
  return r & "|" & t & "|" & d & "|" & px & "," & py & "," & sx & "x" & sy
end axLine

on axWalk(el, remaining, counter, acc)
  if remaining ≤ 0 or counter ≥ ${limit} then return acc
  set acc to acc & (my axLine(el, remaining)) & linefeed
  set counter to counter + 1
  if remaining > 1 then
    try
      set subs to UI elements of el
      repeat with s in subs
        set acc to my axWalk(s, remaining - 1, counter, acc)
      end repeat
    on error
    end try
  end if
  return acc
end axWalk

on run
  tell application "System Events"
    tell process "${appleScriptEscape(app)}"
      set targetWindow to window ${windowID}
      set out to my axWalk(targetWindow, ${depth}, 0, "")
      return out
    end tell
  end tell
end run
`;
  const r = spawnSync("osascript", [], { input: script, encoding: "utf8", timeout: 25000 });
  if (r.status !== 0) {
    const stderrText = (r.stderr || "").trim();
    if (/not allowed assistive access|-1719/i.test(stderrText)) {
      return errResult("ax", `读取辅助功能树失败：System Events 报 -1719 not allowed assistive access，请到 系统设置 → 隐私与安全性 → 辅助功能 授权本应用。`, { stderr: stderrText });
    }
    if (r.error && r.error.code === "ETIMEDOUT") {
      return errResult("ax", `读取辅助功能树超时（25s），请降低 depth/limit 或改用 windows/screenshot。`);
    }
    return errResult("ax", `读取辅助功能树失败：${stderrText || "osascript 退出码 " + r.status}`, { stderr: stderrText });
  }
  const lines = (r.stdout || "").split("\n").filter((l) => l.includes("|")).slice(0, limit);
  log(`ax app=${app} lines=${lines.length} depth=${depth}`);
  return okResult("ax", { app, depth, nodes: lines });
}

// ---------------------------------------------------------------------------
// Result helpers
// ---------------------------------------------------------------------------

function okResult(action, extra) {
  const result = { ok: true, action, ...extra };
  return { ok: true, text: JSON.stringify(result, null, 2) };
}

function errResult(action, message, extra) {
  const result = { ok: false, action, error: message, ...extra };
  return { ok: false, text: JSON.stringify(result, null, 2), isError: true };
}

// ---------------------------------------------------------------------------
// MCP protocol
// ---------------------------------------------------------------------------

const TOOL_DEFS = [
  {
    name: "screenshot",
    description:
      "捕获屏幕并生成两张 PNG：shot-NNN.png（原始像素）与 shot-NNN.view.png（长边缩放到 view 尺寸）。" +
      "返回的 image_path 用内置 read 工具查看（imageMode=\"detail\"）。坐标以 view 图片像素为单位。" +
      "geometry 含 view_size/full_size/screen_points/scale/points_per_view_px，点击类工具依赖它换算。",
    inputSchema: {
      type: "object",
      properties: {
        display: { type: "integer", description: "显示器编号（screencapture -D），默认主屏" },
        region: { type: "object", description: "区域截图，屏幕 points：{x, y, w, h}", properties: { x: { type: "number" }, y: { type: "number" }, w: { type: "number" }, h: { type: "number" } } },
        window_id: { type: "string", description: "窗口 ID（screencapture -l），需配合 app 传窗口 bounds" },
        app: { type: "string", description: "窗口所属应用名，用于读取窗口 bounds" },
        window_bounds: { type: "object", description: "可选：窗口 bounds {x, y, w, h}（points），用于坐标换算", properties: { x: { type: "number" }, y: { type: "number" }, w: { type: "number" }, h: { type: "number" } } },
        label: { type: "string", description: "本次截图的说明标签（仅用于日志）" },
      },
    },
  },
  {
    name: "click",
    description:
      "点击屏幕。x/y 默认是最近一次 screenshot 的 view 图片像素坐标；space=\"screen\" 时是屏幕 points。支持 count（连击）、button（left/right/middle）、modifiers（command/shift/option/control）。",
    inputSchema: {
      type: "object",
      properties: {
        x: { type: "number" }, y: { type: "number" },
        space: { type: "string", enum: ["view", "screen"], description: "坐标空间，默认 view（最近一次截图的图片像素）" },
        button: { type: "string", enum: ["left", "right", "middle"], default: "left" },
        count: { type: "integer", minimum: 1, maximum: 5, default: 1 },
        modifiers: { type: "array", items: { type: "string" }, description: "如 [\"command\", \"shift\"]" },
      },
      required: ["x", "y"],
    },
  },
  {
    name: "move",
    description: "移动鼠标指针到指定坐标（同 click 的坐标约定）。无 cliclick 时降级为点击并标记 degraded。",
    inputSchema: {
      type: "object",
      properties: { x: { type: "number" }, y: { type: "number" }, space: { type: "string", enum: ["view", "screen"] } },
      required: ["x", "y"],
    },
  },
  {
    name: "drag",
    description: "从 from 拖拽到 to（坐标约定同 click）。需要 cliclick（brew install cliclick）。",
    inputSchema: {
      type: "object",
      properties: {
        from: { type: "object", properties: { x: { type: "number" }, y: { type: "number" }, space: { type: "string" } }, required: ["x", "y"] },
        to: { type: "object", properties: { x: { type: "number" }, y: { type: "number" }, space: { type: "string" } }, required: ["x", "y"] },
      },
      required: ["from", "to"],
    },
  },
  {
    name: "type_text",
    description:
      "向当前聚焦应用键入文本。纯 ASCII 走 keystroke；含非 ASCII（如中文）默认走剪贴板 + ⌘V，避开输入法拦截。method 可强制 keystroke/clipboard。",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string" },
        method: { type: "string", enum: ["auto", "keystroke", "clipboard"], default: "auto" },
      },
      required: ["text"],
    },
  },
  {
    name: "key",
    description: "按下按键。key 为名称（return/escape/tab/space/delete/up/down/left/right/home/end/page-up/page-down/f1-f16 等），或直接传 code（key code）。",
    inputSchema: {
      type: "object",
      properties: {
        key: { type: "string" },
        code: { type: "integer" },
        modifiers: { type: "array", items: { type: "string" } },
      },
    },
  },
  {
    name: "activate",
    description: "激活（前置）一个应用，app 可以是应用名称或 bundle id。",
    inputSchema: {
      type: "object",
      properties: { app: { type: "string" } },
      required: ["app"],
    },
  },
  {
    name: "apps",
    description: "列出前台应用（background only is false）的名称。",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "windows",
    description: "列出前台应用（或指定 app）的窗口 {name, position, size}，坐标为屏幕 points。",
    inputSchema: {
      type: "object",
      properties: {
        app: { type: "string", description: "应用名；缺省用当前前台应用" },
        limit: { type: "integer", minimum: 1, maximum: 50, default: 20 },
      },
    },
  },
  {
    name: "ax",
    description:
      "读取指定应用窗口的辅助功能（AX）树文本（role|title|description|position,size 每行一个节点）。" +
      "可能很慢（AppleScript + System Events），默认 depth=3、limit=200；请优先用 screenshot+click。",
    inputSchema: {
      type: "object",
      properties: {
        app: { type: "string", description: "应用名（必须，如 \"Safari\"）" },
        depth: { type: "integer", minimum: 1, maximum: 6, default: 3 },
        limit: { type: "integer", minimum: 1, maximum: 500, default: 200 },
        window: { type: "integer", default: 1 },
      },
      required: ["app"],
    },
  },
];

function handleToolsCall(workdir, params, args) {
  const name = params && params.name;
  const toolArgs = (params && params.arguments) || {};
  switch (name) {
    case "screenshot": return toolScreenshot(workdir, toolArgs);
    case "click": return toolClick(workdir, toolArgs);
    case "move": return toolMove(workdir, toolArgs);
    case "drag": return toolDrag(workdir, toolArgs);
    case "type_text": return toolTypeText(workdir, toolArgs);
    case "key": return toolKey(workdir, toolArgs);
    case "activate": return toolActivate(workdir, toolArgs);
    case "apps": return toolApps(workdir, toolArgs);
    case "windows": return toolWindows(workdir, toolArgs);
    case "ax": return toolAX(workdir, toolArgs);
    default:
      return { ok: false, isError: true, text: JSON.stringify({ ok: false, action: name, error: `未知工具 ${name}` }, null, 2) };
  }
}

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function handleRequest(workdir, args, line) {
  let req;
  try {
    req = JSON.parse(line);
  } catch (_) {
    return; // ignore non-JSON lines
  }
  if (!req || req.jsonrpc !== "2.0" || !req.method) return;

  const hasID = req.id !== undefined && req.id !== null;
  const respond = (result) => { if (hasID) send({ jsonrpc: "2.0", id: req.id, result }); };
  const respondError = (code, message) => { if (hasID) send({ jsonrpc: "2.0", id: req.id, error: { code, message } }); };

  switch (req.method) {
    case "initialize":
      respond({
        protocolVersion: "2025-11-25",
        capabilities: { tools: {} },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      });
      break;
    case "notifications/initialized":
    case "notifications/cancelled":
      break; // no response
    case "ping":
      respond({});
      break;
    case "tools/list":
      respond({ tools: TOOL_DEFS });
      break;
    case "tools/call": {
      const params = req.params || {};
      const res = handleToolsCall(workdir, params, args);
      respond({ content: [{ type: "text", text: res.text }], isError: !!res.isError });
      break;
    }
    case "resources/list":
      respond({ resources: [] });
      break;
    case "prompts/list":
      respond({ prompts: [] });
      break;
    default:
      respondError(-32601, `Method not found: ${req.method}`);
  }
}

// ---------------------------------------------------------------------------
// Self-test
// ---------------------------------------------------------------------------

function runSelfTest(args) {
  const tmpBase = args.workdir || "/tmp/mothx-cu-selftest";
  const workdir = path.resolve(tmpBase);
  fs.mkdirSync(workdir, { recursive: true });
  const res = toolScreenshot(workdir, {});
  if (!res.ok) {
    process.stdout.write(res.text + "\n");
    process.exitCode = 1;
    return;
  }
  process.stdout.write(res.text + "\n");
  log("selftest OK");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const args = parseArgs(process.argv.slice(2));
const viewLongEdge = args.viewLongEdge;
const keep = args.keep;

if (args.showVersion) {
  process.stdout.write(`${SERVER_NAME} ${SERVER_VERSION}\n`);
  process.exit(0);
}

if (args.selftest) {
  runSelfTest(args);
  return;
}

const wd = resolveWorkDir(args);
if (wd.error) {
  log("fatal:", wd.error);
  process.stderr.write(`${SERVER_NAME}: ${wd.error}\n`);
  process.exit(1);
}
const workdir = wd.workdir;
log(`server v${SERVER_VERSION} started workdir=${workdir} viewLongEdge=${viewLongEdge} keep=${keep} node=${process.version}`);

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  try {
    handleRequest(workdir, args, trimmed);
  } catch (err) {
    log("handler error:", err && err.message ? err.message : String(err));
  }
});
rl.on("close", () => {
  log("stdin closed, exiting");
  process.exit(0);
});
