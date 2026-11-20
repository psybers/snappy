import XCTest

/// Tests for `DomainModels.swift`: geometry helpers, `DetectionCandidate`
/// validation, `DisplayDescriptor` validation, and session codable.
final class DomainModelsTests: XCTestCase {
    func testRectangleUnionAndIntersection() {
        let first = Rect2D(x: -10, y: 5, width: 20, height: 10)
        let second = Rect2D(x: 5, y: 0, width: 10, height: 20)

        XCTAssertTrue(first.intersects(second))
        XCTAssertEqual(first.union(second), Rect2D(x: -10, y: 0, width: 25, height: 20))
    }

    func testDetectionCandidateRequiresUsableBoundsAndConfidence() {
        XCTAssertTrue(
            DetectionCandidate(
                bounds: Rect2D(x: 1, y: 2, width: 30, height: 40),
                source: .accessibility,
                confidence: 1
            ).isValid
        )
        XCTAssertFalse(
            DetectionCandidate(
                bounds: Rect2D(x: 1, y: 2, width: 0, height: 40),
                source: .vision,
                confidence: 0.9
            ).isValid
        )
        XCTAssertFalse(
            DetectionCandidate(
                bounds: Rect2D(x: 1, y: 2, width: 30, height: 40),
                source: .vision,
                confidence: 1.1
            ).isValid
        )
    }

    func testDisplayDescriptorValidatesGeometryAndScale() {
        XCTAssertTrue(
            DisplayDescriptor(
                id: "display-1",
                logicalBounds: Rect2D(x: -100, y: 0, width: 100, height: 80),
                pixelWidth: 200,
                pixelHeight: 160,
                backingScale: 2
            ).isValid
        )
        XCTAssertFalse(
            DisplayDescriptor(
                id: "display-2",
                logicalBounds: Rect2D(x: 0, y: 0, width: 100, height: 80),
                pixelWidth: 200,
                pixelHeight: 160,
                backingScale: 0
            ).isValid
        )
    }

    func testSessionAndAnnotationCodableRoundTrip() throws {
        let display = DisplayDescriptor(
            id: "display-1",
            logicalBounds: Rect2D(x: -100, y: 20, width: 100, height: 80),
            pixelWidth: 200,
            pixelHeight: 160,
            backingScale: 2
        )
        let session = MeasurementSession(
            id: UUID(uuidString: "D7DF3A31-016C-42AD-8D4B-7AA6B5A46E80")!,
            createdAt: Date(timeIntervalSince1970: 100),
            lastModifiedAt: Date(timeIntervalSince1970: 200),
            displays: [
                DisplayAnnotations(
                    display: display,
                    annotations: [
                        MeasurementAnnotation(
                            id: UUID(uuidString: "8C1171AC-7514-46CD-80AF-7CC45C039C66")!,
                            displayID: display.id,
                            geometry: .rectangle(Rect2D(x: 2, y: 3, width: 20, height: 10))
                        ),
                        MeasurementAnnotation(
                            displayID: display.id,
                            geometry: .guideline(axis: .vertical, position: 15)
                        )
                    ]
                )
            ]
        )

        let decoded = try JSONDecoder().decode(
            MeasurementSession.self,
            from: JSONEncoder().encode(session)
        )

        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.schemaVersion, MeasurementSession.currentSchemaVersion)
    }
}
