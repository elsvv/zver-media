# AI-движок: профили провайдеров, типы API, tools, свои инструкции

Апгрейд «Интеллекта» (PR #14): вместо одного набора «URL+ключ+модель» —
переключаемые профили с разными ТИПАМИ API и инструментами.

## Типы API (ZverBrain)

`BrainAPIKind`, один `ChatClient`-протокол, три адаптера:

| Тип | Endpoint | Кто | Веб-поиск | Reasoning |
|---|---|---|---|---|
| `chatCompletions` | `POST {base}/chat/completions` | OpenRouter (дефолт), OpenAI, Gemini-compat, любой совместимый | плагин OpenRouter `plugins:[{id:"web"}]` (тумблер с пометкой «через OpenRouter») | `reasoning_effort: low\|medium\|high` (стандарт OpenAI, OpenRouter нормализует) |
| `openaiResponses` | `POST {base}/responses` | OpenAI (новые модели) | нативный тул `tools:[{type:"web_search"}]` | `reasoning:{effort}` |
| `anthropicMessages` | `POST {base}/messages` | Anthropic | нативный тул `tools:[{type:"web_search_20250305", name:"web_search", max_uses:5}]` | extended thinking `thinking:{type:"enabled", budget_tokens}` (low 4k / medium 8k / high 16k), `max_tokens = 8192 + budget` |

- Gemini поддерживается через его OpenAI-совместимый endpoint
  (`https://generativelanguage.googleapis.com/v1beta/openai`) типом
  `chatCompletions` — отдельный четвёртый адаптер не плодим.
- Anthropic: заголовки `x-api-key` + `anthropic-version: 2023-06-01`;
  ответ — блоки `content[]`, берём конкатенацию `type=="text"` (thinking-блоки
  пропускаем). `max_tokens` обязателен (8192 без thinking).
- Responses: `instructions` = system, `input` = user; ответ — `output[]`,
  элементы `type=="message"` → `content[]` `type=="output_text"` → текст.
- Reasoning/thinking замедляют ответ: таймаут 120с → 300с, если reasoning ≠ off.
- `BrainConfig` расширяется: `kind`, `webSearch: Bool`,
  `reasoning: BrainReasoning (off/low/medium/high)`. `ChatClient` и
  `BrainError` не меняются; фабрика `BrainClientFactory.make(config:...)`.

## Профили (iOS)

`BrainProfile`: `id: UUID`, `name`, `kind`, `baseURL`, `model`,
`webSearch`, `reasoning`. Хранение:
- профили — JSON в `UserDefaults` (`brain.profiles`), активный —
  `brain.activeProfileId`;
- ключи — Keychain, по записи на профиль (`zver-brain-key-{uuid}`);
- **миграция**: существующие `brain.baseURL`/`brain.model` + ключ
  `zver-brain-key` при первом запуске превращаются в профиль
  «OpenRouter» (kind=chatCompletions) и становятся активными.

`BrainProfilesStore` (замена BrainAccount): CRUD, активный профиль,
`config`/`tokenProvider` активного. `HomeFeedService` работает с ним.

## Настройки: раздел «ИИ»

Секция в Настройках (переименовать «Интеллект» → «ИИ»):
- список профилей: имя + подзаголовок (тип API · модель), галочка у
  активного, тап — активировать; свайп — удалить; «Добавить профиль…»;
- редактор профиля (шит): имя, тип API (пикер, при смене подставляется
  дефолтный base URL типа), base URL, модель, ключ (SecureField → Keychain,
  маскированный статус), «Инструменты»: тумблер «Веб-поиск» (с пояснением
  по типу) и пикер «Рассуждение» (выкл/низко/средне/глубоко);
- ниже — секция «Свои инструкции»: TextEditor (`brain.customInstructions`,
  AppStorage), футер «добавляются к каждому запросу ленты».

## Свои инструкции (ZverBrain)

`HomeFeedPrompt.build(snapshot:customInstructions:)` — аддитивный параметр;
непустой текст уходит в КОНЕЦ system-промпта секцией «Пожелания слушателя»
с оговоркой, что формат ответа (строгий JSON) они изменить не могут.

## Верификация

ZverBrain: тесты трёх адаптеров на мок-URLProtocol (тело запроса: правильный
endpoint/заголовки/tools/reasoning; разбор ответа; ошибки 401/429), промпт с
инструкциями. iOS: сборка + миграция покрыта логикой store (простая). Ревью —
один агент (Opus).
