import Foundation

/// Абстракция «подождать N секунд» — чтобы backoff ``BackupQueue`` тестировался без
/// реального ожидания.
///
/// Реальный ``TaskSleeper`` зовёт `Task.sleep`; тестовый ``FakeSleeper`` возвращается
/// мгновенно, лишь записывая запрошенные задержки — так TDD ретраев проходит за
/// миллисекунды и проверяет точные значения backoff.
public protocol Sleeper: Sendable {
    /// Приостанавливает текущую задачу на `seconds`. Должен уважать отмену задачи.
    func sleep(_ seconds: TimeInterval) async
}

/// Боевой ``Sleeper`` поверх `Task.sleep`. Отмена прерывает ожидание (проглатываем
/// `CancellationError` — для планировщика отмена сна = «продолжить/завершить»).
public struct TaskSleeper: Sleeper {
    public init() {}

    public func sleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanos = UInt64((seconds * 1_000_000_000).rounded())
        try? await Task.sleep(nanoseconds: nanos)
    }
}

/// Тестовый ``Sleeper``: возвращается немедленно, копит запрошенные задержки.
///
/// Позволяет проверить, что планировщик уважает `Retry-After` и экспоненту backoff,
/// не тратя реальное время. Потокобезопасен (актор) — сны могут запрашиваться из
/// параллельных задач очереди.
public actor FakeSleeper: Sleeper {
    /// Все запрошенные задержки в порядке вызова `sleep`.
    public private(set) var requestedDelays: [TimeInterval] = []

    public init() {}

    public func sleep(_ seconds: TimeInterval) async {
        requestedDelays.append(seconds)
        // Мгновенно: реального ожидания нет.
    }
}
