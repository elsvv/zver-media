import Testing
import Foundation
@testable import ZverStorage

/// Тесты ``RetryPolicy``: классификация ошибок (ретраябельность) и детерминированный
/// exponential backoff с учётом `Retry-After`.
///
/// Никакого random jitter — backoff детерминированный (личное приложение, ≤2
/// параллельных передач), что позволяет точно зафиксировать значения в TDD.
@Suite struct RetryPolicyTests {

    // MARK: - дефолты

    @Test func defaultsMatchSpec() {
        let policy = RetryPolicy()
        #expect(policy.maxAttempts == 5)
        #expect(policy.baseDelay == 1)
        #expect(policy.maxDelay == 60)
    }

    @Test func customParametersAreStored() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 2, maxDelay: 30)
        #expect(policy.maxAttempts == 3)
        #expect(policy.baseDelay == 2)
        #expect(policy.maxDelay == 30)
    }

    // MARK: - классификация: ретраябельные ошибки

    @Test func rateLimitedIsRetryable() {
        let policy = RetryPolicy()
        #expect(policy.isRetryable(.rateLimited(retryAfter: nil)))
        #expect(policy.isRetryable(.rateLimited(retryAfter: 5)))
    }

    @Test func lockedIsRetryable() {
        #expect(RetryPolicy().isRetryable(.locked))
    }

    @Test func serverIsRetryable() {
        #expect(RetryPolicy().isRetryable(.server(status: 500)))
        #expect(RetryPolicy().isRetryable(.server(status: 503)))
    }

    @Test func transportIsRetryable() {
        struct Boom: Error {}
        #expect(RetryPolicy().isRetryable(.transport(underlying: Boom())))
    }

    // MARK: - классификация: фатальные ошибки

    @Test func unauthorizedIsNotRetryable() {
        #expect(!RetryPolicy().isRetryable(.unauthorized))
    }

    @Test func notFoundIsNotRetryable() {
        #expect(!RetryPolicy().isRetryable(.notFound))
    }

    @Test func conflictIsNotRetryable() {
        #expect(!RetryPolicy().isRetryable(.conflict))
    }

    @Test func insufficientStorageIsNotRetryable() {
        #expect(!RetryPolicy().isRetryable(.insufficientStorage))
    }

    @Test func badResponseIsNotRetryable() {
        #expect(!RetryPolicy().isRetryable(.badResponse))
    }

    // MARK: - backoff: детерминированная экспонента

    @Test func exponentialSequenceFromBaseOne() {
        // baseDelay=1, maxDelay большой → 1, 2, 4, 8, 16 для попыток 1..5.
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 1, maxDelay: 1000)
        #expect(policy.delay(forAttempt: 1, retryAfter: nil) == 1)
        #expect(policy.delay(forAttempt: 2, retryAfter: nil) == 2)
        #expect(policy.delay(forAttempt: 3, retryAfter: nil) == 4)
        #expect(policy.delay(forAttempt: 4, retryAfter: nil) == 8)
        #expect(policy.delay(forAttempt: 5, retryAfter: nil) == 16)
    }

    @Test func exponentialScalesWithBaseDelay() {
        // baseDelay=2 → 2, 4, 8, 16, 32.
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 2, maxDelay: 1000)
        #expect(policy.delay(forAttempt: 1, retryAfter: nil) == 2)
        #expect(policy.delay(forAttempt: 2, retryAfter: nil) == 4)
        #expect(policy.delay(forAttempt: 3, retryAfter: nil) == 8)
    }

    // MARK: - backoff: кламп на maxDelay

    @Test func exponentClampsToMaxDelay() {
        // baseDelay=1, maxDelay=60: 1,2,4,8,16,32, затем кламп 60.
        let policy = RetryPolicy(maxAttempts: 20, baseDelay: 1, maxDelay: 60)
        #expect(policy.delay(forAttempt: 6, retryAfter: nil) == 32)
        #expect(policy.delay(forAttempt: 7, retryAfter: nil) == 60) // 64 → кламп
        #expect(policy.delay(forAttempt: 8, retryAfter: nil) == 60) // 128 → кламп
        #expect(policy.delay(forAttempt: 20, retryAfter: nil) == 60)
    }

    // MARK: - backoff: Retry-After перебивает короткую экспоненту

    @Test func retryAfterOverridesShortExponent() {
        // Попытка 1: экспонента=1, Retry-After=3 → берём 3 (больше).
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 60)
        #expect(policy.delay(forAttempt: 1, retryAfter: 3) == 3)
    }

    @Test func retryAfterDoesNotShrinkLongerExponent() {
        // Попытка 5: экспонента=16, Retry-After=3 → берём 16 (экспонента больше).
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 60)
        #expect(policy.delay(forAttempt: 5, retryAfter: 3) == 16)
    }

    @Test func retryAfterCanExceedMaxDelayOfExponentButNotItself() {
        // Сервер прислал Retry-After=120 при maxDelay=60 → уважаем сервер (120).
        // Кламп maxDelay относится к экспоненте, а явная директива сервера — приоритетна.
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 60)
        #expect(policy.delay(forAttempt: 2, retryAfter: 120) == 120)
    }

    @Test func nilRetryAfterUsesPureExponent() {
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 60)
        #expect(policy.delay(forAttempt: 3, retryAfter: nil) == 4)
    }

    @Test func zeroRetryAfterDoesNotReduceExponent() {
        // Retry-After=0 не должен уменьшать вычисленную экспоненту.
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 60)
        #expect(policy.delay(forAttempt: 3, retryAfter: 0) == 4)
    }

    // MARK: - граница попыток

    @Test func attemptWithinMaxIsAllowed() {
        // Вызывающий проверяет attempt <= maxAttempts перед повтором.
        let policy = RetryPolicy(maxAttempts: 5)
        #expect(policy.shouldRetry(attempt: 1))
        #expect(policy.shouldRetry(attempt: 5))
    }

    @Test func attemptBeyondMaxStops() {
        let policy = RetryPolicy(maxAttempts: 5)
        #expect(!policy.shouldRetry(attempt: 6))
        #expect(!policy.shouldRetry(attempt: 100))
    }

    @Test func firstAttemptIsZeroOneAgnosticButPositive() {
        // attempt начинается с 1; нулевая/отрицательная попытка — не повторять.
        let policy = RetryPolicy(maxAttempts: 5)
        #expect(!policy.shouldRetry(attempt: 0))
    }
}
