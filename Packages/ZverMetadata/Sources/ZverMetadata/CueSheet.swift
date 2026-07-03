import Foundation

/// Один трек внутри `FILE` cue-шита: 1-based номер (`TRACK NN`), опциональные
/// `TITLE`/`PERFORMER` и старт (`INDEX 01`) в CD-фреймах (1/75 с, 75 fps).
public struct CueTrack: Equatable, Sendable {
    public let index: Int
    public let title: String?
    public let performer: String?
    /// Старт трека (`INDEX 01`, при отсутствии — `INDEX 00`) в 1/75 секунды.
    public let startFrames75: Int

    public init(index: Int, title: String?, performer: String?, startFrames75: Int) {
        self.index = index
        self.title = title
        self.performer = performer
        self.startFrames75 = startFrames75
    }
}

/// Один `FILE "name" WAVE` и его треки (в порядке появления).
public struct CueFile: Equatable, Sendable {
    public let fileName: String
    public let tracks: [CueTrack]

    public init(fileName: String, tracks: [CueTrack]) {
        self.fileName = fileName
        self.tracks = tracks
    }

    /// Старт каждого трека ЭТОГО файла в сэмплах: `round(frames75/75 · sampleRate)`.
    /// Офсеты ОТНОСИТЕЛЬНЫ началу этого `.flac` — для multi-file cue (винил: стороны;
    /// CD-диски) каждая сторона считается от нуля СВОЕГО файла.
    public func frameOffsets(sampleRate: Double) -> [Int64] {
        tracks.map { Int64((Double($0.startFrames75) / 75.0 * sampleRate).rounded()) }
    }
}

/// Чистый разбор cue-шита (`.cue`): границы треков внутри одного непрерывного
/// аудиофайла (audiophile-рип «весь CD одним `.flac` + `.cue`»), а также имена
/// файлов, названия и исполнители по трекам.
///
/// В отличие от `.m3u` (порядок/диски по отдельным файлам), cue-шит образа
/// содержит один `FILE "album.flac" WAVE` и внутри него `TRACK NN AUDIO` с
/// `INDEX 01 MM:SS:FF` — точкой старта трека в 1/75 секунды (CD-фрейм, 75 fps).
/// Границы храним ИМЕННО в этих CD-фреймах (побитово точно), конвертацию в сэмплы
/// делает ``frameOffsets(sampleRate:)`` по реальному sampleRate контейнера.
///
/// Раскрываем в N треков только образ (`isSingleFileImage`): один `FILE` и больше
/// одного `TRACK`. Если `FILE` на каждый трек — это обычный многофайловый альбом,
/// и cue игнорируется вызывающей стороной (``LibraryScanner``).
///
/// Только разбор строки, без ФС — покрыт юнит-тестами на литералах; чтение файла
/// (в т.ч. Shift-JIS для японских рипов) и раскрытие в треки — в ``LibraryScanner``.
public struct CueSheet: Equatable, Sendable {
    public let files: [CueFile]

    public init(files: [CueFile]) {
        self.files = files
    }

    /// Образ (image+cue): ровно один `FILE` с более чем одним `TRACK`.
    public var isSingleFileImage: Bool {
        files.count == 1 && files[0].tracks.count > 1
    }

    /// `FILE`-запись, чьё имя (регистронезависимо) совпадает с `fileName`, и её индекс
    /// среди `files` — для сквозной нумерации. Сопоставляет конкретный `.flac` его
    /// секции в cue (в т.ч. multi-file: каждая сторона/диск — свой `FILE`). nil — файла
    /// нет в cue.
    public func file(named fileName: String) -> (index: Int, file: CueFile)? {
        guard let index = files.firstIndex(where: {
            $0.fileName.caseInsensitiveCompare(fileName) == .orderedSame
        }) else { return nil }
        return (index, files[index])
    }

    /// Сколько треков во всех `FILE` ДО индекса `fileIndex` — сквозной офсет нумерации
    /// (сторона 2 продолжает нумерацию стороны 1), не полагаясь на номера `TRACK` в cue.
    public func trackOffset(beforeFile fileIndex: Int) -> Int {
        files[..<min(fileIndex, files.count)].reduce(0) { $0 + $1.tracks.count }
    }

    /// Старт каждого трека ПЕРВОГО `FILE` в сэмплах. Для multi-file используйте
    /// `CueFile.frameOffsets(sampleRate:)` по конкретному файлу.
    public func frameOffsets(sampleRate: Double) -> [Int64] {
        files.first?.frameOffsets(sampleRate: sampleRate) ?? []
    }

    // MARK: - Разбор

