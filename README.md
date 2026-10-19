# ezconvert

A tiny macOS menu-bar app for converting files by dragging them.

Hold **⇧ Shift** while dragging any file. A circular menu opens under the cursor; drop the file on a
format and the result is saved next to the original. Conversions run locally — nothing is uploaded.
Slide decks also get a **Study** section that writes summaries, lecture transcripts and textbook-style chapters.

## Install

1. Download `ezconvert-<version>-macos.zip` from [Releases](https://github.com/dusherak/ezconvert/releases/latest)
   and unzip it. Works on macOS 14+ (Apple Silicon and Intel).
2. Drag `ezconvert.app` into your **Applications** folder and open it.
3. The app isn't notarized by Apple, so macOS blocks the first launch. Open **System Settings → Privacy &
   Security**, scroll down and click **Open Anyway** next to ezconvert, then confirm. You only do this once.
4. An icon appears in the menu bar. Hold **⇧ Shift** while dragging a file to use it.
5. For video and audio, install ffmpeg: `brew install ffmpeg` (needs [Homebrew](https://brew.sh)).
   Images, PDFs and documents work without it.

To start ezconvert at login, add it in System Settings → General → Login Items. Prefer to build it
yourself? See [Build](#build).

## What it does

| Files | Options |
|---|---|
| Images | Convert (PNG, JPEG, HEIC, TIFF, GIF, BMP), Compress, Resize, Edit (rotate, flip, grayscale, square), Remove background, PDF |
| Video | Convert (MP4, MOV, MKV, WebM, AVI), Compress (1080p/720p/480p), GIF, extract audio, Mute, Rotate, 2× speed, Thumbnail, Merge |
| Audio | Convert (MP3, M4A, WAV, FLAC, AIFF, Opus), Compress, Normalize, Trim silence, 1.5× speed, Merge |
| Slides (PowerPoint, Keynote) | Study (Summarize, Transcript, Textbook), Slide text |
| PDF | Study (Summarize, Transcript, Textbook), Pages to images, Compress, Text, Split, Rotate, Merge |
| Documents | PDF, DOCX, RTF, TXT, HTML, ODT |
| Anything | Zip |

Groups (Convert, Compress, …) open into an outer ring. While converting, the menu turns into a progress ring.

## Study

Drop a slide deck (`.pptx`, `.key`) or a PDF on **Study**:

- **Summarize** — an overview, key points and key terms, saved as `deck (summary).docx`.
- **Transcript** — what a lecturer would say for each slide, saved as `deck (transcript).docx`. For
  PowerPoint and Keynote decks it also writes `deck (with transcript).pptx` with each script in the
  slide's speaker notes (when the deck has a notes layout; the original is never changed).
- **Textbook** — a chapter that teaches the material: introduction, explained sections with examples,
  summary and review questions, saved as `deck (textbook).docx`.

Choose the AI under the menu bar icon → **Study AI**:

- **On-device (Apple Intelligence)** — the default. Free, private and offline. Needs macOS 26+ with
  Apple Intelligence turned on.
- **Claude (Anthropic API)** — better writing and handles long decks in one go. Add your API key from
  the same menu; it's stored in the macOS Keychain. Uses `claude-opus-5-5` and is billed to your
  Anthropic account.

Reading Keynote files needs the Keynote app (macOS asks once for permission to control it). Slides that
are only pictures have no text to study yet.

## Where files go

Next to the original, with the new extension (`photo.heic` → `photo.png`). Existing files are never
overwritten (`photo 2.png`). Multi-page output goes in a subfolder. If the folder isn't writable, the
result goes to Downloads. Click the toast in the bottom-right corner to reveal it in Finder.

## Build

Requires macOS 14+, the Xcode command line tools, and [ffmpeg](https://ffmpeg.org) for video/audio
(`brew install ffmpeg`).

```bash
./build.sh            # builds ezconvert.app here
./build.sh --install  # also copies it to /Applications and launches it
```

To start it at login, add it in System Settings → General → Login Items.

### Testing from the command line

```bash
ezconvert.app/Contents/MacOS/ezconvert --list photo.png             # show the menu for a file
ezconvert.app/Contents/MacOS/ezconvert --run "Convert/PNG" photo.heic
```

## Privacy and safety

ezconvert has no remote control or update mechanism. It only reads the files you drop on it and writes
new files next to them. The only network connection it ever makes is to `api.anthropic.com`, and only
when you've chosen Claude for Study — then the deck's text is sent to Anthropic to write the material.
With the default on-device AI, nothing leaves your Mac. Conversions call built-in macOS tools (`sips`,
`textutil`, `zip`) and ffmpeg with fixed argument lists — never through a shell — so file names can't be
turned into commands.

## License

[MIT](LICENSE)
