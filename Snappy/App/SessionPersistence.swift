import AppKit
import Combine
import Foundation

enum SessionStoreError: Error, Equatable {
    case unsupportedSchema(Int)
    case invalidContent(String)
    case corrupt(String)
}

enum SessionSlot: String {
    case active = "active-session.json"
    case lastRestorable = "last-session.json"
}

/// Versioned, atomic JSON storage kept independent of any rendering code.
struct SessionStore {
    let directory: URL

    static func defaultDirectory() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Snappy", isDirectory: true)
    }

    private func url(_ slot: SessionSlot) -> URL {
        directory.appendingPathComponent(slot.rawValue)
    }

    func hasSession(_ slot: SessionSlot) -> Bool {
        FileManager.default.fileExists(atPath: url(slot).path)
    }

    func save(_ session: MeasurementSession, to slot: SessionSlot) throws {
        try Self.validate(session)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        // .atomic writes a temporary file and replaces the destination in one step.
        try encoder.encode(session).write(to: url(slot), options: .atomic)
    }

    /// Returns nil when no file exists. A corrupt file is moved aside, never silently deleted.
    func load(_ slot: SessionSlot) throws -> MeasurementSession? {
        let fileURL = url(slot)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)

        struct Header: Decodable { var schemaVersion: Int }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.schemaVersion >= 1 else {
                throw SessionStoreError.invalidContent("schema version \(header.schemaVersion)")
            }
            guard header.schemaVersion <= MeasurementSession.currentSchemaVersion else {
                throw SessionStoreError.unsupportedSchema(header.schemaVersion)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let session = try decoder.decode(MeasurementSession.self, from: data)
            try Self.validate(session)
            return session
        } catch let error as SessionStoreError {
            if case .unsupportedSchema = error { throw error }
            quarantine(fileURL)
            throw error
        } catch {
            quarantine(fileURL)
            throw SessionStoreError.corrupt(error.localizedDescription)
        }
    }

    private func quarantine(_ fileURL: URL) {
        let target = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: fileURL, to: target)
    }

    static func validate(_ session: MeasurementSession) throws {
        for group in session.displays {
            guard group.display.isValid else {
                throw SessionStoreError.invalidContent("invalid display \(group.display.id)")
            }
            for annotation in group.annotations {
                guard annotation.displayID == group.display.id, annotation.geometry.isFinite else {
                    throw SessionStoreError.invalidContent("invalid annotation \(annotation.id)")
                }
            }
        }
    }
}

extension AnnotationGeometry {
    var isFinite: Bool {
        switch self {
        case .horizontalMeasurement(let start, let length), .verticalMeasurement(let start, let length):
            start.isFinite && length.isFinite && length >= 0
        case .rectangle(let rect):
            rect.isFiniteAndNonnegative
        case .guideline(_, let position):
            position.isFinite
        }
    }
}

extension MeasurementSession {
    var annotationCount: Int {
        displays.reduce(0) { $0 + $1.annotations.count }
    }
}

/// Maps saved display groups onto the displays that are connected now.
enum SessionRemapper {
    /// Identity match first, then identical pixel size and scale. Groups with no match
    /// are retained unchanged so they can reappear if their display returns.
    static func remap(
        _ groups: [DisplayAnnotations],
        connected: [DisplayDescriptor]
    ) -> [DisplayAnnotations] {
        let displays = connected.filter(\.isValid)
        var result: [DisplayAnnotations] = []
        var usedDisplayIDs = Set<String>()
        var unmatched: [DisplayAnnotations] = []

        for group in groups {
            if let display = displays.first(where: { $0.id == group.display.id }),
                !usedDisplayIDs.contains(display.id)
            {
                usedDisplayIDs.insert(display.id)
                result.append(adapt(group, to: display))
            } else {
                unmatched.append(group)
            }
        }

        var retained: [DisplayAnnotations] = []
        for group in unmatched {
            let candidate = displays.first { d in
                !usedDisplayIDs.contains(d.id)
                    && !groups.contains(where: { $0.display.id == d.id })
                    && d.pixelWidth == group.display.pixelWidth
                    && d.pixelHeight == group.display.pixelHeight
                    && d.backingScale == group.display.backingScale
            }
            if let candidate {
                usedDisplayIDs.insert(candidate.id)
                result.append(adapt(group, to: candidate))
            } else {
                retained.append(group)
            }
        }

        for display in displays where !usedDisplayIDs.contains(display.id) {
            result.append(DisplayAnnotations(display: display, annotations: []))
        }
        return result + retained
    }