    /// Разбор cue-шита в модель. Устойчив к отступам, `REM`-строкам, BOM, CRLF и
    /// незакавыченным именам файлов. `TITLE`/`PERFORMER`/`INDEX` до первого
    /// `TRACK` (уровень альбома) в модель не попадают — берём по трекам.
    public static func parse(from content: String) -> CueSheet {
        var stripped = content
        if stripped.hasPrefix("\u{FEFF}") { stripped.removeFirst() }

        var files: [FileBuilder] = []

        for rawLine in stripped.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let (command, rest) = splitCommand(line)

            switch command.uppercased() {
            case "REM":
                continue
            case "FILE":
                let name = firstQuoted(rest) ?? droppingTrailingType(rest)
                files.append(FileBuilder(fileName: name))
            case "TRACK":
                guard !files.isEmpty else { continue }
                let tokens = rest.split(separator: " ", omittingEmptySubsequences: true)
                let number = tokens.first.flatMap { Int($0) }
                    ?? (files[files.count - 1].tracks.count + 1)
                files[files.count - 1].tracks.append(TrackBuilder(index: number))
            case "TITLE":
                if var track = currentTrack(&files) {
                    track.title = firstQuoted(rest) ?? rest
                    setCurrentTrack(&files, track)
                }
            case "PERFORMER":
                if var track = currentTrack(&files) {
                    track.performer = firstQuoted(rest) ?? rest
                    setCurrentTrack(&files, track)
                }
            case "INDEX":
                guard var track = currentTrack(&files) else { continue }
                let tokens = rest.split(separator: " ", omittingEmptySubsequences: true)
                guard tokens.count >= 2, let idx = Int(tokens[0]) else { continue }
                let frames = framesFromMSF(tokens[1])
                if idx == 1 {
                    track.index01 = frames
                } else if idx == 0 {
                    track.index00 = frames
                }
                setCurrentTrack(&files, track)
            default:
                continue
            }
        }

        return CueSheet(files: files.map { fb in
            CueFile(fileName: fb.fileName, tracks: fb.tracks.map { tb in
                CueTrack(index: tb.index,
                         title: tb.title,
                         performer: tb.performer,
                         // Граница = INDEX 01; фоллбэк на INDEX 00 (пре-гэп) при отсутствии.
                         startFrames75: tb.index01 ?? tb.index00 ?? 0)
            })
        })
    }

    // MARK: - Строители (мутабельные во время разбора)

    private struct FileBuilder {
        let fileName: String
        var tracks: [TrackBuilder] = []
    }
    private struct TrackBuilder {
        let index: Int
        var title: String? = nil
        var performer: String? = nil
        var index00: Int? = nil
        var index01: Int? = nil
    }

    /// Текущий (последний) трек последнего файла — цель для `TITLE`/`PERFORMER`/`INDEX`.
    private static func currentTrack(_ files: inout [FileBuilder]) -> TrackBuilder? {
        guard let f = files.indices.last, let t = files[f].tracks.indices.last else { return nil }
        return files[f].tracks[t]
    }
    private static func setCurrentTrack(_ files: inout [FileBuilder], _ track: TrackBuilder) {
        guard let f = files.indices.last, let t = files[f].tracks.indices.last else { return }
        files[f].tracks[t] = track
    }

    // MARK: - Помощники разбора строки

    /// Делит строку на команду (первый токен) и остаток (без ведущих пробелов).
    private static func splitCommand(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (line, "")
        }
        let command = String(line[line.startIndex..<space])
        let rest = String(line[line.index(after: space)...])
            .trimmingCharacters(in: .whitespaces)
        return (command, rest)
    }

    /// Содержимое первой пары кавычек, если есть.
    private static func firstQuoted(_ s: String) -> String? {
        guard let open = s.firstIndex(of: "\"") else { return nil }
        let after = s.index(after: open)
        guard let close = s[after...].firstIndex(of: "\"") else { return nil }
        return String(s[after..<close])
    }

    /// Незакавыченное имя файла из `FILE name WAVE`: отбрасывает последний токен-тип
    /// (`WAVE`/`BINARY`/`MP3`/…), если токенов больше одного.
    private static func droppingTrailingType(_ rest: String) -> String {
        let tokens = rest.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 2 else { return rest }
        return tokens.dropLast().joined(separator: " ")
    }

    /// `MM:SS:FF` → CD-фреймы (1/75 с): `((MM·60 + SS)·75 + FF)`. Мусор → 0.
    private static func framesFromMSF(_ token: Substring) -> Int {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let mm = Int(parts[0]), let ss = Int(parts[1]), let ff = Int(parts[2])
        else { return 0 }
        return ((mm * 60) + ss) * 75 + ff
    }
}
