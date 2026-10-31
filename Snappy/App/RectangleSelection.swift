import CoreGraphics
import Combine
import Foundation

/// Pure geometry used when turning a dragged selection into a measured rectangle.
enum SelectionGeometry {
    /// Selection rectangle clipped to a display, or nil when they do not overlap.
    static func clip(_ rect: Rect2D, to bounds: Rect2D) -> Rect2D? {
        let left = max(rect.minX, bounds.minX)
        let right = min(rect.maxX, bounds.maxX)
        let bottom = max(rect.minY, bounds.minY)
        let top = min(rect.maxY, bounds.maxY)
        guard right > left, top > bottom else { return nil }
        return Rect2D(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    /// Centres of a columns x rows grid over the rectangle.
    static func samplePoints(in rect: Rect2D, columns: Int, rows: Int) -> [Point2D] {
        guard rect.isNonEmpty, columns > 0, rows > 0 else { return [] }
        var points: [Point2D] = []
        for row in 0..<rows {
            for column in 0..<columns {
                points.append(
                    Point2D(
                        x: rect.minX + rect.size.width * (Double(column) + 0.5) / Double(columns),
                        y: rect.minY + rect.size.height * (Double(row) + 0.5) / Double(rows)
                    )
                )
            }
        }
        return points
    }

    /// Smallest rectangle enclosing every element that is contained in or
    /// overlaps the selection. Elements that merely touch an edge are ignored.
    static func enclosing(selection: Rect2D, elements: [Rect2D]) -> Rect2D? {
        var result: Rect2D?
        for element in elements where element.isNonEmpty && element.intersects(selection) {
            result = result.flatMap { $0.union(element) } ?? element
        }
        return result
    }
}

/// Finds the bounding box of content that differs from the region's background.
struct ContentBoundsDetector {
    var threshold = 24

    func bounds(in captured: CapturedDisplayRegion) -> Rect2D? {
        let image = captured.image
        let region = captured.displayLocalBounds
        guard region.isNonEmpty, image.width > 0, image.height > 0,
            let pixels = PixelExtentDetector.rgbaPixels(of: image)
        else {
            return nil
        }
        let width = image.width
        let height = image.height

        func color(_ x: Int, _ row: Int) -> (Int, Int, Int) {
            let o = (row * width + x) * 4
            return (Int(pixels[o]), Int(pixels[o + 1]), Int(pixels[o + 2]))
        }

        // Background = most common (quantised) colour on the region's border.
        var counts: [Int: (count: Int, color: (Int, Int, Int))] = [:]
        func tally(_ x: Int, _ row: Int) {
            let c = color(x, row)
            let key = (c.0 >> 4) << 8 | (c.1 >> 4) << 4 | (c.2 >> 4)
            let entry = counts[key]
            counts[key] = (count: (entry?.count ?? 0) + 1, color: entry?.color ?? c)
        }
        for x in 0..<width {
            tally(x, 0)
            tally(x, height - 1)
        }
        for row in 0..<height {
            tally(0, row)
            tally(width - 1, row)
        }
        guard let background = counts.values.max(by: { $0.count < $1.count })?.color else { return nil }

        var minCol = width, maxCol = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            for x in 0..<width {
                let c = color(x, row)
                if abs(c.0 - background.0) > threshold
                    || abs(c.1 - background.1) > threshold
                    || abs(c.2 - background.2) > threshold
                {
                    minCol = min(minCol, x)
                    maxCol = max(maxCol, x)
                    minRow = min(minRow, row)
                    maxRow = max(maxRow, row)
                }
            }
        }
        guard maxCol >= minCol, maxRow >= minRow else { return nil }

        let scaleX = Double(width) / region.size.width
        let scaleY = Double(height) / region.size.height
        let left = region.minX + Double(minCol) / scaleX
        let right = region.minX + Double(maxCol + 1) / scaleX
        let top = region.maxY - Double(minRow) / scaleY
        let bottom = region.maxY - Double(maxRow + 1) / scaleY
        let result = Rect2D(x: left, y: bottom, width: right - left, height: top - bottom)
        return result.isNonEmpty ? result : nil
    }
}

struct RectangleAnalysis: Equatable {
    var displayID: String
    /// Display-local bounds of the resulting rectangle.
    var bounds: Rect2D
    /// nil when no content could be identified and the selection itself is used.
    var source: DetectionSource?
}

@MainActor
protocol RectangleSelectionAnalyzing {
    func analyze(
        selection: Rect2D,
        displays: [DisplayDescriptor],
        primaryDisplayBounds: Rect2D
    ) async -> RectangleAnalysis?
}

/// Accessibility first (elements sampled across the selection), screen-capture
/// content detection as the fallback, and the raw selection as a last resort.
@MainActor
final class RectangleSelectionService: RectangleSelectionAnalyzing {
    private let accessibilityDetector: AccessibilityElementDetector
    private let capturer: ScreenRegionCapturing
    private let contentDetector: ContentBoundsDetector
    private let columns = 5
    private let rows = 5

