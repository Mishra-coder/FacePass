import Foundation
import OpenDirectory

/// Checks a password against the current macOS user account, so a wrong password
/// is never stored (typing a wrong one at the lock screen could trigger lockout).
enum AccountPassword {
    static func isCorrect(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }
}