    static func adapt(_ group: DisplayAnnotations, to display: DisplayDescriptor) -> DisplayAnnotations {
        let old = group.display.logicalBounds.size
        let new = display.logicalBounds.size
        let sx = old.width > 0 ? new.width / old.width : 1
        let sy = old.height > 0 ? new.height / old.height : 1
        let annotations = group.annotations.map { annotation in
            MeasurementAnnotation(
                id: annotation.id,
                displayID: display.id,
                geometry: sx == 1 && sy == 1 ? annotation.geometry : scale(annotation.geometry, sx, sy)
            )
        }
        return DisplayAnnotations(display: display, annotations: annotations)
    }

    private static func scale(_ geometry: AnnotationGeometry, _ sx: Double, _ sy: Double) -> AnnotationGeometry {
        switch geometry {
        case .horizontalMeasurement(let start, let length):
            .horizontalMeasurement(start: Point2D(x: start.x * sx, y: start.y * sy), length: length * sx)
        case .verticalMeasurement(let start, let length):
            .verticalMeasurement(start: Point2D(x: start.x * sx, y: start.y * sy), length: length * sy)
        case .rectangle(let rect):
            .rectangle(
                Rect2D(x: rect.minX * sx, y: rect.minY * sy, width: rect.size.width * sx, height: rect.size.height * sy)
            )
        case .guideline(let axis, let position):
            .guideline(axis: axis, position: position * (axis == .horizontal ? sy : sx))
        }
    }
}

@MainActor
final class SessionPersistenceController: ObservableObject {
    static let shared = SessionPersistenceController()

    @Published private(set) var hasRestorableSession = false
    @Published private(set) var hasAnnotations = false
    @Published private(set) var lastError: String?

    private let store: SessionStore
    private let coordinator: MeasurementCoordinator
    private let displays: () -> [DisplayDescriptor]
    private var cancellables = Set<AnyCancellable>()
    private var pendingSave = false

    convenience init() {
        self.init(
            store: SessionStore(directory: SessionStore.defaultDirectory()),
            coordinator: .shared,
            displays: { DisplayManager.shared.connectedDisplays }
        )
    }

    init(
        store: SessionStore,
        coordinator: MeasurementCoordinator,
        displays: @escaping () -> [DisplayDescriptor]
    ) {
        self.store = store
        self.coordinator = coordinator
        self.displays = displays
        hasRestorableSession = store.hasSession(.lastRestorable)
    }

    func start(displayChanges: AnyPublisher<[DisplayDescriptor], Never>) {
        guard cancellables.isEmpty else { return }
        coordinator.$activeSession
            .dropFirst()
            .sink { [weak self] session in
                self?.hasAnnotations = (session?.annotationCount ?? 0) > 0
                self?.pendingSave = true
            }
            .store(in: &cancellables)
        coordinator.$activeSession
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.flush() }
            .store(in: &cancellables)
        coordinator.$mode
            .map(\.isActive)
            .removeDuplicates()
            .sink { [weak self] active in
                guard !active, let self else { return }
                // Save first so the snapshot keeps this work, then clear the screen.
                flush()
                coordinator.clearAnnotations()
            }
            .store(in: &cancellables)
        displayChanges
            .removeDuplicates()
            .sink { [weak self] connected in
                self?.coordinator.remapSession(to: connected)
            }
            .store(in: &cancellables)
    }

    /// Writes the active session; promotes it to the restorable snapshot only if non-empty.
    func flush() {
        guard pendingSave, let session = coordinator.activeSession else { return }
        pendingSave = false
        do {
            try store.save(session, to: .active)
            if session.annotationCount > 0 {
                try store.save(session, to: .lastRestorable)
                hasRestorableSession = true
            }
            lastError = nil
        } catch {
            pendingSave = true
            lastError = "Session could not be saved: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func restoreLastSession() -> Bool {
        do {
            guard let session = try store.load(.lastRestorable) else {
                hasRestorableSession = false
                return false
            }
            coordinator.restore(session, displays: displays())
            lastError = nil
            return true
        } catch {
            hasRestorableSession = store.hasSession(.lastRestorable)
            lastError = "Last session could not be restored: \(error)"
            return false
        }
    }

    func clearAnnotations() {
        coordinator.clearAnnotations()
    }
}
