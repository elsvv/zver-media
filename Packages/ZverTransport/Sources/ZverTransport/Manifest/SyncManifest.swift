import Foundation

/// Версионируемый JSON-манифест синка Mac → iPhone (протокол синка, версия 1).
///
/// `protocolVersion` сериализуется явным полем. Декод манифеста с версией,
/// отличной от текущей, успешно парсится — несовместимость это решение
/// вызывающего, а не «пустой манифест». Неизвестные лишние ключи игнорируются
/// (forward-compat): будущие версии могут добавлять поля.
public struct SyncManifest: Codable, Equatable, Sendable {
    /// Текущая версия протокола, которой придерживается эта сборка.
    public static let currentProtocolVersion: Int = 1

    public var protocolVersion: Int
    public var albums: [ManifestAlbum]

    public init(protocolVersion: Int = SyncManifest.currentProtocolVersion,
                albums: [ManifestAlbum]) {
        self.protocolVersion = protocolVersion
        self.albums = albums
    }
}
