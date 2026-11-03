import Foundation
import AppKit

class ServiceProvider: NSObject {
    static private let errorNoString = NSString(string: "Could not load any text from the clipboard.")

    /// mostty: "New mostty Terminal Here". Opens a tab in the workspace for
    /// that folder if there is one, otherwise a new workspace for it.
    @objc func openTerminal(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openTerminal(from: pasteboard, error: error)
    }

    private func openTerminal(
        from pasteboard: NSPasteboard,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }

        guard let pathURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            error.pointee = Self.errorNoString
            return
        }

        // Build a set of unique directory URLs to open. File paths are truncated
        // to their directories because that's the only thing we can open.
        let directoryURLs = Set(
            pathURLs.map { url -> URL in
                /// We check file system resources here because
                /// NSURL doesn't append `/` when reading string contents from pasteboard
                ///     ```
                ///     NSURL(pasteboardPropertyList: "/System/Library".propertyList(), ofType: .fileURL)?.hasDirectoryPath
                ///     ```
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
                return isDirectory ? url : url.deletingLastPathComponent()
            }
        )

        guard !directoryURLs.isEmpty else {
            error.pointee = Self.errorNoString
            return
        }

        for url in directoryURLs {
            delegate.openFolderInWorkspace(url.pathWithoutTrailingSlash)
        }
    }
}
