import AppKit
import Combine
import Foundation

@MainActor
final class TemporaryMeasurementController {
    private let coordinator: MeasurementCoordinator
    private let detector: ElementDetecting
    private let displayManager: TemporaryMeasurementPresenting
    private let displaySource: MeasurementDisplayProviding
    private let preferencesStore: PreferencesStore
    private var cancellables = Set<AnyCancellable>()
    private var detectionTask: Task<Void, Never>?
    private var detectionTaskID: UUID?
    private var pointerGeneration = 0
    private var isMeasuringActive = false
    private var isShowingCrosshair = false
    private var latestPointer: Point2D?
    private var lastResult: ElementDetectionResult?
    private var lastTolerance: EdgeToleranceSettings?
    private(set) var lastDetectedCandidate: DetectionCandidate?
    private var lastPointer: Point2D?
    private var lastDetectionStart = Date.distantPast
    private let minimumDetectionInterval: TimeInterval

    init(
        coordinator: MeasurementCoordinator,
        detector: ElementDetecting,
        displayManager: TemporaryMeasurementPresenting,
        displaySource: MeasurementDisplayProviding,
        preferencesStore: PreferencesStore,
        minimumDetectionInterval: TimeInterval = 0.01
    ) {
        self.coordinator = coordinator
        self.detector = detector
        self.displayManager = displayManager
        self.displaySource = displaySource
        self.preferencesStore = preferencesStore
        self.minimumDetectionInterval = minimumDetectionInterval
    }

    func start() {
        guard cancellables.isEmpty else { return }
        coordinator.$mode
            .sink { [weak self] mode in
                self?.modeChanged(mode)
            }
            .store(in: &cancellables)
        preferencesStore.$preferences
            .sink { [weak self] preferences in
                self?.refreshPresentation(preferences: preferences)
            }
            .store(in: &cancellables)
    }

    func stop() {
        detectionTask?.cancel()
        detectionTask = nil
        detectionTaskID = nil
        cancellables.removeAll()
        isShowingCrosshair = false
        lastResult = nil
        lastPointer = nil
        latestPointer = nil
        pointerGeneration += 1
        displayManager.clearTemporaryMeasurements()
    }

    private func modeChanged(_ mode: MeasurementModeState) {
        let wasActive = isMeasuringActive
        isMeasuringActive = mode.isActive
        if mode.isActive, !wasActive {
            displayManager.freezeScreens()
        } else if !mode.isActive, wasActive {
            displayManager.unfreezeScreens()
        }
        guard case .tracking(let pointer, let shiftHeld) = mode else {
            isShowingCrosshair = false
            detectionTask?.cancel()
            detectionTask = nil
            detectionTaskID = nil
            lastResult = nil
            lastPointer = nil
            latestPointer = nil
            lastDetectedCandidate = nil
            pointerGeneration += 1
            displayManager.clearTemporaryMeasurements()
            return
        }
        if shiftHeld {
            detectionTask?.cancel()
            detectionTask = nil
            detectionTaskID = nil
            pointerGeneration += 1
            latestPointer = pointer
            isShowingCrosshair = true
            lastDetectedCandidate = nil
            displayManager.showTemporaryCrosshair(
                at: pointer, preferences: preferencesStore.preferences)
            return
        }

        if isShowingCrosshair {
            isShowingCrosshair = false
            if lastPointer == pointer, let lastResult {
                if case .detected(let candidate) = lastResult {
                    lastDetectedCandidate = candidate
                }
                displayManager.showTemporaryMeasurement(
                    lastResult, at: pointer, preferences: preferencesStore.preferences)
                return
            }
            displayManager.clearTemporaryMeasurements()
        }
        if latestPointer != pointer {
            latestPointer = pointer
            pointerGeneration += 1
            if lastResult != nil {
                lastResult = nil
                lastPointer = nil
            }
        }
        if detectionTask == nil {
            scheduleDetection()
        }
    }

    private func scheduleDetection() {
        guard detectionTask == nil, latestPointer != nil else { return }
        let taskID = UUID()
        detectionTaskID = taskID
        detectionTask = Task { [weak self] in
            guard let self else { return }
            let delay = max(
                0,
                minimumDetectionInterval - Date().timeIntervalSince(lastDetectionStart)
            )
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    finishDetectionTask(taskID)
                    return
                }
            }

            guard !Task.isCancelled,
                let pointer = latestPointer,
                coordinator.mode == .tracking(pointer: pointer),
                !displaySource.connectedDisplays.isEmpty,
                let primaryBounds = displaySource.primaryDisplayBounds
            else {
                finishDetectionTask(taskID)
                return
            }
            let generation = pointerGeneration
            lastDetectionStart = Date()
            let result = await detector.detect(
                at: pointer,
                displays: displaySource.connectedDisplays,
                primaryDisplayBounds: primaryBounds,
                now: Date()
            )
            if !Task.isCancelled,
                generation == pointerGeneration,
                coordinator.mode == .tracking(pointer: pointer)
            {
                var result = result
                if case .detected(let candidate) = result,
                    let display = displaySource.connectedDisplays.first(where: { $0.logicalBounds.contains(pointer) }),
                    let session = coordinator.activeSession
                {
                    let local = DisplayCoordinateMapper.globalToDisplayLocal(
                        pointer, displayBounds: display.logicalBounds)
                    result = .detected(PinnedLineSnapper.snap(
                        candidate, pointer: local,
                        annotations: session.displays.flatMap(\.annotations)))
                }
                lastResult = result
                lastPointer = pointer
                if case .detected(let candidate) = result {
                    lastDetectedCandidate = candidate
                }
                displayManager.showTemporaryMeasurement(
                    result,
                    at: pointer,
                    preferences: preferencesStore.preferences
                )
            }
            finishDetectionTask(taskID, afterGeneration: generation)
        }
    }

    private func finishDetectionTask(_ taskID: UUID, afterGeneration: Int? = nil) {
        guard detectionTaskID == taskID else { return }
        detectionTask = nil
        detectionTaskID = nil
        guard let afterGeneration,
            pointerGeneration != afterGeneration,
            case .tracking = coordinator.mode
        else {
            return
        }
        scheduleDetection()
    }

    private func refreshPresentation(preferences: AppPreferences) {
        let tolerance = preferences.edgeTolerance
        let changed = lastTolerance != nil && lastTolerance != tolerance
        lastTolerance = tolerance
        if changed, let pointer = coordinator.mode.pointer {
            displayManager.showToleranceToast(tolerance, at: pointer)
            // A stationary pointer must be rescanned; discard results from the old threshold.
            detectionTask?.cancel()
            detectionTask = nil
            detectionTaskID = nil
            pointerGeneration += 1
            lastResult = nil
            lastPointer = nil
            lastDetectedCandidate = nil
            latestPointer = pointer
            if case .tracking(_, false) = coordinator.mode { scheduleDetection() }
        }
        if case .tracking(let pointer, true) = coordinator.mode {
            displayManager.showTemporaryCrosshair(at: pointer, preferences: preferences)
            return
        }
        guard let lastResult, let lastPointer else { return }
        displayManager.showTemporaryMeasurement(
            lastResult,
            at: lastPointer,
            preferences: preferences
        )
    }
}
