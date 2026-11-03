// EdgeGlow: screen-edge glow + Dynamic Island style pill for AI coding agents.
//
//   edgeglow hook <agent>               read an agent's hook JSON on stdin and react
//                                       agents: claude codex gemini qwen kimi grok
//   edgeglow done  [title] [subtitle]   green  - task finished
//   edgeglow input [title] [subtitle]   blue   - needs your input
//   edgeglow warn  [title] [subtitle]   amber  - warning
//   edgeglow alert [title] [subtitle]   red    - critical, stays until clicked
//   edgeglow clear                      dismiss everything
//   --id X        dedupe key: same id replaces the old alert; `clear --id X` removes just that one
//   --agent X     agent name shown in the pill (e.g. opencode)
//   --project X   project name shown in the pill
//
// Only local processes can trigger it; there is no network listener.
// Run with no arguments to start the overlay app.
import Cocoa
import SwiftUI

let eventName = Notification.Name("io.github.emre-diricanli.edgeglow.event")
let cmuxBin = "/Applications/cmux.app/Contents/Resources/bin/cmux"
let validKinds: Set<String> = ["done", "input", "warn", "alert", "clear"]

// MARK: - Helpers

func runCapture(_ path: String, _ args: [String], timeout: Double = 1.5) -> String? {
    guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["CMUX_QUIET"] = "1"
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(10_000) }
    if p.isRunning { p.terminate(); return nil }
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

/// First meaningful line of a markdown reply, trimmed for the pill.
func oneLine(_ s: String, max: Int = 120) -> String {
    let line = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    var t = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    while let c = t.first, "#->* ".contains(c) { t.removeFirst() }
    return t.count > max ? String(t.prefix(max - 1)) + "…" : t
}

/// Last assistant text block from a Claude Code transcript (reads only the tail).
func lastAssistantText(_ path: String) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    try? fh.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
    guard let data = try? fh.readToEnd() else { return nil }
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
        guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              j["type"] as? String == "assistant",
              let msg = j["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]] else { continue }
        for c in content.reversed() where c["type"] as? String == "text" {
            if let t = c["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        }
    }
    return nil
}

func cmuxWorkspaceTitle(_ uuid: String) -> String? {
    guard let out = runCapture(cmuxBin, ["workspace", "list", "--id-format", "both"], timeout: 0.8) else { return nil }
    for line in out.split(separator: "\n") where line.contains(uuid) {
        guard let r = line.range(of: uuid) else { continue }
        var t = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("[selected]") { t = String(t.dropLast(10)).trimmingCharacters(in: .whitespaces) }
        return t.isEmpty ? nil : t
    }
    return nil
}

// MARK: - Agent adapters

let agentNames = ["claude": "Claude", "codex": "Codex", "gemini": "Gemini", "qwen": "Qwen",
                  "kimi": "Kimi", "grok": "Grok", "opencode": "OpenCode"]

/// "UserPromptSubmit", "user_prompt_submit" -> "userpromptsubmit"
func norm(_ s: String?) -> String { (s ?? "").lowercased().replacingOccurrences(of: "_", with: "") }

func str(_ j: [String: Any], _ keys: String...) -> String? {
    for k in keys { if let v = j[k] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v } }
    return nil
}

