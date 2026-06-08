import Testing
import Foundation
@testable import ZverTransport

/// Поведение `RemoteCodec`: версия, forward-compat (неизвестный `type` и лишние
/// ключи не роняют декод), доступность чужой версии вызывающему.
@Suite struct RemoteCodecTests {
    private let codec = RemoteCodec()

    @Test func decodeVersionReadsProtocolVersionWithoutFullDecode() throws {
        let json = """
        { "protocolVersion": 7, "payload": { "type": "play" } }
        """
        let version = try codec.decodeVersion(Data(json.utf8))
        #expect(version == 7)
    }

    @Test func decodeWithDifferentProtocolVersionStillParses() throws {
        // Несовместимость по версии — решение вызывающего, а не пустое сообщение.
        let json = """
        { "protocolVersion": 99, "payload": { "type": "play" } }
        """
        let decoded = try codec.decode(Data(json.utf8))
        #expect(decoded.protocolVersion == 99)
        #expect(decoded.protocolVersion != RemoteMessage.currentProtocolVersion)
        #expect(decoded.payload == .play)
    }

    @Test func unknownPayloadTypeDecodesAsUnknownNotThrow() throws {
        // Forward-compat: новый клиент шлёт неизвестную команду — старый декодер
        // НЕ роняет соединение, отдаёт `.unknown(type:)`, вызывающий игнорирует.
        let json = """
        { "protocolVersion": 1, "payload": { "type": "teleport", "x": 1 } }
        """
        let decoded = try codec.decode(Data(json.utf8))
        #expect(decoded.payload == .unknown(type: "teleport"))
    }

    @Test func unknownTopLevelKeysIgnored() throws {
        let json = """
        { "protocolVersion": 1, "futureFlag": true, "payload": { "type": "pause" } }
        """
        let decoded = try codec.decode(Data(json.utf8))
        #expect(decoded.payload == .pause)
    }

    @Test func unknownKeysInsidePayloadIgnored() throws {
        // Известный type с лишними будущими полями — парсим, лишнее игнорируем.
        let json = """
        { "protocolVersion": 1, "payload": { "type": "seek", "seconds": 5.0, "futureField": "x" } }
        """
        let decoded = try codec.decode(Data(json.utf8))
        #expect(decoded.payload == .seek(seconds: 5.0))
    }

    @Test func unknownKeysInsideNestedStateIgnored() throws {
        let json = """
        {
          "protocolVersion": 1,
          "payload": {
            "type": "state",
            "state": {
              "playback": "playing",
              "position": 10.0,
              "queue": [],
              "futureStateField": 42,
              "current": {
                "id": "t1",
                "title": "T",
                "duration": 100.0,
                "futureTrackField": "x"
              }
            }
          }
        }
        """
        let decoded = try codec.decode(Data(json.utf8))
        guard case let .state(s) = decoded.payload else {
            Issue.record("expected .state payload")
            return
        }
        #expect(s.playback == .playing)
        #expect(s.current?.id == "t1")
        #expect(s.current?.artist == nil)
        #expect(s.queue.isEmpty)
    }

    @Test func encodeProducesValidJSONObject() throws {
        let data = try codec.encode(RemoteMessage(payload: .next))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object != nil)
        #expect(object?["protocolVersion"] as? Int == 1)
    }

    @Test func unknownPlaybackStringDecodesToUnknownPlayback() throws {
        // Forward-compat для вложенных enum-ов: новое состояние playback.
        let json = """
        {
          "protocolVersion": 1,
          "payload": {
            "type": "state",
            "state": { "playback": "buffering", "position": 0.0, "queue": [] }
          }
        }
        """
        let decoded = try codec.decode(Data(json.utf8))
        guard case let .state(s) = decoded.payload else {
            Issue.record("expected .state payload")
            return
        }
        #expect(s.playback == .unknown)
    }

    @Test func malformedJSONThrows() {
        #expect(throws: (any Error).self) {
            _ = try codec.decode(Data("{ not json".utf8))
        }
    }

    @Test func missingProtocolVersionThrows() {
        // Конверт обязан нести версию — её отсутствие это уже не наш протокол.
        #expect(throws: (any Error).self) {
            _ = try codec.decode(Data(#"{ "payload": { "type": "play" } }"#.utf8))
        }
    }
}
