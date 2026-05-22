import SwiftUI
import WledCore

private enum SettingsPaneHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SettingsPaneView: View {
    @EnvironmentObject private var model: AppModel
    let onHeightChange: (CGFloat) -> Void
    let minWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            LazyVGrid(
                columns: gridColumns(for: geo.size.width),
                alignment: .leading,
                spacing: 12
            ) {
                OutputSection()
                CaptureSection()
                if model.captureMode == .video {
                    VideoSourceSection()
                }
                FiltersSection()
            }
            .padding(12)
            .background(
                GeometryReader { inner in
                    Color.clear.preference(key: SettingsPaneHeightKey.self, value: inner.size.height)
                }
            )
        }
        .frame(minWidth: minWidth, alignment: .topLeading)
        .onPreferenceChange(SettingsPaneHeightKey.self) { height in
            onHeightChange(max(1, height))
        }
    }

    private func gridColumns(for width: CGFloat) -> [GridItem] {
        let count: Int
        if width >= 760 {
            count = 3
        } else if width >= 500 {
            count = 2
        } else {
            count = 1
        }
        return Array(
            repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
            count: count
        )
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        )
    }
}

private struct OutputSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SectionCard(title: "Output", systemImage: "antenna.radiowaves.left.and.right") {
            Picker("Mode", selection: Binding(
                get: { model.captureMode },
                set: { model.setCaptureMode($0) }
            )) {
                Text("Region").tag(CaptureMode.region)
                Text("Video").tag(CaptureMode.video)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("WLED host", selection: Binding(
                get: { model.selectedHost },
                set: { model.setHost($0) }
            )) {
                if model.hosts.isEmpty {
                    Text("No verified hosts").tag("")
                } else {
                    ForEach(model.hosts) { host in
                        Text("\(host.host)  \(host.resolution.width)x\(host.resolution.height)")
                            .tag(host.host)
                    }
                }
            }
        }
    }
}

private struct CaptureSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SectionCard(title: "Capture", systemImage: "viewfinder") {
            Stepper(value: Binding(
                get: { model.fps },
                set: { model.setFPS($0) }
            ), in: 1...120) {
                HStack {
                    Label("Frame Rate", systemImage: "speedometer")
                    Spacer()
                    Text("\(model.fps) fps")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Lock output ratio", isOn: Binding(
                get: { model.aspectLock },
                set: { model.setAspectLock($0) }
            ))

            Toggle("Show mosaic in overlay", isOn: Binding(
                get: { model.overlayMosaicEnabled },
                set: { model.setOverlayMosaicEnabled($0) }
            ))
        }
    }
}

private struct VideoSourceSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SectionCard(title: "Video Source", systemImage: "film") {
            HStack(spacing: 8) {
                TextField("YouTube URL", text: $model.youtubeURLInput)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                Button("Fetch") {
                    model.fetchYouTube()
                }
                .disabled(model.youtubeURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.fetchState == .running)
            }

            if case .failed(let message) = model.fetchState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if model.fetchState == .running {
                ProgressView()
                    .controlSize(.small)
            }

            Picker("Source", selection: Binding(
                get: { model.selectedVideo?.path ?? "" },
                set: { newPath in
                    let selected = model.videoLibrary.first(where: { $0.path == newPath })
                    model.setSelectedVideo(selected)
                }
            )) {
                Text("None").tag("")
                ForEach(model.videoLibrary, id: \.path) { video in
                    Text(video.lastPathComponent).tag(video.path)
                }
            }
            .labelsHidden()

            Toggle("Loop playback", isOn: Binding(
                get: { model.loopVideo },
                set: { model.setLoopVideo($0) }
            ))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Loop Range", systemImage: "timeline.selection")
                    Spacer()
                    Text(formatRange(model.loopRange))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LoopRangeSlider(
                    range: $model.loopRange,
                    onScrubBegin: { model.beginLoopScrub() },
                    onScrubChange: { ratio in model.scrubLoopRange(toRatio: ratio) },
                    onCommit: { model.commitLoopRange(model.loopRange) }
                )
            }

            Button("Refresh library") {
                model.refreshVideoLibrary()
            }
        }
    }

    private func formatRange(_ range: LoopRange) -> String {
        String(format: "%.0f%% – %.0f%%", range.start * 100, range.end * 100)
    }
}

private struct LoopRangeSlider: View {
    @Binding var range: LoopRange
    var onScrubBegin: () -> Void
    var onScrubChange: (Double) -> Void
    var onCommit: () -> Void

