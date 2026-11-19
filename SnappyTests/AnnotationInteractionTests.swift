import XCTest

@MainActor
final class AnnotationInteractionTests: XCTestCase {
    func testUnavailableOrLateCaptureDoesNotInterruptDragging() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600,
            bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 500, y: 0, width: 500, height: 600))
        let capture = CapturedDisplayRegion(image: try XCTUnwrap(context.makeImage()), displayID: "d1",
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 600))
        for result in [Result<CapturedDisplayRegion, Error>.failure(ScreenCaptureError.permissionDenied),
                       .success(capture)] {
            let coordinator = MeasurementCoordinator()
            session(coordinator)
            let guideline = MeasurementAnnotation(displayID: "d1", geometry: .guideline(axis: .vertical, position: 450))
            coordinator.addAnnotation(guideline)
            let capturer = DelayedSnapCapturer(result: result)
            var feedbackCount = 0
            let controller = AnnotationInteractionController(coordinator: coordinator,
                surface: StubSurface(displays: [display]), preferencesStore: .shared,
                currentMeasurement: { nil }, snapCapturer: capturer, snapFeedback: { _ in feedbackCount += 1 })
            controller.start()
            controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 450, y: 300))
            controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 490, y: 300))
            controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 490, y: 300))
            try await Task.sleep(nanoseconds: 60_000_000)
            XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                           .guideline(axis: .vertical, position: 490))
            XCTAssertEqual(feedbackCount, 0, "Released drags must ignore late captures")
            controller.stop()
        }
    }

    func testGuidelineSnapFeedbackOccursOnlyOnAcquisitionAndKeepsSnappedPosition() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600,
            bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 500, y: 0, width: 500, height: 600))
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let guideline = MeasurementAnnotation(displayID: "d1", geometry: .guideline(axis: .vertical, position: 450))
        coordinator.addAnnotation(guideline)
        let surface = StubSurface(displays: [display])
        surface.capture = CapturedDisplayRegion(image: try XCTUnwrap(context.makeImage()), displayID: "d1",
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 600))
        var feedback: [Double] = []
        var commandHeld = false
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let controller = AnnotationInteractionController(coordinator: coordinator, surface: surface,
            preferencesStore: preferences, currentMeasurement: { nil },
            commandHeld: { commandHeld }, snapFeedback: { feedback.append($0) })
        controller.start()
        defer { controller.stop() }
        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 450, y: 300))
        for x in [490.0, 492, 494] {
            controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: x, y: 300))
            XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                           .guideline(axis: .vertical, position: 500))
        }
        XCTAssertEqual(feedback, [1])
        commandHeld = true
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 492, y: 300))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .guideline(axis: .vertical, position: 492))
        XCTAssertEqual(feedback, [1], "Command-drag must not produce snap feedback")
        commandHeld = false
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 492, y: 300))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .guideline(axis: .vertical, position: 500))
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 470, y: 300))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .guideline(axis: .vertical, position: 470))
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 490, y: 300))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 490, y: 300))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .guideline(axis: .vertical, position: 500))
    }

    func testVerticalMeasurementSnapsToVerticalEdgeAndCommandDisables() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600,
            bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 500, y: 0, width: 500, height: 600))
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let measurement = MeasurementAnnotation(
            displayID: "d1",
            geometry: .verticalMeasurement(start: Point2D(x: 450, y: 100), length: 200)
        )
        coordinator.addAnnotation(measurement)
        let surface = StubSurface(displays: [display])
        surface.capture = CapturedDisplayRegion(image: try XCTUnwrap(context.makeImage()), displayID: "d1",
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 600))
        var feedback: [Double] = []
        var commandHeld = false
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let controller = AnnotationInteractionController(coordinator: coordinator, surface: surface,
            preferencesStore: preferences, currentMeasurement: { nil },
            commandHeld: { commandHeld }, snapFeedback: { feedback.append($0) })
        controller.start()
        defer { controller.stop() }
        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 452, y: 200))
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 492, y: 200))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .verticalMeasurement(start: Point2D(x: 500, y: 100), length: 200))
        XCTAssertFalse(feedback.isEmpty)
        commandHeld = true
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 470, y: 200))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .verticalMeasurement(start: Point2D(x: 468, y: 100), length: 200))
        commandHeld = false
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 492, y: 200))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .verticalMeasurement(start: Point2D(x: 500, y: 100), length: 200))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 492, y: 200))
    }

    func testHorizontalMeasurementSnapsToHorizontalEdge() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600,
            bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 300, width: 1000, height: 300))
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let measurement = MeasurementAnnotation(
            displayID: "d1",
            geometry: .horizontalMeasurement(start: Point2D(x: 100, y: 280), length: 200)
        )
        coordinator.addAnnotation(measurement)
        let surface = StubSurface(displays: [display])
        surface.capture = CapturedDisplayRegion(image: try XCTUnwrap(context.makeImage()), displayID: "d1",
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 600))
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let controller = AnnotationInteractionController(coordinator: coordinator, surface: surface,
            preferencesStore: preferences, currentMeasurement: { nil }, snapFeedback: { _ in })
        controller.start()
        defer { controller.stop() }
        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 200, y: 282))
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 200, y: 312))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .horizontalMeasurement(start: Point2D(x: 100, y: 300), length: 200))
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 200, y: 502))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .horizontalMeasurement(start: Point2D(x: 100, y: 500), length: 200))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 200, y: 502))
    }

    func testHorizontalMeasurementSnapsEitherEnd() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600,
            bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 500, y: 0, width: 500, height: 600))
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        // Ends at x=320 and x=520; the vertical edge sits at x=500.
        let measurement = MeasurementAnnotation(
            displayID: "d1",
            geometry: .horizontalMeasurement(start: Point2D(x: 320, y: 280), length: 200)
        )
        coordinator.addAnnotation(measurement)
        let surface = StubSurface(displays: [display])
        surface.capture = CapturedDisplayRegion(image: try XCTUnwrap(context.makeImage()), displayID: "d1",
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 600))
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let controller = AnnotationInteractionController(coordinator: coordinator, surface: surface,
            preferencesStore: preferences, currentMeasurement: { nil }, snapFeedback: { _ in })
        controller.start()
        defer { controller.stop() }
        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 350, y: 282))
        // Drag left so the right end (x=510) is near the edge while the
        // left end (x=310) is far from any edge.
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 340, y: 282))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .horizontalMeasurement(start: Point2D(x: 300, y: 280), length: 200))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 340, y: 282))
    }

    func testVerticalMeasurementSnapsTopEnd() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600,
            bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 300, width: 1000, height: 300))
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        // Ends at y=100 and y=300; the horizontal edge sits at y=300.
        let measurement = MeasurementAnnotation(
            displayID: "d1",
            geometry: .verticalMeasurement(start: Point2D(x: 100, y: 100), length: 200)
        )
        coordinator.addAnnotation(measurement)
        let surface = StubSurface(displays: [display])
        surface.capture = CapturedDisplayRegion(image: try XCTUnwrap(context.makeImage()), displayID: "d1",
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 600))
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let controller = AnnotationInteractionController(coordinator: coordinator, surface: surface,
            preferencesStore: preferences, currentMeasurement: { nil }, snapFeedback: { _ in })
        controller.start()
        defer { controller.stop() }
        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 102, y: 150))
        // Drag up so the top end (y=310) is near the edge while the bottom
        // end (y=110) is far from any edge.
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 102, y: 160))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .verticalMeasurement(start: Point2D(x: 100, y: 100), length: 200))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 102, y: 160))
    }

    func testMeasurementSnapsToExistingLinesItCrosses() throws {
        // Blank capture: no visual edges, only pinned lines can snap.
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600,
            bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        // Vertical guideline at x=500 spans the display and always overlaps.
        coordinator.addAnnotation(MeasurementAnnotation(
            displayID: "d1", geometry: .guideline(axis: .vertical, position: 500)))
        // Vertical bar at x=512 spanning y=400...500 is nearer the dragged
        // end but does not cross the bar, so it must be ignored.
        coordinator.addAnnotation(MeasurementAnnotation(
            displayID: "d1",
            geometry: .verticalMeasurement(start: Point2D(x: 512, y: 400), length: 100)))
        // Horizontal bar at y=300 overlapping the dragged bar's x-range;
        // dragging down onto it must snap the dragged bar's height to y=300.
        coordinator.addAnnotation(MeasurementAnnotation(
            displayID: "d1",
            geometry: .horizontalMeasurement(start: Point2D(x: 350, y: 300), length: 200)))
        let dragged = MeasurementAnnotation(
            displayID: "d1",
            geometry: .horizontalMeasurement(start: Point2D(x: 320, y: 280), length: 200)
        )
        coordinator.addAnnotation(dragged)
        let surface = StubSurface(displays: [display])
        surface.capture = CapturedDisplayRegion(image: try XCTUnwrap(context.makeImage()), displayID: "d1",
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 600))
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let controller = AnnotationInteractionController(coordinator: coordinator, surface: surface,
            preferencesStore: preferences, currentMeasurement: { nil }, snapFeedback: { _ in })
        controller.start()
        defer { controller.stop() }
        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 350, y: 282))
        // Ends move to x=310 and x=510 and the bar drops to y=310. The right
        // end snaps to the guideline at x=500 (start.x becomes 300), the
        // height snaps onto the horizontal bar at y=300, and the nearer
        // vertical bar at x=512 is ignored because it never crosses y=310.
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 340, y: 312))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[3].geometry,
                       .horizontalMeasurement(start: Point2D(x: 300, y: 300), length: 200))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 340, y: 312))
    }

    func testRectangleSnapsSidesToVisualEdgeAndCommandDisables() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600,
            bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 500, y: 0, width: 500, height: 600))
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let rect = Rect2D(x: 100, y: 100, width: 200, height: 100)
        coordinator.addAnnotation(MeasurementAnnotation(displayID: "d1", geometry: .rectangle(rect)))
        let surface = StubSurface(displays: [display])
        surface.capture = CapturedDisplayRegion(image: try XCTUnwrap(context.makeImage()), displayID: "d1",
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 600))
        var commandHeld = false
        let controller = AnnotationInteractionController(coordinator: coordinator, surface: surface,
            preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            currentMeasurement: { nil }, commandHeld: { commandHeld }, snapFeedback: { _ in })
        controller.start()
        defer { controller.stop() }
        // Grab away from the centred label; drag +195 puts the right side at 495.
        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 120, y: 120))
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 315, y: 120))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .rectangle(Rect2D(x: 300, y: 100, width: 200, height: 100)))
        commandHeld = true
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 315, y: 120))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .rectangle(Rect2D(x: 295, y: 100, width: 200, height: 100)))
        commandHeld = false
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 315, y: 120))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .rectangle(Rect2D(x: 300, y: 100, width: 200, height: 100)))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 315, y: 120))
    }

    func testRectangleSnapsToGuidelinesOnBothAxes() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600,
            bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        coordinator.addAnnotation(MeasurementAnnotation(displayID: "d1",
            geometry: .guideline(axis: .vertical, position: 490)))
        coordinator.addAnnotation(MeasurementAnnotation(displayID: "d1",
            geometry: .guideline(axis: .horizontal, position: 245)))
        let rect = Rect2D(x: 100, y: 100, width: 200, height: 100)
        coordinator.addAnnotation(MeasurementAnnotation(displayID: "d1", geometry: .rectangle(rect)))
        let surface = StubSurface(displays: [display])
        surface.capture = CapturedDisplayRegion(image: try XCTUnwrap(context.makeImage()), displayID: "d1",
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 600))
        let controller = AnnotationInteractionController(coordinator: coordinator, surface: surface,
            preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            currentMeasurement: { nil }, snapFeedback: { _ in })
        controller.start()
        defer { controller.stop() }
        // Moved rect would be x=295,y=150 (sides 295/495 and 150/250); the
        // right side snaps onto the vertical guideline at 490 and the bottom
        // side onto the horizontal guideline at 245.
        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 120, y: 120))
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 315, y: 170))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[2].geometry,
                       .rectangle(Rect2D(x: 290, y: 145, width: 200, height: 100)))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 315, y: 170))
    }

    func testRectangleResizeSnapsDraggedEdgeAndCommandDisables() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600,
            bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 500, y: 0, width: 500, height: 600))
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let rect = Rect2D(x: 100, y: 100, width: 200, height: 100)
        coordinator.addAnnotation(MeasurementAnnotation(displayID: "d1", geometry: .rectangle(rect)))
        let surface = StubSurface(displays: [display])
        surface.capture = CapturedDisplayRegion(image: try XCTUnwrap(context.makeImage()), displayID: "d1",
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 600))
        var commandHeld = false
        let controller = AnnotationInteractionController(coordinator: coordinator, surface: surface,
            preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            currentMeasurement: { nil }, commandHeld: { commandHeld }, snapFeedback: { _ in })
        controller.start()
        defer { controller.stop() }
        // Grab the right edge; dragging to x=495 puts it near the visual
        // edge at x=500, so the edge snaps there instead of stopping at 495.
        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 300, y: 150))
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 495, y: 150))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .rectangle(Rect2D(x: 100, y: 100, width: 400, height: 100)))
        commandHeld = true
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 490, y: 150))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .rectangle(Rect2D(x: 100, y: 100, width: 390, height: 100)))
        commandHeld = false
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 495, y: 150))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .rectangle(Rect2D(x: 100, y: 100, width: 400, height: 100)))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 495, y: 150))
    }

    func testRectangleResizeCornerSnapsToGuidelines() throws {
        // Blank capture: only pinned lines can snap.
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600,
            bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        coordinator.addAnnotation(MeasurementAnnotation(displayID: "d1",
            geometry: .guideline(axis: .vertical, position: 490)))
        coordinator.addAnnotation(MeasurementAnnotation(displayID: "d1",
            geometry: .guideline(axis: .horizontal, position: 90)))
        let rect = Rect2D(x: 100, y: 100, width: 200, height: 100)
        coordinator.addAnnotation(MeasurementAnnotation(displayID: "d1", geometry: .rectangle(rect)))
        let surface = StubSurface(displays: [display])
        surface.capture = CapturedDisplayRegion(image: try XCTUnwrap(context.makeImage()), displayID: "d1",
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 600))
        let controller = AnnotationInteractionController(coordinator: coordinator, surface: surface,
            preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            currentMeasurement: { nil }, snapFeedback: { _ in })
        controller.start()
        defer { controller.stop() }
        // Grab the bottom-right corner; the raw drag lands the right edge at
        // x=485 and the bottom edge at y=95, near the guidelines at 490 and 90.
        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 300, y: 100))
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 485, y: 95))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[2].geometry,
                       .rectangle(Rect2D(x: 100, y: 90, width: 390, height: 110)))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 485, y: 95))
    }

    private let display = DisplayDescriptor(
        id: "d1",
        logicalBounds: Rect2D(x: -1000, y: 0, width: 1000, height: 600),
        pixelWidth: 2000,
        pixelHeight: 1200,
        backingScale: 2
    )

    private func session(_ coordinator: MeasurementCoordinator) {
        coordinator.startFreshSession(displays: [display], pointer: Point2D(x: -500, y: 300))
    }

    func testAddMoveRemove() {
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let annotation = MeasurementAnnotation(
            displayID: "d1",
            geometry: .horizontalMeasurement(start: Point2D(x: 10, y: 20), length: 100)
        )
        coordinator.addAnnotation(annotation)
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations.count, 1)

        let moved = AnnotationGeometry.horizontalMeasurement(start: Point2D(x: 50, y: 60), length: 100)
        coordinator.updateAnnotationGeometry(id: annotation.id, geometry: moved)
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry, moved)

        coordinator.removeAnnotation(id: annotation.id)
        XCTAssertTrue(coordinator.activeSession?.displays[0].annotations.isEmpty ?? false)
    }

    func testRectangleDragsFromInteriorAndOutlineAndDeletesFromLabel() {
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let rect = Rect2D(x: 100, y: 100, width: 300, height: 200)
        let annotation = MeasurementAnnotation(displayID: "d1", geometry: .rectangle(rect))
        coordinator.addAnnotation(annotation)
        let controller = AnnotationInteractionController(
            coordinator: coordinator, surface: StubSurface(displays: [display]),
            preferencesStore: .shared, currentMeasurement: { nil })
        controller.start()
        defer { controller.stop() }

        // Interior drags move the rectangle without changing its dimensions.
        coordinator.updateAnnotationGeometry(id: annotation.id, geometry: .rectangle(rect))
        XCTAssertEqual(AnnotationHitTester.hit(at: Point2D(x: 120, y: 120), in: [annotation], labelFontSize: 14), .body(annotation.id))
        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 120, y: 120))
        XCTAssertEqual(coordinator.activeSession?.annotationCount, 1)
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 160, y: 90))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 160, y: 90))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .rectangle(Rect2D(x: 140, y: 70, width: 300, height: 200)))

        // Edge drags resize instead of move.
        coordinator.updateAnnotationGeometry(id: annotation.id, geometry: .rectangle(rect))
        XCTAssertEqual(AnnotationHitTester.hit(at: Point2D(x: 100, y: 150), in: [annotation], labelFontSize: 14),
                       .resize(annotation.id, .left))
        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 100, y: 150))
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 140, y: 120))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 140, y: 120))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .rectangle(Rect2D(x: 140, y: 100, width: 260, height: 200)))
        XCTAssertEqual(AnnotationEditing.moved(.rectangle(rect), dx: 5000, dy: -5000,
                                             within: display.logicalBounds.size),
                       .rectangle(Rect2D(x: 700, y: 0, width: 300, height: 200)))
        XCTAssertNil(AnnotationHitTester.hit(at: Point2D(x: 450, y: 350), in: [annotation], labelFontSize: 14))
        coordinator.updateAnnotationGeometry(id: annotation.id, geometry: .rectangle(rect))
        let labelCenter = Point2D(x: 250, y: 200)
        XCTAssertEqual(AnnotationHitTester.hit(at: labelCenter, in: [annotation], labelFontSize: 14),
                       .label(annotation.id))
        controller.annotationMouseDown(displayID: "d1", at: labelCenter)
        XCTAssertEqual(coordinator.activeSession?.annotationCount, 0)
    }

    func testRectangleResizeZonesAndClamping() {
        let size = Size2D(width: 1000, height: 600)
        let geometry = AnnotationGeometry.rectangle(Rect2D(x: 100, y: 100, width: 300, height: 200))
        XCTAssertEqual(
            AnnotationEditing.resized(geometry, zone: .right, dx: 50, dy: 0, within: size),
            .rectangle(Rect2D(x: 100, y: 100, width: 350, height: 200))
        )
        XCTAssertEqual(
            AnnotationEditing.resized(geometry, zone: .topLeft, dx: -40, dy: 30, within: size),
            .rectangle(Rect2D(x: 60, y: 100, width: 340, height: 230))
        )
        XCTAssertEqual(
            AnnotationEditing.resized(geometry, zone: .left, dx: -500, dy: 0, within: size),
            .rectangle(Rect2D(x: 0, y: 100, width: 400, height: 200))
        )
        XCTAssertEqual(
            AnnotationEditing.resized(geometry, zone: .right, dx: 5000, dy: 0, within: size),
            .rectangle(Rect2D(x: 100, y: 100, width: 900, height: 200))
        )
        XCTAssertEqual(
            AnnotationEditing.resized(geometry, zone: .bottom, dx: 0, dy: -500, within: size),
            .rectangle(Rect2D(x: 100, y: 0, width: 300, height: 300))
        )
        // Dragging an edge past its opposite edge swaps sides: the dragged
        // edge keeps going and the rectangle grows on the far side.
        XCTAssertEqual(
            AnnotationEditing.resized(geometry, zone: .right, dx: -500, dy: 0, within: size),
            .rectangle(Rect2D(x: 0, y: 100, width: 100, height: 200))
        )
        XCTAssertEqual(
            AnnotationEditing.resized(geometry, zone: .right, dx: -350, dy: 0, within: size),
            .rectangle(Rect2D(x: 50, y: 100, width: 50, height: 200))
        )
        XCTAssertEqual(
            AnnotationEditing.resized(geometry, zone: .left, dx: 350, dy: 0, within: size),
            .rectangle(Rect2D(x: 400, y: 100, width: 50, height: 200))
        )
        XCTAssertEqual(
            AnnotationEditing.resized(geometry, zone: .top, dx: 0, dy: -250, within: size),
            .rectangle(Rect2D(x: 100, y: 50, width: 300, height: 50))
        )
        XCTAssertEqual(
            AnnotationEditing.resized(geometry, zone: .bottom, dx: 0, dy: 250, within: size),
            .rectangle(Rect2D(x: 100, y: 300, width: 300, height: 50))
        )
        // A 1pt minimum dimension is enforced on both sides of the swap.
        XCTAssertEqual(
            AnnotationEditing.resized(geometry, zone: .right, dx: -299, dy: 0, within: size),
            .rectangle(Rect2D(x: 100, y: 100, width: 1, height: 200))
        )
        XCTAssertEqual(
            AnnotationEditing.resized(geometry, zone: .right, dx: -302, dy: 0, within: size),
            .rectangle(Rect2D(x: 98, y: 100, width: 2, height: 200))
        )
    }

    func testRectangleResizeZoneHitTesting() {
        let annotation = MeasurementAnnotation(
            displayID: "d1",
            geometry: .rectangle(Rect2D(x: 100, y: 100, width: 300, height: 200))
        )
        let list = [annotation]
        XCTAssertEqual(
            AnnotationHitTester.hit(at: Point2D(x: 100, y: 150), in: list, labelFontSize: 14),
            .resize(annotation.id, .left)
        )
        XCTAssertEqual(
            AnnotationHitTester.hit(at: Point2D(x: 400, y: 295), in: list, labelFontSize: 14),
            .resize(annotation.id, .topRight)
        )
        XCTAssertEqual(
            AnnotationHitTester.hit(at: Point2D(x: 250, y: 100), in: list, labelFontSize: 14),
            .resize(annotation.id, .bottom)
        )
        XCTAssertEqual(
            AnnotationHitTester.hit(at: Point2D(x: 250, y: 150), in: list, labelFontSize: 14),
            .body(annotation.id)
        )
    }

    func testAnnotationForUnknownDisplayIsIgnored() {
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        coordinator.addAnnotation(
            MeasurementAnnotation(displayID: "other", geometry: .guideline(axis: .vertical, position: 5))
        )
        XCTAssertTrue(coordinator.activeSession?.displays[0].annotations.isEmpty ?? false)
    }

    func testMovePreservesLengthAndClamps() {
        let size = Size2D(width: 1000, height: 600)
        let geometry = AnnotationGeometry.horizontalMeasurement(start: Point2D(x: 100, y: 100), length: 200)
        XCTAssertEqual(
            AnnotationEditing.moved(geometry, dx: 5000, dy: -500, within: size),
            .horizontalMeasurement(start: Point2D(x: 800, y: 0), length: 200)
        )
        XCTAssertEqual(
            AnnotationEditing.moved(.guideline(axis: .horizontal, position: 10), dx: 99, dy: 20, within: size),
            .guideline(axis: .horizontal, position: 30)
        )
    }

    func testPinnedGeometry() {
        let bounds = Rect2D(x: 10, y: 20, width: 300, height: 100)
        XCTAssertEqual(
            AnnotationEditing.pinned(.horizontal, bounds: bounds, pointerLocal: Point2D(x: 50, y: 70)),
            .horizontalMeasurement(start: Point2D(x: 10, y: 70), length: 300)
        )
        XCTAssertEqual(
            AnnotationEditing.pinned(.vertical, bounds: bounds, pointerLocal: Point2D(x: 50, y: 70)),
            .verticalMeasurement(start: Point2D(x: 50, y: 20), length: 100)
        )
    }

    func testHitTesting() {
        let h = MeasurementAnnotation(
            displayID: "d1",
            geometry: .horizontalMeasurement(start: Point2D(x: 100, y: 100), length: 200)
        )
        let g = MeasurementAnnotation(displayID: "d1", geometry: .guideline(axis: .vertical, position: 500))
        let list = [h, g]
        XCTAssertEqual(AnnotationHitTester.hit(at: Point2D(x: 150, y: 102), in: list, labelFontSize: 14), .body(h.id))
        XCTAssertEqual(AnnotationHitTester.hit(at: Point2D(x: 503, y: 400), in: list, labelFontSize: 14), .body(g.id))
        XCTAssertNil(AnnotationHitTester.hit(at: Point2D(x: 400, y: 300), in: list, labelFontSize: 14))
        let label = AnnotationLayout.labelRect(for: h.geometry, fontSize: 14)!
        let center = Point2D(x: label.minX + label.size.width / 2, y: label.minY + label.size.height / 2)
        XCTAssertEqual(AnnotationHitTester.hit(at: center, in: list, labelFontSize: 14), .label(h.id))
    }

    func testPinCommandStoresLocalGeometryOnPointerDisplay() {
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let surface = StubSurface(displays: [display])
        let candidate = DetectionCandidate(
            bounds: Rect2D(x: 100, y: 200, width: 300, height: 150),
            source: .vision,
            confidence: 0.5,
            displayID: "d1"
        )
        let controller = AnnotationInteractionController(
            coordinator: coordinator,
            surface: surface,
            preferencesStore: PreferencesStore.shared,
            currentMeasurement: { candidate }
        )
        controller.handle(.pinHorizontal(at: Point2D(x: -800, y: 250)))
        controller.handle(.pinVertical(at: Point2D(x: -800, y: 250)))
        let geometries = coordinator.activeSession?.displays[0].annotations.map(\.geometry)
        XCTAssertEqual(
            geometries,
            [
                .horizontalMeasurement(start: Point2D(x: 100, y: 250), length: 300),
                .verticalMeasurement(start: Point2D(x: 200, y: 200), length: 150),
            ]
        )
    }

    func testRightClickDeletesOnlyGuidelines() {
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let guideline = MeasurementAnnotation(
            displayID: "d1", geometry: .guideline(axis: .vertical, position: 500))
        let measurement = MeasurementAnnotation(
            displayID: "d1",
            geometry: .horizontalMeasurement(start: Point2D(x: 100, y: 100), length: 200))
        let rectangle = MeasurementAnnotation(
            displayID: "d1", geometry: .rectangle(Rect2D(x: 400, y: 100, width: 200, height: 100)))
        coordinator.addAnnotation(guideline)
        coordinator.addAnnotation(measurement)
        coordinator.addAnnotation(rectangle)
        let controller = AnnotationInteractionController(
            coordinator: coordinator, surface: StubSurface(displays: [display]),
            preferencesStore: .shared, currentMeasurement: { nil })
        controller.start()
        defer { controller.stop() }

        controller.annotationRightMouseDown(displayID: "d1", at: Point2D(x: 502, y: 300))
        XCTAssertEqual(coordinator.activeSession?.annotationCount, 2)
        XCTAssertNil(coordinator.activeSession?.displays[0].annotations
            .first { $0.id == guideline.id })

        // Right-clicking a measurement or rectangle body must not delete it.
        controller.annotationRightMouseDown(displayID: "d1", at: Point2D(x: 150, y: 102))
        controller.annotationRightMouseDown(displayID: "d1", at: Point2D(x: 500, y: 150))
        XCTAssertEqual(coordinator.activeSession?.annotationCount, 2)
    }

    func testDragEventsOnOtherDisplayAreIgnored() {
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let guideline = MeasurementAnnotation(
            displayID: "d1", geometry: .guideline(axis: .vertical, position: 500))
        coordinator.addAnnotation(guideline)
        let surface = StubSurface(displays: [display])
        let controller = AnnotationInteractionController(
            coordinator: coordinator, surface: surface,
            preferencesStore: .shared, currentMeasurement: { nil })
        controller.start()
        defer { controller.stop() }

        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 500, y: 300))
        controller.annotationMouseDragged(displayID: "d2", at: Point2D(x: 600, y: 300))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .guideline(axis: .vertical, position: 500))
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 520, y: 300))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 520, y: 300))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .guideline(axis: .vertical, position: 520))
    }

    func testDeletingAnnotationMidDragCancelsTheDrag() {
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let guideline = MeasurementAnnotation(
            displayID: "d1", geometry: .guideline(axis: .vertical, position: 500))
        coordinator.addAnnotation(guideline)
        let controller = AnnotationInteractionController(
            coordinator: coordinator, surface: StubSurface(displays: [display]),
            preferencesStore: .shared, currentMeasurement: { nil })
        controller.start()
        defer { controller.stop() }

        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 502, y: 300))
        coordinator.removeAnnotation(id: guideline.id)
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 520, y: 300))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 520, y: 300))
        XCTAssertEqual(coordinator.activeSession?.annotationCount, 0)
    }

    func testPinCommandRejectsMissingDisplayUnboundCandidateAndPointerOutside() {
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        let surface = StubSurface(displays: [display])
        var candidate: DetectionCandidate?
        let controller = AnnotationInteractionController(
            coordinator: coordinator, surface: surface,
            preferencesStore: .shared, currentMeasurement: { candidate })
        controller.start()
        defer { controller.stop() }
        let pointer = Point2D(x: -500, y: 300)  // display-local (500, 300)

        // Candidate without a display association.
        candidate = DetectionCandidate(
            bounds: Rect2D(x: 400, y: 250, width: 200, height: 100),
            source: .vision, confidence: 0.5, displayID: nil)
        controller.handle(.pinHorizontal(at: pointer))
        controller.handle(.pinVertical(at: pointer))
        XCTAssertEqual(coordinator.activeSession?.annotationCount, 0)

        // Pointer outside the candidate bounds (local 500,300 vs bounds 0-50).
        candidate = DetectionCandidate(
            bounds: Rect2D(x: 0, y: 0, width: 50, height: 50),
            source: .vision, confidence: 0.5, displayID: "d1")
        controller.handle(.pinHorizontal(at: pointer))
        XCTAssertEqual(coordinator.activeSession?.annotationCount, 0)

        // Display no longer connected.
        candidate = DetectionCandidate(
            bounds: Rect2D(x: 400, y: 250, width: 200, height: 100),
            source: .vision, confidence: 0.5, displayID: "missing")
        controller.handle(.pinHorizontal(at: pointer))
        XCTAssertEqual(coordinator.activeSession?.annotationCount, 0)

        // Sanity: a valid candidate pins.
        candidate = DetectionCandidate(
            bounds: Rect2D(x: 400, y: 250, width: 200, height: 100),
            source: .vision, confidence: 0.5, displayID: "d1")
        controller.handle(.pinHorizontal(at: pointer))
        XCTAssertEqual(coordinator.activeSession?.annotationCount, 1)
    }

    func testGuidelinesStoreDisplayLocalPosition() {
        let coordinator = MeasurementCoordinator()
        session(coordinator)  // display d1: global x -1000..0, y 0..600
        let surface = StubSurface(displays: [display])
        let controller = AnnotationInteractionController(
            coordinator: coordinator, surface: surface,
            preferencesStore: .shared, currentMeasurement: { nil })
        controller.start()
        defer { controller.stop() }

        // Pointer at global (-500, 300) -> display-local (500, 300).
        controller.handle(.addVerticalGuideline(x: -500))
        controller.handle(.addHorizontalGuideline(y: 300))
        XCTAssertEqual(
            coordinator.activeSession?.displays[0].annotations.map(\.geometry),
            [
                .guideline(axis: .vertical, position: 500),
                .guideline(axis: .horizontal, position: 300),
            ]
        )
    }

    func testGuidelineOnDisplayWithNonZeroOrigin() {
        let topDisplay = DisplayDescriptor(
            id: "dtop",
            logicalBounds: Rect2D(x: 0, y: 1000, width: 1000, height: 600),
            pixelWidth: 2000,
            pixelHeight: 1200,
            backingScale: 2
        )
        let coordinator = MeasurementCoordinator()
        coordinator.startFreshSession(displays: [topDisplay], pointer: Point2D(x: 500, y: 1300))
        let controller = AnnotationInteractionController(
            coordinator: coordinator,
            surface: StubSurface(displays: [topDisplay]),
            preferencesStore: .shared, currentMeasurement: { nil })
        controller.start()
        defer { controller.stop() }

        controller.handle(.addVerticalGuideline(x: 500))
        controller.handle(.addHorizontalGuideline(y: 1300))
        XCTAssertEqual(
            coordinator.activeSession?.displays[0].annotations.map(\.geometry),
            [
                .guideline(axis: .vertical, position: 500),
                .guideline(axis: .horizontal, position: 300),
            ]
        )
    }

    func testSnapIgnoresSiblingLinesTheDraggedAnnotationDoesNotCross() throws {
        // Blank capture: no visual edges, only pinned lines can snap.
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600,
            bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        let coordinator = MeasurementCoordinator()
        session(coordinator)
        // Dragged bar: y=100 spanning x 100-400. Sibling bar: y=105 but
        // spanning x 600-700, so the dragged bar never crosses it.
        coordinator.addAnnotation(MeasurementAnnotation(displayID: "d1",
            geometry: .horizontalMeasurement(start: Point2D(x: 100, y: 100), length: 300)))
        coordinator.addAnnotation(MeasurementAnnotation(displayID: "d1",
            geometry: .horizontalMeasurement(start: Point2D(x: 600, y: 105), length: 100)))
        let surface = StubSurface(displays: [display])
        surface.capture = CapturedDisplayRegion(image: try XCTUnwrap(context.makeImage()),
            displayID: "d1",
            displayLocalBounds: Rect2D(x: 0, y: 0, width: 1000, height: 600))
        let controller = AnnotationInteractionController(coordinator: coordinator, surface: surface,
            preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            currentMeasurement: { nil }, commandHeld: { false }, snapFeedback: { _ in })
        controller.start()
        defer { controller.stop() }

        controller.annotationMouseDown(displayID: "d1", at: Point2D(x: 250, y: 102))
        // dy=+1 puts the raw bar at y=101 — inside the sibling's attraction
        // range, but the sibling is excluded because the bars never cross.
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 250, y: 103))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .horizontalMeasurement(start: Point2D(x: 100, y: 101), length: 300))

        // A full-width guideline at y=105 does cross the dragged bar.
        coordinator.addAnnotation(MeasurementAnnotation(displayID: "d1",
            geometry: .guideline(axis: .horizontal, position: 105)))
        controller.annotationMouseDragged(displayID: "d1", at: Point2D(x: 250, y: 103))
        XCTAssertEqual(coordinator.activeSession?.displays[0].annotations[0].geometry,
                       .horizontalMeasurement(start: Point2D(x: 100, y: 105), length: 300))
        controller.annotationMouseUp(displayID: "d1", at: Point2D(x: 250, y: 103))
    }
}

