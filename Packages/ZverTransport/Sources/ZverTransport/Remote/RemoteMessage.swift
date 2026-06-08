import Foundation

/// Версионируемый конверт протокола пульта (как `SyncManifest` этапа 3).
///
/// `protocolVersion` сериализуется явным полем; декод конверта чужой версии
/// успешен — несовместимость это решение вызывающего, а не «пустое сообщение»
/// (см. `RemoteCodec.decode`). Полезная нагрузка — `RemotePayload` (oneOf по
/// тегу `type`).
public struct RemoteMessage: Codable, Equatable, Sendable {
    /// Текущая версия протокола пульта, которой придерживается эта сборка.
    public static let currentProtocolVersion: Int = 1

    public var protocolVersion: Int
    public var payload: RemotePayload

    public init(protocolVersion: Int = RemoteMessage.currentProtocolVersion,
                payload: RemotePayload) {
        self.protocolVersion = protocolVersion
        self.payload = payload
    }
}

/// Полезная нагрузка протокола пульта (oneOf, тег `type`).
///
/// Кодек тегирует вариант полем `type`; неизвестный будущей версии `type`
/// декодится в `.unknown(type:)` — соединение НЕ рвётся (forward-compat),
/// вызывающий просто игнорирует такой кадр. Equatable/Sendable.
public enum RemotePayload: Equatable, Sendable {
    // MARK: Mac → iPhone (команды/запросы)
    case pair(code: String)                         // до авторизации
    case hello(token: String)                       // первое сообщение при наличии токена
    case play
    case pause
    case togglePlayPause
    case next
    case previous
    case seek(seconds: Double)
    case requestLibrary
    case requestAlbumTracks(albumId: String)
    case playAlbum(albumId: String, startIndex: Int)

    // MARK: iPhone → Mac (ответы/пуш)
    case paired(token: String)                      // ответ на pair при верном коде
    case helloAck(ok: Bool, protocolVersion: Int)   // ответ на hello
    case state(RemotePlayerState)                   // пуш при изменении
    case library(RemoteLibrary)                     // на коннект и при изменении каталога
    case albumTracks(albumId: String, tracks: [RemoteTrack])
    case error(message: String)

    /// Forward-compat: неизвестный будущей версии `type`. Несёт прочитанный тег,
    /// чтобы вызывающий мог залогировать, но НЕ роняет декод/соединение.
    case unknown(type: String)
}

extension RemotePayload: Codable {
    /// Стабильные строковые теги вариантов (значение поля `type`).
    enum Tag: String {
        case pair, hello, play, pause, togglePlayPause, next, previous, seek
        case requestLibrary, requestAlbumTracks, playAlbum
        case paired, helloAck, state, library, albumTracks, error
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case code, token, seconds, albumId, startIndex
        case ok, protocolVersion, message
        case state, library, tracks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        guard let tag = Tag(rawValue: rawType) else {
            // Неизвестный type — forward-compat, не бросаем.
            self = .unknown(type: rawType)
            return
        }
        switch tag {
        case .pair:
            self = .pair(code: try container.decode(String.self, forKey: .code))
        case .hello:
            self = .hello(token: try container.decode(String.self, forKey: .token))
        case .play:
            self = .play
        case .pause:
            self = .pause
        case .togglePlayPause:
            self = .togglePlayPause
        case .next:
            self = .next
        case .previous:
            self = .previous
        case .seek:
            self = .seek(seconds: try container.decode(Double.self, forKey: .seconds))
        case .requestLibrary:
            self = .requestLibrary
        case .requestAlbumTracks:
            self = .requestAlbumTracks(albumId: try container.decode(String.self, forKey: .albumId))
        case .playAlbum:
            self = .playAlbum(
                albumId: try container.decode(String.self, forKey: .albumId),
                startIndex: try container.decode(Int.self, forKey: .startIndex)
            )
        case .paired:
            self = .paired(token: try container.decode(String.self, forKey: .token))
        case .helloAck:
            self = .helloAck(
                ok: try container.decode(Bool.self, forKey: .ok),
                protocolVersion: try container.decode(Int.self, forKey: .protocolVersion)
            )
        case .state:
            self = .state(try container.decode(RemotePlayerState.self, forKey: .state))
        case .library:
            self = .library(try container.decode(RemoteLibrary.self, forKey: .library))
        case .albumTracks:
            self = .albumTracks(
                albumId: try container.decode(String.self, forKey: .albumId),
                tracks: try container.decode([RemoteTrack].self, forKey: .tracks)
            )
        case .error:
            self = .error(message: try container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pair(code):
            try container.encode(Tag.pair.rawValue, forKey: .type)
            try container.encode(code, forKey: .code)
        case let .hello(token):
            try container.encode(Tag.hello.rawValue, forKey: .type)
            try container.encode(token, forKey: .token)
        case .play:
            try container.encode(Tag.play.rawValue, forKey: .type)
        case .pause:
            try container.encode(Tag.pause.rawValue, forKey: .type)
        case .togglePlayPause:
            try container.encode(Tag.togglePlayPause.rawValue, forKey: .type)
        case .next:
            try container.encode(Tag.next.rawValue, forKey: .type)
        case .previous:
            try container.encode(Tag.previous.rawValue, forKey: .type)
        case let .seek(seconds):
            try container.encode(Tag.seek.rawValue, forKey: .type)
            try container.encode(seconds, forKey: .seconds)
        case .requestLibrary:
            try container.encode(Tag.requestLibrary.rawValue, forKey: .type)
        case let .requestAlbumTracks(albumId):
            try container.encode(Tag.requestAlbumTracks.rawValue, forKey: .type)
            try container.encode(albumId, forKey: .albumId)
        case let .playAlbum(albumId, startIndex):
            try container.encode(Tag.playAlbum.rawValue, forKey: .type)
            try container.encode(albumId, forKey: .albumId)
            try container.encode(startIndex, forKey: .startIndex)
        case let .paired(token):
            try container.encode(Tag.paired.rawValue, forKey: .type)
            try container.encode(token, forKey: .token)
        case let .helloAck(ok, protocolVersion):
            try container.encode(Tag.helloAck.rawValue, forKey: .type)
            try container.encode(ok, forKey: .ok)
            try container.encode(protocolVersion, forKey: .protocolVersion)
        case let .state(state):
            try container.encode(Tag.state.rawValue, forKey: .type)
            try container.encode(state, forKey: .state)
        case let .library(library):
            try container.encode(Tag.library.rawValue, forKey: .type)
            try container.encode(library, forKey: .library)
        case let .albumTracks(albumId, tracks):
            try container.encode(Tag.albumTracks.rawValue, forKey: .type)
            try container.encode(albumId, forKey: .albumId)
            try container.encode(tracks, forKey: .tracks)
        case let .error(message):
            try container.encode(Tag.error.rawValue, forKey: .type)
            try container.encode(message, forKey: .message)
        case let .unknown(type):
            // Прозрачная пере-сериализация неизвестного тега (тело потеряно, но
            // тип сохраняется — этого достаточно, такие кадры мы не порождаем).
            try container.encode(type, forKey: .type)
        }
    }
}
