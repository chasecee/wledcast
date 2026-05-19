import Foundation
import XCTest
@testable import WledCore

final class DDPPacketizerTests: XCTestCase {
    func testDDPPacketizerMatchesFixtureHeaders() throws {
        let fixture = try FixtureLoader.loadJSON(name: "ddp_fixture")
        let inputLength = fixture["input_length"] as! Int
        let maxDataLen = fixture["max_data_len"] as! Int
        let packetsHex = fixture["packets"] as! [String]

        var payload = [UInt8]()
        payload.reserveCapacity(inputLength)
        for i in 0..<inputLength {
            payload.append(UInt8(i % 255))
        }

        var packetizer = DDPPacketizer()
        let packets = packetizer.packets(for: Data(payload))

        XCTAssertEqual(maxDataLen, DDPPacketizer.maxDataLength)
        XCTAssertEqual(packets.count, packetsHex.count)
        XCTAssertEqual(packets.first?.hexString, packetsHex.first)
        XCTAssertEqual(packets.last?.hexString, packetsHex.last)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
