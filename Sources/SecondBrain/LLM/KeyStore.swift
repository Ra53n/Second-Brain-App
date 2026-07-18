// KeyStore.swift — API-ключи провайдеров: Keychain (основное) + env (fallback).
//
// Отличие от эталонного Manager Assistant (ключи в файлах ~/.config/*/*.key) —
// осознанное: здесь Keychain, он безопаснее (шифрование на диске, доступ через
// системный ACL). Ключи никогда не попадают в код/git (см. CLAUDE.md).
//
// Запись Keychain: kSecClassGenericPassword,
//   service = "<bundle id>.apikeys", account = ProviderID.rawValue, value = ключ.
// env-переменная (приоритетнее — удобно при разработке): SECONDBRAIN_<ID>_KEY.
//
// Без сторонних обёрток — прямые вызовы Security.framework (SecItemAdd/
// CopyMatching/Update/Delete), как и просит задача.

import Foundation
import Security

enum KeyStore {
    /// Namespace Keychain-записей. Тесты подменяют на отдельный сервис, чтобы
    /// не трогать реальные ключи пользователя и не оставлять мусор.
    static var service = "\(Config.bundleID).apikeys"

    /// Имя переменной окружения для провайдера, напр. SECONDBRAIN_OPENAI_KEY.
    /// Дефис в id (запись «github-token», задача 36) невалиден в именах env —
    /// заменяется на подчёркивание: SECONDBRAIN_GITHUB_TOKEN_KEY.
    static func envVar(for id: ProviderID) -> String {
        "SECONDBRAIN_\(id.rawValue.uppercased().replacingOccurrences(of: "-", with: "_"))_KEY"
    }

    /// Ключ провайдера: сначала env (приоритет), затем Keychain. nil — ключа нет нигде.
    static func key(for id: ProviderID) -> String? {
        if let value = ProcessInfo.processInfo.environment[envVar(for: id)] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return readKeychain(account: id.rawValue)
    }

    static func hasKey(for id: ProviderID) -> Bool {
        key(for: id) != nil
    }

    /// Сохраняет ключ в Keychain; пустая строка удаляет запись. env не трогает —
    /// он задаётся снаружи процесса и всегда имеет приоритет при чтении.
    static func setKey(_ value: String, for id: ProviderID) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteKeychain(account: id.rawValue)
        } else {
            writeKeychain(account: id.rawValue, value: trimmed)
        }
    }

    // MARK: - Keychain (SecItemAdd/CopyMatching/Update/Delete)

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func readKeychain(account: String) -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(account: String, value: String) {
        let data = Data(value.utf8)
        if readKeychain(account: account) != nil {
            SecItemUpdate(
                query(account: account) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        } else {
            var attributes = query(account: account)
            attributes[kSecValueData as String] = data
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    private static func deleteKeychain(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
