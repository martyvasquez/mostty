import SwiftUI
import UniformTypeIdentifiers

/// mostty: Lays out the workspace sidebar to the left of the terminal content.
struct WorkspaceSidebarContainer<Content: View>: View {
    @ObservedObject var manager: WorkspaceManager = .shared
    @ObservedObject var ghostty: Ghostty.App
    @ViewBuilder let content: () -> Content

    /// Height of the titlebar (the top safe area), measured below.
    @State private var topInset: CGFloat = 0

    var body: some View {
        // The window lets content extend under the titlebar. The sidebar uses
        // that to run the full window height (under the traffic lights), and
        // the terminal stays inside the safe area, below the tab bar.
        HStack(spacing: 0) {
            if manager.sidebarVisible {
                WorkspaceSidebarView(ghostty: ghostty, topInset: topInset)
                    .ignoresSafeArea(.container, edges: .top)
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)
                    .ignoresSafeArea(.container, edges: .top)
            }
            content()
                .padding(.leading, manager.sidebarVisible ? WorkspaceManager.contentGap : 0)
                .overlay(alignment: .topTrailing) { WorkspaceToastView() }
        }
        // Measure the titlebar height from the window so the sidebar header
        // sits just below the window buttons.
        .background(TitlebarHeightReader(height: $topInset))
    }
}

/// Reports the height of the window's titlebar area (window height minus the
/// content layout rect), updating on resize and fullscreen changes.
private struct TitlebarHeightReader: NSViewRepresentable {
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { h in
            if abs(h - height) > 0.5 { DispatchQueue.main.async { height = h } }
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        var onChange: ((CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func report() {
            guard let window else { return }
            let h = window.frame.height - window.contentLayoutRect.height
            onChange?(max(0, h))
        }
    }
}

/// mostty: The workspace sidebar shown on the left of every terminal window.
struct WorkspaceSidebarView: View {
    @ObservedObject var manager: WorkspaceManager = .shared
    @ObservedObject var ghostty: Ghostty.App
    /// Height of the titlebar area the sidebar extends under.
    var topInset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Leave room for the window buttons.
            Color.clear.frame(height: topInset)

            HStack {
                Text("WORKSPACES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
                Button {
                    manager.createWithFolderPicker()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Workspace for a Folder (⌃⌘N)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(manager.items) { item in
                        WorkspaceRow(item: item, manager: manager)
                            .opacity(manager.draggingID == item.id ? 0.35 : 1)
                            .onDrag {
                                manager.draggingID = item.id
                                return NSItemProvider(
                                    item: item.id.uuidString.data(using: .utf8) as NSData?,
                                    typeIdentifier: UTType.mosttyWorkspace.identifier)
                            }
                            .onDrop(
                                of: [.mosttyWorkspace],
                                delegate: WorkspaceDropDelegate(target: item.id, manager: manager))
                    }

                    // Dropping below the last workspace moves it to the end.
                    Color.clear
                        .frame(height: 40)
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [.mosttyWorkspace],
                            delegate: WorkspaceDropDelegate(target: nil, manager: manager))
                }
                .padding(.horizontal, 6)
                .animation(.easeInOut(duration: 0.15), value: manager.items.map(\.id))
            }

            Spacer(minLength: 0)
        }
        .frame(width: WorkspaceManager.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(sidebarBackground)
    }

    private var sidebarBackground: some View {
        ZStack {
            ghostty.config.backgroundColor
            Color.primary.opacity(0.04)
        }
    }
}

private struct WorkspaceRow: View {
    let item: WorkspaceManager.Item
    @ObservedObject var manager: WorkspaceManager

    @State private var hovering = false
    @State private var draft = ""
    @State private var pulse = false
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { manager.renamingID == item.id }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(item.index < 9 ? "\(item.index + 1)" : "·")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 10, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if isRenaming {
                        TextField("Name", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium))
                            .focused($fieldFocused)
                            .onSubmit(commit)
                            .onExitCommand {
                                manager.renamingID = nil
                                manager.refocusTerminal()
                            }
                            .onAppear {
                                draft = item.name
                                DispatchQueue.main.async { fieldFocused = true }
                            }
                            .onChange(of: fieldFocused) { focused in
                                if !focused && isRenaming { commit() }
                            }
                    } else {
                        Text(item.name)
                            .font(.system(size: 12.5, weight: item.isActive ? .semibold : .regular))
                            .foregroundStyle(item.isActive ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 0)

                    statusIndicator

                    if item.tabCount > 1 {
                        Text("\(item.tabCount)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 16)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(item.waiting ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(item.isActive ? 0.12 : (hovering ? 0.06 : 0)))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { manager.renamingID = item.id }
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            if !isRenaming { manager.activate(item.id) }
        })
        .contextMenu {
            Button("Rename…") { manager.renamingID = item.id }
            Button(item.folder == nil ? "Set Project Folder…" : "Change Project Folder…") {
                manager.chooseFolder(for: item.id)
            }
            if let folder = item.folder {
                Button("Show Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                }
            }
            Divider()
            Button("Move Up") { manager.move(item.id, by: -1) }
                .disabled(item.index == 0)
            Button("Move Down") { manager.move(item.id, by: 1) }
                .disabled(item.index == manager.items.count - 1)
            Divider()
            Button("Close Workspace") { manager.close(item.id) }
        }
    }

    private var subtitle: String? {
        if item.working {
            guard let since = item.workingSince else { return "Working…" }
            let minutes = Int(Date().timeIntervalSince(since) / 60)
            return minutes < 1 ? "Working…" : "Working · \(Self.duration(minutes))"
        }
        return item.message ?? item.folder.map { ($0 as NSString).abbreviatingWithTildeInPath }
    }

    private static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Claude working: spinner. Claude waiting on you: pulsing orange dot.
    /// Finished but not yet seen: solid blue dot.
    @ViewBuilder private var statusIndicator: some View {
        if item.waiting {
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
                .scaleEffect(pulse ? 1.25 : 0.85)
                .opacity(pulse ? 1 : 0.6)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
                .onDisappear { pulse = false }
                .help("Claude is waiting for you")
        } else if item.working {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 10, height: 10)
                .help("Claude is working")
        } else if item.attention {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .help("Something finished in this workspace")
        }
    }

    private func commit() {
        manager.setName(draft, for: item.id)
        manager.renamingID = nil
        manager.refocusTerminal()
    }
}

extension UTType {
    /// mostty: a workspace being dragged in the sidebar. A private type so a
    /// workspace dropped on a terminal can't be pasted into it as text.
    static let mosttyWorkspace = UTType(exportedAs: "com.mostty.workspace")
}

/// Reorders workspaces live as a dragged workspace passes over others.
private struct WorkspaceDropDelegate: DropDelegate {
    /// The workspace under the cursor, or nil for "the end of the list".
    let target: UUID?
    let manager: WorkspaceManager

    func dropEntered(info: DropInfo) {
        guard let dragging = manager.draggingID else { return }
        if let target {
            manager.move(dragging, to: target)
        } else {
            manager.moveToEnd(dragging)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        manager.draggingID != nil
    }

    func performDrop(info: DropInfo) -> Bool {
        manager.draggingID = nil
        return true
    }
}
