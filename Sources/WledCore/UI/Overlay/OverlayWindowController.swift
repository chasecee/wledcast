import AppKit
import Foundation
import SwiftUI

public final class OverlayWindowController: NSWindowController, ObservableObject {
    public var onChange: ((CaptureBox) -> Void)?
    public var aspectLock = true
    @Published public var outputResolution = OutputResolution(width: 1, height: 1)

    public var captureWindowID: CGWindowID? {
        guard let number = window?.windowNumber, number > 0 else { return nil }
        return CGWindowID(number)
    }

    @Published public private(set) var captureBox: CaptureBox
    private var dragOriginFrame: NSRect?
    private var dragOriginMouse: NSPoint?
    private var monitor: Any?

    public init(captureBox: CaptureBox) {
        let initialScreen = NSScreen.screen(for: captureBox.displayID)
            ?? NSScreen.main
            ?? NSScreen.screens.first!
        let resolved: CaptureBox
        let initialFrame: NSRect
        if NSScreen.screen(for: captureBox.displayID) != nil {
            resolved = captureBox
            initialFrame = captureBox.nsRect(on: initialScreen)
        } else {
            resolved = CaptureBox.centered(on: initialScreen)
            initialFrame = resolved.nsRect(on: initialScreen)
        }
        self.captureBox = resolved
        let window = OverlayPanel(
            contentRect: initialFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = false
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let view = OverlayHUD(controller: self)
        window.contentView = NSHostingView(rootView: view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func show() {
        recoverIfOffscreen()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        startKeyMonitor()
    }

    public func hide() {
        stopKeyMonitor()
        window?.orderOut(nil)
    }

    public func nudge(dx: CGFloat, dy: CGFloat) {
        guard let window else { return }
        var frame = window.frame
        frame.origin.x += dx
        frame.origin.y += dy
        apply(frame)
    }

    public func startDrag() {
        guard dragOriginFrame == nil, let window else { return }
        dragOriginFrame = window.frame
        dragOriginMouse = NSEvent.mouseLocation
    }

    public func move() {
        guard let start = dragOriginFrame, let startMouse = dragOriginMouse else { return }
        let currentMouse = NSEvent.mouseLocation
        let dx = currentMouse.x - startMouse.x
        let dy = currentMouse.y - startMouse.y
        var frame = start
        frame.origin.x += dx
        frame.origin.y += dy
        apply(frame)
    }

    public func startResize() {
        guard dragOriginFrame == nil, let window else { return }
        dragOriginFrame = window.frame
        dragOriginMouse = NSEvent.mouseLocation
    }

    public func resize(handle: OverlayHandle) {
        guard let start = dragOriginFrame, let startMouse = dragOriginMouse else { return }
        let currentMouse = NSEvent.mouseLocation
        let dx = currentMouse.x - startMouse.x
        let dy = currentMouse.y - startMouse.y
        var frame = start
        let minSize: CGFloat = 32

        switch handle {
        case .topLeft:
            frame.origin.x += dx
            frame.size.width -= dx
            frame.size.height += dy
        case .top:
            frame.size.height += dy
        case .topRight:
            frame.size.width += dx
            frame.size.height += dy
        case .right:
            frame.size.width += dx
        case .bottomRight:
            frame.size.width += dx
            frame.origin.y += dy
            frame.size.height -= dy
        case .bottom:
            frame.origin.y += dy
            frame.size.height -= dy
        case .bottomLeft:
            frame.origin.x += dx
            frame.size.width -= dx
            frame.origin.y += dy
            frame.size.height -= dy
        case .left:
            frame.origin.x += dx
            frame.size.width -= dx
        }

        if aspectLock, outputResolution.height > 0 {
            let ratio = CGFloat(outputResolution.width) / CGFloat(outputResolution.height)
            let widthDominant = abs(dx) >= abs(dy)
            if widthDominant {
                let newHeight = max(minSize, frame.width / ratio)
                let delta = frame.height - newHeight
                frame.size.height = newHeight
                if handle == .bottom || handle == .bottomLeft || handle == .bottomRight {
                    frame.origin.y += delta
                }
            } else {
                let newWidth = max(minSize, frame.height * ratio)
                let delta = frame.width - newWidth
                frame.size.width = newWidth
                if handle == .left || handle == .topLeft || handle == .bottomLeft {
                    frame.origin.x += delta
                }
            }
        }

        frame.size.width = max(minSize, frame.size.width)
        frame.size.height = max(minSize, frame.size.height)
        apply(frame)
    }

    public func endDrag() {
        dragOriginFrame = nil
        dragOriginMouse = nil
    }

    private func apply(_ frame: NSRect) {
        let clamped = clampToScreen(frame)
        window?.setFrame(clamped, display: true)
        updateBox(from: clamped)
    }

    fileprivate func updateBox(from frame: NSRect) {
        let screen = NSScreen.screens.max {
            $0.frame.intersection(frame).rectArea < $1.frame.intersection(frame).rectArea
        } ?? NSScreen.main ?? NSScreen.screens.first!
        captureBox = CaptureBox(nsFrame: frame, screen: screen)
        onChange?(captureBox)
    }

    private func startKeyMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123:
                self.nudge(dx: -step, dy: 0)
                return nil
            case 124:
                self.nudge(dx: step, dy: 0)
                return nil
            case 125:
                self.nudge(dx: 0, dy: -step)
                return nil
            case 126:
                self.nudge(dx: 0, dy: step)
                return nil
            default:
                return event
            }
        }
    }

