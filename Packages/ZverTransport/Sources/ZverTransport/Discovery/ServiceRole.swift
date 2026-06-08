import Foundation

/// Константы TXT-записи Bonjour для различения роли сервиса на общем типе
/// `_zver._tcp`.
///
/// Этап 3 (синк) анонсит сервис Мака БЕЗ поля `svc`. Этап 5 (пульт) добавляет
/// `svc=remote` для WebSocket-сервера iPhone. Чтобы Mac не путал пульт-сервис
/// iPhone с синк-сервисом Мака (один и тот же тип Bonjour), вводим фильтр по
/// роли. Отсутствие `svc` ДОЛЖНО трактоваться как `sync` — иначе поведение
/// этапа 3 сломается.
public enum ServiceTXT {
    /// Ключ TXT-поля с ролью сервиса.
    public static let roleKey = "svc"
    /// Роль «пульт» — WebSocket-сервер iPhone (этап 5).
    public static let remote = "remote"
    /// Роль «синк» — файловый сервер Мака (этап 3); также дефолт при отсутствии `svc`.
    public static let sync = "sync"
}

public extension DiscoveredService {
    /// Роль сервиса из TXT-поля `svc`. Отсутствие поля → `sync` (обратная
    /// совместимость этапа 3, где синк-сервисы анонсятся без `svc`).
    var role: String {
        txt[ServiceTXT.roleKey] ?? ServiceTXT.sync
    }
}
