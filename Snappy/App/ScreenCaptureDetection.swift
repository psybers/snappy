import AppKit
import Combine
import CoreGraphics
import ScreenCaptureKit
import Vision

struct CapturedDisplayRegion {
    let image: CGImage
    let displayID: String
    let displayLocalBounds: Rect2D

    /// Crop a full-display image using display-local, bottom-left coordinates.
    static func cropping(
        _ image: CGImage,
        to region: Rect2D,
        on display: DisplayDescriptor
    ) throws -> CapturedDisplayRegion {
        let scaleX = Double(image.width) / display.logicalBounds.size.width
        let scaleY = Double(image.height) / display.logicalBounds.size.height
        // CGImage cropping uses a top-left origin. Round out to whole pixels
        // and report the corresponding bounds so detection retains its scale.
        let crop = CGRect(
            x: region.minX * scaleX,
            y: (display.logicalBounds.size.height - region.maxY) * scaleY,
            width: region.size.width * scaleX,
            height: region.size.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isNull, !crop.isEmpty,
              let croppedImage = image.cropping(to: crop)
        else { throw ScreenCaptureError.captureReturnedNoImage }

        return CapturedDisplayRegion(
            image: croppedImage,
            displayID: display.id,
            displayLocalBounds: Rect2D(
                x: crop.minX / scaleX,
                y: display.logicalBounds.size.height - crop.maxY / scaleY,
                width: crop.width / scaleX,
                height: crop.height / scaleY
            )
        )
    }
}

@MainActor
protocol ScreenCaptureAuthorizationChecking {
    var isAuthorized: Bool { get }
    @discardableResult func refresh() -> Bool
    @discardableResult func requestPrompt() -> Bool
}

@MainActor
protocol ScreenRegionCapturing {
    func capture(region: Rect2D, on display: DisplayDescriptor) async throws -> CapturedDisplayRegion
}

@MainActor
protocol ElementDetecting {
    func detect(
        at globalPointer: Point2D,
        displays: [DisplayDescriptor],
        primaryDisplayBounds: Rect2D,
        now: Date
    ) async -> ElementDetectionResult
}

enum ScreenCaptureError: Error, Equatable {
    case permissionDenied
    case displayUnavailable
    case captureReturnedNoImage
}

@MainActor
final class ScreenRecordingPermissionManager: ObservableObject, ScreenCaptureAuthorizationChecking {
    static let shared = ScreenRecordingPermissionManager()

    @Published private(set) var isAuthorized = false

    @discardableResult
    func refresh() -> Bool {
        isAuthorized = CGPreflightScreenCaptureAccess()
        return isAuthorized
    }

    @discardableResult
    func requestPrompt() -> Bool {
        isAuthorized = CGRequestScreenCaptureAccess()
        return isAuthorized
    }
}

@MainActor
final class ScreenCaptureKitRegionCapturer: ScreenRegionCapturing {
    private let permissionManager: ScreenCaptureAuthorizationChecking
    private let captureDisplay: (UInt32) async throws -> CGImage

    convenience init() {
        self.init(permissionManager: ScreenRecordingPermissionManager.shared)
    }

    init(
        permissionManager: ScreenCaptureAuthorizationChecking,
        captureDisplay: @escaping (UInt32) async throws -> CGImage = { displayID in
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return try await DisplayManager.captureDisplayImage(displayID, from: content)
        }
    ) {
        self.permissionManager = permissionManager
        self.captureDisplay = captureDisplay
    }

