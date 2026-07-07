import SwiftUI
import AppKit

/// Превью импортированного альбома с инлайн-редактором.
///
/// Левая колонка — обложка (из `folder.jpg`/sidecar, можно заменить файлом).
/// Правая — album-уровень (название/артист/год) и список треков с правкой
/// названия/артиста/номера. Все правки идут в `AlbumDraft` в памяти; исходные
/// файлы не трогаются. Кнопка «В очередь» собирает манифест и кладёт в
/// `OutgoingQueue` (хеширование — вне главного потока).
struct AlbumPreviewView: View {
    @ObservedObject var draft: AlbumDraft
    /// Асинхронная сборка манифеста + постановка в очередь. Возвращает текст
    /// ошибки (RU) при сбое, либо nil на успехе. View сама управляет
    /// `isBuilding`/индикацией ошибки по результату — чтобы UI не залипал на
    /// failure-пути (черновик остаётся, можно повторить отправку).
    let onEnqueue: () async -> String?
    let onCancel: () -> Void

    /// true, пока идёт сбор манифеста (хеширование файлов) после «В очередь».
    @State private var isBuilding = false
    /// Текст ошибки последней попытки постановки в очередь (RU), если был сбой.
    @State private var enqueueError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if draft.hasDSD {
                        Divider()
                        dsdOptions
                    }
                    Divider()
                    trackList
                }
                .padding(20)
            }
            Divider()
            footer
        }
    }

    // MARK: Album-уровень

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            artwork
            VStack(alignment: .leading, spacing: 10) {
                LabeledField(label: "Альбом", text: $draft.title)
                LabeledField(label: "Артист", text: $draft.artist)
                LabeledField(label: "Год", text: $draft.year)
                Text("ID: \(draft.albumId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private var artwork: some View {
        VStack(spacing: 6) {
            artworkImage
                .frame(width: 160, height: 160)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Button("Заменить обложку…", action: chooseArtwork)
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var artworkImage: some View {
        if let url = draft.artworkURL,
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "opticaldisc")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: DSD → FLAC

    /// Пикер качества конвертации для DSD-альбомов (показывается только когда в
    /// альбоме есть `.dsf`). Во время самой конвертации заблокирован.
    private var dsdOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DSD → FLAC")
                .font(.headline)
            Text("DSD (SACD) нельзя проиграть на iPhone напрямую — Мак сконвертирует его в FLAC без потери качества. Файлы в исходной папке не меняются.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Качество", selection: $draft.dsdQuality) {
                ForEach(DSDQuality.allCases) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(draft.conversionProgress != nil)
        }
    }

    // MARK: Треки

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Треки (\(draft.tracks.count))")
                .font(.headline)
            ForEach($draft.tracks) { $track in
                TrackEditorRow(track: $track)
            }
        }
    }

    // MARK: Низ

    private var footer: some View {
        HStack {
            Button("Отмена", action: onCancel)
                .keyboardShortcut(.cancelAction)
            if let enqueueError {
                Text(enqueueError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            if let progress = draft.conversionProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Конвертирую DSD… \(progress.done)/\(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if isBuilding {
                ProgressView().controlSize(.small)
            }
            Button(draft.hasDSD ? "Конвертировать и в очередь" : "В очередь") {
                enqueueError = nil
                isBuilding = true
                Task {
                    // На успехе ZverMacApp очищает черновик (вью демонтируется);
                    // на ошибке черновик остаётся, поэтому ОБЯЗАТЕЛЬНО сбрасываем
                    // isBuilding и показываем ошибку — иначе кнопка залипнет.
                    let error = await onEnqueue()
                    isBuilding = false
                    enqueueError = error
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isBuilding)
        }
        .padding(12)
    }

    // MARK: Обложка из файла

    /// Открывает панель выбора файла обложки. Файл должен лежать в папке
    /// альбома (раздаётся как часть альбома); иначе показываем системный отказ
    /// через простое игнорирование выбора вне папки.
    private func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = draft.sourceFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Обложка раздаётся из папки альбома: принимаем только файл внутри неё.
        let folderPath = draft.sourceFolder.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(folderPath + "/") {
            // ОТНОСИТЕЛЬНЫЙ путь от корня альбома: обложка может лежать в подпапке
            // (напр. `covers/front.jpg`). Взяли бы `lastPathComponent` — `artworkURL`
            // указал бы на `<корень>/front.jpg` (нет файла) → превью не обновится и на
            // телефон обложка не приедет. Пайплайн (манифест/раздача/sidecar) несёт
            // относительный путь и воссоздаёт подпапку, как для треков/extras.
            draft.artworkFileName = AlbumDraft.relativePath(of: url, under: draft.sourceFolder)
        }
    }
}

/// Строка инлайн-редактора одного трека.
private struct TrackEditorRow: View {
    @Binding var track: TrackDraft

    var body: some View {
        HStack(spacing: 8) {
            TextField("№", text: $track.trackNumber)
                .frame(width: 36)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Название", text: $track.title)
                TextField("Артист", text: $track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(track.formatBadge)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, 2)
    }
}

/// Подписанное текстовое поле album-уровня.
private struct LabeledField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 60, alignment: .leading)
                .foregroundStyle(.secondary)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private extension TrackDraft {
    /// Короткий технический бейдж (расширение + частота/разрядность).
    var formatBadge: String {
        // DSD-трек: показываем «DSD64/128» (кратность частоты к CD), а не «1/2822».
        if isDSD {
            let multiple = Int((sampleRate / 44_100).rounded())
            return multiple > 0 ? "DSD\(multiple)" : "DSD"
        }
        var parts: [String] = [fileExtension.uppercased()]
        let khz = sampleRate / 1000
        if khz > 0 {
            let formatted = khz.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", khz)
                : String(format: "%.1f", khz)
            if let bitDepth {
                parts.append("\(bitDepth)/\(formatted)")
            } else {
                parts.append("\(formatted)кГц")
            }
        }
        return parts.joined(separator: " · ")
    }
}
