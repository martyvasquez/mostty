import AppKit
import IOKit.pwr_mgt
import SwiftUI

extension Notification.Name {
    /// mostty: Posted (object: Ghostty.SurfaceView) when a program in a surface
    /// requests a desktop notification via OSC 9 / OSC 777. userInfo has
    /// "title" and "body" strings.
    static let mosttyDesktopNotification = Notification.Name("com.mostty.desktopNotification")
}

/// mostty: Turns terminal desktop notifications (e.g. from the Claude Code
/// `Stop` hook) into a sound, an attention dot on the workspace + tab, and a
/// small toast in the window.
@MainActor
final class WorkspaceNotifier: ObservableObject {
    static let shared = WorkspaceNotifier()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let body: String
        let location: String
        weak var surface: Ghostty.SurfaceView?

        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    @Published private(set) var toast: Toast?
    private var dismissWork: DispatchWorkItem?

    /// What a coding agent (Claude Code) in a terminal is doing, as reported
    /// by its hooks. Terminals with no agent have no entry.
    enum AgentState: Equatable {
        case working
        case waiting
    }

    private struct AgentEntry {
        weak var surface: Ghostty.SurfaceView?
        var state: AgentState
        /// Last time a hook refreshed this state.
        var updated: Date
        /// When the current stretch of "working" began.
        var since: Date
    }

    private struct MessageEntry {
        weak var surface: Ghostty.SurfaceView?
        var text: String
        var date: Date
    }

    /// A Claude Code session running in a terminal, kept so it can be resumed
    /// after mostty restarts. Saved with the window restoration state.
    struct ClaudeSession: Codable, Equatable {
        let id: String
        let cwd: String
    }

    private var agents: [ObjectIdentifier: AgentEntry] = [:]
    private var messages: [ObjectIdentifier: MessageEntry] = [:]

    /// Open Claude sessions keyed by surface id (stable across restarts).
    private var sessions: [UUID: ClaudeSession] = [:]

    /// Set once the app is quitting. Claude sessions that end because mostty
    /// is quitting must stay recorded so they can be resumed on next launch.
    var isTerminating = false

    /// A "working" state that hasn't been refreshed by any hook in this long
    /// is dropped. Covers interrupts from Remote Control (Claude Code has no
    /// hook for interrupts). Local interrupts (Esc / ⌃C) clear immediately.
    private let workingTimeout: TimeInterval = 15 * 60

    /// Sound name from /System/Library/Sounds (or ~/Library/Sounds), or "none".
    /// Change with: defaults write com.mostty.app MosttyNotificationSound Ping
    private var soundName: String {
        UserDefaults.standard.string(forKey: "MosttyNotificationSound") ?? "Glass"
    }

    /// Resume Claude sessions after restart (default on).
    /// Disable with: defaults write com.mostty.app MosttyResumeClaude -bool false
    private var resumeEnabled: Bool {
        UserDefaults.standard.object(forKey: "MosttyResumeClaude") as? Bool ?? true
    }

    private init() {
        NotificationCenter.default.addObserver(
            forName: .mosttyDesktopNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let surface = notification.object as? Ghostty.SurfaceView else { return }
            let title = notification.userInfo?["title"] as? String ?? ""
            let body = notification.userInfo?["body"] as? String ?? ""
            MainActor.assumeIsolated {
                WorkspaceNotifier.shared.handle(surface: surface, title: title, body: body)
            }
        }
    }

    /// Call once at launch to start listening.
    func start() {}

    // MARK: Agent state

    /// Handles a `mostty` control message from the hook script. These are
    /// never shown as notifications.
    func handleControl(surface: Ghostty.SurfaceView, body: String) {
        let key = ObjectIdentifier(surface)
        let now = Date()

        if body.hasPrefix("session=") {
            setSession(String(body.dropFirst("session=".count)), for: surface)
            return
        }

        switch body {
        case "state=working":
            let since = agents[key].flatMap { $0.state == .working ? $0.since : nil } ?? now
            agents[key] = .init(surface: surface, state: .working, updated: now, since: since)
        case "state=waiting":
            agents[key] = .init(surface: surface, state: .waiting, updated: now, since: now)
        case "state=idle":
            agents[key] = nil
        default:
            return
        }
        agentStateDidChange(surface)
    }

    /// The user pressed Esc or ⌃C in a terminal: that interrupts Claude Code,
    /// which fires no hook, so clear "working" ourselves.
    func userInterrupted(_ surface: Ghostty.SurfaceView) {
        let key = ObjectIdentifier(surface)
        guard agents[key]?.state == .working else { return }
        agents[key] = nil
        agentStateDidChange(surface)
    }

    func agentState(_ surface: Ghostty.SurfaceView) -> AgentState? {
        let key = ObjectIdentifier(surface)
        guard let entry = agents[key], entry.surface != nil else { return nil }
        if entry.state == .working, Date().timeIntervalSince(entry.updated) > workingTimeout {
            agents[key] = nil
            DispatchQueue.main.async { self.agentStateDidChange(surface) }
            return nil
        }
        return entry.state
    }

