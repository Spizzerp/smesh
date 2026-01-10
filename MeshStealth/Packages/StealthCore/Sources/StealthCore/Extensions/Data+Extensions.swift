import Foundation

extension Data {

    /// Hex string representation (lowercase)
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Initialize from hex string
    /// - Parameter hexString: Hex-encoded string (with or without spaces)
    public init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "0x", with: "")

        guard hex.count % 2 == 0 else { return nil }

        var data = Data()
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    /// Safe prefix of specified length (returns Data, not SubSequence)
    /// - Parameter length: Number of bytes
    /// - Returns: Data prefix
    public func safePrefix(_ length: Int) -> Data {
        let end = Swift.min(length, count)
        return Data(self[startIndex..<self.index(startIndex, offsetBy: end)])
    }

    /// Safe suffix of specified length (returns Data, not SubSequence)
    /// - Parameter length: Number of bytes
    /// - Returns: Data suffix
    public func safeSuffix(_ length: Int) -> Data {
        let start = Swift.max(0, count - length)
        return Data(self[self.index(startIndex, offsetBy: start)..<endIndex])
    }

    /// Split data into two parts at index
    /// - Parameter index: Split point
    /// - Returns: Tuple of (prefix, suffix)
    public func splitAt(_ index: Int) -> (Data, Data) {
        let splitPoint = Swift.min(Swift.max(0, index), count)
        let prefixData = Data(self[startIndex..<self.index(startIndex, offsetBy: splitPoint)])
        let suffixData = Data(self[self.index(startIndex, offsetBy: splitPoint)..<endIndex])
        return (prefixData, suffixData)
    }

    /// XOR with another data (truncates to shorter length)
    /// - Parameter other: Data to XOR with
    /// - Returns: XOR result
    public func xor(with other: Data) -> Data {
        let length = Swift.min(count, other.count)
        var result = Data(count: length)

        for i in 0..<length {
            result[i] = self[i] ^ other[i]
        }

        return result
    }

    /// Constant-time comparison (to prevent timing attacks)
    /// - Parameter other: Data to compare with
    /// - Returns: true if equal
    public func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }

        var result: UInt8 = 0
        for i in 0..<count {
            result |= self[i] ^ other[i]
        }

        return result == 0
    }
}
