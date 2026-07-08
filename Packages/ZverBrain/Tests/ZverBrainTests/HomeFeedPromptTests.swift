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

    // MARK: - Свои инструкции слушателя

    @Test func legacyBuildWithoutInstructionsStillCompilesAndMatchesBase() {
        // Старый вызов build(snapshot:) — параметр по умолчанию nil, база не тронута.
        let (system, _) = HomeFeedPrompt.build(snapshot: sampleSnapshot())
        #expect(system == HomeFeedPrompt.systemPrompt)
        #expect(!system.contains("Пожелания слушателя"))
    }

    @Test func customInstructionsAppendedToEndOfSystem() {
        let (system, _) = HomeFeedPrompt.build(
            snapshot: sampleSnapshot(),
            customInstructions: "Больше джаза и меньше попсы"
        )
        // База целиком сохранена как префикс, пожелания — в конце.
        #expect(system.hasPrefix(HomeFeedPrompt.systemPrompt))
        #expect(system.contains("Пожелания слушателя"))
        #expect(system.contains("Больше джаза и меньше попсы"))
        // Оговорка про неизменность формата присутствует.
        #expect(system.contains("JSON-схема выше всегда главнее"))
        // Секция именно в конце.
        #expect(system.hasSuffix("Больше джаза и меньше попсы"))
    }

    @Test func emptyCustomInstructionsAreIgnored() {
        let (system, _) = HomeFeedPrompt.build(snapshot: sampleSnapshot(), customInstructions: "")
        #expect(system == HomeFeedPrompt.systemPrompt)
        #expect(!system.contains("Пожелания слушателя"))
    }

    @Test func whitespaceOnlyCustomInstructionsAreIgnored() {
        let (system, _) = HomeFeedPrompt.build(snapshot: sampleSnapshot(), customInstructions: "   \n\t  ")
        #expect(system == HomeFeedPrompt.systemPrompt)
        #expect(!system.contains("Пожелания слушателя"))
    }

    @Test func customInstructionsAreTrimmed() {
        let (system, _) = HomeFeedPrompt.build(
            snapshot: sampleSnapshot(),
            customInstructions: "  край пробелов  "
        )
        // Обрезка по краям: в хвосте нет лишних пробелов/переводов строк.
        #expect(system.hasSuffix("край пробелов"))
    }

    @Test func customInstructionsDoNotChangeUserPrompt() {
        let base = HomeFeedPrompt.build(snapshot: sampleSnapshot())
        let withInstr = HomeFeedPrompt.build(snapshot: sampleSnapshot(), customInstructions: "что-то")
        #expect(base.user == withInstr.user)
    }
}

/// Тесты новых сигнальных блоков снапшота: одержимости, скипы/скрытое, фидбек
/// по рекомендациям, «уже предлагали», родственные артисты от Deezer.
/// Пустые сигналы → блоков в промпте нет (не тратим токены и не путаем модель).
@Suite struct HomeFeedPromptSignalsTests {
    private func signalSnapshot() -> LibrarySnapshot {
        LibrarySnapshot(
            albums: [.init(id: "A1", artist: "Radiohead", album: "Kid A", year: 2000)],
            topArtists: [],
            topAlbums: [],
            favoriteAlbumIds: [],
            favoriteTrackTitles: [],
            recentlyPlayedIds: [],
            recentlyAddedIds: [],
            obsessions: ["Autechre — Tri Repetae", "Burial — Untrue"],
            skippedArtists: ["Muse", "Imagine Dragons"],
            recFeedback: .init(
                liked: ["Plaid — Not for Threes"],
                hidden: ["Coldplay — X&Y"],
                recentlyShown: ["Clark — Body Riddle", "Bola — Soup"]
            ),
            similarArtistsHints: [
                "Radiohead": ["Thom Yorke", "Portishead"],
                "Aphex Twin": ["Squarepusher", "µ-Ziq"],
            ]
        )
    }

    @Test func obsessionsBlockListsAnchors() {
        let (_, user) = HomeFeedPrompt.build(snapshot: signalSnapshot())
        #expect(user.contains("ОДЕРЖИМОСТИ"))
        #expect(user.contains("Autechre — Tri Repetae"))
        #expect(user.contains("Burial — Untrue"))
    }

