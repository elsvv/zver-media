import Foundation

/// Чистая логика сопряжения (pairing) хоста и клиента.
///
/// Хост (Mac) при открытии окна pairing генерирует 6-значный код и одноразовый
/// токен. Клиент (iPhone) присылает `PairRequest{code}`; хост сверяет код через
/// `verify(code:expected:)` (сравнение, не зависящее от данных по времени) и при
/// совпадении отдаёт `PairResponse{token}`. Здесь — только детерминируемая/
/// случайная логика без сети и без сторонних эффектов.
public enum Pairing {
    /// Число цифр в коде сопряжения.
    public static let codeLength = 6

    /// Размер токена в байтах (256 бит).
    private static let tokenByteCount = 32

    /// Генерирует 6-значный код строкой. Ведущие нули допустимы и сохраняются
    /// (значение в `0...999999`, добитое нулями слева до 6 символов).
    ///
    /// Источник энтропии — `SystemRandomNumberGenerator` (криптографически
    /// стойкий на Apple-платформах).
    public static func generateCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return generateCode(using: &rng)
    }

    /// Версия с инъекцией ГПСЧ — для детерминированной проверки в тестах при
    /// необходимости. Открыта как `internal` для пакета.
    static func generateCode<G: RandomNumberGenerator>(using rng: inout G) -> String {
        let upperExclusive: UInt32 = 1_000_000 // 10^6
        let value = UInt32.random(in: 0..<upperExclusive, using: &rng)
        return String(format: "%06u", value)
    }

    /// Генерирует одноразовый токен: 256 бит криптослучайных данных в виде hex
    /// нижнего регистра (64 символа).
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Сверяет присланный код с ожидаемым. Сравнение по возможности постоянно по
    /// времени: проходит по всем байтам без раннего выхода, не давая утечки
    /// длины общего префикса по времени отклика.
    ///
    /// Строки разной длины не равны (но даже здесь сравнение не «коротит»).
    public static func verify(code: String, expected: String) -> Bool {
        let a = Array(code.utf8)
        let b = Array(expected.utf8)
        return constantTimeEquals(a, b)
    }

    /// Сравнение двух байтовых последовательностей за время, не зависящее от их
    /// содержимого (только от длины `expected`). Возвращает true лишь при полном
    /// совпадении длины и всех байтов.
    private static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        // Длины раскрываются и так (это не секрет), но накапливаем разницу без
        // ветвлений по содержимому.
        var diff: UInt8 = a.count == b.count ? 0 : 1
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            diff |= x ^ y
        }
        return diff == 0
    }
}
