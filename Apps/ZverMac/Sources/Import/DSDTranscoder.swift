import Foundation

/// Конвертирует один `.dsf` (DSD) в FLAC заданного качества через `ffmpeg`.
///
/// Команда проверена end-to-end на синтетическом DSD64: 1-битный поток →
/// декод ffmpeg → ресемпл до целевой частоты → 24-битный FLAC (тон 1 кГц
/// восстанавливается точно). `-nostats -loglevel error` держит stderr крошечным
/// (только реальные ошибки), поэтому его безопасно читать после завершения без
/// параллельного слива (иначе прогресс-строки переполнили бы пайп и повесили
/// процесс). Прогресс по альбому даёт покадровый вызывающий (`DSDStaging`).
enum DSDTranscoder {
    enum TranscodeError: LocalizedError {
        case ffmpegFailed(code: Int32, stderr: String)
        case outputMissing(URL)

        var errorDescription: String? {
            switch self {
            case let .ffmpegFailed(code, stderr):
                let tail = stderr.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
                return "ffmpeg не смог сконвертировать DSD (код \(code)). \(tail)"
            case .outputMissing:
                return "ffmpeg завершился, но FLAC не создан."
            }
        }
    }

    /// Синхронно (в отдельном процессе) конвертирует `input` (.dsf) в `output`
    /// (.flac). Каталог назначения должен существовать. Бросает при ненулевом
    /// коде выхода или отсутствии выходного файла.
    static func transcode(dsf input: URL, to output: URL,
                          quality: DSDQuality, ffmpeg: URL) throws {
        try? FileManager.default.removeItem(at: output)

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-y",
            "-i", input.path,
            "-ar", String(quality.sampleRate),
            "-sample_fmt", "s32",
            "-bits_per_raw_sample", "24",
            "-c:a", "flac",
            "-compression_level", "8",
            output.path,
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        // stdout при выводе в файл ffmpeg не использует; /dev/null убирает любой
        // теоретический дедлок от непрочитанного пайпа (буфер некуда переполнять).
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        // stderr крошечный (loglevel error) — читаем до EOF, потом ждём выход.
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw TranscodeError.ffmpegFailed(code: process.terminationStatus, stderr: stderr)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw TranscodeError.outputMissing(output)
        }
    }
}