    @Test func negativeBlockCombinesSkipsAndHidden() {
        let (_, user) = HomeFeedPrompt.build(snapshot: signalSnapshot())
        #expect(user.contains("НЕ ЗАХОДИТ"))
        #expect(user.contains("Muse"))
        #expect(user.contains("Imagine Dragons"))
        #expect(user.contains("Coldplay — X&Y"))
        // Мягкая оговорка из дизайна: не предлагать похожее без веской причины.
        #expect(user.contains("без веской причины"))
    }

    @Test func likedBlockListsPositiveFeedback() {
        let (_, user) = HomeFeedPrompt.build(snapshot: signalSnapshot())
        #expect(user.contains("ПОНРАВИЛОСЬ ИЗ РЕКОМЕНДАЦИЙ"))
        #expect(user.contains("Plaid — Not for Threes"))
    }

    @Test func alreadySuggestedBlockForbidsRepeats() {
        let (_, user) = HomeFeedPrompt.build(snapshot: signalSnapshot())
        #expect(user.contains("УЖЕ ПРЕДЛАГАЛИ"))
        #expect(user.contains("Clark — Body Riddle"))
        #expect(user.contains("Bola — Soup"))
        // Жёсткий запрет повтора — прямо словами.
        #expect(user.contains("НЕ повторяй"))
    }

    @Test func similarArtistsBlockCreditsDeezerAndListsHints() {
        let (_, user) = HomeFeedPrompt.build(snapshot: signalSnapshot())
        #expect(user.contains("РОДСТВЕННЫЕ АРТИСТЫ"))
        #expect(user.contains("Deezer"))
        #expect(user.contains("Radiohead: Thom Yorke, Portishead"))
        #expect(user.contains("Aphex Twin: Squarepusher, µ-Ziq"))
        // Инструкция из дизайна: скелет — подсказка, а не диктат.
        #expect(user.contains("от себя"))
    }

    @Test func similarArtistsHintsAreSortedByArtistForDeterminism() {
        // Словарь не упорядочен — сериализация обязана сортировать ключи,
        // иначе одинаковый снапшот даст разные промпты (ломается детерминизм).
        let (_, user) = HomeFeedPrompt.build(snapshot: signalSnapshot())
        let aphex = user.range(of: "Aphex Twin: Squarepusher")
        let radiohead = user.range(of: "Radiohead: Thom Yorke")
        #expect(aphex != nil && radiohead != nil)
        if let aphex, let radiohead {
            #expect(aphex.lowerBound < radiohead.lowerBound)
        }
    }

    @Test func emptySignalsProduceNoBlocks() {
        let empty = LibrarySnapshot(
            albums: [.init(id: "A1", artist: "X", album: "Y", year: nil)],
            topArtists: [], topAlbums: [],
            favoriteAlbumIds: [], favoriteTrackTitles: [],
            recentlyPlayedIds: [], recentlyAddedIds: []
        )
        let (_, user) = HomeFeedPrompt.build(snapshot: empty)
        #expect(!user.contains("ОДЕРЖИМОСТИ"))
        #expect(!user.contains("НЕ ЗАХОДИТ"))
        #expect(!user.contains("ПОНРАВИЛОСЬ ИЗ РЕКОМЕНДАЦИЙ"))
        #expect(!user.contains("УЖЕ ПРЕДЛАГАЛИ"))
        #expect(!user.contains("РОДСТВЕННЫЕ АРТИСТЫ"))
    }

    @Test func skipsOnlyStillRenderNegativeBlock() {
        // Скипы без hidden — блок «НЕ ЗАХОДИТ» всё равно появляется.
        let snapshot = LibrarySnapshot(
            albums: [.init(id: "A1", artist: "X", album: "Y", year: nil)],
            topArtists: [], topAlbums: [],
            favoriteAlbumIds: [], favoriteTrackTitles: [],
            recentlyPlayedIds: [], recentlyAddedIds: [],
            skippedArtists: ["Muse"]
        )
        let (_, user) = HomeFeedPrompt.build(snapshot: snapshot)
        #expect(user.contains("НЕ ЗАХОДИТ"))
        #expect(user.contains("Muse"))
    }

    @Test func buildWithSignalsIsDeterministic() {
        let snapshot = signalSnapshot()
        let first = HomeFeedPrompt.build(snapshot: snapshot)
        let second = HomeFeedPrompt.build(snapshot: snapshot)
        #expect(first.system == second.system)
        #expect(first.user == second.user)
    }
}

