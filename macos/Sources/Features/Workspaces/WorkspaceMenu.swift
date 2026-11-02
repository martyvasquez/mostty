import AppKit
import Combine

/// mostty: The "Workspaces" menu in the menu bar. Its key equivalents are the
/// workspace keyboard shortcuts (Ghostty passes unbound keys to the menu).
@MainActor
final class WorkspaceMenu: NSObject, NSMenuDelegate {
    static let shared = WorkspaceMenu()

    private let menu = NSMenu(title: "Workspaces")
    private var cancellables: Set<AnyCancellable> = []

    func install() {
        guard let mainMenu = NSApp.mainMenu else { return }
        guard mainMenu.item(withTitle: "Workspaces") == nil else { return }

        menu.delegate = self
        let item = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        item.submenu = menu

        // Insert before the Window menu
        let windowIndex = mainMenu.items.firstIndex { $0.submenu == NSApp.windowsMenu }
            ?? mainMenu.indexOfItem(withTitle: "Window")
        mainMenu.insertItem(item, at: windowIndex >= 0 ? windowIndex : mainMenu.items.count)

        rebuild()

        // Keep the menu (and therefore the ⌃⌘1-9 key equivalents) in sync.
        let manager = WorkspaceManager.shared
        manager.$items.combineLatest(manager.$sidebarVisible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func add(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.control, .command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        menu.addItem(item)
        return item
    }

    private func rebuild() {
        menu.removeAllItems()
        let manager = WorkspaceManager.shared

        _ = add("New Workspace for Folder…", #selector(newWorkspace), "n")
        _ = add("New Empty Workspace", #selector(newEmptyWorkspace), "n", [.control, .command, .shift])
        _ = add("Set Project Folder…", #selector(setFolder), "")
        _ = add("Rename Workspace…", #selector(renameWorkspace), "r")
        _ = add("Close Workspace", #selector(closeWorkspace), "")
        menu.addItem(.separator())
        let toggle = add(manager.sidebarVisible ? "Hide Sidebar" : "Show Sidebar", #selector(toggleSidebar), "s")
        toggle.state = .off
        menu.addItem(.separator())
        _ = add("Jump to Latest Notification", #selector(jumpToLatest), "u")
        menu.addItem(.separator())
        _ = add("Next Workspace", #selector(nextWorkspace), "j")
        _ = add("Previous Workspace", #selector(previousWorkspace), "k")
        menu.addItem(.separator())

        for item in manager.items {
            let key = item.index < 9 ? "\(item.index + 1)" : ""
            let mi = add(item.name, #selector(gotoWorkspace(_:)), key)
            mi.tag = item.index
            mi.state = item.isActive ? .on : .off
        }

        // Keep ⌃⌘1-9 working even before the items are populated.
        if manager.items.isEmpty {
            for i in 0..<9 {
                let mi = add("Workspace \(i + 1)", #selector(gotoWorkspace(_:)), "\(i + 1)")
                mi.tag = i
                mi.isHidden = true
                mi.allowsKeyEquivalentWhenHidden = true
            }
        }
    }

    @objc private func jumpToLatest() { WorkspaceNotifier.shared.jumpToLatestUnread() }
    @objc private func newWorkspace() { WorkspaceManager.shared.createWithFolderPicker() }
    @objc private func newEmptyWorkspace() { WorkspaceManager.shared.create() }
    @objc private func setFolder() {
        let manager = WorkspaceManager.shared
        guard let active = manager.items.first(where: \.isActive) else { return }
        manager.chooseFolder(for: active.id)
    }
    @objc private func renameWorkspace() { WorkspaceManager.shared.renameActive() }
    @objc private func toggleSidebar() { WorkspaceManager.shared.toggleSidebar() }
    @objc private func nextWorkspace() { WorkspaceManager.shared.activateRelative(1) }
    @objc private func previousWorkspace() { WorkspaceManager.shared.activateRelative(-1) }
    @objc private func gotoWorkspace(_ sender: NSMenuItem) { WorkspaceManager.shared.activate(index: sender.tag) }
    @objc private func closeWorkspace() {
        let manager = WorkspaceManager.shared
        guard let active = manager.items.first(where: \.isActive) else { return }
        manager.close(active.id)
    }
}
