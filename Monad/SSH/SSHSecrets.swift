//
//  SSHSecrets.swift — where an SSH host's password is kept: the user's
//  login Keychain, one generic password item per host, never Monad's files.
//
//  Only MonadHost reads and writes these items (one process, one Keychain
//  access list): the app sends a typed password over XPC and never gets one
//  back. Tests use a dictionary behind the same seam.
//

import Foundation
import Security

protocol SecretStoring: Sendable {
    func password(for account: String) throws -> String?
    func setPassword(_ password: String, for account: String) throws
    func removePassword(for account: String) throws
    /// Whether there is one, without reading it (no Keychain prompt).
    func hasPassword(for account: String) -> Bool
}

struct KeychainSecrets: SecretStoring {
    /// "dev.monad.ssh" (a Debug build: "dev.monad.debug.ssh").
    var service = Flavor.current.logSubsystem + ".ssh"

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
    }

    func password(for account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MonadError("The Keychain did not give the password: \(Self.message(status))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func setPassword(_ password: String, for account: String) throws {
        let data = Data(password.utf8)
        var q = query(account)
        q[kSecAttrLabel] = "Monad SSH host \(account)"
        q[kSecValueData] = data
        var status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw MonadError("The password could not be kept in the Keychain: \(Self.message(status))")
        }
    }

    func removePassword(for account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MonadError("The password could not be removed from the Keychain: \(Self.message(status))")
        }
    }

    func hasPassword(for account: String) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
}