/// Тесты заказанных категорий: external-секции = ровно переданный список,
/// 4–6 кандидатов, category-эхо в схеме и примере; пустой список — легаси-промпт
/// байт-в-байт (обратная совместимость и детерминизм).
@Suite struct HomeFeedPromptCategoriesTests {
    private func snapshot() -> LibrarySnapshot {
        LibrarySnapshot(
            albums: [.init(id: "A1", artist: "Radiohead", album: "Kid A", year: 2000)],
            topArtists: [], topAlbums: [],
            favoriteAlbumIds: [], favoriteTrackTitles: [],
            recentlyPlayedIds: [], recentlyAddedIds: []
        )
    }

    @Test func orderedCategoriesListedWithSlugsTitlesAndInstructions() {
        let categories: [DiscoveryCategory] = [.deeperDiscography, .digDeeper, .timeTravel]
        let (_, user) = HomeFeedPrompt.build(snapshot: snapshot(), categories: categories)
        #expect(user.contains("ЗАКАЗАННЫЕ КАТЕГОРИИ"))
        for category in categories {
            #expect(user.contains(category.rawValue))
            #expect(user.contains(category.title))
            #expect(user.contains(category.promptInstruction))
        }
    }

    @Test func categoriesKeepGivenOrder() {
        let (_, user) = HomeFeedPrompt.build(
            snapshot: snapshot(),
            categories: [.timeTravel, .deeperDiscography]
        )
        let first = user.range(of: "time-travel")
        let second = user.range(of: "deeper-discography")
        #expect(first != nil && second != nil)
        if let first, let second {
            #expect(first.lowerBound < second.lowerBound)
        }
    }

    @Test func categorizedPromptAsksFourToSixCandidates() {
        let (system, user) = HomeFeedPrompt.build(
            snapshot: snapshot(),
            categories: [.deeperDiscography]
        )
        // Запас ×1.5 под отсев валидацией: просим 4–6 кандидатов на секцию.
        #expect(system.contains("4–6") || user.contains("4–6"))
    }

    @Test func categorizedSchemaAndExampleEchoCategory() {
        let (_, user) = HomeFeedPrompt.build(snapshot: snapshot(), categories: [.digDeeper])
        #expect(user.contains(#""category""#))
    }

    @Test func legacySchemaHasNoCategoryField() {
        // Без заказанных категорий модель не должна выдумывать слаги.
        let (_, user) = HomeFeedPrompt.build(snapshot: snapshot())
        #expect(!user.contains(#""category""#))
    }

    @Test func categorizedSystemPromptDemandsExactSections() {
        let (system, _) = HomeFeedPrompt.build(snapshot: snapshot(), categories: [.digDeeper])
        #expect(system != HomeFeedPrompt.systemPrompt)
        #expect(system.contains("ЗАКАЗАННЫЕ КАТЕГОРИИ"))
        // Легаси-правило «1–2 external-секции» в категорийном режиме не действует.
        #expect(!system.contains("их должно быть 1–2"))
    }

    @Test func emptyCategoriesMatchLegacyBuild() {
        let legacy = HomeFeedPrompt.build(snapshot: snapshot())
        let explicit = HomeFeedPrompt.build(snapshot: snapshot(), categories: [])
        #expect(legacy.system == explicit.system)
        #expect(legacy.user == explicit.user)
    }

    @Test func buildWithCategoriesIsDeterministic() {
        let categories: [DiscoveryCategory] = [.similarToObsession, .sceneDive]
        let first = HomeFeedPrompt.build(snapshot: snapshot(), categories: categories)
        let second = HomeFeedPrompt.build(snapshot: snapshot(), categories: categories)
        #expect(first.system == second.system)
        #expect(first.user == second.user)
    }

    @Test func categoriesCombineWithCustomInstructions() {
        let (system, user) = HomeFeedPrompt.build(
            snapshot: snapshot(),
            categories: [.missedClassics],
            customInstructions: "Побольше джаза"
        )
        #expect(system.contains("Пожелания слушателя"))
        #expect(system.hasSuffix("Побольше джаза"))
        #expect(user.contains("missed-classics"))
    }
}