    /// When the earliest of these surfaces started working, if any are.
    func workingSince(_ surfaces: [Ghostty.SurfaceView]) -> Date? {
        surfaces
            .compactMap { s -> Date? in
                guard agentState(s) == .working else { return nil }
                return agents[ObjectIdentifier(s)]?.since
            }
            .min()
    }

    /// Number of terminals where Claude is waiting on the user.
    var waitingCount: Int {
        agents.values.filter { $0.surface != nil && $0.state == .waiting }.count
    }

    private func agentStateDidChange(_ surface: Ghostty.SurfaceView) {
        (surface.window?.windowController as? BaseTerminalController)?.mosttyRefreshTitle()
        (NSApp.delegate as? AppDelegate)?.syncDockBadge()
        syncPowerAssertion()
        WorkspaceManager.shared.refresh()
    }

    // MARK: Keep awake

    private var powerAssertion: IOPMAssertionID = 0

    /// While any Claude session is working, prevent idle system sleep so the
    /// work (and Remote Control) isn't interrupted. The display may still sleep.
    func syncPowerAssertion() {
        let anyWorking = agents.values.contains {
            $0.surface != nil && $0.state == .working &&
                Date().timeIntervalSince($0.updated) <= workingTimeout
        }

        if anyWorking && powerAssertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Claude Code is working in mostty" as CFString,
                &id)
            if result == kIOReturnSuccess { powerAssertion = id }
        } else if !anyWorking && powerAssertion != 0 {
            IOPMAssertionRelease(powerAssertion)
            powerAssertion = 0
        }
    }

    // MARK: Sessions (resume after restart)

    private func setSession(_ value: String, for surface: Ghostty.SurfaceView) {
        if value.isEmpty {
            // Claude exited. If that's because mostty is quitting, keep it so
            // the session is resumed on next launch.
            guard !isTerminating else { return }
            sessions[surface.id] = nil
        } else {
            let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
            let id = parts[0]
            guard id.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { return }
            let session = ClaudeSession(id: id, cwd: parts.count > 1 ? parts[1] : "")
            guard sessions[surface.id] != session else { return }
            sessions[surface.id] = session
        }
        surface.window?.invalidateRestorableState()
    }

    /// Sessions for the given surfaces, for saving in restoration state.
    func sessions(for tree: SplitTree<Ghostty.SurfaceView>) -> [String: ClaudeSession] {
        var result: [String: ClaudeSession] = [:]
        for surface in tree {
            if let s = sessions[surface.id] { result[surface.id.uuidString] = s }
        }
        return result
    }

    /// Restart saved Claude sessions in a restored window.
    ///
    /// Each saved session is resumed at most once: it is not re-recorded here.
    /// When the resume works, Claude's SessionStart hook records it again; if
    /// it doesn't, it's forgotten instead of being retried on every launch.
    func resume(_ saved: [String: ClaudeSession], in tree: SplitTree<Ghostty.SurfaceView>) {
        guard resumeEnabled, !saved.isEmpty else { return }
        for surface in tree {
            guard let session = saved[surface.id.uuidString] else { continue }
            surface.window?.invalidateRestorableState()
            guard Self.transcriptExists(for: session.id) else { continue }
            sendResume(session, to: surface, attempt: 0)
        }
    }

    /// Whether Claude Code has a saved conversation with this id.
    private static func transcriptExists(for id: String) -> Bool {
        transcriptURL(for: id) != nil
    }

    /// Claude Code's saved conversation with this id:
    /// `<config>/projects/<project>/<id>.jsonl`.
    nonisolated static func transcriptURL(for id: String) -> URL? {
        let fm = FileManager.default
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let projects = configDir.appendingPathComponent("projects")
        guard let dirs = try? fm.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil) else { return nil }
        return dirs
            .map { $0.appendingPathComponent("\(id).jsonl") }
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// The Claude session running in a terminal, if mostty knows it.
    func session(for surface: Ghostty.SurfaceView) -> ClaudeSession? {
        sessions[surface.id]
    }

    private func sendResume(_ session: ClaudeSession, to surface: Ghostty.SurfaceView, attempt: Int) {
        var command = "claude --resume \(session.id)"
        if !session.cwd.isEmpty {
            let quoted = "'" + session.cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
            command = "cd -- \(quoted) && \(command)"
        }
        run(command, in: surface)
    }

    /// Type a command into a new terminal's shell and run it, once the shell
    /// is at its first prompt. Going through the shell (rather than starting
    /// the command directly) keeps mostty's `claude` wrapper and hooks, and
    /// leaves the shell there when the command exits.
    func run(_ command: String, in surface: Ghostty.SurfaceView, pressReturn: Bool = true, attempt: Int = 0) {
        // Ghostty's shell integration reports the working directory at the
        // prompt, so `pwd` becoming non-nil is the signal. Typing earlier
        // works too (the tty buffers it) but shows the command twice. Give up
        // waiting after ~4s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak surface] in
            guard let surface else { return }
            let ready = surface.surface != nil && surface.pwd != nil
            guard ready || attempt >= 40 else {
                self.run(command, in: surface, pressReturn: pressReturn, attempt: attempt + 1)
                return
            }
            guard surface.surface != nil else { return }
            surface.mosttySendText(command)
            if pressReturn { surface.mosttySendReturn() }
        }
    }

    /// Text for the quit confirmation when Claude is active in `surfaces`.
    func quitWarning(for surfaces: [Ghostty.SurfaceView]) -> String? {
        let active = surfaces.filter { agentState($0) != nil || sessions[$0.id] != nil }
        guard !active.isEmpty else { return nil }
        if resumeEnabled {
            return "Claude Code is running here. It will be stopped now and resumed automatically when you reopen mostty."
        }
        return closeWarning(for: surfaces, action: "quit")
    }

    /// Text for close confirmations when Claude is active in `surfaces`.
    func closeWarning(for surfaces: [Ghostty.SurfaceView], action: String) -> String? {
        let active = surfaces.filter { agentState($0) != nil || sessions[$0.id] != nil }
        guard !active.isEmpty else { return nil }
        let working = surfaces.filter { agentState($0) == .working }.count
        let waiting = surfaces.filter { agentState($0) == .waiting }.count

        func terminals(_ n: Int) -> String { "\(n) terminal\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if working > 0 { parts.append("working in \(terminals(working))") }
        if waiting > 0 { parts.append("waiting for you in \(terminals(waiting))") }
        let lead = parts.isEmpty
            ? "Claude Code is running in \(terminals(active.count))"
            : "Claude Code is " + parts.joined(separator: " and ")
        return "\(lead). If you \(action), it will be stopped. You can pick it back up later with claude --resume."
    }

    /// The latest notification text from any of these surfaces.
    func latestMessage(_ surfaces: [Ghostty.SurfaceView]) -> String? {
        surfaces
            .compactMap { messages[ObjectIdentifier($0)] }
            .filter { $0.surface != nil }
            .max { $0.date < $1.date }?
            .text
    }

    /// Jump to the most recent terminal that is asking for attention.
    func jumpToLatestUnread() {
        let latest = messages.values
            .filter { $0.surface?.bell == true }
            .max { $0.date < $1.date }
        guard let surface = latest?.surface else { NSSound.beep(); return }
        focus(surface)
    }

    private func focus(_ surface: Ghostty.SurfaceView) {
        guard let window = surface.window,
              let controller = window.windowController as? BaseTerminalController else { return }
        window.tabGroup?.selectedWindow = window
        controller.focusSurface(surface)
    }

    // MARK: Notifications

    private func handle(surface: Ghostty.SurfaceView, title: String, body: String) {
        let key = ObjectIdentifier(surface)
        messages[key] = .init(surface: surface, text: body.isEmpty ? title : body, date: Date())
        messages = messages.filter { $0.value.surface != nil }
        // 1. Sound
        if soundName.lowercased() != "none", let sound = NSSound(named: soundName) {
            sound.stop()
            sound.play()
        }

        // 2. Attention: if the user isn't looking at this exact terminal, ring
        //    Ghostty's bell for it. That drives the 🔔 in the tab title, the
        //    dock bounce, and the orange dot on the workspace in the sidebar.
        //    It clears automatically when the surface is focused.
        let lookingAtIt = NSApp.isActive && surface.focused && (surface.window?.isKeyWindow ?? false)
        if !lookingAtIt {
            NotificationCenter.default.post(name: .ghosttyBellDidRing, object: surface)
        }
        WorkspaceManager.shared.refresh()

        // 3. Toast
        let controller = surface.window?.windowController as? TerminalController
        let workspace = controller.map { WorkspaceManager.shared.name(for: $0.workspaceID) } ?? ""
        let tab = controller?.window?.title ?? surface.title
        let location = [workspace, tab].filter { !$0.isEmpty }.joined(separator: " › ")

        let toast = Toast(
            title: title.isEmpty ? "Notification" : title,
            body: body,
            location: location,
            surface: surface)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.toast = toast }

        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard self?.toast?.id == toast.id else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) { toast = nil }
    }

    /// Jump to the terminal that sent the toast.
    func open(_ toast: Toast) {
        dismiss()
        guard let surface = toast.surface else { return }
        focus(surface)
    }
}

/// mostty: The toast overlay, shown at the top-right of the terminal content.
struct WorkspaceToastView: View {
    @ObservedObject var notifier: WorkspaceNotifier = .shared
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        if activeState == .key, let toast = notifier.toast {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: toast.title.localizedCaseInsensitiveContains("claude")
                      ? "sparkle" : "bell.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.title)
                        .font(.system(size: 12, weight: .semibold))
                    if !toast.body.isEmpty {
                        Text(toast.body)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !toast.location.isEmpty {
                        Text(toast.location)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Button {
                    notifier.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 300, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .contentShape(Rectangle())
            .onTapGesture { notifier.open(toast) }
            .padding(12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(toast.id)
        }
    }
}
