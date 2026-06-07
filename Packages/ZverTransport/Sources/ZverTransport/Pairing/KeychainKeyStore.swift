import Foundation
import Security

/// Тонкий адаптер `KeyStore` поверх системного Keychain (`Security`).
///
/// Работает на iOS и macOS: хранит токен как `kSecClassGenericPassword` с
/// `kSecAttrService = <service>` и общим `kSecAttrAccount`. Тестами в `swift
/// test` НЕ покрывается — Keychain недоступен без подписи/entitlements; этот тип
/// обязан лишь компилироваться на обеих платформах. Реальная проверка — на
/// устройстве у владельца.
public struct KeychainKeyStore: KeyStore {
    /// Аккаунт-метка записи. Сервис различает разные Маки, аккаунт фиксирован.
    private let account: String

    public init(account: String = "zver-sync-token") {
        self.account = account
    }

    /// Ошибки обёртки Keychain с кодом `OSStatus` для диагностики.
    public enum KeychainError: Error, Sendable {
        case unexpectedStatus(OSStatus)
        case dataEncoding
    }

    public func save(token: String, forService service: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.dataEncoding
        }

        // Перезапись: сначала удаляем существующую запись, затем добавляем.
        let deleteQuery = baseQuery(forService: service)
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery = baseQuery(forService: service)
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func token(forService service: String) -> String? {
        var query = baseQuery(forService: service)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    public func delete(forService service: String) throws {
        let query = baseQuery(forService: service)
        let status = SecItemDelete(query as CFDictionary)
        // Отсутствие записи — не ошибка (идемпотентность).
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(forService service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