    func capture(
        region: Rect2D,
        on display: DisplayDescriptor
    ) async throws -> CapturedDisplayRegion {
        guard display.isValid, region.isNonEmpty,
              region.minX >= 0,
              region.minY >= 0,
              region.maxX <= display.logicalBounds.size.width,
              region.maxY <= display.logicalBounds.size.height
        else {
            throw ScreenCaptureError.displayUnavailable
        }

        _ = permissionManager.refresh()
        // Preflight can remain false even when ScreenCaptureKit has access
        // (see ScreenAccessProbe). Let the capture API determine access instead
        // of silently disabling live measurements before attempting a capture.

        guard display.id.hasPrefix("cgdisplay-"),
              let cgDisplayID = UInt32(
                  display.id.dropFirst("cgdisplay-".count)
              )
        else {
            throw ScreenCaptureError.displayUnavailable
        }

        let image = try await captureDisplay(cgDisplayID)

        return try CapturedDisplayRegion.cropping(image, to: region, on: display)
    }
}

struct VisualBoundaryDetector {
    var minimumConfidence = 0.65
    var maximumDisplayAreaFraction = 0.85
    var minimumEdgeLengthInPoints = 8.0

    func detect(
        in capturedRegion: CapturedDisplayRegion,
        pointer: Point2D,
        display: DisplayDescriptor
    ) throws -> [DetectionCandidate] {
        guard capturedRegion.displayID == display.id,
              capturedRegion.displayLocalBounds.isNonEmpty,
              display.isValid,
              pointer.isFinite,
              capturedRegion.displayLocalBounds.contains(pointer),
              capturedRegion.image.width > 0,
              capturedRegion.image.height > 0
        else {
            return []
        }

        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = Float(minimumConfidence)
        request.minimumSize = 0.03
        request.minimumAspectRatio = 0.05
        request.maximumAspectRatio = 1
        request.maximumObservations = 32

        try VNImageRequestHandler(cgImage: capturedRegion.image).perform([request])

        let region = capturedRegion.displayLocalBounds
        let displayArea = display.logicalBounds.size.width * display.logicalBounds.size.height
        let candidates = (request.results ?? []).compactMap { observation -> DetectionCandidate? in
            let normalized = observation.boundingBox
            let bounds = Rect2D(
                x: region.minX + normalized.minX * region.size.width,
                y: region.minY + normalized.minY * region.size.height,
                width: normalized.width * region.size.width,
                height: normalized.height * region.size.height
            )
            let candidate = DetectionCandidate(
                bounds: bounds,
                source: .vision,
                confidence: Double(observation.confidence),
                displayID: display.id
            )
            let areaFraction =
                (bounds.size.width * bounds.size.height) / displayArea
            guard candidate.isValid,
                  candidate.confidence >= minimumConfidence,
                  bounds.size.width >= minimumEdgeLengthInPoints,
                  bounds.size.height >= minimumEdgeLengthInPoints,
                  region.contains(Point2D(x: bounds.minX, y: bounds.minY)),
                  region.contains(Point2D(x: bounds.maxX, y: bounds.maxY)),
                  bounds.contains(pointer),
                  areaFraction.isFinite,
                  areaFraction < maximumDisplayAreaFraction
            else {
                return nil
            }
            return candidate
        }

        return Self.ranked(candidates, containing: pointer)
    }

    static func ranked(
        _ candidates: [DetectionCandidate],
        containing pointer: Point2D
    ) -> [DetectionCandidate] {
        candidates
            .filter { $0.isValid && $0.bounds.contains(pointer) }
            .sorted {
                let firstArea = $0.bounds.size.width * $0.bounds.size.height
                let secondArea = $1.bounds.size.width * $1.bounds.size.height
                return firstArea == secondArea
                    ? $0.confidence > $1.confidence
                    : firstArea < secondArea
            }
    }
}

@MainActor
final class ElementDetectionService: ElementDetecting {
    private let accessibilityDetector: AccessibilityElementDetector
    private let screenCapturer: ScreenRegionCapturing
    private let visualDetector: VisualBoundaryDetector
    private let extentDetector: PixelExtentDetector?
    private let accessibilityFirst: Bool
    private let screenPermission: ScreenCaptureAuthorizationChecking
    private let minimumCaptureInterval: TimeInterval
    private let captureRegionSize: Size2D
    private var lastCaptureDate = Date.distantPast
    private var cache: CachedCapture?
    private var refreshTask: Task<Void, Never>?
    private let cacheMargin = 120.0
    private let cacheRefreshAge: TimeInterval = 1.0