@MainActor
private final class DelayedSnapCapturer: ScreenRegionCapturing {
    let result: Result<CapturedDisplayRegion, Error>
    init(result: Result<CapturedDisplayRegion, Error>) { self.result = result }
    func capture(region: Rect2D, on display: DisplayDescriptor) async throws -> CapturedDisplayRegion {
        // Deliberately finish even when canceled, to exercise stale-result rejection.
        try? await Task.sleep(nanoseconds: 30_000_000)
        return try result.get()
    }
}

@MainActor
private final class StubSurface: AnnotationSurfacePresenting {
    var capture: CapturedDisplayRegion?
    func snappingCapture(for display: DisplayDescriptor) -> CapturedDisplayRegion? { capture }
    let connectedDisplays: [DisplayDescriptor]
    init(displays: [DisplayDescriptor]) { connectedDisplays = displays }
    func presentAnnotations(_ groups: [DisplayAnnotations], preferences: AppPreferences) {}
    func setAnnotationHover(_ hit: AnnotationHit?, onDisplay displayID: String?) {}
    func setAnnotationMouseHandler(_ handler: AnnotationMouseHandling?) {}
}

final class PinnedLineSnapperTests: XCTestCase {
    func testGuidelinesAndMeasurementsNarrowDetectedBounds() {
        let candidate = DetectionCandidate(
            bounds: Rect2D(x: 0, y: 0, width: 400, height: 300),
            source: .vision, confidence: 1, displayID: "d")
        let annotations = [
            MeasurementAnnotation(displayID: "d", geometry: .guideline(axis: .vertical, position: 100)),
            MeasurementAnnotation(displayID: "d", geometry: .guideline(axis: .vertical, position: 350)),
            MeasurementAnnotation(displayID: "d", geometry: .horizontalMeasurement(start: Point2D(x: 100, y: 50), length: 200)),
            MeasurementAnnotation(displayID: "d", geometry: .verticalMeasurement(start: Point2D(x: 300, y: 0), length: 20)),
            MeasurementAnnotation(displayID: "other", geometry: .guideline(axis: .vertical, position: 190)),
        ]
        let snapped = PinnedLineSnapper.snap(
            candidate, pointer: Point2D(x: 200, y: 150), annotations: annotations)
        XCTAssertEqual(snapped.bounds, Rect2D(x: 100, y: 50, width: 250, height: 250))
    }

