import Testing
import Foundation
@testable import ZverTransport

/// Чистые тесты роли Bonjour-сервиса (`svc` в TXT). Сети нет — проверяем только
/// маппинг TXT → роль и константы протокола. Этап 3 (синк) не имел поля `svc`,
/// поэтому его отсутствие ДОЛЖНО трактоваться как `sync` (обратная совместимость).
@Suite struct ServiceRoleTests {
    // Константы протокола зафиксированы в плане этапа 5 (Bonjour: svc=remote|sync).
    @Test func roleConstantsMatchProtocol() {
        #expect(ServiceTXT.roleKey == "svc")
        #expect(ServiceTXT.remote == "remote")
        #expect(ServiceTXT.sync == "sync")
    }

    // svc=remote → роль remote (пульт iPhone).
    @Test func remoteTXTYieldsRemoteRole() {
        let svc = DiscoveredService(name: "iPhone", txt: ["svc": "remote"])
        #expect(svc.role == ServiceTXT.remote)
    }

    // svc=sync → роль sync (явный синк-сервис).
    @Test func syncTXTYieldsSyncRole() {
        let svc = DiscoveredService(name: "Mac", txt: ["svc": "sync"])
        #expect(svc.role == ServiceTXT.sync)
    }

    // КЛЮЧЕВОЕ: отсутствие svc → sync. Так выглядят синк-сервисы этапа 3,
    // которые анонсятся без поля svc; они НЕ должны исчезнуть из синка.
    @Test func missingSvcDefaultsToSync() {
        let svc = DiscoveredService(name: "OldMac", txt: [:])
        #expect(svc.role == ServiceTXT.sync)
    }

    // Конструктор без txt (вызовы этапа 3) → пустой txt → роль sync.
    @Test func defaultInitHasEmptyTXTAndSyncRole() {
        let svc = DiscoveredService(name: "Legacy")
        #expect(svc.txt.isEmpty)
        #expect(svc.role == ServiceTXT.sync)
    }

    // Произвольное значение svc пробрасывается как есть (forward-compat: новые
    // роли в будущих версиях не ломают парсинг — вызывающий решает сам).
    @Test func unknownSvcValueIsPassedThrough() {
        let svc = DiscoveredService(name: "Future", txt: ["svc": "cast"])
        #expect(svc.role == "cast")
    }

    // Прочие TXT-поля (name/v) не влияют на роль.
    @Test func otherTXTFieldsDoNotAffectRole() {
        let svc = DiscoveredService(
            name: "iPhone",
            txt: ["name": "Андрей iPhone", "v": "1", "svc": "remote"]
        )
        #expect(svc.role == ServiceTXT.remote)
        #expect(svc.txt["name"] == "Андрей iPhone")
        #expect(svc.txt["v"] == "1")
    }
}