    private struct CachedCapture {
        let captured: CapturedDisplayRegion
        let pixels: [UInt8]?
        let date: Date
    }

    /// The cached capture can serve a pointer that is comfortably inside it,
    /// which keeps per-move detection to a cheap pixel scan.
    private func usableCache(for display: DisplayDescriptor, pointer: Point2D) -> CachedCapture? {
        guard let cache, cache.captured.displayID == display.id else { return nil }
        let region = cache.captured.displayLocalBounds
        let size = display.logicalBounds.size
        let fitsX = (pointer.x - region.minX >= cacheMargin || region.minX <= 0)
            && (region.maxX - pointer.x >= cacheMargin || region.maxX >= size.width)
        let fitsY = (pointer.y - region.minY >= cacheMargin || region.minY <= 0)
            && (region.maxY - pointer.y >= cacheMargin || region.maxY >= size.height)
        return region.contains(pointer) && fitsX && fitsY ? cache : nil
    }

    private func refreshCache(around globalPointer: Point2D, on display: DisplayDescriptor) {
        guard refreshTask == nil else { return }
        let region = captureRegion(around: globalPointer, on: display)
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { refreshTask = nil }
            guard let captured = try? await screenCapturer.capture(region: region, on: display) else { return }
            cache = CachedCapture(
                captured: captured,
                pixels: extentDetector == nil ? nil : PixelExtentDetector.rgbaPixels(of: captured.image),
                date: Date()
            )
        }
    }

    convenience init() {
        self.init(
            accessibilityClient: SystemAccessibilityElementClient(),
            screenCapturer: ScreenCaptureKitRegionCapturer(),
            visualDetector: VisualBoundaryDetector(),
            screenPermission: ScreenRecordingPermissionManager.shared,
            minimumCaptureInterval: 0.12,
            captureRegionSize: Size2D(width: 1000, height: 700),
            extentDetector: PixelExtentDetector(),
            accessibilityFirst: false
        )
    }

    init(
        accessibilityClient: AccessibilityElementQuerying,
        screenCapturer: ScreenRegionCapturing,
        visualDetector: VisualBoundaryDetector,
        screenPermission: ScreenCaptureAuthorizationChecking,
        minimumCaptureInterval: TimeInterval,
        captureRegionSize: Size2D,
        extentDetector: PixelExtentDetector? = nil,
        accessibilityFirst: Bool = true
    ) {
        self.extentDetector = extentDetector
        self.accessibilityFirst = accessibilityFirst
        self.accessibilityDetector = AccessibilityElementDetector(client: accessibilityClient)
        self.screenCapturer = screenCapturer
        self.visualDetector = visualDetector
        self.screenPermission = screenPermission
        self.minimumCaptureInterval = minimumCaptureInterval
        self.captureRegionSize = captureRegionSize
    }

