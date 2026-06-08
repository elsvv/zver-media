import Foundation

/// JSON-кодек протокола пульта: `RemoteMessage` ⇄ `Data` (текстовый WS-фрейм).
///
/// Forward-compat: лишние ключи игнорируются (поведение `JSONDecoder` по
/// умолчанию), неизвестный `type` payload-а декодится в `.unknown` (см.
/// `RemotePayload.init(from:)`), конверт чужой версии парсится — версия доступна
/// вызывающему через `RemoteMessage.protocolVersion` или `decodeVersion(_:)`.
/// `Sendable` — безопасен в `@Sendable`-замыканиях сетевых адаптеров (S5-3).
public struct RemoteCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let encoder = JSONEncoder()
        // Детерминированный порядок ключей упрощает отладку/снапшоты; на провод
        // это не влияет (JSON-объект неупорядочен по спецификации).
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// Кодирует сообщение в UTF-8 JSON для текстового WebSocket-фрейма.
    public func encode(_ message: RemoteMessage) throws -> Data {
        try encoder.encode(message)
    }

    /// Декодирует сообщение. Бросает только на «не наш протокол» (битый JSON,
    /// отсутствует обязательный конверт-ключ `protocolVersion`/`payload`).
    /// Неизвестный `type` или чужая версия — НЕ ошибка (forward-compat).
    public func decode(_ data: Data) throws -> RemoteMessage {
        try decoder.decode(RemoteMessage.self, from: data)
    }

    /// Лёгкое чтение только версии конверта без полного декода payload —
    /// вызывающий может решить про совместимость до разбора тела.
    public func decodeVersion(_ data: Data) throws -> Int {
        try decoder.decode(VersionProbe.self, from: data).protocolVersion
    }

    /// Минимальная проекция конверта только с версией.
    private struct VersionProbe: Decodable {
        let protocolVersion: Int
    }
}
