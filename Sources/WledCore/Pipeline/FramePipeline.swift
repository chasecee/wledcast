import Accelerate
import Foundation

public final class FramePipeline {
    private let outputWidth: Int
    private let outputHeight: Int
    private let pixelCount: Int
    private let bgraStride: Int

    private let scaledBGRA: UnsafeMutablePointer<UInt8>
    private let rgbBuffer: UnsafeMutablePointer<UInt8>
    private let sharpenBuffer: UnsafeMutablePointer<UInt8>

    public init(output: OutputResolution) {
        self.outputWidth = max(1, output.width)
        self.outputHeight = max(1, output.height)
        self.pixelCount = outputWidth * outputHeight
        self.bgraStride = outputWidth * 4
        self.scaledBGRA = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount * 4)
        self.rgbBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount * 3)
        self.sharpenBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount * 3)
        scaledBGRA.initialize(repeating: 0, count: pixelCount * 4)
        rgbBuffer.initialize(repeating: 0, count: pixelCount * 3)
        sharpenBuffer.initialize(repeating: 0, count: pixelCount * 3)
    }

    deinit {
        scaledBGRA.deallocate()
        rgbBuffer.deallocate()
        sharpenBuffer.deallocate()
    }

    public func process(bgra source: vImage_Buffer, filters: FilterConfig) -> RGBFrame {
        var pixels = [UInt8]()
        process(bgra: source, filters: filters, rgbOut: &pixels)
        return RGBFrame(width: outputWidth, height: outputHeight, pixels: pixels)
    }

    public func process(bgra source: vImage_Buffer, filters: FilterConfig, rgbOut: inout [UInt8]) {
        scale(source: source)
        swizzleToRGB()
        applyColorFilters(filters)
        if filters.sharpen != 0 {
            applySharpen(alpha: filters.sharpen)
        }
        let byteCount = pixelCount * 3
        if rgbOut.count != byteCount {
            rgbOut = [UInt8](repeating: 0, count: byteCount)
        }
        rgbOut.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress else { return }
            memcpy(dstBase, rgbBuffer, byteCount)
        }
    }

    private func scale(source: vImage_Buffer) {
        var src = source
        var dst = vImage_Buffer(
            data: scaledBGRA,
            height: vImagePixelCount(outputHeight),
            width: vImagePixelCount(outputWidth),
            rowBytes: bgraStride
        )
        let ratioX = Double(src.width) / Double(outputWidth)
        let ratioY = Double(src.height) / Double(outputHeight)
        let ratio = max(ratioX, ratioY)
        var flags = vImage_Flags(kvImageEdgeExtend) | vImage_Flags(kvImageDoNotTile)
        if ratio > 2 {
            flags |= vImage_Flags(kvImageHighQualityResampling)
        }
        vImageScale_ARGB8888(&src, &dst, nil, flags)
    }

    private func swizzleToRGB() {
        var src = vImage_Buffer(
            data: scaledBGRA,
            height: vImagePixelCount(outputHeight),
            width: vImagePixelCount(outputWidth),
            rowBytes: bgraStride
        )
        var dst = vImage_Buffer(
            data: rgbBuffer,
            height: vImagePixelCount(outputHeight),
            width: vImagePixelCount(outputWidth),
            rowBytes: outputWidth * 3
        )
        vImageConvert_BGRA8888toRGB888(&src, &dst, vImage_Flags(kvImageDoNotTile))
    }

    private func applyColorFilters(_ filters: FilterConfig) {
        let s = filters.saturation
        let oneMinusS = 1 - s
        let satRR = s + oneMinusS * 0.299
        let satRG = oneMinusS * 0.587
        let satRB = oneMinusS * 0.114
        let satGR = oneMinusS * 0.299
        let satGG = s + oneMinusS * 0.587
        let satGB = oneMinusS * 0.114
        let satBR = oneMinusS * 0.299
        let satBG = oneMinusS * 0.587
        let satBB = s + oneMinusS * 0.114

        var sumR: UInt64 = 0
        var sumG: UInt64 = 0
        var sumB: UInt64 = 0
        for i in 0..<pixelCount {
            let p = i * 3
            sumR += UInt64(rgbBuffer[p])
            sumG += UInt64(rgbBuffer[p + 1])
            sumB += UInt64(rgbBuffer[p + 2])
        }
        let invN = 1 / Float(pixelCount)
        let meanR = Float(sumR) * invN
        let meanG = Float(sumG) * invN
        let meanB = Float(sumB) * invN
        let satMeanR = satRR * meanR + satRG * meanG + satRB * meanB
        let satMeanG = satGR * meanR + satGG * meanG + satGB * meanB
        let satMeanB = satBR * meanR + satBG * meanG + satBB * meanB

        let c = filters.contrast
        let oneMinusC = 1 - c
        let postR = filters.balanceR * filters.brightness
        let postG = filters.balanceG * filters.brightness
        let postB = filters.balanceB * filters.brightness

        let aRR = postR * c * satRR
        let aRG = postR * c * satRG
        let aRB = postR * c * satRB
        let aGR = postG * c * satGR
        let aGG = postG * c * satGG
        let aGB = postG * c * satGB
        let aBR = postB * c * satBR
        let aBG = postB * c * satBG
        let aBB = postB * c * satBB

        let biasR = postR * oneMinusC * satMeanR
        let biasG = postG * oneMinusC * satMeanG
        let biasB = postB * oneMinusC * satMeanB

        for i in 0..<pixelCount {
            let p = i * 3
            let r = Float(rgbBuffer[p])
            let g = Float(rgbBuffer[p + 1])
            let b = Float(rgbBuffer[p + 2])
            rgbBuffer[p] = clip(aRR * r + aRG * g + aRB * b + biasR)
            rgbBuffer[p + 1] = clip(aGR * r + aGG * g + aGB * b + biasG)
            rgbBuffer[p + 2] = clip(aBR * r + aBG * g + aBB * b + biasB)
        }
    }

    private func applySharpen(alpha: Float) {
        let kc = 1 + (4 * alpha)
        let ke = -alpha
        let width = outputWidth
        let height = outputHeight
        memcpy(sharpenBuffer, rgbBuffer, pixelCount * 3)
        for y in 0..<height {
            let yUp = max(0, y - 1)
            let yDn = min(height - 1, y + 1)
            for x in 0..<width {
                let xLf = max(0, x - 1)
                let xRt = min(width - 1, x + 1)
                let baseC = (y * width + x) * 3
                let baseU = (yUp * width + x) * 3
                let baseD = (yDn * width + x) * 3
                let baseL = (y * width + xLf) * 3
                let baseR = (y * width + xRt) * 3
                for c in 0..<3 {
                    let center = Float(sharpenBuffer[baseC + c])
                    let top = Float(sharpenBuffer[baseU + c])
                    let bot = Float(sharpenBuffer[baseD + c])
                    let lf = Float(sharpenBuffer[baseL + c])
                    let rt = Float(sharpenBuffer[baseR + c])
                    rgbBuffer[baseC + c] = clip(kc * center + ke * (top + bot + lf + rt))
                }
            }
        }
    }
}

@inline(__always)
private func clip(_ value: Float) -> UInt8 {
    if value <= 0 { return 0 }
    if value >= 255 { return 255 }
    return UInt8(value.rounded())
}
