import AppKit
import ApplicationServices
import Combine
import Foundation

struct AccessibilityElementSnapshot: Equatable {
    var position: Point2D?
    var size: Size2D?
    var role: String?
}

@MainActor
protocol AccessibilityElementQuerying {
    var isTrusted: Bool { get }
    func element(at accessibilityPoint: Point2D) -> AccessibilityElementSnapshot?
}

@MainActor
final class SystemAccessibilityElementClient: AccessibilityElementQuerying {
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func element(at accessibilityPoint: Point2D) -> AccessibilityElementSnapshot? {
        guard accessibilityPoint.isFinite else { return nil }
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, 0.25)

        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(accessibilityPoint.x),
            Float(accessibilityPoint.y),
            &hitElement
        ) == .success,
        let hitElement
        else {
            return nil
        }

        let role = attribute(kAXRoleAttribute as CFString, from: hitElement) as? String
        let position = pointAttribute(kAXPositionAttribute as CFString, from: hitElement)
        let size = sizeAttribute(kAXSizeAttribute as CFString, from: hitElement)
        return AccessibilityElementSnapshot(position: position, size: size, role: role)
    }

    private func attribute(_ name: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func pointAttribute(_ name: CFString, from element: AXUIElement) -> Point2D? {
        guard let rawValue = attribute(name, from: element),
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let value = rawValue as! AXValue
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        let result = Point2D(x: Double(point.x), y: Double(point.y))
        return result.isFinite ? result : nil
    }

    private func sizeAttribute(_ name: CFString, from element: AXUIElement) -> Size2D? {
        guard let rawValue = attribute(name, from: element),
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let value = rawValue as! AXValue
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        let result = Size2D(width: Double(size.width), height: Double(size.height))
        return result.isFiniteAndNonnegative ? result : nil
    }
}

@MainActor
struct AccessibilityElementDetector {
    private static let rejectedRoles: Set<String> = [
        "AXApplication",
        "AXGroup",
        "AXLayoutArea",
        "AXScrollArea",
        "AXSplitGroup",
        "AXSystemWide",
        "AXUnknown",
        "AXWindow"
    ]

    private let client: AccessibilityElementQuerying
    private let pointerTolerance = 2.0
    private let maximumDisplayAreaFraction = 0.85

    init(client: AccessibilityElementQuerying) {
        self.client = client
    }

    func detect(
        at globalPointer: Point2D,
        displays: [DisplayDescriptor],
        primaryDisplayBounds: Rect2D
    ) -> ElementDetectionResult {
        guard client.isTrusted else {
            return .unavailable(.accessibilityPermissionDenied)
        }
        guard globalPointer.isFinite,
              primaryDisplayBounds.isNonEmpty,
              let display = displays.first(where: { $0.logicalBounds.contains(globalPointer) }),
              display.isValid
        else {
            return .unavailable(.noConfidentBoundary)
        }

        let accessibilityPoint = DisplayCoordinateMapper.appKitGlobalToAccessibility(
            globalPointer,
            primaryDisplayBounds: primaryDisplayBounds
        )
        guard let element = client.element(at: accessibilityPoint),
              let position = element.position,
              let size = element.size,
              let role = element.role?.trimmingCharacters(in: .whitespacesAndNewlines),
              !role.isEmpty
        else {
            return .unavailable(.accessibilityElementUnavailable)
        }

        let accessibilityBounds = Rect2D(
            x: position.x,
            y: position.y,
            width: size.width,
            height: size.height
        )
        guard accessibilityBounds.isNonEmpty else {
            return .unavailable(.invalidAccessibilityBounds)
        }

        let globalBounds = DisplayCoordinateMapper.accessibilityToAppKitGlobal(
            accessibilityBounds,
            primaryDisplayBounds: primaryDisplayBounds
        )
        let displayBounds = display.logicalBounds
        guard globalBounds.isNonEmpty,
              globalBounds.minX >= displayBounds.minX,
              globalBounds.minY >= displayBounds.minY,
              globalBounds.maxX <= displayBounds.maxX,
              globalBounds.maxY <= displayBounds.maxY
        else {
            return .unavailable(.invalidAccessibilityBounds)
        }
        guard contains(globalPointer, in: globalBounds, tolerance: pointerTolerance) else {
            return .unavailable(.noConfidentBoundary)
        }

        let areaFraction =
            (globalBounds.size.width * globalBounds.size.height)
            / (displayBounds.size.width * displayBounds.size.height)
        guard !Self.rejectedRoles.contains(role),
              areaFraction.isFinite,
              areaFraction < maximumDisplayAreaFraction
        else {
            return .unavailable(.noConfidentBoundary)
        }

        let localBounds = DisplayCoordinateMapper.globalToDisplayLocal(
            globalBounds,
            displayBounds: displayBounds
        )
        let candidate = DetectionCandidate(
            bounds: localBounds,
            source: .accessibility,
            confidence: 0.9,
            displayID: display.id,
            elementRole: role
        )
        guard candidate.isValid else {
            return .unavailable(.invalidAccessibilityBounds)
        }
        return .detected(candidate)
    }

    private func contains(_ point: Point2D, in rect: Rect2D, tolerance: Double) -> Bool {
        point.x >= rect.minX - tolerance
            && point.x <= rect.maxX + tolerance
            && point.y >= rect.minY - tolerance
            && point.y <= rect.maxY + tolerance
    }
}

@MainActor
final class AccessibilityPermissionManager: ObservableObject {
    static let shared = AccessibilityPermissionManager()

    @Published private(set) var isTrusted = false

    @discardableResult
    func refresh() -> Bool {
        isTrusted = AXIsProcessTrusted()
        return isTrusted
    }

    @discardableResult
    func requestPrompt() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        return isTrusted
    }
}
