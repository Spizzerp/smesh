import Foundation

/// Solana transaction builder and serializer
/// Implements the Solana transaction wire format for constructing and signing transactions
public struct SolanaTransaction {

    // MARK: - Constants

    /// System Program ID (all zeros)
    public static let systemProgramId = Data(repeating: 0, count: 32)

    /// System Program transfer instruction index
    private static let transferInstructionIndex: UInt32 = 2

    // MARK: - Types

    /// A compiled instruction for inclusion in a transaction
    public struct CompiledInstruction {
        let programIdIndex: UInt8
        let accountIndices: [UInt8]
        let data: Data
    }

    /// Transaction message (unsigned portion)
    public struct Message {
        let header: MessageHeader
        let accountKeys: [Data]  // Array of 32-byte public keys
        let recentBlockhash: Data  // 32 bytes
        let instructions: [CompiledInstruction]

        /// Serialize the message to bytes
        public func serialize() -> Data {
            var data = Data()

            // Header (3 bytes)
            data.append(header.numRequiredSignatures)
            data.append(header.numReadonlySignedAccounts)
            data.append(header.numReadonlyUnsignedAccounts)

            // Account keys (compact array)
            data.append(contentsOf: encodeCompactU16(UInt16(accountKeys.count)))
            for key in accountKeys {
                data.append(key)
            }

            // Recent blockhash (32 bytes)
            data.append(recentBlockhash)

            // Instructions (compact array)
            data.append(contentsOf: encodeCompactU16(UInt16(instructions.count)))
            for instruction in instructions {
                data.append(instruction.programIdIndex)
                data.append(contentsOf: encodeCompactU16(UInt16(instruction.accountIndices.count)))
                for idx in instruction.accountIndices {
                    data.append(idx)
                }
                data.append(contentsOf: encodeCompactU16(UInt16(instruction.data.count)))
                data.append(instruction.data)
            }

            return data
        }
    }

    /// Message header
    public struct MessageHeader {
        let numRequiredSignatures: UInt8
        let numReadonlySignedAccounts: UInt8
        let numReadonlyUnsignedAccounts: UInt8
    }

    // MARK: - Transaction Building

    /// Build a SOL transfer transaction
    /// - Parameters:
    ///   - from: Sender's 32-byte public key
    ///   - to: Recipient's 32-byte public key
    ///   - lamports: Amount to transfer in lamports
    ///   - recentBlockhash: Recent blockhash from RPC (base58 string)
    /// - Returns: Unsigned transaction message
    public static func buildTransfer(
        from: Data,
        to: Data,
        lamports: UInt64,
        recentBlockhash: String
    ) throws -> Message {
        guard from.count == 32 else {
            throw TransactionError.invalidPublicKey("From key must be 32 bytes")
        }
        guard to.count == 32 else {
            throw TransactionError.invalidPublicKey("To key must be 32 bytes")
        }

        // Decode blockhash from base58
        guard let blockhashData = Data(base58Decoding: recentBlockhash), blockhashData.count == 32 else {
            throw TransactionError.invalidBlockhash
        }

        // Account keys order:
        // 0: from (signer, writable)
        // 1: to (writable)
        // 2: System Program (readonly, unsigned)
        let accountKeys = [from, to, systemProgramId]

        // Header:
        // - 1 required signature (from)
        // - 0 readonly signed accounts
        // - 1 readonly unsigned account (System Program)
        let header = MessageHeader(
            numRequiredSignatures: 1,
            numReadonlySignedAccounts: 0,
            numReadonlyUnsignedAccounts: 1
        )

        // Build transfer instruction data:
        // [4 bytes LE: instruction index (2)] [8 bytes LE: lamports]
        var instructionData = Data()
        var index = transferInstructionIndex
        instructionData.append(contentsOf: withUnsafeBytes(of: &index) { Data($0) })
        var amount = lamports
        instructionData.append(contentsOf: withUnsafeBytes(of: &amount) { Data($0) })

        let instruction = CompiledInstruction(
            programIdIndex: 2,  // System Program is at index 2
            accountIndices: [0, 1],  // from, to
            data: instructionData
        )

        return Message(
            header: header,
            accountKeys: accountKeys,
            recentBlockhash: blockhashData,
            instructions: [instruction]
        )
    }

    /// Build a complete signed transaction
    /// - Parameters:
    ///   - message: The unsigned message
    ///   - signature: 64-byte ed25519 signature
    /// - Returns: Serialized signed transaction (base64 encoded for RPC)
    public static func buildSignedTransaction(message: Message, signature: Data) throws -> String {
        guard signature.count == 64 else {
            throw TransactionError.invalidSignature
        }

        var txData = Data()

        // Signatures (compact array with 1 signature)
        txData.append(contentsOf: encodeCompactU16(1))
        txData.append(signature)

        // Message
        txData.append(message.serialize())

        return txData.base64EncodedString()
    }

    // MARK: - Compact-U16 Encoding

    /// Encode a value as Solana's compact-u16 format
    /// Values 0-127: 1 byte
    /// Values 128-16383: 2 bytes
    /// Values 16384-4194303: 3 bytes (max for compact-u16)
    private static func encodeCompactU16(_ value: UInt16) -> [UInt8] {
        if value < 0x80 {
            return [UInt8(value)]
        } else if value < 0x4000 {
            return [
                UInt8((value & 0x7F) | 0x80),
                UInt8(value >> 7)
            ]
        } else {
            return [
                UInt8((value & 0x7F) | 0x80),
                UInt8(((value >> 7) & 0x7F) | 0x80),
                UInt8(value >> 14)
            ]
        }
    }
}

// MARK: - Errors

public enum TransactionError: Error, LocalizedError {
    case invalidPublicKey(String)
    case invalidBlockhash
    case invalidSignature
    case serializationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKey(let msg):
            return "Invalid public key: \(msg)"
        case .invalidBlockhash:
            return "Invalid blockhash"
        case .invalidSignature:
            return "Invalid signature (must be 64 bytes)"
        case .serializationFailed:
            return "Transaction serialization failed"
        }
    }
}

// MARK: - Data Extension for Base58

extension Data {
    /// Decode from base58 string
    init?(base58Decoding string: String) {
        let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
        var decoded = [UInt8]()
        var intData = [UInt8]()

        for char in string {
            guard let index = alphabet.firstIndex(of: char) else {
                return nil
            }
            let digit = alphabet.distance(from: alphabet.startIndex, to: index)

            var carry = digit
            for i in (0..<intData.count).reversed() {
                carry += Int(intData[i]) * 58
                intData[i] = UInt8(carry & 0xFF)
                carry >>= 8
            }

            while carry > 0 {
                intData.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }

        // Add leading zeros
        let leadingZeros = string.prefix(while: { $0 == "1" }).count
        decoded = Array(repeating: 0, count: leadingZeros)
        decoded.append(contentsOf: intData)

        self = Data(decoded)
    }
}
