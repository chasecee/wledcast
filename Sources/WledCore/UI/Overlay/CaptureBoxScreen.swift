import AppKit
import CoreGraphics
import Foundation

public extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }
}

public extension CaptureBox {
    init(nsFrame: NSRect, screen: NSScreen) {
        self.init(
            displayID: screen.displayID,
            left: Int((nsFrame.minX - screen.frame.minX).rounded()),
            top: Int((screen.frame.maxY - nsFrame.maxY).rounded()),
            width: Int(nsFrame.width.rounded()),
            height: Int(nsFrame.height.rounded())
        )
    }

    func nsRect(on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.minX + CGFloat(left),
            y: screen.frame.maxY - CGFloat(top + height),
            width: CGFloat(width),
            height: CGFloat(height)
        )
    }

    func windowRect(on screen: NSScreen, settingsHeight: CGFloat) -> NSRect {
        let topRect = nsRect(on: screen)
        return NSRect(
            x: topRect.minX,
            y: topRect.minY - settingsHeight,
            width: topRect.width,
            height: topRect.height + settingsHeight
        )
    }

    init(windowFrame: NSRect, settingsHeight: CGFloat, screen: NSScreen) {
        let topRect = NSRect(
            x: windowFrame.minX,
            y: windowFrame.minY + settingsHeight,
            width: windowFrame.width,
            height: max(1, windowFrame.height - settingsHeight)
        )
        self.init(nsFrame: topRect, screen: screen)
    }

    static func centered(on screen: NSScreen, size: CGFloat = 500) -> CaptureBox {
        let w = min(size, screen.frame.width)
        let h = min(size, screen.frame.height)
        return CaptureBox(
            displayID: screen.displayID,
            left: Int(((screen.frame.width - w) / 2).rounded()),
            top: Int(((screen.frame.height - h) / 2).rounded()),
            width: Int(w.rounded()),
            height: Int(h.rounded())
        )
    }
}
