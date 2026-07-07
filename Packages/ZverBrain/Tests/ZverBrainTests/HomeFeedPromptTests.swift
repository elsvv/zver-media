import Testing
import Foundation
@testable import ZverBrain

/// Тесты сборки промпта: снапшот полностью попадает в user-промпт, а system-промпт
/// несёт роль, запрет выдумывать id и строгий JSON-формат.
@Suite struct HomeFeedPromptTests {
    private func sampleSnapshot() -> LibrarySnapshot {
        LibrarySnapshot(
            albums: [
                .init(id: "A1", artist: "Radiohead", album: "Kid A", year: 2000),
                .init(id: "A2", artist: "Boards of Canada", album: "Music Has the Right to Children", year: 1998),
                .init(id: "A17", artist: "Aphex Twin", album: "Drukqs", year: 2001),
                .init(id: "A9", artist: nil, album: "Sbornik Bez Artista", year: nil),
            ],
            topArtists: [
                .init(name: "Radiohead", plays: 42),
                .init(name: "Aphex Twin", plays: 31),
            ],
            topAlbums: [
                .init(id: "A1", plays: 40),
                .init(id: "A17", plays: 22),
            ],
            favoriteAlbumIds: ["A1", "A17"],
            favoriteTrackTitles: ["Idioteque", "Everything in Its Right Place"],
            recentlyPlayedIds: ["A2", "A1"],
            recentlyAddedIds: ["A9"]
        )
    }

    // MARK: - System

    @Test func systemPromptStatesCuratorRoleAndConstraints() {
        let (system, _) = HomeFeedPrompt.build(snapshot: sampleSnapshot())
        #expect(system.contains("куратор"))
        // счёт секций
        #expect(system.contains("5") && system.contains("8"))
        // запрет выдумывать id
        #expect(system.contains("ТОЛЬКО id"))
        #expect(system.contains("НЕ выдумывай"))
        // строгий JSON без обёрток
        #expect(system.contains("JSON"))
        #expect(system.contains("markdown"))
        // ровно два вида секций
        #expect(system.contains("\"albums\""))
        #expect(system.contains("\"external\""))
    }

    @Test func systemPromptDoesNotRequestTrackPlaylists() {
        // Плейлисты-из-треков отложены: слова "tracks" в промпте быть не должно.
        let (system, user) = HomeFeedPrompt.build(snapshot: sampleSnapshot())
        #expect(!system.contains("tracks"))
        #expect(!user.contains("\"tracks\""))
    }

    // MARK: - User

    @Test func userPromptContainsEveryAlbumId() {
        let snapshot = sampleSnapshot()
        let (_, user) = HomeFeedPrompt.build(snapshot: snapshot)
        for entry in snapshot.albums {
            #expect(user.contains(entry.id))
        }
    }

    @Test func userPromptFormatsAlbumLineWithArtistAndYear() {
        let (_, user) = HomeFeedPrompt.build(snapshot: sampleSnapshot())
        #expect(user.contains("A17: Aphex Twin — Drukqs (2001)"))
    }

    @Test func albumLineOmitsMissingArtistAndYear() {
        let entry = LibrarySnapshot.AlbumEntry(id: "A9", artist: nil, album: "Sbornik Bez Artista", year: nil)
        #expect(HomeFeedPrompt.albumLine(entry) == "A9: Sbornik Bez Artista")
    }

    @Test func userPromptIncludesTopsFavoritesAndRecents() {
        let (_, user) = HomeFeedPrompt.build(snapshot: sampleSnapshot())
        #expect(user.contains("Radiohead (42)"))   // топ-артист с прослушиваниями
        #expect(user.contains("A1 (40)"))           // топ-альбом с прослушиваниями
        #expect(user.contains("Idioteque"))         // любимый трек
        #expect(user.contains("ИЗБРАННЫЕ АЛЬБОМЫ")) // блок избранного
        #expect(user.contains("НЕДАВНО ПРОСЛУШАННОЕ"))
    }

    @Test func userPromptIncludesSchemaAndExample() {
        let (_, user) = HomeFeedPrompt.build(snapshot: sampleSnapshot())
        #expect(user.contains("СХЕМА ОТВЕТА"))
        #expect(user.contains("albumIds"))
        #expect(user.contains("reason"))
    }

    @Test func emptyListsRenderAsDash() {
        let empty = LibrarySnapshot(
            albums: [.init(id: "A1", artist: "X", album: "Y", year: nil)],
            topArtists: [], topAlbums: [],
            favoriteAlbumIds: [], favoriteTrackTitles: [],
            recentlyPlayedIds: [], recentlyAddedIds: []
        )
        let (_, user) = HomeFeedPrompt.build(snapshot: empty)
        #expect(user.contains("ЛЮБИМЫЕ ТРЕКИ: —"))
    }

    // MARK: - Детерминизм

    @Test func buildIsDeterministic() {
        let snapshot = sampleSnapshot()
        let first = HomeFeedPrompt.build(snapshot: snapshot)
        let second = HomeFeedPrompt.build(snapshot: snapshot)
        #expect(first.system == second.system)
        #expect(first.user == second.user)
    }
}
