import CryptoKit
import Foundation

/// The enrolled face: mean template plus the raw samples, saved encrypted so it
/// survives quitting and relaunching. Only 128-number embeddings are stored — never
/// an image. Encrypted with an AES key kept in the keychain (this device, available
/// while logged in — including at the lock screen, so scanning works while locked).
struct FaceEnrollment: Codable {
    var template: [Float]
    var samples: [[Float]]
    var createdAt: Date
    var modelVersion: String
}

final class FaceTemplateStore {
    static let shared = FaceTemplateStore()

    private static let service = "com.devendramishra.facepass.face"
    private static let keyAccount = "template-key"
    private static let dataAccount = "template-data"
    private static let aad = Data("facepass.face.v1".utf8)

    private let keychain = KeychainStore(service: FaceTemplateStore.service)

    var isEnrolled: Bool {
        (try? keychain.read(Self.dataAccount)) != nil
    }

    func save(_ enrollment: FaceEnrollment) throws {
        let key = try loadOrCreateKey()
        let plaintext = try JSONEncoder().encode(enrollment)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.aad)
        guard let combined = sealed.combined else { throw VaultError.corrupt }
        try keychain.write(combined, account: Self.dataAccount)
    }

    func load() throws -> FaceEnrollment? {
        guard let combined = try keychain.read(Self.dataAccount),
              let keyData = try keychain.read(Self.keyAccount) else {
            return nil
        }
        let key = SymmetricKey(data: keyData)
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: key, authenticating: Self.aad)
        return try JSONDecoder().decode(FaceEnrollment.self, from: plaintext)
    }

    func delete() throws {
        try keychain.delete(Self.dataAccount)
        try keychain.delete(Self.keyAccount)
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try keychain.read(Self.keyAccount) {
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try keychain.write(data, account: Self.keyAccount)
        return key
    }
}
