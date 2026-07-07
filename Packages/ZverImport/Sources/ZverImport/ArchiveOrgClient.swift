import Foundation

/// Карточка концерта из поиска Live Music Archive (`advancedsearch.php`). Достаточно
/// для списка: заголовок, исполнитель, год, число скачиваний. `identifier` открывает
/// экран релиза (`/metadata/{identifier}`).
public struct ArchiveSearchItem: Sendable, Equatable, Identifiable {
    public var id: String { identifier }
    public let identifier: String
    public let title: String?
    public let creator: String?
    public let year: String?
    public let downloads: Int?

    public init(identifier: String, title: String?, creator: String?, year: String?, downloads: Int?) {
        self.identifier = identifier
        self.title = title
        self.creator = creator
        self.year = year
        self.downloads = downloads
    }
}

/// Один FLAC-файл релиза из `/metadata`. `name` — путь файла внутри item (для
/// download-URL), `format` — «Flac» или «24bit Flac».
public struct ArchiveFile: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let format: String
    public let sizeBytes: Int64?
    public let durationSeconds: Double?
    public let title: String?
    public let track: Int?

    public init(name: String, format: String, sizeBytes: Int64?, durationSeconds: Double?, title: String?, track: Int?) {
        self.name = name
        self.format = format
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.title = title
        self.track = track
    }
}

/// Релиз (концерт) Live Music Archive: метаданные + отсортированный список FLAC-файлов
/// (только lossless, MP3/обложки/логи отфильтрованы).
public struct ArchiveRelease: Sendable, Equatable {
    public let identifier: String
    public let title: String?
    public let creator: String?
    public let year: String?
    public let flacFiles: [ArchiveFile]

    public init(identifier: String, title: String?, creator: String?, year: String?, flacFiles: [ArchiveFile]) {
        self.identifier = identifier
        self.title = title
        self.creator = creator
        self.year = year
        self.flacFiles = flacFiles
    }
}

/// Ошибка сетевого слоя клиента Internet Archive.
public enum ArchiveError: Error, Sendable, Equatable {
    /// Ответ не HTTP (или не 2xx).
    case http(Int)
    case notHTTP
}

/// Клиент Internet Archive / Live Music Archive поверх официальных публичных API без
/// ключей: `advancedsearch.php` (поиск по коллекции `etree`), `/metadata/{id}` (файлы
/// релиза) и `/download/{id}/{file}` (сам файл, Range поддерживается).
///
/// Чистые построители запросов и Codable-разбор JSON под TDD (`ArchiveOrgClientTests`);
/// сеть — тонкий `URLSession`-адаптер (`search`/`fetchRelease`) по образцу
/// `ZverBrain.ModelCatalogFetcher`. Загрузку файлов ведёт приложение (`ArchiveDownloader`
/// поверх `URLSession` с Range-докачкой), используя `downloadURL(...)`.
public enum ArchiveOrgClient {
    static let host = "archive.org"

    /// Форматы IA, считающиеся lossless FLAC (для фильтра файлов релиза).
    static let flacFormats: Set<String> = ["flac", "24bit flac"]

    // MARK: - Построение запросов (чистое)

