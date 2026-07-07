import Foundation

/// Заголовок Sony DSF (`.dsf`) — контейнер DSD (SACD-рипы вида «трек = файл»).
///
/// DSD — это 1-битный поток на очень высокой частоте (DSD64 = 2 822 400 Гц), не
/// PCM. Ни Core Audio, ни AVFoundation `.dsf` не открывают, поэтому формат
/// разбираем нативно: читаем фиксированные поля чанков `DSD ` и `fmt ` (частота,
/// число каналов, число сэмплов). Достаточно первых 80 байт файла — саму
/// (сотни МБ) дорожку не читаем. В PCM/сэмплы 1-битный поток переводит транскодер
/// (`ffmpeg` на Маке), а не этот разбор: телефон получает уже FLAC.
///
/// Раскладка (все числа little-endian):
/// ```
/// off  size  поле
///  0    4    "DSD "
///  4    8    размер DSD-чанка (28)
/// 12    8    полный размер файла
/// 20    8    указатель на метадату (ID3v2) или 0
/// 28    4    "fmt "
/// 32    8    размер fmt-чанка (52)
/// 40    4    версия формата
/// 44    4    id формата (0 = DSD raw)
/// 48    4    тип каналов
/// 52    4    число каналов        ← channels
/// 56    4    частота DSD          ← sampleRate
/// 60    4    бит на сэмпл (1)
/// 64    8    сэмплов на канал     ← sampleCount
/// 72    4    размер блока (4096)
/// 76    4    reserved
/// ```
public struct DSFHeader: Equatable, Sendable {
    /// Частота DSD в Гц (DSD64 = 2 822 400, DSD128 = 5 644 800).
    public let sampleRate: Double
    public let channels: Int
    /// Число 1-битных сэмплов на канал.
    public let sampleCount: Int64

    public init(sampleRate: Double, channels: Int, sampleCount: Int64) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleCount = sampleCount
    }

    /// Длительность = сэмплов / частоту.
    public var duration: Double {
        sampleRate > 0 ? Double(sampleCount) / sampleRate : 0
    }

    /// Кратность DSD относительно CD (44.1к): 64 → «DSD64», 128 → «DSD128».
    public var dsdMultiple: Int {
        Int((sampleRate / 44_100.0).rounded())
    }

    public enum ParseError: Error, Equatable { case tooShort, badMagic }

    /// Минимум байт заголовка, которых хватает для разбора (`DSD ` + `fmt ` чанки).
    public static let headerLength = 80

    /// Разбор из первых байт файла (нужны минимум ``headerLength`` = 80 байт).
    public static func parse(headerBytes b: [UInt8]) throws -> DSFHeader {
        guard b.count >= headerLength else { throw ParseError.tooShort }

        func u32(_ off: Int) -> UInt32 {
            UInt32(b[off]) | (UInt32(b[off + 1]) << 8)
                | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
        }
        func u64(_ off: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(b[off + i]) << (8 * i) }
            return v
        }
        func magic(_ off: Int) -> String {
            String(bytes: b[off..<off + 4], encoding: .ascii) ?? ""
        }

        guard magic(0) == "DSD " else { throw ParseError.badMagic }
        guard magic(28) == "fmt " else { throw ParseError.badMagic }

        let channels = Int(u32(52))
        let sampleRate = Double(u32(56))
        let sampleCount = Int64(bitPattern: u64(64))
        return DSFHeader(sampleRate: sampleRate,
                         channels: max(channels, 1),
                         sampleCount: max(sampleCount, 0))
    }

    /// Читает и разбирает заголовок `.dsf` с диска (первые ``headerLength`` байт).
    public static func parse(url: URL) throws -> DSFHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: headerLength) ?? Data()
        return try parse(headerBytes: [UInt8](data))
    }
}
