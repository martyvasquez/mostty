import AppKit
import Combine
import SwiftUI

/// mostty: Named workspaces.
///
/// A workspace is a Ghostty window (a native tab group) that has a user-given
/// name. Each workspace keeps its own tabs (and splits), exactly like a normal
/// Ghostty window. The sidebar lists all workspaces and switching to one brings
/// its window forward at the same frame as the current one, so the workspaces
/// feel like "pages" of a single window.
///
/// Nothing here touches the terminal engine or the PTYs: windows are never
/// hidden or suspended, so long-running processes (e.g. Claude Code with
/// Remote Control) in background workspaces keep running untouched.
@MainActor
final class WorkspaceManager: ObservableObject {
    static let shared = WorkspaceManager()

    struct Item: Identifiable, Equatable {
        let id: UUID
        var name: String
        var tabCount: Int
        var attention: Bool
        var working: Bool
        var waiting: Bool
        var message: String?
        var workingSince: Date?
        var folder: String?
        var isActive: Bool
        var index: Int
    }

    /// The workspaces as displayed in the sidebar, in order.
    @Published private(set) var items: [Item] = []

    /// Whether the sidebar is visible in terminal windows.
    @Published var sidebarVisible: Bool {
        didSet { defaults.set(sidebarVisible, forKey: Keys.sidebarVisible) }
    }

    /// The workspace currently being renamed inline in the sidebar.
    @Published var renamingID: UUID?

    private let defaults = UserDefaults.standard
    private var names: [String: String]
    private var folders: [String: String]
    private var order: [String]
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    private enum Keys {
        static let names = "MosttyWorkspaceNames"
        static let folders = "MosttyWorkspaceFolders"
        static let order = "MosttyWorkspaceOrder"
        static let sidebarVisible = "MosttyWorkspaceSidebarVisible"
    }

    static let sidebarWidth: CGFloat = 190

    /// Space between the sidebar and the terminal content.
    static let contentGap: CGFloat = 10

