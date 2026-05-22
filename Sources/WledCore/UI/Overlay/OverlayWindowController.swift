import AppKit
import CoreImage
import CoreVideo
import Foundation
import SwiftUI
import VideoToolbox

public final class MosaicLayerView: NSView {
    public override var isFlipped: Bool { true }
    public override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .linear
        layer.contentsGravity = .resize
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        return layer
    }
}

public final class MosaicImageHolder {
    private weak var view: MosaicLayerView?
    private var pending: CGImage?

    public init() {}

    public func attach(_ view: MosaicLayerView) {
        self.view = view
        if let pending {
            view.layer?.contents = pending
            self.pending = nil
        }
    }

    public func set(_ image: CGImage?) {
        if Thread.isMainThread {
            applyOnMain(image)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyOnMain(image)
            }
        }
    }

    private func applyOnMain(_ image: CGImage?) {
        if let view {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.contents = image
            CATransaction.commit()
        } else {
            pending = image
        }
    }
}

struct MosaicImageView: NSViewRepresentable {
    let holder: MosaicImageHolder

    func makeNSView(context: Context) -> MosaicLayerView {
        let view = MosaicLayerView()
        view.wantsLayer = true
        holder.attach(view)
        return view
    }

    func updateNSView(_ nsView: MosaicLayerView, context: Context) {}
}

public final class OverlayWindowController: NSWindowController, ObservableObject {
    public var onChange: ((CaptureBox) -> Void)?
    public var onVideoCropChange: ((VideoCropBox) -> Void)?
    public var aspectLock = true
    public let mosaicHolder = MosaicImageHolder()
    public let previewHolder = MosaicImageHolder()
    @Published public var outputResolution = OutputResolution(width: 1, height: 1)
    @Published public var mosaicEnabled = false
    @Published public var mode: CaptureMode = .region
    @Published public private(set) var hasPreviewImage = false
    @Published public private(set) var videoCropBox: VideoCropBox = .full
    @Published public var loopScrubbing = false
    @Published public private(set) var captureBox: CaptureBox
    @Published private var settingsContent: AnyView = AnyView(EmptyView())
    private let ciContext = CIContext(options: nil)
    @Published public private(set) var videoAspectRatio: CGFloat?

    public var videoAspectRatioOrFallback: CGFloat {
        videoAspectRatio ?? CGFloat(outputResolution.width) / CGFloat(max(1, outputResolution.height))
    }
    private var dragOriginFrame: NSRect?
    private var dragOriginCaptureBox: CaptureBox?
    private var resizeOriginTopFrame: NSRect?
    private var resizeOriginCaptureBox: CaptureBox?
    private var dragOriginMouse: NSPoint?
    private var monitor: Any?
    private var settingsHeight: CGFloat = 320
    private var minimumSettingsWidth: CGFloat = 360
    private let minimumTopSide: CGFloat = 32

    public var captureWindowID: CGWindowID? {
        guard let number = window?.windowNumber, number > 0 else { return nil }
        return CGWindowID(number)
    }

    public init(captureBox: CaptureBox, windowFrame: NSRect? = nil) {
        let initialScreen = NSScreen.main ?? NSScreen.screens.first!
        self.captureBox = captureBox
        let initialFrame = windowFrame ?? Self.defaultWindowFrame(on: initialScreen, settingsHeight: settingsHeight)
        let window = OverlayWindow(contentRect: initialFrame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "WledCast"
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.level = .normal
        window.hasShadow = true
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.isMovableByWindowBackground = false
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: UnifiedOverlayRoot(controller: self))
        updateWindowMinimums()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func setMode(_ mode: CaptureMode) {
        self.mode = mode
        if mode == .video {
            enforceVideoAspectOnTopRegion()
        }
    }
    public func setVideoCrop(_ crop: VideoCropBox) { videoCropBox = normalize(crop) }
    public func setSettingsContent(_ content: AnyView) { settingsContent = content }
    public func setSettingsHeight(_ height: CGFloat) {
        let resolved = max(1, height)
        guard abs(resolved - settingsHeight) > 0.5 else { return }
        guard let window else {
            settingsHeight = resolved
            return
        }
        let topFrame = Self.topRegionFrame(windowFrame: window.frame, settingsHeight: settingsHeight)
        settingsHeight = resolved
        updateWindowMinimums()
        applyWindowFrame(Self.windowFrame(topRegionFrame: topFrame, settingsHeight: settingsHeight))
    }

    public func setMinimumSettingsWidth(_ width: CGFloat) {
        minimumSettingsWidth = max(minimumTopSide, width)
        updateWindowMinimums()
    }

    public func setPreviewImage(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        previewHolder.set(cg)
        let width = image.size.width
        let height = image.size.height
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPreviewImage = true
            guard width > 0, height > 0 else { return }
            let nextAspect = max(0.0001, width / height)
            let previousAspect = self.videoAspectRatio
            self.videoAspectRatio = nextAspect
            if self.mode == .video, previousAspect == nil || abs((previousAspect ?? nextAspect) - nextAspect) > 0.05 {
                self.enforceVideoAspectOnTopRegion()
            }
        }
    }

