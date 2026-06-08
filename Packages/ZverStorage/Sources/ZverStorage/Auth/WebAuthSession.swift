import Foundation

/// Абстракция браузерной сессии OAuth-входа.
///
/// Прячет единственный рантайм-объект входа (`ASWebAuthenticationSession`) за
/// протоколом — ровно как `RemoteStore` прячет сеть. Чистая логика (построение
/// authorize-URL и разбор redirect) живёт в ``YandexOAuth`` и тестируется без UI;
/// этот протокол — лишь точка подключения системной сессии.
///
/// Реализация (``ASWebAuthSession``) — ЗАГОТОВКА: компилируется, но в MVP не
/// активируется (требует зарегистрированного на oauth.yandex.ru `client_id`).
/// MVP-вход приложения — ручной токен в Keychain (S4-9), он не зависит от этого
/// протокола; браузерный вход подключается позже подменой реализации.
public protocol WebAuthSession: Sendable {
    /// Открывает `url` в браузерной сессии и ждёт redirect на `callbackScheme`.
    ///
    /// - Parameters:
    ///   - url: authorize-URL (из ``YandexOAuth/authorizeURL(clientID:scope:redirectURI:state:)``).
    ///   - callbackScheme: схема `redirect_uri` приложения, по которой ловится redirect.
    /// - Returns: пойманный callback-URL (его разбирает ``YandexOAuth/parseRedirect(_:)``).
    /// - Throws: при отмене пользователем/системной ошибке сессии.
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// Ошибка браузерной сессии входа.
public enum WebAuthError: Error, Sendable, Equatable {
    /// Пользователь закрыл сессию входа, не завершив авторизацию.
    case cancelled
    /// Системная сессия завершилась ошибкой (детали — `message` для лога).
    case session(message: String)
    /// Сессия вернула пустой/некорректный callback.
    case noCallback
}

#if canImport(AuthenticationServices)
import AuthenticationServices

/// Адаптер ``WebAuthSession`` поверх `ASWebAuthenticationSession` (ЗАГОТОВКА).
///
/// **Не активен в MVP.** Полноценный браузерный вход требует зарегистрированного
/// на oauth.yandex.ru приложения (`client_id` + `redirect_uri`), которого пока нет
/// — поэтому приложение использует ручной токен (S4-9). Этот адаптер компилируется
/// и готов к подключению: достаточно создать его и передать в поток входа, когда
/// `client_id` появится. Тестами НЕ покрывается (рантайм-сетевой/UI-объект — лессон
/// прошлых этапов: проверяет владелец на устройстве).
///
/// `ASWebAuthenticationSession` требует контекст представления (окно). Презентер
/// инъецируется как `@Sendable`-замыкание, чтобы адаптер оставался `Sendable` и не
/// тащил UIKit-типы в сигнатуру.
public final class ASWebAuthSession: WebAuthSession, @unchecked Sendable {
    /// Поставщик якоря представления для системной сессии (окно приложения).
    private let presentationAnchorProvider: @Sendable () -> ASPresentationAnchor

    /// - Parameter presentationAnchorProvider: возвращает окно для показа сессии входа.
    public init(presentationAnchorProvider: @escaping @Sendable () -> ASPresentationAnchor) {
        self.presentationAnchorProvider = presentationAnchorProvider
    }

    public func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        // `ASWebAuthenticationSession` и его context provider — @MainActor-объекты
        // (UI): создаём, настраиваем и стартуем строго на главном акторе. Provider
        // удерживается через `presentationContextProvider` сессии, сама сессия — в
        // боксе, который освобождается из completion-handler, переживая старт.
        let anchorProvider = presentationAnchorProvider
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let box = SessionBox()
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme
                ) { callbackURL, error in
                    defer { box.session = nil } // освобождаем сессию после завершения
                    if let error {
                        if let asError = error as? ASWebAuthenticationSessionError,
                           asError.code == .canceledLogin {
                            continuation.resume(throwing: WebAuthError.cancelled)
                        } else {
                            continuation.resume(throwing: WebAuthError.session(message: error.localizedDescription))
                        }
                        return
                    }
                    guard let callbackURL else {
                        continuation.resume(throwing: WebAuthError.noCallback)
                        return
                    }
                    continuation.resume(returning: callbackURL)
                }
                session.presentationContextProvider = AnchorContextProvider(anchor: anchorProvider())
                session.prefersEphemeralWebBrowserSession = false
                box.session = session // удерживаем сессию живой до завершения
                session.start()
            }
        }
    }
}

/// Контейнер для удержания сессии живой между `start()` и её completion-handler.
/// `@MainActor`, т.к. `ASWebAuthenticationSession` — главноакторный UI-объект.
@MainActor
private final class SessionBox {
    var session: ASWebAuthenticationSession?
}

/// Мост `ASWebAuthenticationPresentationContextProviding` для системной сессии.
private final class AnchorContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
#endif
