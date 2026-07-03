# DSD (`.dsf`) album support — design

Date: 2026-07-03
Status: validated, ready to implement

## Goal

First-class support for DSD / SACD rips (`.dsf`, single-track-per-file, e.g.
`01 - Птица.dsf`). To the user it must look like any other album on the phone —
track list, per-track play/scrub, gapless, quality label — **without** the app
depending on DSD playback (which iOS cannot do).

## The hard constraint (proven, not assumed)

- iOS **cannot output DSD or DoP** to a DAC — bit-perfect DSD on the phone is
  physically impossible. `AVAudioFile`/Core Audio can't even open `.dsf`.
- macOS Core Audio **cannot encode FLAC** (`ExtAudioFileOpenURL` → `fmt?`).
  Decode-only. ALAC-in-`.m4a` via `AVAssetWriter` works (proven fallback).
- The user's Mac has **`ffmpeg` 7.1.1** with `dsd_lsbf/msbf` decoders + `flac`
  encoder. Verified end to end on a synthetic DSD64 `.dsf`: a 1 kHz sine
  survives DSD → ffmpeg decode → resample → FLAC (peak read back at 999.5 Hz,
  24-bit, exact target rate).

**Decision (user):** the Mac transcodes `.dsf` → **true FLAC** with the
installed `ffmpeg` (auto-detected). The phone receives normal FLAC; zero iOS
changes. Quality is chosen per-album in the ZverMac import window.

## Transcode command (validated)

```
ffmpeg -hide_banner -y -i IN.dsf \
  -ar <176400|88200> -sample_fmt s32 -bits_per_raw_sample 24 \
  -c:a flac -compression_level 8 OUT.flac
```

Quality picker: **176.4 kHz / 24-bit** (default, `÷16`, full DSD bandwidth) or
**88.2 kHz / 24-bit** (`÷32`, transparent, ~half size).

## Architecture — where each piece lives

### ZverMetadata (shared, NO ffmpeg — also compiles for iOS)
- `audioExtensions += "dsf"`.
- `DSFHeader`: native parse of the Sony DSF header → sample rate (2 822 400 for
  DSD64), channels, sample count → duration. ~60 lines, pure bytes.
- `FormatProbe.probe`: route `.dsf` to `DSFHeader` (AudioToolbox can't open it).
- `MetadataReader.read`: for `.dsf` skip `AVURLAsset` (can't parse); derive
  `title`/`trackNumber` from the `NN - Title` filename pattern. New
  `AudioFileInfo.isDSD` flag + DSD source rate.

### ZverMac (has ffmpeg)
- `FFmpegLocator`: find `ffmpeg` (`/opt/homebrew/bin`, `/usr/local/bin`,
  `/usr/bin`, `PATH`). Clear RU error if missing (`brew install ffmpeg`).
- `DSDQuality`: `.hi (176400)` / `.standard (88200)`; target rate + label.
- `DSDTranscoder`: `transcode(dsf:to:quality:) async throws` — runs ffmpeg,
  throws with stderr tail on failure.
- `DSDStaging.materialize(snapshot:quality:progress:) async throws -> Snapshot`:
  - DSD album → create `~/Library/Application Support/ZverMac/staging/<albumId>/`
    (cleared first), transcode each `.dsf` → `<base>.flac`, copy artwork/extras,
    re-probe each FLAC with `AVAudioFile` (macOS decodes FLAC) for exact
    length/duration, return a NEW snapshot: `sourceFolder = staging`, tracks
    point at the FLACs, `fileExtension = "flac"`, `sampleRate = target`,
    `bitDepth = 24`.
  - Non-DSD album → snapshot returned unchanged (source folder served directly,
    as today).
- Enqueue wiring (`ZverMacApp.enqueue` + `MacEnqueue.enqueueFolder`): insert
  `materialize` **before** `ManifestBuilder.buildAlbum`. `QueuedAlbum` gains
  `deliveredKeyFolder` (= original dropped folder) so delivered-dedup keys on the
  immutable source, not staging.
- UI (`AlbumPreviewView`): quality `Picker` shown when `draft.hasDSD`; footer
  shows conversion progress (`N/총` files) while enqueuing.

### Unchanged
- `SyncHost`, `FileServer`, `ManifestBuilder`, transport, **all of iOS** — the
  phone just downloads FLAC and plays it on the existing bit-perfect path.

## Immutability

The dropped folder is read-only throughout: scan reads it, transcode reads
`.dsf` and writes FLAC only into app-managed staging. Nothing is written back.

## Out of scope (v1)

`.dff` (DSDIFF), multichannel SACD, embedded-ID3 read from `.dsf`, live on-device
DSD decode. `.dff` recognition can be added later behind the same `DSDTranscoder`.

## Verification

- ZverMetadata unit tests: DSF header parse (synthetic), scan → `isDSD` +
  filename-derived track numbers/titles.
- ZverMac tests: `FFmpegLocator` finds the binary; `DSDTranscoder` turns a
  synthetic `.dsf` into a valid 24-bit FLAC at the target rate (ffprobe/AVAudioFile);
  `DSDStaging` produces staging FLACs + updated snapshot, non-DSD unchanged.
- End-to-end on the real rip once downloaded: drop → pick quality → enqueue →
  phone shows N tracks, plays lossless, gapless.
