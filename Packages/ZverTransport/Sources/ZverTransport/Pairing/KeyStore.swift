import Foundation

/// Хранилище секретных токенов сессии, разнесённых по сервисам (имя/host Мака).
///
/// Абстракция над платформенным хранилищем: продакшен — Keychain
/// (`KeychainKeyStore`), тесты — `InMemoryKeyStore`. Методы синхронные и
/// бросающие — Keychain-операции блокирующие и могут падать.
public protocol KeyStore: Sendable {
    /// Сохраняет (или перезаписывает) токен под именем сервиса.
    func save(token: String, forService service: String) throws
    /// Возвращает сохранённый токен сервиса либо nil, если его нет.
    func token(forService service: String) -> String?
    /// Удаляет токен сервиса. Удаление отсутствующего токена — не ошибка.
    func delete(forService service: String) throws
}

/// Потокобезопасная in-memory реализация `KeyStore` для тестов и предпросмотра.
///
/// Реализована на `final class` с `NSLock` (а не actor), чтобы соответствовать
/// синхронному протоколу `KeyStore`. `@unchecked Sendable` оправдан: всё
/// состояние под замком.
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func save(token: String, forService service: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[service] = token
    }

    public func token(forService service: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[service]
    }

    public func delete(forService service: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[service] = nil
    }
}
