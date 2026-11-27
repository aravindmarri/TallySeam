import CommonCrypto
import CryptoKit
import Foundation

enum BackupError: Error, Equatable, LocalizedError {
    case weakPassword
    case notABackup
    case unsupportedVersion
    case wrongPasswordOrDamaged
    case invalidContents
    case tooLarge
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .weakPassword: "Use a password of at least \(BackupCrypto.minimumPasswordLength) characters."
        case .notABackup: "This file isn't a TallySeam backup."
        case .unsupportedVersion: "This backup was made by a newer version of TallySeam."
        case .wrongPasswordOrDamaged: "The password is wrong or the file is damaged."
        case .invalidContents: "The backup contains invalid data. Nothing was imported."
        case .tooLarge: "The file is too large to be a TallySeam backup."
        case .keyDerivationFailed: "The encryption key couldn't be created."
        }
    }
}

/// Password-based encryption for backup files.
///
/// Format (JSON envelope):
/// - key = PBKDF2-HMAC-SHA256(password UTF-8, random 16-byte salt, `iterations`) → 32 bytes
/// - payload sealed with AES-256-GCM (random 12-byte nonce, 16-byte tag)
/// - the header (format, version, iterations, salt) is authenticated as additional data,
///   so it can't be altered without detection.
enum BackupCrypto {
    /// Format tag written into every new backup.
    static let format = "TallySeam-Backup"
    /// Tags that can still be opened: the second is the tag used by early builds, so their
    /// backups can still be imported.
    static let readableFormats: Set<String> = [format, "MyMoneyAI-Backup"]
    static let version = 1
    static let defaultIterations = 600_000
    static let allowedIterations = 100_000...10_000_000
    static let minimumPasswordLength = 8
    static let maximumFileBytes = 300 * 1024 * 1024

    struct Envelope: Codable, Equatable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: Data
        var cipher: String
        /// nonce ‖ ciphertext ‖ tag
        var sealed: Data
    }

    static func isAcceptable(password: String) -> Bool {
        password.count >= minimumPasswordLength
    }

    static func encrypt(_ plaintext: Data, password: String, iterations: Int = defaultIterations, format: String = BackupCrypto.format) throws -> Data {
        guard isAcceptable(password: password) else { throw BackupError.weakPassword }
        let salt = randomBytes(16)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let aad = additionalData(format: format, version: version, iterations: iterations, salt: salt)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = box.combined else { throw BackupError.keyDerivationFailed }
        let envelope = Envelope(format: format, version: version, kdf: "PBKDF2-HMAC-SHA256", iterations: iterations,
                                salt: salt, cipher: "AES-256-GCM", sealed: combined)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    static func decrypt(_ file: Data, password: String) throws -> Data {
        guard file.count <= maximumFileBytes else { throw BackupError.tooLarge }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: file), readableFormats.contains(envelope.format) else {
            throw BackupError.notABackup
        }
        guard envelope.version == version else { throw BackupError.unsupportedVersion }
        guard envelope.kdf == "PBKDF2-HMAC-SHA256", envelope.cipher == "AES-256-GCM",
              allowedIterations.contains(envelope.iterations), envelope.salt.count >= 16 else { throw BackupError.notABackup }
        let key = try deriveKey(password: password, salt: envelope.salt, iterations: envelope.iterations)
        let aad = additionalData(format: envelope.format, version: envelope.version, iterations: envelope.iterations, salt: envelope.salt)
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw BackupError.wrongPasswordOrDamaged
        }
    }

    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { pw in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pw.baseAddress?.assumingMemoryBound(to: CChar.self), passwordData.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw BackupError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }

    private static func additionalData(format: String, version: Int, iterations: Int, salt: Data) -> Data {
        Data("\(format)|\(version)|\(iterations)|\(salt.base64EncodedString())".utf8)
    }

    private static func randomBytes(_ count: Int) -> Data {
        Data(SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Array($0) })
    }
}
