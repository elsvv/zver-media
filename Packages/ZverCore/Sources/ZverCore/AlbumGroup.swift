import Foundation

/// Группа треков одного альбома.
///
/// Идентичность альбома — это ПАПКА (родительский каталог файлов), а не тег ALBUM:
/// две оцифровки одной пластинки в разных папках остаются разными альбомами, даже
/// если тег ALBUM у них совпадает (иначе версии сливались бы и терялись). `id` —
/// путь папки; `album` — отображаемое название (по тегу, см. `group`).
public struct AlbumGroup: Identifiable, Equatable, Sendable {
    public static let noAlbumTitle = "Без альбома"

    public let id: String          // стабильный ключ: путь папки (или noAlbumTitle)
    public let album: String       // отображаемое название (тег или имя папки)
    public let artist: String?     // артист первого трека (MVP)
    public let tracks: [Track]

    public init(id: String, album: String, artist: String?, tracks: [Track]) {
        self.id = id
        self.album = album
        self.artist = artist
        self.tracks = tracks
    }

    /// Одна дисковая секция альбома: номер, метка и его треки (в порядке трека).
    public struct DiscSection: Identifiable, Equatable, Sendable {
        public let number: Int          // 1-based; nil-диски нормализованы в 1
        public let label: String?       // «CD1»/«Side A» из папки/плейлиста; nil → по номеру
        public let tracks: [Track]
        public var id: Int { number }
        /// Заголовок секции: метка как есть, иначе «Диск N».
        public var title: String { label ?? "Диск \(number)" }
    }

    /// Треки, разбитые по дискам, в порядке (диск, трек). `tracks` уже
    /// отсортированы `group`, поэтому диски идут непрерывными отрезками — просто
    /// склеиваем соседние с одинаковым номером (nil-диск нормализуем в 1). Метка
    /// секции — из первого её трека.
    public var discSections: [DiscSection] {
        var sections: [(number: Int, label: String?, tracks: [Track])] = []
        for track in tracks {
            let disc = track.discNumber ?? 1
            if var last = sections.last, last.number == disc {
                last.tracks.append(track)
                sections[sections.count - 1] = last
            } else {
                sections.append((number: disc, label: track.discLabel, tracks: [track]))
            }
        }
        return sections.map { DiscSection(number: $0.number, label: $0.label, tracks: $0.tracks) }
    }

    /// Альбом занимает больше одного диска — показывать заголовки «Диск N».
    public var hasMultipleDiscs: Bool { discSections.count > 1 }

    /// Группирует треки по альбомам-ПАПКАМ: каждая папка (родительский каталог
    /// файлов) — отдельный альбом. Разные папки = разные альбомы, даже при
    /// одинаковом теге ALBUM (поддержка версий/оцифровок). Отображаемое название —
    /// по большинству непустых тегов ALBUM в папке (тег с опечаткой у части треков
    /// не плодит альбом), с фоллбэком на имя папки.
    ///
    /// Треки без тега альбома (пустой/пробельный ALBUM) — «свободные»: сканер
    /// проставляет не-корневым трекам album = имя папки, поэтому пустой тег ⟺
    /// одиночный трек в корне скана. Все такие треки идут в одну группу
    /// «Без альбома» в конце (как раньше).
    ///
    /// Альбомы — по алфавиту (как в Finder, без учёта регистра), тай-брейк по пути
    /// папки (детерминизм при одинаковых названиях-версиях). Внутри альбома —
    /// по trackNumber (nil — в конец), затем по title.
    public static func group(_ tracks: [Track]) -> [AlbumGroup] {
        // Свободные треки (без тега) отделяем сразу — они группируются вместе
        // независимо от папки, сохраняя прежнее поведение «Без альбома».
        var orphans: [Track] = []
        // Остальные — по папке, с сохранением порядка первого появления папки.
        var byFolder: [String: [Track]] = [:]
        var folderOrder: [String] = []
        for track in tracks {
            if normalizedAlbum(track.album) == nil {
                orphans.append(track)
            } else {
                let folder = albumFolderPath(for: track)
                if byFolder[folder] == nil { folderOrder.append(folder) }
                byFolder[folder, default: []].append(track)
            }
        }

        func makeGroup(id: String, title: String?, tracks: [Track]) -> AlbumGroup {
            let sorted = tracks.sorted { lhs, rhs in
                // Диск — старший ключ порядка: без него треки много-дискового
                // альбома перемешивались бы (диск 2 трек 1 «вклинивался» между
                // диск 1 трек 1 и 2). nil диск считаем первым (одно-дисковый).
                let ld = lhs.discNumber ?? 1
                let rd = rhs.discNumber ?? 1
                if ld != rd { return ld < rd }
                switch (lhs.trackNumber, rhs.trackNumber) {
                case let (l?, r?) where l != r: return l < r
                case (.some, .none): return true
                case (.none, .some): return false
                default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            }
            return AlbumGroup(id: id,
                              album: title ?? displayTitle(for: sorted, folderPath: id),
                              artist: sorted.first?.artist,
                              tracks: sorted)
        }

        var groups = folderOrder
            .map { folder in makeGroup(id: folder, title: nil, tracks: byFolder[folder] ?? []) }
            .sorted { lhs, rhs in
                let byTitle = lhs.album.localizedStandardCompare(rhs.album)
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return lhs.id < rhs.id   // одинаковые названия (версии) — по пути папки
            }

        if !orphans.isEmpty {
            groups.append(makeGroup(id: noAlbumTitle, title: noAlbumTitle, tracks: orphans))
        }
        return groups
    }

    /// Отображаемое название альбома-папки: большинство непустых тегов ALBUM среди
    /// треков папки; при равенстве счёта — по первому появлению; при полном
    /// отсутствии тегов — имя папки (для не-корневых треков сканер уже проставил
    /// имя папки в тег, так что фоллбэк — защитный).
    private static func displayTitle(for tracks: [Track], folderPath: String) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for tag in tracks.compactMap({ normalizedAlbum($0.album) }) {
            if counts[tag] == nil { order.append(tag) }
            counts[tag, default: 0] += 1
        }
        let majority = order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
        return majority ?? (folderPath as NSString).lastPathComponent
    }

    /// Путь папки-альбома трека. Если у трека есть метка диска, совпадающая (без
    /// учёта регистра) с именем его непосредственной папки (папка-диск `CD1`/
    /// `Side A`), альбомом считаем РОДИТЕЛЬСКУЮ папку — так диски-подпапки
    /// сворачиваются в один альбом, а не плодят по альбому на диск.
    private static func albumFolderPath(for track: Track) -> String {
        let parent = track.url.deletingLastPathComponent().standardizedFileURL
        if let disc = track.discLabel,
           parent.lastPathComponent.caseInsensitiveCompare(disc) == .orderedSame {
            return parent.deletingLastPathComponent().standardizedFileURL.path
        }
        return parent.path
    }

    /// Пустая или пробельная строка альбома — это отсутствие альбома.
    private static func normalizedAlbum(_ album: String?) -> String? {
        guard let album,
              !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return album
    }
}
