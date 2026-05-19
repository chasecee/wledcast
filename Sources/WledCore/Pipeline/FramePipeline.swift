import Foundation
import Accelerate

public enum FramePipeline {
    public static func process(
        frame: RGBFrame,
        output: OutputResolution,
        filters: FilterConfig
    ) -> RGBFrame {
        var resized = resizeIfNeeded(frame: frame, targetWidth: output.width, targetHeight: output.height)
        resized = applySaturation(frame: resized, saturation: filters.saturation)
        resized = applyBrightness(frame: resized, brightness: filters.brightness)
        resized = applyContrast(frame: resized, contrast: filters.contrast)
        resized = applySharpen(frame: resized, alpha: filters.sharpen)
        resized = applyBalance(frame: resized, r: filters.balanceR, g: filters.balanceG, b: filters.balanceB)
        return resized
    }

    private static func resizeIfNeeded(frame: RGBFrame, targetWidth: Int, targetHeight: Int) -> RGBFrame {
        if frame.width == targetWidth, frame.height == targetHeight {
            return frame
        }
        var targetPixels = [UInt8](repeating: 0, count: targetWidth * targetHeight * 3)
        for y in 0..<targetHeight {
            let sourceY = min(frame.height - 1, y * frame.height / targetHeight)
            for x in 0..<targetWidth {
                let sourceX = min(frame.width - 1, x * frame.width / targetWidth)
                let sourceIndex = (sourceY * frame.width + sourceX) * 3
                let targetIndex = (y * targetWidth + x) * 3
                targetPixels[targetIndex] = frame.pixels[sourceIndex]
                targetPixels[targetIndex + 1] = frame.pixels[sourceIndex + 1]
                targetPixels[targetIndex + 2] = frame.pixels[sourceIndex + 2]
            }
        }
        return RGBFrame(width: targetWidth, height: targetHeight, pixels: targetPixels)
    }

    private static func applyBrightness(frame: RGBFrame, brightness: Float) -> RGBFrame {
        mapChannels(frame: frame) { channel in
            var out = [Float](repeating: 0, count: channel.count)
            var scale = brightness
            vDSP_vsmul(channel, 1, &scale, &out, 1, vDSP_Length(channel.count))
            return out
        }
    }

    private static func applyContrast(frame: RGBFrame, contrast: Float) -> RGBFrame {
        mapChannels(frame: frame) { channel in
            var mean: Float = 0
            vDSP_meanv(channel, 1, &mean, vDSP_Length(channel.count))
            var centered = [Float](repeating: 0, count: channel.count)
            var offset = -mean
            vDSP_vsadd(channel, 1, &offset, &centered, 1, vDSP_Length(channel.count))
            var scaled = [Float](repeating: 0, count: channel.count)
            var alpha = contrast
            vDSP_vsmul(centered, 1, &alpha, &scaled, 1, vDSP_Length(channel.count))
            var restored = [Float](repeating: 0, count: channel.count)
            var addMean = mean
            vDSP_vsadd(scaled, 1, &addMean, &restored, 1, vDSP_Length(channel.count))
            return restored
        }
    }

    private static func applyBalance(frame: RGBFrame, r: Float, g: Float, b: Float) -> RGBFrame {
        mapChannels(frame: frame) { channel, index in
            let scale: Float = switch index {
            case 0: r
            case 1: g
            default: b
            }
            var out = [Float](repeating: 0, count: channel.count)
            var factor = scale
            vDSP_vsmul(channel, 1, &factor, &out, 1, vDSP_Length(channel.count))
            return out
        }
    }

    private static func applySaturation(frame: RGBFrame, saturation: Float) -> RGBFrame {
        var out = frame.pixels
        for i in stride(from: 0, to: out.count, by: 3) {
            let r = Float(out[i])
            let g = Float(out[i + 1])
            let b = Float(out[i + 2])
            let gray = (0.299 * r) + (0.587 * g) + (0.114 * b)
            out[i] = clip(gray + (r - gray) * saturation)
            out[i + 1] = clip(gray + (g - gray) * saturation)
            out[i + 2] = clip(gray + (b - gray) * saturation)
        }
        return RGBFrame(width: frame.width, height: frame.height, pixels: out)
    }

    private static func applySharpen(frame: RGBFrame, alpha: Float) -> RGBFrame {
        if alpha == 0 { return frame }
        var out = frame.pixels
        let width = frame.width
        let height = frame.height
        let kernelCenter = 1 + (4 * alpha)
        let kernelEdge = -alpha
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                for c in 0..<3 {
                    let center = sample(frame, x: x, y: y, c: c)
                    let top = sample(frame, x: x, y: y - 1, c: c)
                    let left = sample(frame, x: x - 1, y: y, c: c)
                    let right = sample(frame, x: x + 1, y: y, c: c)
                    let bottom = sample(frame, x: x, y: y + 1, c: c)
                    let value = (kernelCenter * center) + (kernelEdge * (top + left + right + bottom))
                    out[(y * width + x) * 3 + c] = clip(value)
                }
            }
        }
        return RGBFrame(width: width, height: height, pixels: out)
    }

    private static func mapChannels(frame: RGBFrame, transform: (_ channel: [Float]) -> [Float]) -> RGBFrame {
        mapChannels(frame: frame) { channel, _ in transform(channel) }
    }

    private static func mapChannels(frame: RGBFrame, transform: (_ channel: [Float], _ index: Int) -> [Float]) -> RGBFrame {
        let count = frame.width * frame.height
        var channels = [[Float]](
            repeating: [Float](repeating: 0, count: count),
            count: 3
        )
        for i in 0..<count {
            channels[0][i] = Float(frame.pixels[i * 3])
            channels[1][i] = Float(frame.pixels[i * 3 + 1])
            channels[2][i] = Float(frame.pixels[i * 3 + 2])
        }
        let r = transform(channels[0], 0)
        let g = transform(channels[1], 1)
        let b = transform(channels[2], 2)
        var pixels = [UInt8](repeating: 0, count: count * 3)
        for i in 0..<count {
            pixels[i * 3] = clip(r[i])
            pixels[i * 3 + 1] = clip(g[i])
            pixels[i * 3 + 2] = clip(b[i])
        }
        return RGBFrame(width: frame.width, height: frame.height, pixels: pixels)
    }

    private static func sample(_ frame: RGBFrame, x: Int, y: Int, c: Int) -> Float {
        Float(frame.pixels[(y * frame.width + x) * 3 + c])
    }

    private static func clip(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, Int(value.rounded()))))
    }
}
