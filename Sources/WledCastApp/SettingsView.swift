import SwiftUI
import WledCore

struct SettingsView: View {
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Capture") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Mode")
                            Spacer()
                            Picker("Capture Mode", selection: Binding(
                                get: { model.captureMode },
                                set: { model.setCaptureMode($0) }
                            )) {
                                ForEach(CaptureMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue.capitalized).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }
                        HStack {
                            Text("FPS")
                            Spacer()
                            Stepper(value: Binding(
                                get: { model.fps },
                                set: { model.setFPS($0) }
                            ), in: 1...120) {
                                Text("\(model.fps)")
                            }
                            .frame(width: 140)
                        }
                        Toggle("Lock aspect ratio", isOn: Binding(
                            get: { model.aspectLock },
                            set: { model.setAspectLock($0) }
                        ))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Transmit Preview") {
                    VStack(alignment: .leading, spacing: 8) {
                        let aspect: CGFloat = {
                            if let r = model.outputResolution, r.height > 0 {
                                return CGFloat(r.width) / CGFloat(r.height)
                            }
                            return 1
                        }()
                        if let image = model.txPreviewImage {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(aspect, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.15))
                                .aspectRatio(aspect, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .overlay(Text("No frame yet").foregroundStyle(.secondary))
                        }
                        Text(model.txPreviewInfo)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if !model.captureDiagnostics.isEmpty {
                            Text(model.captureDiagnostics)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Filters") {
                    VStack(alignment: .leading, spacing: 8) {
                        slider("Saturation", value: $saturation, range: 0...2)
                        slider("Brightness", value: $brightness, range: 0...2)
                        slider("Contrast", value: $contrast, range: 0...2)
                        slider("Sharpen", value: $sharpen, range: 0...2)
                        slider("Balance R", value: $balanceR, range: 0...2)
                        slider("Balance G", value: $balanceG, range: 0...2)
                        slider("Balance B", value: $balanceB, range: 0...2)
                        slider("Flicker", value: $flickerFighter, range: 0...1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: 420, idealHeight: 560)
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

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
                .frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .frame(width: 40, alignment: .trailing)
                .monospacedDigit()
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
