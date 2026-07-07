import Foundation

/// Находит исполняемый `ffmpeg` на Маке для конвертации DSD → FLAC.
///
/// macOS сам FLAC не кодирует (Core Audio — только декод), а DSD не декодирует
/// вообще; `ffmpeg` умеет и то, и другое в один проход. Ищем в стандартных
/// местах (Homebrew Intel/ARM, системный `bin`) и в `PATH`. nil — не установлен;
/// вызывающая сторона показывает подсказку «brew install ffmpeg».
enum FFmpegLocator {
    /// Типичные пути установки (Homebrew ARM/Intel, MacPorts, системный).
    private static let knownPaths = [
        "/opt/homebrew/bin/ffmpeg",   // Homebrew (Apple Silicon)
        "/usr/local/bin/ffmpeg",      // Homebrew (Intel)
        "/opt/local/bin/ffmpeg",      // MacPorts
        "/usr/bin/ffmpeg",
    ]

    /// URL исполняемого `ffmpeg` или nil, если не найден.
    static func find() -> URL? {
        let fm = FileManager.default
        for path in knownPaths where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return locateViaWhich()
    }

    /// Резерв: спросить `which ffmpeg` через логин-shell (подхватит нестандартный
    /// `PATH` пользователя). Тихо возвращает nil при любой осечке.
    private static func locateViaWhich() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v ffmpeg"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
