import Foundation
import Base58Swift

extension String {

    /// Decode base58 string to Data
    public var base58DecodedData: Data? {
        guard let bytes = Base58.base58Decode(self) else { return nil }
        return Data(bytes)
    }

    /// Check if string is valid base58
    public var isValidBase58: Bool {
        return Base58.base58Decode(self) != nil
    }
}

extension Data {

    /// Encode Data to base58 string
    public var base58EncodedString: String {
        return Base58.base58Encode([UInt8](self))
    }
}