    func detect(
        at globalPointer: Point2D,
        displays: [DisplayDescriptor],
        primaryDisplayBounds: Rect2D,
        now: Date = Date()
    ) async -> ElementDetectionResult {
        if accessibilityFirst {
            let accessibilityResult = accessibilityDetector.detect(
                at: globalPointer,
                displays: displays,
                primaryDisplayBounds: primaryDisplayBounds
            )
            if case .detected = accessibilityResult {
                return accessibilityResult
            }
        }
        _ = screenPermission.refresh()
        guard let display = displays.first(where: { $0.logicalBounds.contains(globalPointer) }),
              display.isValid
        else {
            return .unavailable(.noConfidentBoundary)
        }
        let localPointer = DisplayCoordinateMapper.globalToDisplayLocal(
            globalPointer,
            displayBounds: display.logicalBounds
        )
        let captured: CapturedDisplayRegion
        var pixels: [UInt8]?
        if let cached = usableCache(for: display, pointer: localPointer) {
            captured = cached.captured
            pixels = cached.pixels
            if now.timeIntervalSince(cached.date) > cacheRefreshAge {
                refreshCache(around: globalPointer, on: display)
            }
        } else {
            guard now.timeIntervalSince(lastCaptureDate) >= minimumCaptureInterval else {
                return .unavailable(.captureThrottled)
            }
            lastCaptureDate = now

            let region = captureRegion(around: globalPointer, on: display)
            guard region.isNonEmpty else {
                return .unavailable(.noConfidentBoundary)
            }
            do {
                try Task.checkCancellation()
                captured = try await screenCapturer.capture(region: region, on: display)
                try Task.checkCancellation()
            } catch is CancellationError {
                return .unavailable(.detectionCancelled)
            } catch ScreenCaptureError.permissionDenied {
                return .unavailable(.screenCapturePermissionDenied)
            } catch {
                return .unavailable(
                    screenPermission.refresh()
                        ? .screenCaptureFailed
                        : .screenCapturePermissionDenied
                )
            }
            if extentDetector != nil {
                pixels = PixelExtentDetector.rgbaPixels(of: captured.image)
            }
            cache = CachedCapture(captured: captured, pixels: pixels, date: Date())
        }

        if let extentDetector {
            let pointer = DisplayCoordinateMapper.globalToDisplayLocal(
                globalPointer,
                displayBounds: display.logicalBounds
            )
            return extentDetector.detect(in: captured, pointer: pointer, display: display, pixels: pixels)
                .map(ElementDetectionResult.detected) ?? .unavailable(.noConfidentBoundary)
        }

        do {
            return try visualDetector.detect(
                in: captured,
                pointer: DisplayCoordinateMapper.globalToDisplayLocal(
                    globalPointer,
                    displayBounds: display.logicalBounds
                ),
                display: display
            )
            .first
            .map(ElementDetectionResult.detected)
            ?? .unavailable(.noConfidentBoundary)
        } catch {
            return .unavailable(.visionProcessingFailed)
        }
    }

    private func captureRegion(around globalPointer: Point2D, on display: DisplayDescriptor) -> Rect2D {
        // Extent measurements must reach real boundaries, never the edge of
        // a cursor-centred crop. The full display is captured by the backend
        // already; retain it for the cached pixel scans.
        if extentDetector != nil {
            return Rect2D(x: 0, y: 0,
                          width: display.logicalBounds.size.width,
                          height: display.logicalBounds.size.height)
        }
        let pointer = DisplayCoordinateMapper.globalToDisplayLocal(
            globalPointer,
            displayBounds: display.logicalBounds
        )
        let width = min(captureRegionSize.width, display.logicalBounds.size.width)
        let height = min(captureRegionSize.height, display.logicalBounds.size.height)
        let x = min(max(pointer.x - width / 2, 0), display.logicalBounds.size.width - width)
        let y = min(max(pointer.y - height / 2, 0), display.logicalBounds.size.height - height)
        return Rect2D(x: x, y: y, width: width, height: height)
    }
}

/// Scans outward from the pointer in four directions until the pixel colour
/// changes sharply. The result is the horizontal and vertical extent of the
/// visually uniform area under the pointer, returned as the rectangle spanned
/// by those two extents. Works on any content, not only recognised elements.
struct PixelExtentDetector {
    /// Largest per-channel difference across a short edge transition (0...255)
    /// that is still considered the same visual area.
    var edgeThreshold = 8

