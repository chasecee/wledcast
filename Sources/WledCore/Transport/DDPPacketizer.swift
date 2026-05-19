import Foundation

public struct DDPPacketizer: Sendable {
    public static let maxDataLength = 1200
    public static let destinationID: UInt8 = 1
    public static let port: UInt16 = 4048

    private(set) var sequenceID: UInt8 = 1

    public init() {}

    public mutating func packets(for rgbData: Data) -> [Data] {
        if rgbData.isEmpty { return [] }
        var packets: [Data] = []
        var offset = 0

        while offset < rgbData.count {
            let chunkLength = min(Self.maxDataLength, rgbData.count - offset)
            let isLast = (offset + chunkLength) >= rgbData.count
            let chunk = rgbData.subdata(in: offset..<(offset + chunkLength))
            packets.append(packet(data: chunk, dataOffset: offset, isLast: isLast))
            offset += chunkLength
        }

        sequenceID = (sequenceID + 1) % 16
        return packets
    }

    private func packet(data: Data, dataOffset: Int, isLast: Bool) -> Data {
        var header = Data(repeating: 0, count: 10)
        header[0] = 0b0100_0000 | (isLast ? 0b0000_0001 : 0)
        header[1] = sequenceID
        header[2] = 0x0B
        header[3] = Self.destinationID

        let offsetBE = UInt32(dataOffset).bigEndian
        withUnsafeBytes(of: offsetBE) { header.replaceSubrange(4...7, with: $0) }

        let lenBE = UInt16(data.count).bigEndian
        withUnsafeBytes(of: lenBE) { header.replaceSubrange(8...9, with: $0) }

        var packet = Data()
        packet.reserveCapacity(10 + data.count)
        packet.append(header)
        packet.append(data)
        return packet
    }
}
