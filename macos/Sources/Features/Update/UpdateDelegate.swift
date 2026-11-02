import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // mostty: updates come from mostty's own GitHub releases. Each release
        // publishes an appcast.xml (see extras/release.sh); "latest" always
        // redirects to the newest one. Ghostty's update channels don't apply.
        //
        // For testing a release locally:
        //   defaults write com.mostty.app MosttyUpdateFeedURL http://localhost:8000/appcast.xml
        if let override = UserDefaults.standard.string(forKey: "MosttyUpdateFeedURL"), !override.isEmpty {
            return override
        }
        return "https://github.com/martyvasquez/mostty/releases/latest/download/appcast.xml"
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            appcastItem: item,
            retryTerminatingApplication: immediateInstallHandler
        ))
        AppDelegate.logger.info("Version: \(item.displayVersionString) installed silently, waiting for relaunch...")
        // Even when hasUnobtrusiveTarget is false, we don't show the alert immediately.
        // We wait until the user manually checks for updates or relaunches.
        return true
    }
}