    func testMeasurementLinesApplyOnlyWithinPointerSpan() {
        let candidate = DetectionCandidate(
            bounds: Rect2D(x: 0, y: 0, width: 400, height: 300),
            source: .vision, confidence: 1, displayID: "d")
        let annotations = [
            // x-range 50-150 excludes pointer.x=200: ignored.
            MeasurementAnnotation(displayID: "d",
                geometry: .horizontalMeasurement(start: Point2D(x: 50, y: 40), length: 100)),
            // x-range 150-250 contains pointer.x=200: narrows minY to 60.
            MeasurementAnnotation(displayID: "d",
                geometry: .horizontalMeasurement(start: Point2D(x: 150, y: 60), length: 100)),
            // 0.2pt from the pointer: inside the epsilon, ignored.
            MeasurementAnnotation(displayID: "d",
                geometry: .guideline(axis: .vertical, position: 199.8)),
            // Beyond the pointer on x: narrows maxX to 350.
            MeasurementAnnotation(displayID: "d",
                geometry: .guideline(axis: .vertical, position: 350)),
            // y=500 is outside the candidate's height: ignored.
            MeasurementAnnotation(displayID: "d",
                geometry: .guideline(axis: .horizontal, position: 500)),
        ]
        let snapped = PinnedLineSnapper.snap(
            candidate, pointer: Point2D(x: 200, y: 150), annotations: annotations)
        XCTAssertEqual(snapped.bounds, Rect2D(x: 0, y: 60, width: 350, height: 240))
    }

    func testCandidateWithoutDisplayIDIsReturnedUnchanged() {
        let candidate = DetectionCandidate(
            bounds: Rect2D(x: 0, y: 0, width: 400, height: 300),
            source: .vision, confidence: 1, displayID: nil)
        let annotations = [
            MeasurementAnnotation(displayID: "d",
                geometry: .guideline(axis: .vertical, position: 100)),
        ]
        XCTAssertEqual(
            PinnedLineSnapper.snap(candidate, pointer: Point2D(x: 200, y: 150), annotations: annotations),
            candidate)
    }
}