/// Turns one agent's hook payload into (kind, subtitle). nil = ignore this event.
func adapt(_ agent: String, _ j: [String: Any]) -> (kind: String, subtitle: String?)? {
    let event = norm(str(j, "hook_event_name", "hookEventName"))
    let ntype = norm(str(j, "notification_type", "notificationType"))
    let message = str(j, "message")
    let summary = str(j, "last_assistant_message", "lastAssistantMessage", "prompt_response").map { oneLine($0) }
    let tool = j["tool_input"] as? [String: Any] ?? [:]
    let snake = j["hook_event_name"] is String && j["hookEventName"] == nil

    switch agent {
    case "claude":
        // Grok and Kimi can end up calling Claude's hooks; only accept Claude's own payload shape.
        guard snake, j["client_type"] == nil else { return nil }
        switch event {
        case "stop":
            return ("done", summary ?? str(j, "transcript_path").flatMap(lastAssistantText).map { oneLine($0) })
        case "notification":
            // skip the "still waiting" nudge after a finished turn, and auth/info notices
            guard ["", "permissionprompt", "elicitationdialog"].contains(ntype),
                  !(message ?? "").lowercased().contains("waiting for your input") else { return nil }
            return ("input", message)
        case "userpromptsubmit", "posttooluse": return ("clear", nil)
        default: return nil
        }
    case "qwen":
        guard snake else { return nil }
        switch event {
        case "stop": return ("done", summary)
        case "notification": return ntype == "permissionprompt" ? ("input", message) : nil
        case "userpromptsubmit", "posttooluse": return ("clear", nil)
        default: return nil
        }
    case "gemini":
        guard snake else { return nil }
        switch event {
        case "afteragent": return ("done", summary)
        case "notification": return ("input", message)
        case "beforeagent", "aftertool": return ("clear", nil)
        default: return nil
        }
    case "codex":
        guard snake else { return nil }
        switch event {
        case "stop": return ("done", summary)
        case "permissionrequest":
            return ("input", (tool["description"] as? String) ?? (tool["command"] as? String).map { "Run: \($0)" } ?? "Approval needed")
        case "userpromptsubmit", "posttooluse", "interrupt", "sessionend": return ("clear", nil)
        default: return nil
        }
    case "kimi":
        guard snake else { return nil }
        switch event {
        case "stop": return ("done", nil)
        case "permissionrequest": return ("input", str(j, "action") ?? str(j, "tool_name").map { "Approve \($0)" })
        case "pretooluse":
            guard str(j, "tool_name") == "AskUserQuestion" else { return nil }
            let q = (tool["questions"] as? [[String: Any]])?.first?["question"] as? String
            return ("input", q ?? "Kimi has a question")
        case "userpromptsubmit", "posttooluse": return ("clear", nil)
        default: return nil
        }
    case "grok":
        guard j["hookEventName"] != nil else { return nil }
        switch event {
        case "stop": return norm(str(j, "reason")) == "endturn" ? ("done", summary) : nil
        case "notification":
            return ["permissionprompt", "elicitationdialog"].contains(ntype) ? ("input", message) : nil
        case "userpromptsubmit", "posttooluse": return ("clear", nil)
        default: return nil
        }
    default:
        return nil
    }
}

// MARK: - CLI mode

let cliArgs = Array(CommandLine.arguments.dropFirst())
if let cmd = cliArgs.first, validKinds.contains(cmd) || cmd == "hook" {
    var info: [String: String] = [:]
    var positional: [String] = []
    var i = 1
    while i < cliArgs.count {
        let a = cliArgs[i]
        let next = i + 1 < cliArgs.count ? cliArgs[i + 1] : nil
        switch a {
        case "--id": info["id"] = next; i += 2; continue
        case "--agent": info["agent"] = next.map { agentNames[$0.lowercased()] ?? $0 }; i += 2; continue
        case "--project": info["project"] = next; i += 2; continue
        case "--hook": break                     // legacy: `<kind> --hook` == `hook claude`
        default: positional.append(a)
        }
        i += 1
    }

    if cmd == "hook" || cliArgs.contains("--hook") {
        let agent = cmd == "hook" ? (positional.first ?? "claude").lowercased() : "claude"
        // most agents send JSON on stdin; Codex's legacy notify passes it as the last argument
        var data = FileHandle.standardInput.readDataToEndOfFile()
        if data.isEmpty, let last = cliArgs.last, last.hasPrefix("{") { data = Data(last.utf8) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let (kind, subtitle) = adapt(agent, json) else { exit(0) }
        info["kind"] = kind
        info["agent"] = agentNames[agent] ?? agent
        if let sid = str(json, "session_id", "sessionId") { info["id"] = "\(agent):\(sid)" }
        if let cwd = str(json, "cwd") { info["project"] = (cwd as NSString).lastPathComponent }
        if let subtitle { info["subtitle"] = subtitle }
    } else {
        info["kind"] = cmd
        if positional.count > 0, !positional[0].isEmpty { info["title"] = positional[0] }
        if positional.count > 1, !positional[1].isEmpty { info["subtitle"] = positional[1] }
        if let id = info["id"], let agent = info["agent"] { info["id"] = "\(agent.lowercased()):\(id)" }
    }

    let env = ProcessInfo.processInfo.environment
    if info["kind"] != "clear", let ws = env["CMUX_WORKSPACE_ID"] {
        info["workspace"] = ws
        if let s = env["CMUX_SURFACE_ID"] { info["surface"] = s }
        if let t = cmuxWorkspaceTitle(ws) { info["place"] = t }
    }
    DistributedNotificationCenter.default().postNotificationName(
        eventName, object: nil, userInfo: info, deliverImmediately: true)
    exit(0)
}

// MARK: - Model

enum Kind: String {
    case done, input, warn, alert
    var priority: Int { [.done: 0, .warn: 1, .input: 2, .alert: 3][self]! }
    var color: Color {
        switch self {
        case .done:  return Color(red: 0.20, green: 0.95, blue: 0.45)
        case .input: return Color(red: 0.25, green: 0.60, blue: 1.00)
        case .warn:  return Color(red: 1.00, green: 0.72, blue: 0.15)
        case .alert: return Color(red: 1.00, green: 0.23, blue: 0.23)
        }
    }
    var icon: String {
        switch self {
        case .done: return "checkmark"
        case .input: return "hand.raised.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .alert: return "flame.fill"
        }
    }
    var label: String {
        switch self {
        case .done: return "Done"
        case .input: return "Needs you"
        case .warn: return "Warning"
        case .alert: return "Alert"
        }
    }
    var lifetime: Double {
        switch self {
        case .done: return 6
        case .input: return 15 * 60
        case .warn: return 3 * 60
        case .alert: return 60 * 60
        }
    }
}

struct Item: Identifiable {
    let id = UUID()
    let key: String
    let kind: Kind
    let title: String
    let subtitle: String
    let workspace: String?
    let surface: String?
    let created = Date()
    let expires: Date
}

final class GlowState: ObservableObject {
    @Published var items: [Item] = []
    @Published var expanded = false
    var top: Item? {
        items.max { ($0.kind.priority, $0.created) < ($1.kind.priority, $1.created) }
    }
}

// MARK: - Edge glow

struct GlowRing: View {
    let color: Color
    let corner: CGFloat
    let dim: Bool
    let fast: Bool
    @State private var bright = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner).stroke(color, lineWidth: 46).blur(radius: 34)
            RoundedRectangle(cornerRadius: corner).stroke(color.opacity(0.85), lineWidth: 10).blur(radius: 8)
            RoundedRectangle(cornerRadius: corner).stroke(Color.white.opacity(0.35), lineWidth: 2).blur(radius: 1.5)
        }
        .opacity(bright ? (dim ? 0.42 : 1.0) : (dim ? 0.16 : 0.5))
        .animation(.easeInOut(duration: 0.6), value: dim)
        .onAppear {
            withAnimation(.easeInOut(duration: fast ? 0.55 : 1.0).repeatForever(autoreverses: true)) { bright = false }
        }
    }
}

