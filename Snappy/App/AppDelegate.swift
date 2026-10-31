import AppKit
import Combine

@MainActor
final class DisplayLifecycleDelegate: NSObject, NSApplicationDelegate {
    private var shortcutService: GlobalShortcutService?
    private var measurementPresentationController: TemporaryMeasurementController?
    private var annotationController: AnnotationInteractionController?
    private var rectangleController: RectangleSelectionController?
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DisplayManager.shared.start()
        measurementPresentationController = TemporaryMeasurementController(
            coordinator: MeasurementCoordinator.shared,
            detector: ElementDetectionService(),
            displayManager: DisplayManager.shared,
            displaySource: DisplayManager.shared,
            preferencesStore: PreferencesStore.shared
        )
        measurementPresentationController?.start()
        let presenter = measurementPresentationController
        annotationController = AnnotationInteractionController(
            coordinator: MeasurementCoordinator.shared,
            surface: DisplayManager.shared,
            preferencesStore: PreferencesStore.shared,
            currentMeasurement: {
                presenter?.lastDetectedCandidate
            }
        )
        annotationController?.start()
        rectangleController = RectangleSelectionController(
            coordinator: MeasurementCoordinator.shared,
            surface: DisplayManager.shared,
            analyzer: RectangleSelectionService()
        )
        rectangleController?.start()
        SessionPersistenceController.shared.start(
            displayChanges: DisplayManager.shared.$connectedDisplays.eraseToAnyPublisher()
        )
        GlobalInputMonitor.shared.start()
        shortcutService = GlobalShortcutService.shared
        shortcutService?.start()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                GlobalInputMonitor.shared.refreshKeyboardPermission()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        shortcutService?.stop()
        shortcutService = nil
        SessionPersistenceController.shared.flush()
        rectangleController?.stop()
        rectangleController = nil
        annotationController?.stop()
        annotationController = nil
        measurementPresentationController?.stop()
        measurementPresentationController = nil
        GlobalInputMonitor.shared.stop()
        MeasurementCoordinator.shared.stop()
        DisplayManager.shared.stop()
    }
}