    public func setPreviewBuffer(_ pixelBuffer: CVPixelBuffer) {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard let cg = createCGImage(from: pixelBuffer) else { return }
        previewHolder.set(cg)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPreviewImage = true
            guard self.mode == .video, width > 0, height > 0 else { return }
            let nextAspect = max(0.0001, width / height)
            let previousAspect = self.videoAspectRatio
            self.videoAspectRatio = nextAspect
            if previousAspect == nil || abs((previousAspect ?? nextAspect) - nextAspect) > 0.05 {
                self.enforceVideoAspectOnTopRegion()
            }
        }
    }

    private func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let maxEdge = max(width, height)
        if maxEdge <= 320 {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
            return image
        }
        let scale = 320.0 / Double(maxEdge)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(image, from: image.extent)
    }

    public func show() {
        recoverIfOffscreen()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startKeyMonitor()
    }

    public func hide() {
        stopKeyMonitor()
        window?.orderOut(nil)
    }

    public func nudge(dx: CGFloat, dy: CGFloat) {
        if mode == .region {
            nudgeCaptureBox(dx: dx, dy: dy)
            return
        }
        guard let window else { return }
        var frame = window.frame
        frame.origin.x += dx
        frame.origin.y += dy
        applyWindowFrame(frame)
    }

    public func startDrag() {
        guard dragOriginMouse == nil else { return }
        if mode == .region {
            guard dragOriginCaptureBox == nil else { return }
            dragOriginCaptureBox = captureBox
            dragOriginMouse = NSEvent.mouseLocation
            return
        }
        guard dragOriginFrame == nil, let window else { return }
        dragOriginFrame = window.frame
        dragOriginMouse = NSEvent.mouseLocation
    }

    public func move() {
        if mode == .region {
            moveCaptureBox()
            return
        }
        guard let start = dragOriginFrame, let startMouse = dragOriginMouse else { return }
        let currentMouse = NSEvent.mouseLocation
        var frame = start
        frame.origin.x += currentMouse.x - startMouse.x
        frame.origin.y += currentMouse.y - startMouse.y
        applyWindowFrame(frame)
    }

    public func startResize() {
        guard dragOriginMouse == nil else { return }
        if mode == .region {
            guard resizeOriginCaptureBox == nil else { return }
            resizeOriginCaptureBox = captureBox
            dragOriginMouse = NSEvent.mouseLocation
            return
        }
        guard resizeOriginTopFrame == nil, let window else { return }
        resizeOriginTopFrame = Self.topRegionFrame(windowFrame: window.frame, settingsHeight: settingsHeight)
        dragOriginMouse = NSEvent.mouseLocation
    }

    public func resize(handle: OverlayHandle) {
        if mode == .region {
            resizeCaptureBox(handle: handle)
            return
        }
        guard let start = resizeOriginTopFrame, let startMouse = dragOriginMouse else { return }
        let currentMouse = NSEvent.mouseLocation
        let dx = currentMouse.x - startMouse.x
        let dy = currentMouse.y - startMouse.y
        var topFrame = start
        switch handle {
        case .topLeft:
            topFrame.origin.x += dx; topFrame.size.width -= dx; topFrame.size.height += dy
        case .top:
            topFrame.size.height += dy
        case .topRight:
            topFrame.size.width += dx; topFrame.size.height += dy
        case .right:
            topFrame.size.width += dx
        case .bottomRight:
            topFrame.size.width += dx; topFrame.origin.y += dy; topFrame.size.height -= dy
        case .bottom:
            topFrame.origin.y += dy; topFrame.size.height -= dy
        case .bottomLeft:
            topFrame.origin.x += dx; topFrame.size.width -= dx; topFrame.origin.y += dy; topFrame.size.height -= dy
        case .left:
            topFrame.origin.x += dx; topFrame.size.width -= dx
        }
        if let ratio = aspectRatioForCurrentMode() {
            let widthDominant = abs(dx) >= abs(dy)
            if widthDominant {
                let newHeight = max(minimumTopSide, topFrame.width / ratio)
                let delta = topFrame.height - newHeight
                topFrame.size.height = newHeight
                if handle == .bottom || handle == .bottomLeft || handle == .bottomRight { topFrame.origin.y += delta }
            } else {
                let newWidth = max(minimumTopSide, topFrame.height * ratio)
                let delta = topFrame.width - newWidth
                topFrame.size.width = newWidth
                if handle == .left || handle == .topLeft || handle == .bottomLeft { topFrame.origin.x += delta }
            }
        }
        topFrame.size.width = max(minimumSettingsWidth, topFrame.size.width)
        topFrame.size.height = max(minimumTopSide, topFrame.size.height)
        applyTopFrame(topFrame)
    }

    public func endDrag() {
        dragOriginFrame = nil
        dragOriginCaptureBox = nil
        resizeOriginTopFrame = nil
        resizeOriginCaptureBox = nil
        dragOriginMouse = nil
    }

    public func updateVideoCrop(_ box: VideoCropBox) {
        videoCropBox = normalize(box)
        onVideoCropChange?(videoCropBox)
    }

    private func normalize(_ box: VideoCropBox) -> VideoCropBox {
        let x = min(1, max(0, box.x))
        let y = min(1, max(0, box.y))
        let width = min(1 - x, max(0.01, box.width))
        let height = min(1 - y, max(0.01, box.height))
        return VideoCropBox(x: x, y: y, width: width, height: height)
    }

    private func aspectRatioForCurrentMode() -> CGFloat? {
        if mode == .video, let videoAspectRatio {
            return max(0.0001, videoAspectRatio)
        }
        guard aspectLock, outputResolution.height > 0 else { return nil }
        return CGFloat(outputResolution.width) / CGFloat(outputResolution.height)
    }

    private func enforceVideoAspectOnTopRegion() {
        guard mode == .video, let ratio = videoAspectRatio, let window else { return }
        var topFrame = Self.topRegionFrame(windowFrame: window.frame, settingsHeight: settingsHeight)
        let centerY = topFrame.midY
        topFrame.size.width = max(minimumSettingsWidth, topFrame.width)
        topFrame.size.height = max(minimumTopSide, topFrame.width / ratio)
        topFrame.origin.y = centerY - (topFrame.height / 2)
        applyTopFrame(topFrame)
    }

    private func applyTopFrame(_ topFrame: NSRect) {
        applyWindowFrame(Self.windowFrame(topRegionFrame: topFrame, settingsHeight: settingsHeight))
    }

    private func applyWindowFrame(_ frame: NSRect) {
        let clamped = clampToScreen(frame)
        window?.setFrame(clamped, display: true)
    }

    private func moveCaptureBox() {
        guard let start = dragOriginCaptureBox,
              let startMouse = dragOriginMouse,
              let screen = NSScreen.screen(for: start.displayID) ?? NSScreen.main else { return }
        let currentMouse = NSEvent.mouseLocation
        var frame = start.nsRect(on: screen)
        frame.origin.x += currentMouse.x - startMouse.x
        frame.origin.y += currentMouse.y - startMouse.y
        applyCaptureBox(CaptureBox(nsFrame: frame, screen: screen))
    }

    private func nudgeCaptureBox(dx: CGFloat, dy: CGFloat) {
        guard let screen = NSScreen.screen(for: captureBox.displayID) ?? NSScreen.main else { return }
        var frame = captureBox.nsRect(on: screen)
        frame.origin.x += dx
        frame.origin.y += dy
        applyCaptureBox(CaptureBox(nsFrame: frame, screen: screen))
    }

    private func resizeCaptureBox(handle: OverlayHandle) {
        guard let start = resizeOriginCaptureBox,
              let startMouse = dragOriginMouse,
              let screen = NSScreen.screen(for: start.displayID) ?? NSScreen.main else { return }
        let currentMouse = NSEvent.mouseLocation
        let dx = currentMouse.x - startMouse.x
        let dy = currentMouse.y - startMouse.y
        var topFrame = start.nsRect(on: screen)
        switch handle {
        case .topLeft:
            topFrame.origin.x += dx; topFrame.size.width -= dx; topFrame.size.height += dy
        case .top:
            topFrame.size.height += dy
        case .topRight:
            topFrame.size.width += dx; topFrame.size.height += dy
        case .right:
            topFrame.size.width += dx
        case .bottomRight:
            topFrame.size.width += dx; topFrame.origin.y += dy; topFrame.size.height -= dy
        case .bottom:
            topFrame.origin.y += dy; topFrame.size.height -= dy
        case .bottomLeft:
            topFrame.origin.x += dx; topFrame.size.width -= dx; topFrame.origin.y += dy; topFrame.size.height -= dy
        case .left:
            topFrame.origin.x += dx; topFrame.size.width -= dx
        }
        if let ratio = aspectRatioForCurrentMode() {
            let widthDominant = abs(dx) >= abs(dy)
            if widthDominant {
                let newHeight = max(minimumTopSide, topFrame.width / ratio)
                let delta = topFrame.height - newHeight
                topFrame.size.height = newHeight
                if handle == .bottom || handle == .bottomLeft || handle == .bottomRight { topFrame.origin.y += delta }
            } else {
                let newWidth = max(minimumTopSide, topFrame.height * ratio)
                let delta = topFrame.width - newWidth
                topFrame.size.width = newWidth
                if handle == .left || handle == .topLeft || handle == .bottomLeft { topFrame.origin.x += delta }
            }
        }
        topFrame.size.width = max(minimumTopSide, topFrame.size.width)
        topFrame.size.height = max(minimumTopSide, topFrame.size.height)
        applyCaptureBox(CaptureBox(nsFrame: topFrame, screen: screen))
    }

    private func applyCaptureBox(_ box: CaptureBox) {
        guard let screen = NSScreen.screen(for: box.displayID) ?? NSScreen.main else { return }
        var frame = box.nsRect(on: screen)
        frame = clampTopFrameToScreen(frame, on: screen)
        let clamped = CaptureBox(nsFrame: frame, screen: screen)
        captureBox = clamped
        onChange?(clamped)
    }

    private func clampTopFrameToScreen(_ frame: NSRect, on screen: NSScreen) -> NSRect {
        let bounds = screen.frame
        var out = frame
        out.size.width = min(max(minimumTopSide, out.width), bounds.width)
        out.size.height = min(max(minimumTopSide, out.height), bounds.height)
        if out.minX < bounds.minX { out.origin.x = bounds.minX }
        if out.minY < bounds.minY { out.origin.y = bounds.minY }
        if out.maxX > bounds.maxX { out.origin.x = bounds.maxX - out.width }
        if out.maxY > bounds.maxY { out.origin.y = bounds.maxY - out.height }
        return out
    }

    private func startKeyMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: self.nudge(dx: -step, dy: 0); return nil
            case 124: self.nudge(dx: step, dy: 0); return nil
            case 125: self.nudge(dx: 0, dy: -step); return nil
            case 126: self.nudge(dx: 0, dy: step); return nil
            default: return event
            }
        }
    }

    private func stopKeyMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func recoverIfOffscreen() {
        guard let window else { return }
        let frame = window.frame
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            let clamped = clampToScreen(frame)
            if clamped != frame {
                window.setFrame(clamped, display: true)
            }
            return
        }
        guard let target = NSScreen.main ?? NSScreen.screens.first else { return }
        let clamped = clampToScreen(Self.defaultWindowFrame(on: target, settingsHeight: settingsHeight))
        window.setFrame(clamped, display: true)
    }

    private func clampToScreen(_ frame: NSRect) -> NSRect {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main ?? NSScreen.screens.first else { return frame }
        let bounds = screen.visibleFrame
        var out = frame
        let minHeight = minimumTopSide + settingsHeight
        out.size.width = min(max(minimumSettingsWidth, out.width), bounds.width)
        out.size.height = min(max(minHeight, out.height), bounds.height)
        if out.minX < bounds.minX { out.origin.x = bounds.minX }
        if out.minY < bounds.minY { out.origin.y = bounds.minY }
        if out.maxX > bounds.maxX { out.origin.x = bounds.maxX - out.width }
        if out.maxY > bounds.maxY { out.origin.y = bounds.maxY - out.height }
        return out
    }

    private func updateWindowMinimums() {
        guard let window else { return }
        window.minSize = NSSize(width: minimumSettingsWidth, height: minimumTopSide + settingsHeight)
    }

    static func defaultWindowFrame(on screen: NSScreen, settingsHeight: CGFloat, width: CGFloat = 720, previewHeight: CGFloat = 400) -> NSRect {
        let visible = screen.visibleFrame
        let resolvedWidth = min(max(360, width), visible.width)
        let resolvedHeight = min(max(32 + settingsHeight, previewHeight + settingsHeight), visible.height)
        return NSRect(
            x: visible.minX + ((visible.width - resolvedWidth) / 2),
            y: visible.minY + ((visible.height - resolvedHeight) / 2),
            width: resolvedWidth,
            height: resolvedHeight
        )
    }

    static func topRegionFrame(windowFrame: CGRect, settingsHeight: CGFloat) -> CGRect {
        CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY + settingsHeight,
            width: windowFrame.width,
            height: max(1, windowFrame.height - settingsHeight)
        )
    }

    static func windowFrame(topRegionFrame: CGRect, settingsHeight: CGFloat) -> CGRect {
        CGRect(
            x: topRegionFrame.minX,
            y: topRegionFrame.minY - settingsHeight,
            width: topRegionFrame.width,
            height: topRegionFrame.height + settingsHeight
        )
    }

    static func minimumWindowSize(settingsHeight: CGFloat, minimumSettingsWidth: CGFloat, minimumTopSide: CGFloat = 32) -> CGSize {
        CGSize(width: max(minimumTopSide, minimumSettingsWidth), height: max(minimumTopSide, minimumTopSide + settingsHeight))
    }

    static func fittedSize(for aspect: CGFloat, starting size: CGSize, minimumWidth: CGFloat, minimumHeight: CGFloat) -> CGSize {
        var width = max(minimumWidth, size.width)
        var height = max(minimumHeight, size.height)
        if width / max(1, height) > aspect {
            width = max(minimumWidth, height * aspect)
        } else {
            height = max(minimumHeight, width / aspect)
        }
        return CGSize(width: width, height: height)
    }

    static func mosaicRect(
        mode: CaptureMode,
        topSize: CGSize,
        border: CGFloat,
        videoRect: CGRect,
        cropBox: VideoCropBox
    ) -> CGRect {
        if mode == .region {
            return CGRect(
                x: border,
                y: border,
                width: max(1, topSize.width - (border * 2)),
                height: max(1, topSize.height - (border * 2))
            )
        }
        return CGRect(
            x: videoRect.minX + (videoRect.width * cropBox.x),
            y: videoRect.minY + (videoRect.height * cropBox.y),
            width: videoRect.width * cropBox.width,
            height: videoRect.height * cropBox.height
        )
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension OverlayWindowController: NSWindowDelegate {
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

private extension NSRect {
    var rectArea: CGFloat { isNull ? 0 : width * height }
}

public enum OverlayHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

private enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

private struct UnifiedOverlayRoot: View {
    @ObservedObject var controller: OverlayWindowController

    var body: some View {
        GeometryReader { geo in
            let topHeight = max(32, geo.size.height - controller.settingsHeightValue)
            VStack(spacing: 0) {
                OverlayHUD(controller: controller)
                    .frame(width: geo.size.width, height: topHeight)
                Divider()
                controller.settingsContentView
                    .frame(width: geo.size.width, height: controller.settingsHeightValue, alignment: .topLeading)
                    .background(.regularMaterial)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct OverlayHUD: View {
    @ObservedObject var controller: OverlayWindowController
    private let border: CGFloat = 4
    private let dragRingThickness: CGFloat = 14
    private let handle: CGFloat = 14
    @State private var cropDragStart: CGRect?
    @State private var cropDragOrigin: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                contentLayer(in: geo.size)
                if controller.mode == .region {
                    Rectangle().stroke(.red.opacity(0.95), lineWidth: border).padding(border / 2)
                    RingMoveLayer(border: dragRingThickness).gesture(moveGesture)
                    handleLayer(in: geo.size)
                }
                if controller.mode == .video {
                    if !controller.loopScrubbing {
                        videoCropLayer(in: geo.size)
                    }
                    videoEdgeResizeLayer(in: geo.size)
                }
                sizeBadge
                    .padding(.top, 10)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(.clear).padding(border * 2).allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func videoEdgeResizeLayer(in size: CGSize) -> some View {
        let strip = edgeStrip
        return HStack(spacing: 0) {
            edgeHandle(width: strip).gesture(resizeGesture(for: .left))
            Spacer(minLength: 0)
            edgeHandle(width: strip).gesture(resizeGesture(for: .right))
        }
        .frame(width: size.width, height: size.height)
    }

    private func edgeHandle(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: width)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private var edgeStrip: CGFloat { 10 }

    @ViewBuilder
    private func contentLayer(in size: CGSize) -> some View {
        if controller.mode == .video {
            if controller.hasPreviewImage {
                MosaicImageView(holder: controller.previewHolder)
                    .aspectRatio(controller.videoAspectRatioOrFallback, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Rectangle().fill(Color.black.opacity(0.35))
            }
        } else if controller.mosaicEnabled {
            mosaicLayer(in: size)
        } else {
            regionPlaceholder(in: size)
        }
    }

    private func regionPlaceholder(in size: CGSize) -> some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.88))
            VStack(spacing: 6) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Region capture")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Drag edges to resize, ring to reposition on screen")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: min(size.width - 40, 280))
            }
        }
    }

    private func mosaicContent() -> some View {
        MosaicImageView(holder: controller.mosaicHolder)
    }

    private func mosaicLayer(in size: CGSize) -> some View {
        let inset = border
        let innerWidth = max(1, size.width - (inset * 2))
        let innerHeight = max(1, size.height - (inset * 2))
        return mosaicContent().frame(width: innerWidth, height: innerHeight).clipped().position(x: size.width / 2, y: size.height / 2).allowsHitTesting(false)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { _ in controller.startDrag(); controller.move() }
            .onEnded { _ in controller.endDrag() }
    }

    @ViewBuilder
    private func handleLayer(in size: CGSize) -> some View {
        ForEach(OverlayHandle.allCases, id: \.self) { handleType in
            Rectangle().fill(.white).frame(width: handle, height: handle).position(point(for: handleType, in: size)).gesture(resizeGesture(for: handleType))
        }
    }

    private func resizeGesture(for handleType: OverlayHandle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { _ in controller.startResize(); controller.resize(handle: handleType) }
            .onEnded { _ in controller.endDrag() }
    }

    @ViewBuilder
    private func videoCropLayer(in size: CGSize) -> some View {
        let videoRect = fittedVideoRect(in: size)
        let cropRect = cropRect(in: videoRect)
        ZStack {
            VideoOuterMoveLayer(size: size, excludedRect: cropRect)
                .gesture(moveGesture)
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: cropRect.width, height: cropRect.height)
                .contentShape(Rectangle())
                .position(x: cropRect.midX, y: cropRect.midY)
                .gesture(videoMoveGesture(videoRect: videoRect, cropRect: cropRect))
            if controller.mosaicEnabled {
                mosaicContent()
                    .frame(width: cropRect.width, height: cropRect.height)
                    .clipped()
                    .position(x: cropRect.midX, y: cropRect.midY)
                    .allowsHitTesting(false)
            }
            Rectangle()
                .stroke(Color.red.opacity(0.95), lineWidth: 3)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
                .allowsHitTesting(false)
            ForEach(CropHandle.allCases, id: \.self) { cropHandle in
                Rectangle().fill(.white).frame(width: 12, height: 12).position(point(for: cropHandle, in: cropRect)).gesture(videoResizeGesture(handle: cropHandle, videoRect: videoRect, cropRect: cropRect))
            }
        }
    }

    private func fittedVideoRect(in container: CGSize) -> CGRect {
        let imageAspect = controller.videoAspectRatioOrFallback
        guard imageAspect > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let containerAspect = max(0.0001, container.width / max(1, container.height))
        if imageAspect > containerAspect {
            let width = container.width
            let height = width / imageAspect
            return CGRect(x: 0, y: (container.height - height) / 2, width: width, height: height)
        }
        let height = container.height
        let width = height * imageAspect
        return CGRect(x: (container.width - width) / 2, y: 0, width: width, height: height)
    }

    private func cropRect(in videoRect: CGRect) -> CGRect {
        CGRect(x: videoRect.minX + (videoRect.width * controller.videoCropBox.x), y: videoRect.minY + (videoRect.height * controller.videoCropBox.y), width: videoRect.width * controller.videoCropBox.width, height: videoRect.height * controller.videoCropBox.height)
    }

    private func videoMoveGesture(videoRect: CGRect, cropRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if cropDragStart == nil { cropDragStart = cropRect; cropDragOrigin = value.startLocation }
                guard let start = cropDragStart, let origin = cropDragOrigin else { return }
                var moved = start.offsetBy(dx: value.location.x - origin.x, dy: value.location.y - origin.y)
                moved = clamp(rect: moved, in: videoRect)
                controller.updateVideoCrop(toNormalized(moved, videoRect: videoRect))
            }
            .onEnded { _ in cropDragStart = nil; cropDragOrigin = nil }
    }

    private func videoResizeGesture(handle: CropHandle, videoRect: CGRect, cropRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if cropDragStart == nil { cropDragStart = cropRect; cropDragOrigin = value.startLocation }
                guard let start = cropDragStart, let origin = cropDragOrigin else { return }
                var rect = resized(start: start, handle: handle, dx: value.location.x - origin.x, dy: value.location.y - origin.y)
                if controller.aspectLock, controller.outputResolution.height > 0 {
                    rect = applyAspectLock(rect: rect, handle: handle, in: videoRect)
                }
                rect = clampMinSize(rect: rect, minSide: 24)
                rect = clamp(rect: rect, in: videoRect)
                controller.updateVideoCrop(toNormalized(rect, videoRect: videoRect))
            }
            .onEnded { _ in cropDragStart = nil; cropDragOrigin = nil }
    }

    private func resized(start: CGRect, handle: CropHandle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var rect = start
        switch handle {
        case .topLeft: rect.origin.x += dx; rect.size.width -= dx; rect.origin.y += dy; rect.size.height -= dy
        case .top: rect.origin.y += dy; rect.size.height -= dy
        case .topRight: rect.size.width += dx; rect.origin.y += dy; rect.size.height -= dy
        case .right: rect.size.width += dx
        case .bottomRight: rect.size.width += dx; rect.size.height += dy
        case .bottom: rect.size.height += dy
        case .bottomLeft: rect.origin.x += dx; rect.size.width -= dx; rect.size.height += dy
        case .left: rect.origin.x += dx; rect.size.width -= dx
        }
        return rect
    }

    private func applyAspectLock(rect: CGRect, handle: CropHandle, in videoRect: CGRect) -> CGRect {
        var out = rect
        let ratio = CGFloat(controller.outputResolution.width) / CGFloat(controller.outputResolution.height)
        if out.width / max(1, out.height) > ratio {
            let newHeight = out.width / ratio
            let delta = newHeight - out.height
            out.size.height = newHeight
            if handle == .top || handle == .topLeft || handle == .topRight { out.origin.y -= delta }
        } else {
            let newWidth = out.height * ratio
            let delta = newWidth - out.width
            out.size.width = newWidth
            if handle == .left || handle == .topLeft || handle == .bottomLeft { out.origin.x -= delta }
        }
        return clamp(rect: out, in: videoRect)
    }

    private func clampMinSize(rect: CGRect, minSide: CGFloat) -> CGRect {
        var out = rect
        if out.width < minSide { out.size.width = minSide }
        if out.height < minSide { out.size.height = minSide }
        return out
    }

    private func clamp(rect: CGRect, in bounds: CGRect) -> CGRect {
        var out = rect
        if out.width > bounds.width { out.size.width = bounds.width }
        if out.height > bounds.height { out.size.height = bounds.height }
        if out.minX < bounds.minX { out.origin.x = bounds.minX }
        if out.minY < bounds.minY { out.origin.y = bounds.minY }
        if out.maxX > bounds.maxX { out.origin.x = bounds.maxX - out.width }
        if out.maxY > bounds.maxY { out.origin.y = bounds.maxY - out.height }
        return out
    }

    private func toNormalized(_ rect: CGRect, videoRect: CGRect) -> VideoCropBox {
        let x = (rect.minX - videoRect.minX) / max(1, videoRect.width)
        let y = (rect.minY - videoRect.minY) / max(1, videoRect.height)
        let width = rect.width / max(1, videoRect.width)
        let height = rect.height / max(1, videoRect.height)
        return VideoCropBox(x: x, y: y, width: width, height: height)
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

    private func point(for handle: CropHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private var sizeBadge: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(controller.captureBox.width)x\(controller.captureBox.height) -> \(controller.outputResolution.width)x\(controller.outputResolution.height)")
            if controller.mode == .region {
                Text("Screen position \(controller.captureBox.left), \(controller.captureBox.top)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct VideoOuterMoveLayer: View {
    let size: CGSize
    let excludedRect: CGRect

    var body: some View {
        ZStack {
            hitRect(CGRect(x: 0, y: 0, width: size.width, height: max(0, excludedRect.minY)))
            hitRect(CGRect(x: 0, y: excludedRect.maxY, width: size.width, height: max(0, size.height - excludedRect.maxY)))
            hitRect(CGRect(x: 0, y: excludedRect.minY, width: max(0, excludedRect.minX), height: excludedRect.height))
            hitRect(CGRect(x: excludedRect.maxX, y: excludedRect.minY, width: max(0, size.width - excludedRect.maxX), height: excludedRect.height))
        }
    }

    @ViewBuilder
    private func hitRect(_ rect: CGRect) -> some View {
        if rect.width > 0, rect.height > 0 {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }
}

private struct RingMoveLayer: View {
    let border: CGFloat
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Color.white.opacity(0.001)).frame(width: geo.size.width, height: border).position(x: geo.size.width / 2, y: border / 2).contentShape(Rectangle())
                Rectangle().fill(Color.white.opacity(0.001)).frame(width: geo.size.width, height: border).position(x: geo.size.width / 2, y: geo.size.height - border / 2).contentShape(Rectangle())
                Rectangle().fill(Color.white.opacity(0.001)).frame(width: border, height: geo.size.height).position(x: border / 2, y: geo.size.height / 2).contentShape(Rectangle())
                Rectangle().fill(Color.white.opacity(0.001)).frame(width: border, height: geo.size.height).position(x: geo.size.width - border / 2, y: geo.size.height / 2).contentShape(Rectangle())
            }
            .contentShape(Rectangle())
        }
    }
}

private extension OverlayWindowController {
    var settingsHeightValue: CGFloat { settingsHeight }
    var settingsContentView: AnyView { settingsContent }
}