    private func stopKeyMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func recoverIfOffscreen() {
        guard let window else { return }
        let frame = window.frame
        let intersectsAny = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }

        if intersectsAny {
            let clamped = clampToScreen(frame)
            if clamped != frame {
                window.setFrame(clamped, display: true)
                updateBox(from: clamped)
            }
            return
        }

        guard let target = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = target.visibleFrame
        let width = min(max(32, frame.width), visible.width)
        let height = min(max(32, frame.height), visible.height)
        let centered = NSRect(
            x: visible.minX + ((visible.width - width) / 2),
            y: visible.minY + ((visible.height - height) / 2),
            width: width,
            height: height
        )
        let clamped = clampToScreen(centered)
        window.setFrame(clamped, display: true)
        updateBox(from: clamped)
    }

    private func clampToScreen(_ frame: NSRect) -> NSRect {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main ?? NSScreen.screens.first else {
            return frame
        }
        let bounds = screen.visibleFrame
        let minSize: CGFloat = 32

        var out = frame
        out.size.width = min(max(minSize, out.width), bounds.width)
        out.size.height = min(max(minSize, out.height), bounds.height)

        if out.minX < bounds.minX { out.origin.x = bounds.minX }
        if out.minY < bounds.minY { out.origin.y = bounds.minY }
        if out.maxX > bounds.maxX { out.origin.x = bounds.maxX - out.width }
        if out.maxY > bounds.maxY { out.origin.y = bounds.maxY - out.height }
        return out
    }
}

private final class OverlayPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private extension NSRect {
    var rectArea: CGFloat { isNull ? 0 : width * height }
}

public enum OverlayHandle: CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

private struct OverlayHUD: View {
    @ObservedObject var controller: OverlayWindowController
    private let border: CGFloat = 4
    private let dragRingThickness: CGFloat = 14
    private let handle: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .stroke(.red.opacity(0.95), lineWidth: border)
                    .padding(border / 2)
                RingMoveLayer(border: dragRingThickness)
                    .gesture(moveGesture)
                handleLayer(in: geo.size)
                sizeBadge
                    .padding(.top, 10)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle()
                    .fill(.clear)
                    .padding(border * 2)
                    .allowsHitTesting(false)
            }
        }
        .background(.clear)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { _ in
                controller.startDrag()
                controller.move()
            }
            .onEnded { _ in
                controller.endDrag()
            }
    }

    @ViewBuilder
    private func handleLayer(in size: CGSize) -> some View {
        ForEach(OverlayHandle.allCases, id: \.self) { handleType in
            Rectangle()
                .fill(.white)
                .frame(width: handle, height: handle)
                .position(point(for: handleType, in: size))
                .gesture(resizeGesture(for: handleType))
        }
    }

    private func resizeGesture(for handleType: OverlayHandle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { _ in
                controller.startResize()
                controller.resize(handle: handleType)
            }
            .onEnded { _ in
                controller.endDrag()
            }
    }

    private func point(for handleType: OverlayHandle, in size: CGSize) -> CGPoint {
        let inset = handle / 2
        switch handleType {
        case .topLeft: return CGPoint(x: inset, y: inset)
        case .top: return CGPoint(x: size.width / 2, y: inset)
        case .topRight: return CGPoint(x: size.width - inset, y: inset)
        case .right: return CGPoint(x: size.width - inset, y: size.height / 2)
        case .bottomRight: return CGPoint(x: size.width - inset, y: size.height - inset)
        case .bottom: return CGPoint(x: size.width / 2, y: size.height - inset)
        case .bottomLeft: return CGPoint(x: inset, y: size.height - inset)
        case .left: return CGPoint(x: inset, y: size.height / 2)
        }
    }

    private var sizeBadge: some View {
        Text("\(controller.captureBox.width)x\(controller.captureBox.height) -> \(controller.outputResolution.width)x\(controller.outputResolution.height)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct RingMoveLayer: View {
    let border: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: geo.size.width, height: border)
                    .position(x: geo.size.width / 2, y: border / 2)
                    .contentShape(Rectangle())
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: geo.size.width, height: border)
                    .position(x: geo.size.width / 2, y: geo.size.height - border / 2)
                    .contentShape(Rectangle())
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: border, height: geo.size.height)
                    .position(x: border / 2, y: geo.size.height / 2)
                    .contentShape(Rectangle())
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: border, height: geo.size.height)
                    .position(x: geo.size.width - border / 2, y: geo.size.height / 2)
                    .contentShape(Rectangle())
            }
            .contentShape(Rectangle())
        }
    }
}
