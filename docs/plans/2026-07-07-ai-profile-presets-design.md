# AI-профили: пресеты Base URL и поиск моделей

Мелкий UX-апгрейд редактора профиля (PR #16): не перепечатывать одно и то же.

## Пресеты Base URL (ZverBrain, статика — стабильные адреса)

`BrainProviderPreset {name, kind, baseURL}`, статический список:
OpenRouter (chatCompletions), OpenAI · Chat Completions (chatCompletions),
OpenAI · Responses (openaiResponses), Anthropic (anthropicMessages),
Google Gemini · OpenAI-совместимый (chatCompletions,
`generativelanguage.googleapis.com/v1beta/openai`).

В редакторе — компактная кнопка-меню «Пресеты» рядом с полем Base URL:
выбор сразу ставит И `kind`, И `baseURL` (это и есть повторяющаяся пара,
которую человек ленится перепечатывать). Поле остаётся обычным
`TextField` — вписать свой адрес всегда можно.

## Поиск моделей (живой каталог, без хардкода «популярных»)

Хардкодить список «популярных моделей» рискованно — он устаревает и модель
может элементарно не существовать под тем же именем через месяц. Вместо
этого — **живой запрос к `{baseURL}/models`** (стандартный OpenAI-совместимый
эндпоинт, тот же путь работает у chatCompletions/openaiResponses; у
Anthropic — свой `/v1/models` с `x-api-key`). Список настоящий, актуальный
на момент открытия шита, ничего не выдумываем.

`ModelCatalogFetcher.fetchModels(baseURL:kind:apiKey:session:) async -> [ModelSummary]`:
- chatCompletions/openaiResponses: `GET {baseURL}/models`, `Authorization:
  Bearer <key>` если ключ есть (OpenRouter отдаёт список и без ключа);
  разбор `{"data":[{"id","name"?}]}`.
- anthropicMessages: без ключа не дёргаем сеть (Anthropic список требует
  auth) — сразу пустой результат; с ключом — `x-api-key` +
  `anthropic-version`, разбор `{"data":[{"id","display_name"?}]}`.
- Любая ошибка/таймаут (8с) → `[]`, тихий откат к свободному вводу.

`ModelPickerSheet` (iOS): поле поиска сверху = одновременно ввод и фильтр
(`contains`, регистронезависимо) по живому списку; строка «Использовать
«…»» всегда внизу для точного/нестандартного значения, которого нет в
каталоге. Пока грузится — спиннер, не блокирует ввод. Ошибка/пусто —
подсказка «Впиши название модели вручную» (поле поиска работает и так).
Открывается кнопкой с лупой рядом с полем «Модель» — само поле остаётся
`TextField` для быстрой правки/вставки без похода в шит.

Ключ для запроса — актуальный ввод в редакторе (typed `keyInput` для
нового профиля) или значение из Keychain уже сохранённого профиля
(`BrainProfilesStore.currentKey(for:)`, только для этого запроса, наружу
не показывается — как и существующий `tokenProvider`).

## Верификация

`ModelCatalogFetcher` — юнит-тесты на мок-URLProtocol (URL/заголовки по
типу, разбор data[], пусто без ключа у Anthropic, ошибка → []). Пресеты —
тривиальная статика, тест на валидность URL. UI — сборка. Ревью — один
агент (Opus).