struct EdgeGlowView: View {
    @ObservedObject var s: GlowState
    let corner: CGFloat

    var body: some View {
        ZStack {
            if let top = s.top {
                GlowRing(color: top.kind.color, corner: corner,
                         dim: !s.expanded && top.kind != .done && top.kind != .alert,
                         fast: top.kind == .alert)
                    .id(top.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: s.top?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

// MARK: - Island

struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        let t = min(topRadius, r.height / 2), b = min(bottomRadius, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + t), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.maxX - b, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - b), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct PulseDot: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .scaleEffect(on ? 1.6 : 1).opacity(on ? 0.4 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true } }
    }
}

struct CountBadge: View {
    let n: Int
    let color: Color
    var body: some View {
        Text("+\(n)").font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}

struct IslandView: View {
    @ObservedObject var s: GlowState
    let notch: CGSize?          // nil = no notch: float a capsule below the top edge
    let onTap: () -> Void

    var body: some View {
        let top = s.top
        let extra = max(0, s.items.count - 1)
        let mode = top == nil ? 0 : (s.expanded ? 2 : 1)   // 0 hidden, 1 compact, 2 expanded
        let nh = notch?.height ?? 0
        let size: CGSize = {
            switch mode {
            case 2: return CGSize(width: 400, height: nh + 66)
            case 1: return notch.map { CGSize(width: $0.width + 84, height: $0.height) } ?? CGSize(width: 230, height: 30)
            default: return notch ?? CGSize(width: 120, height: 30)
            }
        }()
        let color = top?.kind.color ?? .clear
        let floating = notch == nil

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                IslandShape(topRadius: floating ? size.height / 2 : 0,
                            bottomRadius: floating ? size.height / 2 : (mode == 2 ? 28 : 12))
                    .fill(Color.black)
                    .shadow(color: color.opacity(mode == 2 ? 0.55 : 0), radius: 18, y: 4)

                if let top, mode == 2 {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(color.opacity(0.22)).frame(width: 38, height: 38)
                            Image(systemName: top.kind.icon).font(.system(size: 17, weight: .bold)).foregroundStyle(color)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(top.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                            if !top.subtitle.isEmpty {
                                Text(top.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.68))
                                    .lineLimit(2).truncationMode(.tail)
                            }
                        }
                        Spacer(minLength: 0)
                        if extra > 0 { CountBadge(n: extra, color: color) } else { PulseDot(color: color) }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 66)
                    .padding(.top, nh)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
                } else if let top, mode == 1 {
                    HStack(spacing: 8) {
                        Image(systemName: top.kind.icon).font(.system(size: 12, weight: .bold)).foregroundStyle(color)
                        if floating {
                            Text(top.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if extra > 0 { CountBadge(n: extra, color: color) } else { PulseDot(color: color) }
                    }
                    .padding(.horizontal, floating ? 12 : 14)
                    .frame(height: size.height)
                    .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .opacity(floating && mode == 0 ? 0 : 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .padding(.top, floating ? 8 : 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.74), value: mode)
        .animation(.spring(response: 0.42, dampingFraction: 0.74), value: top?.id)
    }
}

// MARK: - App

final class OverlayWindow: NSWindow {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = GlowState()
    var edgeWindows: [OverlayWindow] = []
    var islandWindows: [OverlayWindow] = []
    var collapseWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onEvent(_:)), name: eventName, object: nil,
            suspensionBehavior: .deliverImmediately)
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        rebuild()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.prune() }
    }

    @objc func rebuild() {
        (edgeWindows + islandWindows).forEach { $0.orderOut(nil) }
        edgeWindows = []; islandWindows = []
        for screen in NSScreen.screens {
            let f = screen.frame
            var notch: CGSize? = nil
            if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
                notch = CGSize(width: f.width - l.width - r.width, height: screen.safeAreaInsets.top)
            }
            let edge = OverlayWindow(frame: f)
            edge.contentView = NSHostingView(rootView: EdgeGlowView(s: state, corner: notch != nil ? 12 : 0))
            edge.orderFrontRegardless()
            edgeWindows.append(edge)

            let iw: CGFloat = 480, ih: CGFloat = 160
            let island = OverlayWindow(frame: NSRect(x: f.midX - iw / 2, y: f.maxY - ih, width: iw, height: ih))
            island.contentView = NSHostingView(rootView: IslandView(s: state, notch: notch) { [weak self] in self?.tapped() })
            island.orderFrontRegardless()
            islandWindows.append(island)
        }
        syncMouse()
    }

    @objc func onEvent(_ n: Notification) {
        let info = n.userInfo as? [String: String] ?? [:]
        DispatchQueue.main.async { self.handle(info) }
    }

    func handle(_ info: [String: String]) {
        let kindStr = info["kind"] ?? "done"
        if kindStr == "clear" {
            if let key = info["id"] { state.items.removeAll { $0.key == key } } else { state.items.removeAll() }
            afterChange(); return
        }
        guard let kind = Kind(rawValue: kindStr) else { return }
        let key = info["id"] ?? UUID().uuidString
        let place = info["place"] ?? info["project"]
        let parts = [kind.label] + [info["agent"], place].compactMap { $0 }
        let title = info["title"] ?? parts.joined(separator: " · ")
        let subtitle = info["subtitle"] ?? (kind == .done ? "All finished" : kind == .input ? "Waiting on you" : "")

        state.items.removeAll { $0.key == key }
        state.items.append(Item(key: key, kind: kind, title: title, subtitle: subtitle,
                                workspace: info["workspace"], surface: info["surface"],
                                expires: Date().addingTimeInterval(kind.lifetime)))
        expand()
    }

    func expand() {
        state.expanded = true
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.state.expanded = false }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: w)
        syncMouse()
    }

    func tapped() {
        guard let top = state.top else { return }
        if !state.expanded { expand(); return }
        state.items.removeAll { $0.id == top.id }
        if let ws = top.workspace { focus(workspace: ws, surface: top.surface) }
        if state.items.isEmpty { state.expanded = false } else { expand() }
        afterChange()
    }

    func focus(workspace: String, surface: String?) {
        DispatchQueue.global().async {
            _ = runCapture(cmuxBin, ["select-workspace", "--workspace", workspace])
            if let s = surface { _ = runCapture(cmuxBin, ["focus-panel", "--panel", s, "--workspace", workspace]) }
            DispatchQueue.main.async {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.cmuxterm.app").first?.activate()
            }
        }
    }

    func prune() {
        let now = Date()
        if state.items.contains(where: { $0.expires < now }) {
            state.items.removeAll { $0.expires < now }
            afterChange()
        }
    }

    func afterChange() {
        if state.items.isEmpty { state.expanded = false; collapseWork?.cancel() }
        syncMouse()
    }

    func syncMouse() {
        let clickable = !state.items.isEmpty
        islandWindows.forEach { $0.ignoresMouseEvents = !clickable }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