    @State private var activeHandle: Handle?

    private enum Handle { case start, end }
    private let thumbSize: CGFloat = 14
    private let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - thumbSize)
            let startX = CGFloat(range.start) * usable
            let endX = CGFloat(range.end) * usable
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.gray.opacity(0.3))
                    .frame(height: trackHeight)
                    .padding(.horizontal, thumbSize / 2)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, endX - startX), height: trackHeight)
                    .offset(x: startX + thumbSize / 2)
                thumb(at: startX)
                    .gesture(handleGesture(.start, usable: usable))
                thumb(at: endX)
                    .gesture(handleGesture(.end, usable: usable))
            }
            .frame(height: thumbSize)
        }
        .frame(height: thumbSize)
    }

    private func thumb(at x: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
            .frame(width: thumbSize, height: thumbSize)
            .offset(x: x)
    }

    private func handleGesture(_ handle: Handle, usable: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeHandle != handle {
                    activeHandle = handle
                    onScrubBegin()
                }
                let raw = max(0, min(usable, value.location.x - thumbSize / 2)) / usable
                var next = range
                switch handle {
                case .start:
                    next.start = min(max(0, raw), range.end - LoopRange.minSpan)
                    range = next
                    onScrubChange(next.start)
                case .end:
                    next.end = max(min(1, raw), range.start + LoopRange.minSpan)
                    range = next
                    onScrubChange(next.end)
                }
            }
            .onEnded { _ in
                activeHandle = nil
                onCommit()
            }
    }
}

private struct FiltersSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var saturation: Double = Double(FilterConfig.default.saturation)
    @State private var brightness: Double = Double(FilterConfig.default.brightness)
    @State private var contrast: Double = Double(FilterConfig.default.contrast)
    @State private var sharpen: Double = Double(FilterConfig.default.sharpen)
    @State private var balanceR: Double = Double(FilterConfig.default.balanceR)
    @State private var balanceG: Double = Double(FilterConfig.default.balanceG)
    @State private var balanceB: Double = Double(FilterConfig.default.balanceB)
    @State private var flickerFighter: Double = 0

    var body: some View {
        SectionCard(title: "Image", systemImage: "camera.filters") {
            slider("Saturation", systemImage: "drop", value: $saturation, range: 0...2)
            slider("Brightness", systemImage: "sun.max", value: $brightness, range: 0...2)
            slider("Contrast", systemImage: "circle.lefthalf.filled", value: $contrast, range: 0...2)
            slider("Sharpen", systemImage: "slider.horizontal.3", value: $sharpen, range: 0...2)
            slider("Balance R", systemImage: "r.square", value: $balanceR, range: 0...2)
            slider("Balance G", systemImage: "g.square", value: $balanceG, range: 0...2)
            slider("Balance B", systemImage: "b.square", value: $balanceB, range: 0...2)
            slider("Flicker", systemImage: "waveform.path.ecg", value: $flickerFighter, range: 0...1)
        }
        .onAppear {
            saturation = Double(model.filters.saturation)
            brightness = Double(model.filters.brightness)
            contrast = Double(model.filters.contrast)
            sharpen = Double(model.filters.sharpen)
            balanceR = Double(model.filters.balanceR)
            balanceG = Double(model.filters.balanceG)
            balanceB = Double(model.filters.balanceB)
            flickerFighter = model.flickerFighter
        }
        .onChange(of: saturation) { _, _ in applyFilters() }
        .onChange(of: brightness) { _, _ in applyFilters() }
        .onChange(of: contrast) { _, _ in applyFilters() }
        .onChange(of: sharpen) { _, _ in applyFilters() }
        .onChange(of: balanceR) { _, _ in applyFilters() }
        .onChange(of: balanceG) { _, _ in applyFilters() }
        .onChange(of: balanceB) { _, _ in applyFilters() }
        .onChange(of: flickerFighter) { _, value in model.setFlickerFighter(value) }
    }

    private func slider(
        _ title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .frame(width: 96, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .frame(width: 40, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func applyFilters() {
        model.setFilters(
            FilterConfig(
                sharpen: Float(sharpen),
                saturation: Float(saturation),
                brightness: Float(brightness),
                contrast: Float(contrast),
                balanceR: Float(balanceR),
                balanceG: Float(balanceG),
                balanceB: Float(balanceB)
            )
        )
    }
}
