import Foundation

enum DisplayCoordinateMapper {
    static func globalToDisplayLocal(_ point: Point2D, displayBounds: Rect2D) -> Point2D {
        Point2D(x: point.x - displayBounds.minX, y: point.y - displayBounds.minY)
    }

    static func displayLocalToGlobal(_ point: Point2D, displayBounds: Rect2D) -> Point2D {
        Point2D(x: point.x + displayBounds.minX, y: point.y + displayBounds.minY)
    }

    static func globalToDisplayLocal(_ rect: Rect2D, displayBounds: Rect2D) -> Rect2D {
        Rect2D(
            x: rect.minX - displayBounds.minX,
            y: rect.minY - displayBounds.minY,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    static func displayLocalToGlobal(_ rect: Rect2D, displayBounds: Rect2D) -> Rect2D {
        Rect2D(
            x: rect.minX + displayBounds.minX,
            y: rect.minY + displayBounds.minY,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    static func appKitGlobalToAccessibility(
        _ point: Point2D,
        primaryDisplayBounds: Rect2D
    ) -> Point2D {
        Point2D(x: point.x, y: primaryDisplayBounds.maxY - point.y)
    }

    static func accessibilityToAppKitGlobal(
        _ point: Point2D,
        primaryDisplayBounds: Rect2D
    ) -> Point2D {
        Point2D(x: point.x, y: primaryDisplayBounds.maxY - point.y)
    }

    static func accessibilityToAppKitGlobal(
        _ rect: Rect2D,
        primaryDisplayBounds: Rect2D
    ) -> Rect2D {
        Rect2D(
            x: rect.minX,
            y: primaryDisplayBounds.maxY - rect.maxY,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    static func displayLocalToCapturePixel(
        _ point: Point2D,
        logicalSize: Size2D,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Point2D? {
        guard point.isFinite,
              logicalSize.width.isFinite,
              logicalSize.height.isFinite,
              logicalSize.width > 0,
              logicalSize.height > 0,
              pixelWidth > 0,
              pixelHeight > 0,
              point.x >= 0,
              point.x <= logicalSize.width,
              point.y >= 0,
              point.y <= logicalSize.height
        else {
            return nil
        }

        let scaleX = Double(pixelWidth) / logicalSize.width
        let scaleY = Double(pixelHeight) / logicalSize.height
        return Point2D(
            x: point.x * scaleX,
            y: (logicalSize.height - point.y) * scaleY
        )
    }

    static func displayLocalToCapturePixel(
        _ rect: Rect2D,
        logicalSize: Size2D,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Rect2D? {
        guard rect.isNonEmpty,
              rect.minX >= 0,
              rect.minY >= 0,
              rect.maxX <= logicalSize.width,
              rect.maxY <= logicalSize.height,
              logicalSize.width > 0,
              logicalSize.height > 0,
              pixelWidth > 0,
              pixelHeight > 0
        else {
            return nil
        }

        let scaleX = Double(pixelWidth) / logicalSize.width
        let scaleY = Double(pixelHeight) / logicalSize.height
        return Rect2D(
            x: rect.minX * scaleX,
            y: (logicalSize.height - rect.maxY) * scaleY,
            width: rect.size.width * scaleX,
            height: rect.size.height * scaleY
        )
    }
}
