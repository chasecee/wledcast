import Foundation
import XCTest
@testable import WledCore

final class WLEDCfgParserTests: XCTestCase {
    func testTargetFpsFromCfg() throws {
        let payload: [String: Any] = [
            "hw": [
                "led": [
                    "fps": 28,
                    "total": 256
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertEqual(WLEDCfgParser.parseTargetFps(from: data), 28)
    }

    func testMissingFpsReturnsNil() throws {
        let payload: [String: Any] = [
            "hw": [
                "led": [
                    "total": 256
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertNil(WLEDCfgParser.parseTargetFps(from: data))
    }

    func testResolveUsesCfgBeforeInfo() throws {
        let info: [String: Any] = ["leds": ["fps": 42, "matrix": ["w": 16, "h": 16]]]
        let cfg: [String: Any] = ["hw": ["led": ["fps": 28]]]
        let infoData = try JSONSerialization.data(withJSONObject: info)
        let cfgData = try JSONSerialization.data(withJSONObject: cfg)
        XCTAssertEqual(WLEDCfgParser.resolveTargetFps(infoData: infoData, cfgData: cfgData), 28)
    }

    func testResolveFallsBackToDefaultWhenCfgMissing() throws {
        let info: [String: Any] = ["leds": ["fps": 28, "matrix": ["w": 16, "h": 16]]]
        let infoData = try JSONSerialization.data(withJSONObject: info)
        XCTAssertEqual(WLEDCfgParser.resolveTargetFps(infoData: infoData, cfgData: nil), WLEDHost.defaultFps)
    }

    func testResolveIgnoresMeasuredInfoFpsWhenCfgPresentWithoutTarget() throws {
        let info: [String: Any] = ["leds": ["fps": 28, "matrix": ["w": 16, "h": 16]]]
        let cfg: [String: Any] = ["hw": ["led": ["total": 256]]]
        let infoData = try JSONSerialization.data(withJSONObject: info)
        let cfgData = try JSONSerialization.data(withJSONObject: cfg)
        XCTAssertEqual(WLEDCfgParser.resolveTargetFps(infoData: infoData, cfgData: cfgData), WLEDHost.defaultFps)
    }

    func testUnlimitedFpsIsZero() throws {
        let payload: [String: Any] = [
            "hw": [
                "led": [
                    "fps": 0
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertEqual(WLEDCfgParser.parseTargetFps(from: data), 0)
    }

    func testEffectiveFpsForUnlimited() {
        let host = WLEDHost(
            host: "test.local",
            resolution: OutputResolution(width: 16, height: 16),
            targetFps: 0
        )
        XCTAssertEqual(host.effectiveFps, WLEDHost.defaultFps)
    }

    func testPlaybackRateWhenOutputSlowerThanSource() {
        XCTAssertEqual(VideoAudioPlayer.playbackRate(sourceFps: 60, outputFps: 28), 28 / 60, accuracy: 0.001)
        XCTAssertEqual(VideoAudioPlayer.playbackRate(sourceFps: 24, outputFps: 28), 1)
    }
}
