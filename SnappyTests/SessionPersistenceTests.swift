import Combine
import XCTest

@MainActor
final class SessionPersistenceTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func display(_ id: String, x: Double = 0, w: Double = 1000, h: Double = 600, px: Int = 2000) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            logicalBounds: Rect2D(x: x, y: 0, width: w, height: h),
            pixelWidth: px,
            pixelHeight: Int(h) * 2,
            backingScale: 2
        )
    }

    private func session(_ d: DisplayDescriptor, count: Int = 1) -> MeasurementSession {
        MeasurementSession(
            displays: [
                DisplayAnnotations(
                    display: d,
                    annotations: (0..<count).map { _ in
                        MeasurementAnnotation(
                            displayID: d.id,
                            geometry: .horizontalMeasurement(start: Point2D(x: 100, y: 200), length: 300)
                        )
                    }
                )
            ]
        )
    }

    private func controller(_ coordinator: MeasurementCoordinator, _ displays: [DisplayDescriptor])
        -> SessionPersistenceController
    {
        SessionPersistenceController(
            store: SessionStore(directory: dir),
            coordinator: coordinator,
            displays: { displays }
        )
    }

    func testSaveLoadRoundTrip() throws {
        let store = SessionStore(directory: dir)
        let s = session(display("a"))
        try store.save(s, to: .active)
        let loaded = try store.load(.active)
        XCTAssertEqual(loaded?.id, s.id)
        XCTAssertEqual(loaded?.displays, s.displays)
    }

    func testMissingFileIsNil() throws {
        XCTAssertNil(try SessionStore(directory: dir).load(.active))
    }

    func testCorruptFileIsQuarantinedAndReported() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{nope".utf8).write(to: dir.appendingPathComponent("last-session.json"))
        let store = SessionStore(directory: dir)
        XCTAssertThrowsError(try store.load(.lastRestorable))
        XCTAssertFalse(store.hasSession(.lastRestorable))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("last-session.corrupt.json").path))
    }

    func testNewerSchemaIsRejectedAndKept() throws {
        let store = SessionStore(directory: dir)
        var s = session(display("a"))
        try store.save(s, to: .active)
        s.schemaVersion = 99
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(s).write(to: dir.appendingPathComponent("active-session.json"))
        XCTAssertThrowsError(try store.load(.active)) {
            XCTAssertEqual($0 as? SessionStoreError, .unsupportedSchema(99))
        }
        XCTAssertTrue(store.hasSession(.active))
    }

    func testFailedWriteKeepsPreviousFile() throws {
        let store = SessionStore(directory: dir)
        let good = session(display("a"))
        try store.save(good, to: .active)
        var bad = session(display("a"))
        bad.displays[0].annotations[0].geometry = .guideline(axis: .vertical, position: .nan)
        XCTAssertThrowsError(try store.save(bad, to: .active))
        XCTAssertEqual(try store.load(.active)?.id, good.id)
    }

    func testFlushPromotesOnlyNonEmptySessions() throws {
        let d = display("a")
        let coordinator = MeasurementCoordinator()
        let c = controller(coordinator, [d])
        c.start(displayChanges: Just([d]).eraseToAnyPublisher())
        coordinator.startFreshSession(displays: [d], pointer: Point2D(x: 1, y: 1))
        c.flush()
        XCTAssertFalse(c.hasRestorableSession)

        coordinator.addAnnotation(
            MeasurementAnnotation(displayID: "a", geometry: .guideline(axis: .vertical, position: 10))
        )
        c.flush()
        XCTAssertTrue(c.hasRestorableSession)
    }

    func testFreshStartAndClearKeepRestorableSnapshot() throws {
        let d = display("a")
        let coordinator = MeasurementCoordinator()
        let c = controller(coordinator, [d])
        c.start(displayChanges: Just([d]).eraseToAnyPublisher())
        coordinator.startFreshSession(displays: [d], pointer: Point2D(x: 1, y: 1))
        coordinator.addAnnotation(
            MeasurementAnnotation(displayID: "a", geometry: .guideline(axis: .vertical, position: 10))
        )
        c.flush()

        c.clearAnnotations()
        c.flush()
        XCTAssertEqual(coordinator.activeSession?.annotationCount, 0)

        coordinator.startFreshSession(displays: [d], pointer: Point2D(x: 1, y: 1))
        c.flush()
        XCTAssertTrue(c.restoreLastSession())
        XCTAssertEqual(coordinator.activeSession?.annotationCount, 1)
    }

    func testRestoreSurvivesRelaunch() throws {
        let d = display("a")
        let first = MeasurementCoordinator()
        let c1 = controller(first, [d])
        c1.start(displayChanges: Just([d]).eraseToAnyPublisher())
        first.startFreshSession(displays: [d], pointer: Point2D(x: 1, y: 1))
        first.addAnnotation(
            MeasurementAnnotation(displayID: "a", geometry: .guideline(axis: .horizontal, position: 42))
        )
        c1.flush()

        let second = MeasurementCoordinator()
        let c2 = controller(second, [d])
        XCTAssertTrue(c2.hasRestorableSession)
        XCTAssertTrue(c2.restoreLastSession())
        XCTAssertEqual(
            second.activeSession?.displays[0].annotations[0].geometry,
            .guideline(axis: .horizontal, position: 42)
        )
    }

    func testRemapByIdentityScalesGeometry() {
        let old = display("a", w: 1000, h: 600)
        let new = display("a", w: 2000, h: 1200)
        let result = SessionRemapper.remap(session(old).displays, connected: [new])
        XCTAssertEqual(
            result[0].annotations[0].geometry,
            .horizontalMeasurement(start: Point2D(x: 200, y: 400), length: 600)
        )
        XCTAssertEqual(result[0].display, new)
    }

    func testRemapByCharacteristicsWhenIDChanges() {
        let old = display("a")
        let new = display("b", x: 500)
        let result = SessionRemapper.remap(session(old).displays, connected: [new])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].display.id, "b")
        XCTAssertEqual(result[0].annotations[0].displayID, "b")
    }

    func testDisconnectedDisplayRetainedAndReconnects() {
        let a = display("a")
        let b = display("b", x: 1000, h: 800, px: 3000)
        let groups = session(a).displays
        let whileGone = SessionRemapper.remap(groups, connected: [b])
        XCTAssertEqual(whileGone.count, 2)
        XCTAssertEqual(whileGone.first(where: { $0.display.id == "a" })?.annotations.count, 1)
        XCTAssertEqual(whileGone.first(where: { $0.display.id == "b" })?.annotations.count, 0)

        let back = SessionRemapper.remap(whileGone, connected: [a, b])
        XCTAssertEqual(back.first(where: { $0.display.id == "a" })?.annotations.count, 1)
    }
}
