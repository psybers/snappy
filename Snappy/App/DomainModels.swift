import Foundation

struct Point2D: Codable, Equatable {
    var x: Double
    var y: Double

    var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}

struct Size2D: Codable, Equatable {
    var width: Double
    var height: Double

    var isFiniteAndNonnegative: Bool {
        width.isFinite && height.isFinite && width >= 0 && height >= 0
    }
}

struct Rect2D: Codable, Equatable {
    var origin: Point2D
    var size: Size2D

    init(x: Double, y: Double, width: Double, height: Double) {
        origin = Point2D(x: x, y: y)
        size = Size2D(width: width, height: height)
    }

    var minX: Double { origin.x }
    var minY: Double { origin.y }
    var maxX: Double { origin.x + size.width }
    var maxY: Double { origin.y + size.height }
    var isFiniteAndNonnegative: Bool {
        origin.isFinite && size.isFiniteAndNonnegative && maxX.isFinite && maxY.isFinite
    }
    var isNonEmpty: Bool {
        isFiniteAndNonnegative && size.width > 0 && size.height > 0
    }

    func contains(_ point: Point2D) -> Bool {
        isFiniteAndNonnegative
            && point.isFinite
            && point.x >= minX
            && point.x <= maxX
            && point.y >= minY
            && point.y <= maxY
    }

    func intersects(_ other: Rect2D) -> Bool {
        isNonEmpty
            && other.isNonEmpty
            && minX < other.maxX
            && maxX > other.minX
            && minY < other.maxY
            && maxY > other.minY
    }

    func union(_ other: Rect2D) -> Rect2D? {
        guard isNonEmpty, other.isNonEmpty else { return nil }
        let left = min(minX, other.minX)
        let bottom = min(minY, other.minY)
        let right = max(maxX, other.maxX)
        let top = max(maxY, other.maxY)
        return Rect2D(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}

struct DisplayDescriptor: Codable, Equatable, Identifiable {
    var id: String
    var logicalBounds: Rect2D
    var pixelWidth: Int
    var pixelHeight: Int
    var backingScale: Double

    var isValid: Bool {
        !id.isEmpty
            && logicalBounds.isNonEmpty
            && pixelWidth > 0
            && pixelHeight > 0
            && backingScale.isFinite
            && backingScale > 0
    }
}

enum AnnotationAxis: String, Codable, Equatable {
    case horizontal
    case vertical
}

enum AnnotationGeometry: Codable, Equatable {
    case horizontalMeasurement(start: Point2D, length: Double)
    case verticalMeasurement(start: Point2D, length: Double)
    case rectangle(Rect2D)
    case guideline(axis: AnnotationAxis, position: Double)
}

struct MeasurementAnnotation: Codable, Equatable, Identifiable {
    var id: UUID
    var displayID: String
    var geometry: AnnotationGeometry

    init(id: UUID = UUID(), displayID: String, geometry: AnnotationGeometry) {
        self.id = id
        self.displayID = displayID
        self.geometry = geometry
    }
}

struct DisplayAnnotations: Codable, Equatable, Identifiable {
    var display: DisplayDescriptor
    var annotations: [MeasurementAnnotation]

    var id: String { display.id }
}

struct MeasurementSession: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    var id: UUID
    var createdAt: Date
    var lastModifiedAt: Date
    var schemaVersion: Int
    var displays: [DisplayAnnotations]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        lastModifiedAt: Date = Date(),
        schemaVersion: Int = MeasurementSession.currentSchemaVersion,
        displays: [DisplayAnnotations] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.lastModifiedAt = lastModifiedAt
        self.schemaVersion = schemaVersion
        self.displays = displays
    }
}

enum DetectionSource: String, Codable, Equatable {
    case accessibility
    case vision
}

struct DetectionCandidate: Codable, Equatable {
    var bounds: Rect2D
    var source: DetectionSource
    var confidence: Double
    var displayID: String?
    var elementRole: String?

    init(
        bounds: Rect2D,
        source: DetectionSource,
        confidence: Double,
        displayID: String? = nil,
        elementRole: String? = nil
    ) {
        self.bounds = bounds
        self.source = source
        self.confidence = confidence
        self.displayID = displayID
        self.elementRole = elementRole
    }

    var isValid: Bool {
        bounds.isNonEmpty && confidence.isFinite && (0...1).contains(confidence)
    }
}

enum DetectionFailure: String, Codable, Equatable {
    case accessibilityUnavailable
    case accessibilityPermissionDenied
    case accessibilityElementUnavailable
    case invalidAccessibilityBounds
    case screenCaptureUnavailable
    case screenCapturePermissionDenied
    case screenCaptureFailed
    case captureThrottled
    case visionProcessingFailed
    case detectionCancelled
    case noConfidentBoundary
}

enum ElementDetectionResult: Codable, Equatable {
    case detected(DetectionCandidate)
    case unavailable(DetectionFailure)
}