    private init() {
        names = defaults.dictionary(forKey: Keys.names) as? [String: String] ?? [:]
        folders = defaults.dictionary(forKey: Keys.folders) as? [String: String] ?? [:]
        order = defaults.stringArray(forKey: Keys.order) ?? []
        sidebarVisible = defaults.object(forKey: Keys.sidebarVisible) as? Bool ?? true

        // Cheap periodic refresh. This catches every way tabs can move between
        // windows (drag and drop, merge all windows, etc.) as well as bell state
        // without having to hook every AppKit code path.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in WorkspaceManager.shared.refresh() }
        }

        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
            NSWindow.didBecomeMainNotification,
        ] {
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { _ in Task { @MainActor in WorkspaceManager.shared.refresh() } }
                .store(in: &cancellables)
        }
    }

    // MARK: Model

    /// A workspace resolved from the current set of windows.
    private struct Group {
        let id: UUID
        let controllers: [TerminalController]
    }

    /// Groups all terminal controllers by tab group. Normalizes workspace IDs so
    /// that every tab in a tab group shares the same ID and no two tab groups
    /// share an ID (e.g. after a tab is dragged out into its own window).
    private func groups() -> [Group] {
        var seen = Set<ObjectIdentifier>()
        var usedIDs = Set<UUID>()
        var result: [Group] = []

        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            guard !seen.contains(ObjectIdentifier(controller)) else { continue }

            let windows = window.tabbedWindows ?? [window]
            let controllers = windows.compactMap { $0.windowController as? TerminalController }
            controllers.forEach { seen.insert(ObjectIdentifier($0)) }
            guard let first = controllers.first else { continue }

            var id = first.workspaceID
            if usedIDs.contains(id) {
                // A tab was dragged out into its own window: it becomes a new
                // workspace named after the one it came from.
                let newID = UUID()
                names[newID.uuidString] = "\(name(for: id)) 2"
                id = newID
            }
            usedIDs.insert(id)
            if names[id.uuidString] == nil {
                names[id.uuidString] = nextDefaultName(excluding: result.map { name(for: $0.id) })
                defaults.set(names, forKey: Keys.names)
            }
            for c in controllers where c.workspaceID != id {
                c.workspaceID = id
                c.window?.invalidateRestorableState()
            }

            result.append(.init(id: id, controllers: controllers))
        }

        // Sort according to the user's ordering; unknown workspaces go last.
        for g in result where !order.contains(g.id.uuidString) {
            order.append(g.id.uuidString)
        }
        return result.sorted {
            (order.firstIndex(of: $0.id.uuidString) ?? .max) < (order.firstIndex(of: $1.id.uuidString) ?? .max)
        }
    }

    func refresh() {
        // A drag that ended outside the sidebar never gets a drop; clear it.
        if draggingID != nil && NSEvent.pressedMouseButtons == 0 { draggingID = nil }

        let groups = groups()
        let keyController = (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? TerminalController
        let activeID = keyController?.workspaceID ?? TerminalController.lastMainWorkspaceID

        let notifier = WorkspaceNotifier.shared
        let newItems = groups.enumerated().map { (i, g) in
            let surfaces = g.controllers.flatMap { Array($0.surfaceTree) }
            let states = surfaces.compactMap { notifier.agentState($0) }
            let attention = surfaces.contains { $0.bell }
            return Item(
                id: g.id,
                name: name(for: g.id),
                tabCount: g.controllers.count,
                attention: attention,
                working: states.contains(.working),
                waiting: states.contains(.waiting),
                message: notifier.latestMessage(surfaces),
                workingSince: notifier.workingSince(surfaces),
                folder: folders[g.id.uuidString],
                isActive: g.id == activeID,
                index: i)
        }
        if newItems != items { items = newItems }

        // Garbage collect ordering for workspaces that no longer exist, but only
        // once windows exist (avoid wiping it before state restoration). Names
        // are kept so that undoing a closed workspace restores its name.
        if !groups.isEmpty {
            let live = Set(groups.map { $0.id.uuidString })
            // Names (and folders) of closed workspaces are kept so undo can
            // restore them, but don't let them pile up forever.
            if names.count > 100 {
                names = names.filter { live.contains($0.key) }
                defaults.set(names, forKey: Keys.names)
            }
            if folders.count > 100 {
                folders = folders.filter { live.contains($0.key) }
                defaults.set(folders, forKey: Keys.folders)
            }

            let newOrder = order.filter { live.contains($0) }
            if newOrder != order {
                order = newOrder
                defaults.set(order, forKey: Keys.order)
            }
        }
    }

    func name(for id: UUID) -> String {
        if let n = names[id.uuidString], !n.isEmpty { return n }
        return "Workspace"
    }

    func setName(_ name: String, for id: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[id.uuidString] = trimmed.isEmpty ? nil : trimmed
        defaults.set(names, forKey: Keys.names)
        refresh()
    }

    /// Picks a default name for a new workspace.
    func nextDefaultName(excluding extra: [String] = []) -> String {
        let existing = Set(items.map(\.name) + extra)
        var n = items.count + 1
        while existing.contains("Workspace \(n)") { n += 1 }
        return "Workspace \(n)"
    }

    // MARK: Actions

    private var activeWindow: NSWindow? {
        let w = NSApp.keyWindow ?? NSApp.mainWindow
        return (w?.windowController is TerminalController) ? w : TerminalController.preferredParent?.window
    }

    /// Bring a workspace's window forward, matching the current window frame.
    func activate(_ id: UUID) {
        guard let group = groups().first(where: { $0.id == id }),
              let anyWindow = group.controllers.first?.window else { return }
        let target = anyWindow.tabGroup?.selectedWindow ?? anyWindow

        if let current = activeWindow, current !== target,
           !current.styleMask.contains(.fullScreen),
           !target.styleMask.contains(.fullScreen),
           current.screen == target.screen || target.screen == nil {
            target.setFrame(current.frame, display: true)
        }

        target.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    func activate(index: Int) {
        guard items.indices.contains(index) else { return }
        activate(items[index].id)
    }

    func activateRelative(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex(where: \.isActive) ?? 0
        let next = (current + delta + items.count) % items.count
        activate(items[next].id)
    }

    /// Ask for a project folder, then create a workspace for it.
    func createWithFolderPicker() {
        chooseFolder(title: "New Workspace", prompt: "Create Workspace") { url in
            guard let url else { return }
            self.create(name: Self.projectName(for: url), folder: url.path)
        }
    }

    /// Create a new workspace (a new window) stacked exactly on top of the
    /// current one. Without a name, it starts renaming it.
    func create(name: String? = nil, folder: String? = nil) {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        let frame = activeWindow.flatMap { $0.styleMask.contains(.fullScreen) ? nil : $0.frame }

        let id = UUID()
        setName(name ?? nextDefaultName(), for: id)
        if let folder { setFolder(folder, for: id) }

        var config: Ghostty.SurfaceConfiguration?
        if let folder {
            var c = Ghostty.SurfaceConfiguration()
            c.workingDirectory = folder
            config = c
        }

        TerminalController.pendingWorkspaceID = id
        let c = TerminalController.newWindow(ghostty, withBaseConfig: config)
        TerminalController.pendingWorkspaceID = nil
        c.workspaceID = id

        if let frame {
            // newWindow cascades on a later runloop tick; place ours after that.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                c.window?.setFrame(frame, display: true)
            }
        }

        refresh()
        if name == nil {
            sidebarVisible = true
            renamingID = id
        }
    }

    // MARK: Project folders

    /// The project folder of a workspace, if it has one.
    func folder(for id: UUID) -> String? {
        folders[id.uuidString]
    }

    func setFolder(_ path: String?, for id: UUID) {
        folders[id.uuidString] = path
        defaults.set(folders, forKey: Keys.folders)
    }

    /// Let the user pick (or change) a workspace's folder. A workspace still
    /// using its default name is renamed after the project.
    func chooseFolder(for id: UUID) {
        chooseFolder(title: "Workspace Folder", prompt: "Choose") { url in
            guard let url else { return }
            self.setFolder(url.path, for: id)
            if self.name(for: id).hasPrefix("Workspace") {
                self.setName(Self.projectName(for: url), for: id)
            }
            self.refresh()
        }
    }

    private func chooseFolder(title: String, prompt: String, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let current = (activeWindow?.windowController as? TerminalController)?.focusedSurface?.pwd {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.url : nil)
        }
        if let window = activeWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    // MARK: Opening folders (Portal, `open -a`, Finder, Dock)

    /// Open a folder: as a new tab in the workspace whose project folder is
    /// (or contains) it, otherwise as a new workspace for it.
    /// Folder opens waiting for launch to settle. While non-zero, Ghostty's
    /// default first window is skipped (the folder brings its own).
    private(set) var pendingFolderOpens = 0

    func openFolder(_ path: String, waitForRestore: Bool) {
        if waitForRestore {
            // On a cold launch, wait for window restoration so we find the
            // restored workspace instead of creating a duplicate.
            pendingFolderOpens += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.pendingFolderOpens -= 1
                self.openFolder(path, waitForRestore: false)
            }
            return
        }

        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        let target = Self.normalize(path)

        // The deepest workspace folder that is, or contains, the target.
        let match = groups()
            .compactMap { g -> (group: Group, folder: String)? in
                guard let folder = folders[g.id.uuidString] else { return nil }
                let f = Self.normalize(folder)
                return Self.isPath(target, inside: f) ? (g, f) : nil
            }
            .max { $0.folder.count < $1.folder.count }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = path

        if let match, let anyWindow = match.group.controllers.first?.window {
            let parent = anyWindow.tabGroup?.selectedWindow ?? anyWindow
            if let current = activeWindow, current !== parent,
               !current.styleMask.contains(.fullScreen), !parent.styleMask.contains(.fullScreen) {
                parent.setFrame(current.frame, display: true)
            }
            _ = TerminalController.newTab(ghostty, from: parent, withBaseConfig: config)
        } else {
            create(name: Self.projectName(for: URL(fileURLWithPath: path)), folder: path)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Standardized absolute path with symlinks resolved and no trailing slash.
    static func normalize(_ path: String) -> String {
        let p = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    /// Whether `path` is `folder` or somewhere inside it.
    static func isPath(_ path: String?, inside folder: String) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let p = normalize(path), f = normalize(folder)
        return p == f || p.hasPrefix(f == "/" ? "/" : f + "/")
    }

    /// A workspace name for a folder: the git repository's name if the folder
    /// is inside one, otherwise the folder's own name.
    static func projectName(for url: URL) -> String {
        let fm = FileManager.default
        var dir = url.standardizedFileURL
        while dir.path != "/" {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                let repo = dir.lastPathComponent
                let leaf = url.standardizedFileURL.lastPathComponent
                return repo == leaf ? repo : "\(repo)/\(leaf)"
            }
            dir.deleteLastPathComponent()
        }
        return url.lastPathComponent
    }

    /// Start renaming the active workspace.
    func renameActive() {
        guard let item = items.first(where: \.isActive) ?? items.first else { return }
        sidebarVisible = true
        renamingID = item.id
    }

    /// Close every window (and therefore every tab) in a workspace. This goes
    /// through the normal close path so running processes trigger confirmation.
    func close(_ id: UUID) {
        guard let group = groups().first(where: { $0.id == id }) else { return }
        group.controllers.first?.closeWindow(nil)
    }

    // MARK: Drag to reorder

    /// The workspace currently being dragged in the sidebar.
    @Published var draggingID: UUID?

    /// Move a workspace to where `target` is (live, while dragging).
    func move(_ id: UUID, to target: UUID) {
        guard id != target,
              let from = order.firstIndex(of: id.uuidString),
              let to = order.firstIndex(of: target.uuidString) else { return }
        order.remove(at: from)
        order.insert(id.uuidString, at: to)
        defaults.set(order, forKey: Keys.order)
        refresh()
    }

    /// Move a workspace to the end of the list.
    func moveToEnd(_ id: UUID) {
        guard let from = order.firstIndex(of: id.uuidString), from != order.count - 1 else { return }
        order.remove(at: from)
        order.append(id.uuidString)
        defaults.set(order, forKey: Keys.order)
        refresh()
    }

    func move(_ id: UUID, by delta: Int) {
        guard let i = order.firstIndex(of: id.uuidString) else { return }
        let j = i + delta
        guard order.indices.contains(j) else { return }
        order.swapAt(i, j)
        defaults.set(order, forKey: Keys.order)
        refresh()
    }

    /// Give keyboard focus back to the terminal in the key window.
    func refocusTerminal() {
        guard let window = activeWindow,
              let c = window.windowController as? TerminalController,
              let surface = c.focusedSurface else { return }
        DispatchQueue.main.async { window.makeFirstResponder(surface) }
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
    }
}