    convenience init() {
        self.init(
            accessibilityClient: SystemAccessibilityElementClient(),
            capturer: ScreenCaptureKitRegionCapturer(),
            contentDetector: ContentBoundsDetector()
        )
    }

    init(
        accessibilityClient: AccessibilityElementQuerying,
        capturer: ScreenRegionCapturing,
        contentDetector: ContentBoundsDetector
    ) {
        accessibilityDetector = AccessibilityElementDetector(client: accessibilityClient)
        self.capturer = capturer
        self.contentDetector = contentDetector
    }

    func analyze(
        selection: Rect2D,
        displays: [DisplayDescriptor],
        primaryDisplayBounds: Rect2D
    ) async -> RectangleAnalysis? {
        let center = Point2D(
            x: selection.minX + selection.size.width / 2,
            y: selection.minY + selection.size.height / 2
        )
        guard let display = displays.first(where: { $0.logicalBounds.contains(center) && $0.isValid })
            ?? displays.first(where: { $0.isValid && $0.logicalBounds.intersects(selection) }),
            let clipped = SelectionGeometry.clip(selection, to: display.logicalBounds)
        else {
            return nil
        }
        let localSelection = DisplayCoordinateMapper.globalToDisplayLocal(
            clipped,
            displayBounds: display.logicalBounds
        )

        var elements: [Rect2D] = []
        for point in SelectionGeometry.samplePoints(in: clipped, columns: columns, rows: rows) {
            if case .detected(let candidate) = accessibilityDetector.detect(
                at: point,
                displays: displays,
                primaryDisplayBounds: primaryDisplayBounds
            ), candidate.displayID == display.id {
                elements.append(candidate.bounds)
            }
        }
        if let enclosing = SelectionGeometry.enclosing(selection: localSelection, elements: elements) {
            return RectangleAnalysis(displayID: display.id, bounds: enclosing, source: .accessibility)
        }

        if let captured = try? await capturer.capture(region: localSelection, on: display),
            let content = contentDetector.bounds(in: captured)
        {
            return RectangleAnalysis(displayID: display.id, bounds: content, source: .vision)
        }
        return RectangleAnalysis(displayID: display.id, bounds: localSelection, source: nil)
    }
}

@MainActor
protocol SelectionSurfacePresenting: AnyObject {
    var connectedDisplays: [DisplayDescriptor] { get }
    var primaryDisplayBounds: Rect2D? { get }
    func setSelectionRect(_ globalRect: Rect2D?)
}

/// Drives the temporary drag rectangle and, on release, creates the persistent rectangle.
@MainActor
final class RectangleSelectionController {
    static let minimumSelectionSize = 4.0

    private let coordinator: MeasurementCoordinator
    private let surface: SelectionSurfacePresenting
    private let analyzer: RectangleSelectionAnalyzing
    private var cancellables = Set<AnyCancellable>()
    private var analysisTask: Task<Void, Never>?

    init(
        coordinator: MeasurementCoordinator,
        surface: SelectionSurfacePresenting,
        analyzer: RectangleSelectionAnalyzing
    ) {
        self.coordinator = coordinator
        self.surface = surface
        self.analyzer = analyzer
    }

    func start() {
        guard cancellables.isEmpty else { return }
        coordinator.$mode
            .sink { [weak self] mode in
                guard let self else { return }
                if case .selecting(let start, let current) = mode {
                    surface.setSelectionRect(Self.rect(from: start, to: current))
                } else {
                    surface.setSelectionRect(nil)
                }
                if !mode.isActive { analysisTask?.cancel() }
            }
            .store(in: &cancellables)
        coordinator.commands
            .sink { [weak self] command in
                if case .selectRectangle(let selection) = command {
                    self?.finish(selection)
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        analysisTask?.cancel()
        cancellables.removeAll()
        surface.setSelectionRect(nil)
    }

    nonisolated static func rect(from a: Point2D, to b: Point2D) -> Rect2D {
        Rect2D(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func finish(_ selection: Rect2D) {
        guard selection.size.width >= Self.minimumSelectionSize,
            selection.size.height >= Self.minimumSelectionSize,
            let primary = surface.primaryDisplayBounds
        else {
            return
        }
        let displays = surface.connectedDisplays
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            guard let self else { return }
            let analysis = await analyzer.analyze(
                selection: selection,
                displays: displays,
                primaryDisplayBounds: primary
            )
            guard !Task.isCancelled, let analysis, coordinator.mode.isActive else { return }
            coordinator.addAnnotation(
                MeasurementAnnotation(displayID: analysis.displayID, geometry: .rectangle(analysis.bounds))
            )
        }
    }
}
