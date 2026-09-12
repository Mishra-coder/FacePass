import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum VaultError: LocalizedError {
    case secureEnclaveUnavailable
    case wrongPassword
    case accessControl
    case notSetUp
    case notArmed
    case corrupt

    var errorDescription: String? {
        switch self {
        case .secureEnclaveUnavailable: return "This Mac has no Secure Enclave."
        case .wrongPassword: return "That isn't the password for this Mac account."
        case .accessControl: return "Could not create the Touch ID access rule."
        case .notSetUp: return "The vault isn't set up."
        case .notArmed: return "The vault isn't armed. Approve with Touch ID first."
        case .corrupt: return "The stored vault data is damaged."
        }
    }
}

/// Seals the Mac account password so only the owner, after Touch ID, can read it.
///
/// Two layers, the Glance pattern:
///   - A random 256-bit **data key K** encrypts the password (AES-GCM).
///   - K is sealed to a **Secure Enclave key** that needs Touch ID with the
///     fingerprints enrolled at setup (`biometryCurrentSet`).
///
/// Arming does ONE Touch ID, unwraps K into locked memory, and keeps K there for
/// the login session. Every later unlock uses the in-memory K with no Secure Enclave
/// call and no prompt — so repeated automatic unlocks keep working while locked.
/// Disarm, quit, logout or reboot wipes K; re-arming needs Touch ID again.
final class PasswordVault {
    static let shared = PasswordVault()

    private static let service = "com.devendramishra.facepass.vault"
    private static let keyAccount = "secure-enclave-key"
    private static let wrappedKeyAccount = "wrapped-data-key"
    private static let passwordAccount = "sealed-password"
    private static let formatVersion: UInt8 = 2
    private static let publicKeyLength = 65
    private static let kdfInfo = Data("FacePass vault v2".utf8)
    private static let keyAAD = Data("facepass.datakey.v2".utf8)
    private static let passwordAAD = Data("facepass.password.v2".utf8)

    private let keychain = KeychainStore(service: PasswordVault.service)
    private var dataKey: SecureBytes?   // K, held only while armed
    private(set) var armedAt: Date?

    var isSetUp: Bool {
        (try? keychain.read(Self.keyAccount)) != nil
            && (try? keychain.read(Self.wrappedKeyAccount)) != nil
            && (try? keychain.read(Self.passwordAccount)) != nil
    }

    var isArmed: Bool { dataKey != nil }

    func setUp(password: String) throws {
        guard SecureEnclave.isAvailable else { throw VaultError.secureEnclaveUnavailable }
        guard AccountPassword.isCorrect(password) else { throw VaultError.wrongPassword }
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil
        ) else {
            throw VaultError.accessControl
        }

        let seKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(compactRepresentable: false, accessControl: accessControl)
        let k = SymmetricKey(size: .bits256)
        var kData = k.withUnsafeBytes { Data($0) }
        defer { kData.resetBytes(in: 0..<kData.count) }

        let wrappedKey = try Self.seal(kData, to: seKey.publicKey, aad: Self.keyAAD)
        var plaintext = Data(password.utf8)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        guard let passwordCipher = try AES.GCM.seal(plaintext, using: k, authenticating: Self.passwordAAD).combined else {
            throw VaultError.corrupt
        }

        disarm()
        try keychain.write(seKey.dataRepresentation, account: Self.keyAccount)
        do {
            try keychain.write(wrappedKey, account: Self.wrappedKeyAccount)
            try keychain.write(passwordCipher, account: Self.passwordAccount)
        } catch {
            try? keychain.delete(Self.keyAccount)
            try? keychain.delete(Self.wrappedKeyAccount)
            throw error
        }
    }

    /// One Touch ID. Unwraps K into memory; later unlocks reuse it with no prompt.
    func arm(reason: String) async throws {
        guard isSetUp else { throw VaultError.notSetUp }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)

        guard let keyHandle = try keychain.read(Self.keyAccount),
              let wrappedKey = try keychain.read(Self.wrappedKeyAccount) else {
            throw VaultError.notSetUp
        }
        let seKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: keyHandle, authenticationContext: context)
        var k = try Self.unseal(wrappedKey, using: seKey, aad: Self.keyAAD)
        defer { k.resetBytes(in: 0..<k.count) }

        disarm()
        dataKey = SecureBytes(k)
        armedAt = Date()
        _ = try openPassword() // fail fast if anything is wrong, before we rely on it while locked
    }

    func disarm() {
        dataKey = nil
        armedAt = nil
    }

    func delete() throws {
        disarm()
        try keychain.delete(Self.keyAccount)
        try keychain.delete(Self.wrappedKeyAccount)
        try keychain.delete(Self.passwordAccount)
    }

    /// Decrypts the password into locked memory for the duration of `body`, then wipes it.
    func withPassword<Result>(_ body: (SecureBytes) throws -> Result) throws -> Result {
        let secret = try openPassword()
        return try body(secret)
    }

    private func openPassword() throws -> SecureBytes {
        guard let dataKey else { throw VaultError.notArmed }
        guard let cipher = try keychain.read(Self.passwordAccount) else { throw VaultError.notSetUp }
        let key = dataKey.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        let box = try AES.GCM.SealedBox(combined: cipher)
        var plaintext = try AES.GCM.open(box, using: key, authenticating: Self.passwordAAD)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        return SecureBytes(plaintext)
    }

    // MARK: - ECDH(P-256) + HKDF + AES-GCM sealing to a Secure Enclave public key

    private static func seal(_ plaintext: Data, to recipient: P256.KeyAgreement.PublicKey, aad: Data) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let symmetricKey = deriveKey(shared, ephemeral: ephemeral.publicKey, recipient: recipient)
        guard let combined = try AES.GCM.seal(plaintext, using: symmetricKey, authenticating: aad).combined else {
            throw VaultError.corrupt
        }
        return Data([formatVersion]) + ephemeral.publicKey.x963Representation + combined
    }

    private static func unseal(_ sealed: Data, using seKey: SecureEnclave.P256.KeyAgreement.PrivateKey, aad: Data) throws -> Data {
        let headerLength = 1 + publicKeyLength
        guard sealed.count > headerLength, sealed.first == formatVersion else { throw VaultError.corrupt }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: sealed.subdata(in: 1..<headerLength))
        let shared = try seKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let symmetricKey = deriveKey(shared, ephemeral: ephemeral, recipient: seKey.publicKey)
        let box = try AES.GCM.SealedBox(combined: sealed.subdata(in: headerLength..<sealed.count))
        return try AES.GCM.open(box, using: symmetricKey, authenticating: aad)
    }

    private static func deriveKey(_ shared: SharedSecret, ephemeral: P256.KeyAgreement.PublicKey,
                                  recipient: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        let inputKey = shared.withUnsafeBytes { SymmetricKey(data: $0) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: ephemeral.x963Representation + recipient.x963Representation,
            info: kdfInfo,
            outputByteCount: 32
        )
    }
}
