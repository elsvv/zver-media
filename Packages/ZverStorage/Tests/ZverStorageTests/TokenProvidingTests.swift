import XCTest
import Foundation
@testable import ZverStorage

/// Тесты ЧИСТОЙ части S4-5: ``StaticTokenProvider`` и конструируемость
/// ``YandexDiskStore`` как ``RemoteStore``.
///
/// Сам сетевой адаптер (`YandexDiskStore` поверх `URLSession`) тестами НЕ покрывается
/// — рантайм-сеть проверяет владелец на устройстве (лессон прошлых этапов). Здесь
/// проверяется лишь то, что: (1) поставщик токена отдаёт/скрывает токен; (2) адаптер
/// собирается всеми инициализаторами и удовлетворяет протоколу `RemoteStore`; (3)
/// фоновая HTTP-обёртка создаётся. Это удерживает `swift test` зелёным и гарантирует
/// компиляцию адаптера в тест-таргете.
final class TokenProvidingTests: XCTestCase {
    func testStaticProviderReturnsToken() async {
        let provider = StaticTokenProvider(token: "abc123")
        let token = await provider.token()
        XCTAssertEqual(token, "abc123")
    }

    func testStaticProviderNilWhenLoggedOut() async {
        let provider = StaticTokenProvider(token: nil)
        let token = await provider.token()
        XCTAssertNil(token)
    }

    /// Адаптер собирается удобным инициализатором и является `RemoteStore`.
    func testStoreConstructsAsRemoteStore() {
        let store: any RemoteStore = YandexDiskStore(
            tokenProvider: StaticTokenProvider(token: "t")
        )
        XCTAssertNotNil(store)
    }

    /// Адаптер собирается явным инициализатором поверх инъецированного `HTTPClient`.
    func testStoreConstructsWithInjectedClient() {
        let factory = YandexRequestFactory(
            baseURL: URL(string: "https://cloud-api.yandex.net/v1/disk")!,
            rootPrefix: "app:/"
        )
        let store = YandexDiskStore(
            http: URLSessionHTTPClient(),
            factory: factory,
            tokenProvider: StaticTokenProvider(token: nil),
            policy: RetryPolicy()
        )
        XCTAssertNotNil(store as any RemoteStore)
    }

    /// Фоновая URLSession-обёртка создаётся (для переживания сворачивания приложения).
    func testBackgroundClientFactory() {
        let client = URLSessionHTTPClient.background(identifier: "dev.zver.tests.bg")
        XCTAssertNotNil(client as any HTTPClient)
    }
}
