// Updater.swift: one-click in-app updates through Sparkle. Sparkle reads the appcast
// published with each release once a day and downloads a newer build in the background.
// The menu then offers "Install Update … and Relaunch": one click installs it. An update
// nobody clicks is installed the next time Loudini quits.

import Foundation
import Sparkle

final class Updater: NSObject, SPUUpdaterDelegate {
    /// Called on the main thread with the version (e.g. "0.5.2") once an update is
    /// downloaded and ready to install.
    var onReady: ((String) -> Void)?
    private(set) var readyVersion: String?
    private var installNow: (() -> Void)?
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                  userDriverDelegate: nil)
        let updater = controller.updater
        // Send no more than the old look-only check did: a bare User-Agent instead of
        // one carrying versions, and a fixed language instead of the user's list.
        updater.userAgentString = "Loudini"
        updater.httpHeaders = ["Accept-Language": "en"]
        // One-time move from the pre-Sparkle setting: someone who turned the check off
        // keeps it off. Sparkle stores the choice itself from here on.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "autoUpdateCheck") as? Bool == false {
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = false
        }
        for key in ["autoUpdateCheck", "lastUpdateCheck", "lastSeenTag"] { defaults.removeObject(forKey: key) }
        controller.startUpdater()
    }

    var isAutomatic: Bool { controller.updater.automaticallyChecksForUpdates }

    /// The menu toggle: the daily check and the background download go on and off together.
    func setAutomatic(_ isOn: Bool) {
        controller.updater.automaticallyChecksForUpdates = isOn
        controller.updater.automaticallyDownloadsUpdates = isOn
    }

    /// Install the downloaded update and relaunch. Loudini quits first, so audio falls
    /// back to the direct path for the few seconds the swap takes.
    func install() { installNow?() }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        readyVersion = item.displayVersionString
        onReady?(item.displayVersionString)
        return true
    }

    /// A cycle that aborts after offering an update (the installer died, say) leaves a
    /// handler that does nothing, so stop offering it; menuWillOpen then hides the row.
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installNow = nil
        readyVersion = nil
    }
}
