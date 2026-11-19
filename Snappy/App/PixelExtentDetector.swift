import CoreGraphics
import Foundation

/// Scans outward from the pointer in four directions until the pixel colour
/// changes sharply. The result is the horizontal and vertical extent of the
/// visually uniform area under the pointer, returned as the rectangle spanned
/// by those two extents. Works on any content, not only recognised elements.
struct PixelExtentDetector {
    /// Largest per-channel difference across a short edge transition (0...100)
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
