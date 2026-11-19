import Foundation

/// A drag uses one overlay-free image, avoiding capture on every mouse event.
struct GuidelineSnapImage {
    let capture: CapturedDisplayRegion
    let pixels: [UInt8]

    init?(_ capture: CapturedDisplayRegion) {
        guard let pixels = PixelExtentDetector.rgbaPixels(of: capture.image) else { return nil }
        self.capture = capture
        self.pixels = pixels
    }

    struct Edge: Equatable {
        let position: Double
        let strength: Double
        var radius: Double { 3 + 11 * strength }
    }

    /// Finds sustained transitions near the grabbed part of the annotation.
    /// Contrast determines both attraction distance and the release distance.
    func edge(axis: AnnotationAxis, position: Double, pointer: Point2D,
              tolerance: Int, holding previous: Edge?) -> Edge? {
        let region = capture.displayLocalBounds
        guard region.contains(pointer), position.isFinite else { return nil }
        let width = capture.image.width, height = capture.image.height
        let sx = Double(width) / region.size.width, sy = Double(height) / region.size.height
        let vertical = axis == .vertical
        let scale = vertical ? sx : sy
        let center = vertical ? (position - region.minX) * sx : (region.maxY - position) * sy
        let along = vertical ? (region.maxY - pointer.y) * sy : (pointer.x - region.minX) * sx
        let alongScale = vertical ? sy : sx
        let limit = vertical ? width : height
        let alongLimit = vertical ? height : width
        guard limit > 1, alongLimit > 1 else { return nil }
        let lower = max(1, Int(floor(center - 22 * scale)))
        let upper = min(limit - 1, Int(ceil(center + 22 * scale)))
        guard lower <= upper else { return nil }
        func contrast(_ across: Int, _ sample: Int, _ span: Int) -> Int {
            let before = max(0, across - span)
            let after = min(limit - 1, across + span - 1)
            let a = vertical ? (sample * width + before) * 4 : (before * width + sample) * 4
            let b = vertical ? (sample * width + after) * 4 : (after * width + sample) * 4
            return (0..<3).map { abs(Int(pixels[a + $0]) - Int(pixels[b + $0])) }.max() ?? 0
        }
        var edges: [Edge] = []
        for across in lower...upper {
            var contrasts: [Int] = []
            for offset in stride(from: -24, through: 24, by: 2) {
                let sample = Int((along + Double(offset) * alongScale).rounded())
                guard sample >= 0, sample < alongLimit else { continue }
                contrasts.append(max(contrast(across, sample, 1),
                                     contrast(across, sample, max(1, Int(scale.rounded())))))
            }
            guard contrasts.count >= 5 else { continue }
            contrasts.sort()
            // A median rejects texture and isolated pixels along the candidate edge.
            let value = contrasts[contrasts.count / 2]
            guard value > tolerance else { continue }
            let coordinate = vertical ? region.minX + Double(across) / sx : region.maxY - Double(across) / sy
            let edge = Edge(position: coordinate, strength: min(1, Double(value) / 64))
            if let previous, abs(previous.position - coordinate) < 0.5 / scale,
               abs(position - coordinate) <= edge.radius * 1.5 {
                return edge
            }
            if abs(position - coordinate) <= edge.radius { edges.append(edge) }
        }
        return edges.min {
            let a = abs($0.position - position) / $0.radius - $0.strength * 0.2
            let b = abs($1.position - position) / $1.radius - $1.strength * 0.2
            return a < b
        }
    }
}
