import AppKit
import Combine
import Sparkle

@MainActor final class UpdaterController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    var preparationIsRunning: () -> Bool = { false }
    private var controller: SPUStandardUpdaterController?
    private var deferredInstallation: (() -> Void)?

    override init() {
        super.init()
        // SwiftPM's bare executable is for development; only a packaged app has a feed/key.
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        controller.startUpdater()
    }

    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { !preparationIsRunning() }
    func checkForUpdates() { controller?.checkForUpdates(nil) }

    func resumeInstallationIfIdle() {
        guard !preparationIsRunning(), let continuation = deferredInstallation else { return }
        deferredInstallation = nil
        continuation()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard preparationIsRunning() else { return false }
        deferredInstallation = installHandler
        return true
    }
}