    /// Lucene-запрос поиска: коллекция `etree` + пользовательские термины. Пустой ввод —
    /// только коллекция (весь Live Music Archive).
    static func searchQuery(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "collection:(etree)" }
        return "collection:(etree) AND (\(trimmed))"
    }

    /// URL `advancedsearch.php`: запрос + запрашиваемые поля карточки + сортировка по
    /// популярности + пагинация + `output=json`.
    static func searchURL(query: String, rows: Int = 50, page: Int = 1) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/advancedsearch.php"
        var items: [URLQueryItem] = [URLQueryItem(name: "q", value: searchQuery(query))]
        for field in ["identifier", "title", "creator", "year", "downloads"] {
            items.append(URLQueryItem(name: "fl[]", value: field))
        }
        items.append(URLQueryItem(name: "sort[]", value: "downloads desc"))
        items.append(URLQueryItem(name: "rows", value: String(rows)))
        items.append(URLQueryItem(name: "page", value: String(page)))
        items.append(URLQueryItem(name: "output", value: "json"))
        components.queryItems = items
        return components.url!
    }

    /// URL метаданных релиза `/metadata/{identifier}`.
    static func metadataURL(identifier: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/metadata/\(identifier)"
        return components.url ?? URL(string: "https://\(host)/metadata/\(identifier)")!
    }

    /// URL скачивания файла `/download/{identifier}/{fileName}`. Имя файла может нести
    /// пробелы/подпапки — `URLComponents` перкодит сегменты пути.
    public static func downloadURL(identifier: String, fileName: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/download/\(identifier)/\(fileName)"
        return components.url ?? URL(string: "https://\(host)/download/\(identifier)/\(fileName)")!
    }

    // MARK: - Фильтр форматов

    /// Является ли формат IA lossless-FLAC (без учёта регистра).
    static func isFlacFormat(_ format: String?) -> Bool {
        guard let format else { return false }
        return flacFormats.contains(format.lowercased())
    }

    // MARK: - Разбор JSON (чистое)

    /// Разбирает ответ `advancedsearch.php` в карточки. Записи без `identifier`
    /// пропускаются (не роняют весь список).
    static func parseSearch(_ data: Data) throws -> [ArchiveSearchItem] {
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        return response.response.docs.compactMap(\.item)
    }

    /// Разбирает ответ `/metadata` в релиз: метаданные + только FLAC-файлы,
    /// отсортированные по номеру дорожки (затем по имени).
    static func parseMetadata(_ data: Data, identifier: String) throws -> ArchiveRelease {
        let response = try JSONDecoder().decode(MetadataResponse.self, from: data)
        let flac = response.files
            .filter { isFlacFormat($0.format?.value) }
            .map { entry in
                ArchiveFile(
                    name: entry.name,
                    format: entry.format?.value ?? "Flac",
                    sizeBytes: entry.size?.value,
                    durationSeconds: parseDuration(entry.length?.value),
                    title: entry.title?.value,
                    track: parseTrack(entry.track?.value)
                )
            }
            .sorted { lhs, rhs in
                let lt = lhs.track ?? Int.max
                let rt = rhs.track ?? Int.max
                if lt != rt { return lt < rt }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        let meta = response.metadata
        return ArchiveRelease(
            identifier: meta?.identifier?.value ?? identifier,
            title: meta?.title?.value,
            creator: meta?.creator?.value,
            year: meta?.year?.value,
            flacFiles: flac
        )
    }

    /// Число дорожки из строки IA («1», «01», «1/12») — ведущее целое.
    static func parseTrack(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let digits = raw.prefix { $0.isNumber }
        return Int(digits)
    }

    /// Длительность из строки IA: секунды дробью («365.5») или «мм:сс»/«ч:мм:сс».
    static func parseDuration(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.contains(":") {
            let parts = raw.split(separator: ":").map { Double($0) ?? 0 }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        return Double(raw)
    }

    // MARK: - Сеть (тонкий URLSession-адаптер)

    /// Короткий таймаут поиска — это вспомогательный запрос UI.
    static let requestTimeout: TimeInterval = 20

    /// Ищет концерты в Live Music Archive по строке (артист/название).
    public static func search(
        query: String,
        rows: Int = 50,
        page: Int = 1,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async throws -> [ArchiveSearchItem] {
        var request = URLRequest(url: searchURL(query: query, rows: rows, page: page))
        request.timeoutInterval = requestTimeout
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try parseSearch(data)
    }

    /// Загружает метаданные релиза и возвращает его FLAC-файлы.
    public static func fetchRelease(
        identifier: String,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async throws -> ArchiveRelease {
        var request = URLRequest(url: metadataURL(identifier: identifier))
        request.timeoutInterval = requestTimeout
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try parseMetadata(data, identifier: identifier)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ArchiveError.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw ArchiveError.http(http.statusCode) }
    }
}

// MARK: - Codable-формы ответов IA

/// Значение IA, приходящее то строкой, то массивом строк, то числом (`creator`,
/// `title`, `year`, `format`, `track`, `length`): массив склеиваем через «, », число —
/// в строку. Пустое/иное → nil, чтобы UI не показывал пустышки.
private struct IAString: Decodable {
    let value: String?
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string.isEmpty ? nil : string
        } else if let array = try? container.decode([String].self) {
            let joined = array.filter { !$0.isEmpty }.joined(separator: ", ")
            value = joined.isEmpty ? nil : joined
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else {
            value = nil
        }
    }
}

/// Целое IA, приходящее числом или строкой (`downloads`, `size`).
private struct IAInt: Decodable {
    let value: Int64?
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int64.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = Int64(double)
        } else if let string = try? container.decode(String.self) {
            value = Int64(string)
        } else {
            value = nil
        }
    }
}

/// Ответ `advancedsearch.php`.
private struct SearchResponse: Decodable {
    struct Response: Decodable {
        let docs: [LossyDoc]
    }
    let response: Response

    /// Запись поиска, которая МОЖЕТ не разобраться (нет `identifier`) — не должна ронять
    /// весь массив. `init` не бросает, поэтому декод `[LossyDoc]` проходит по всем.
    struct LossyDoc: Decodable {
        let item: ArchiveSearchItem?
        init(from decoder: any Decoder) throws {
            item = try? Doc(from: decoder).item
        }
    }

    struct Doc: Decodable {
        let identifier: String
        let title: IAString?
        let creator: IAString?
        let year: IAString?
        let downloads: IAInt?

        var item: ArchiveSearchItem {
            ArchiveSearchItem(
                identifier: identifier,
                title: title?.value,
                creator: creator?.value,
                year: year?.value,
                downloads: downloads?.value.map(Int.init)
            )
        }
    }
}

/// Ответ `/metadata/{identifier}`.
private struct MetadataResponse: Decodable {
    struct Meta: Decodable {
        let identifier: IAString?
        let title: IAString?
        let creator: IAString?
        let year: IAString?
    }
    struct FileEntry: Decodable {
        let name: String
        let format: IAString?
        let size: IAInt?
        let length: IAString?
        let title: IAString?
        let track: IAString?
    }
    let metadata: Meta?
    let files: [FileEntry]
}