    func detect(
        in capturedRegion: CapturedDisplayRegion,
        pointer: Point2D,
        display: DisplayDescriptor,
        pixels precomputed: [UInt8]? = nil
    ) -> DetectionCandidate? {
        let region = capturedRegion.displayLocalBounds
        let image = capturedRegion.image
        guard capturedRegion.displayID == display.id,
              region.isNonEmpty,
              pointer.isFinite,
              region.contains(pointer),
              image.width > 0,
              image.height > 0,
              let pixels = precomputed ?? Self.rgbaPixels(of: image)
        else {
            return nil
        }

        let width = image.width
        let height = image.height
        let scaleX = Double(width) / region.size.width
        let scaleY = Double(height) / region.size.height
        let startX = min(max(Int((pointer.x - region.minX) * scaleX), 0), width - 1)
        let startRow = min(max(Int((region.maxY - pointer.y) * scaleY), 0), height - 1)

        func offset(_ x: Int, _ row: Int) -> Int { (row * width + x) * 4 }

        func differs(_ a: Int, _ b: Int) -> Bool {
            for channel in 0..<3 where abs(Int(pixels[a + channel]) - Int(pixels[b + channel])) > edgeThreshold {
                return true
            }
            return false
        }

        // Returns the number of pixels travelled before hitting an edge.
        func scan(dx: Int, dy: Int, limit: Int) -> Int {
            var travelled = 0
            var x = startX
            var row = startRow
            let transitionSpan = max(2, Int(((dx == 0 ? scaleY : scaleX) * 2).rounded()))
            while travelled < limit {
                x += dx
                row += dy
                let current = offset(x, row)
                // Antialiasing can spread a clear edge over several pixels,
                // with every individual step below the contrast threshold.
                for distance in 1...min(transitionSpan, travelled + 1) {
                    let previousX = x - dx * distance
                    let previousRow = row - dy * distance
                    guard differs(offset(previousX, previousRow), current) else { continue }
                    // Confirm along the edge, rather than through it: a
                    // one-pixel border is a valid boundary. Neighbouring
                    // scanlines reject isolated pixel noise.
                    let spacing = max(1, Int((dx == 0 ? scaleX : scaleY).rounded()))
                    var support = 1
                    for side in [-1, 1] {
                        let shiftX = dy == 0 ? 0 : side * spacing
                        let shiftY = dx == 0 ? 0 : side * spacing
                        let priorX = previousX + shiftX
                        let priorRow = previousRow + shiftY
                        let nextX = x + shiftX
                        let nextRow = row + shiftY
                        guard priorX >= 0, priorX < width, priorRow >= 0, priorRow < height,
                              nextX >= 0, nextX < width, nextRow >= 0, nextRow < height
                        else { continue }
                        if differs(offset(priorX, priorRow), offset(nextX, nextRow)) {
                            support += 1
                        }
                    }
                    if support >= 2 {
                        // Stop at the beginning of the softened transition.
                        return max(0, travelled - distance + 1)
                    }
                }
                travelled += 1
            }
            return travelled
        }

        let left = scan(dx: -1, dy: 0, limit: startX)
        let right = scan(dx: 1, dy: 0, limit: width - 1 - startX)
        let up = scan(dx: 0, dy: -1, limit: startRow)
        let down = scan(dx: 0, dy: 1, limit: height - 1 - startRow)

        // Use pixel boundaries, not the fractional position inside the
        // pointer's pixel, to keep endpoints stable while the mouse moves.
        let minX = region.minX + Double(startX - left) / scaleX
        let maxX = region.minX + Double(startX + right + 1) / scaleX
        let minY = region.maxY - Double(startRow + down + 1) / scaleY
        let maxY = region.maxY - Double(startRow - up) / scaleY
        let bounds = Rect2D(
            x: max(minX, region.minX),
            y: max(minY, region.minY),
            width: min(maxX, region.maxX) - max(minX, region.minX),
            height: min(maxY, region.maxY) - max(minY, region.minY)
        )
        guard bounds.isNonEmpty else { return nil }
        return DetectionCandidate(
            bounds: bounds,
            source: .vision,
            confidence: 0.7,
            displayID: display.id
        )
    }

    static func rgbaPixels(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }
}
