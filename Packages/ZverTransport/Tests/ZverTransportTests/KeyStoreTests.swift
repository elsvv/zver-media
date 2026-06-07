import Testing
import Foundation
@testable import ZverTransport

@Suite struct KeyStoreTests {
    @Test func saveThenTokenReturnsValue() throws {
        let store = InMemoryKeyStore()
        try store.save(token: "tok-1", forService: "MacBook")
        #expect(store.token(forService: "MacBook") == "tok-1")
    }

    @Test func tokenForUnknownServiceIsNil() {
        let store = InMemoryKeyStore()
        #expect(store.token(forService: "Nope") == nil)
    }

    @Test func deleteRemovesToken() throws {
        let store = InMemoryKeyStore()
        try store.save(token: "tok-2", forService: "MacBook")
        try store.delete(forService: "MacBook")
        #expect(store.token(forService: "MacBook") == nil)
    }

    @Test func saveOverwritesExistingToken() throws {
        let store = InMemoryKeyStore()
        try store.save(token: "old", forService: "MacBook")
        try store.save(token: "new", forService: "MacBook")
        #expect(store.token(forService: "MacBook") == "new")
    }

    @Test func deleteUnknownServiceDoesNotThrow() throws {
        let store = InMemoryKeyStore()
        // Идемпотентность: удаление несуществующего сервиса — не ошибка.
        try store.delete(forService: "Ghost")
        #expect(store.token(forService: "Ghost") == nil)
    }

    @Test func distinctServicesAreIsolated() throws {
        let store = InMemoryKeyStore()
        try store.save(token: "a", forService: "Mac-A")
        try store.save(token: "b", forService: "Mac-B")
        #expect(store.token(forService: "Mac-A") == "a")
        #expect(store.token(forService: "Mac-B") == "b")
        try store.delete(forService: "Mac-A")
        #expect(store.token(forService: "Mac-A") == nil)
        #expect(store.token(forService: "Mac-B") == "b")
    }

    // Потокобезопасность InMemoryKeyStore: конкурентные записи не должны падать
    // и итоговое значение читается без гонок.
    @Test func concurrentSavesAreThreadSafe() async throws {
        let store = InMemoryKeyStore()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    try? store.save(token: "tok-\(i)", forService: "svc-\(i % 10)")
                    _ = store.token(forService: "svc-\(i % 10)")
                }
            }
        }
        // Все 10 сервисов имеют какое-то значение, чтения не упали.
        for svc in 0..<10 {
            #expect(store.token(forService: "svc-\(svc)") != nil)
        }
    }
}
