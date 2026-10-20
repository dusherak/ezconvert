import AppKit
import AVFoundation
import NaturalLanguage
import Speech
import UniformTypeIdentifiers

// Your own lecture transcript, attached to a slide deck so Study can use what was actually said.
// It can be text (txt, md, docx, rtf, pdf, subtitles) or a recording, which is transcribed on-device.

/// Where an attached transcript is kept: next to the deck, e.g. "Lecture 7 (my transcript).txt".
func attachedTranscriptURL(for deck: URL) -> URL {
    deck.deletingLastPathComponent()
        .appendingPathComponent(deck.deletingPathExtension().lastPathComponent + " (my transcript)")
        .appendingPathExtension("txt")
}

func attachedTranscript(for deck: URL) -> String? {
    guard let text = try? String(contentsOf: attachedTranscriptURL(for: deck), encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return text
}

/// Kinds of file that can serve as a transcript.
let transcriptKinds: Set<Kind> = [.document, .audio, .video, .subtitle, .pdf]

/// Plain text of a transcript file; recordings are transcribed first.
func transcriptText(from url: URL) throws -> String {
    switch kind(of: url) {
    case .audio, .video: return try transcribeRecording(url)
    case .subtitle: return try subtitleText(url)
    default: return try fileText(url)
    }
}

/// Saves `transcript` as the deck's attached transcript and returns the file.
@discardableResult
func attachTranscript(_ transcript: URL, to deck: URL) throws -> URL {
    let text = try transcriptText(from: transcript)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ConvError.failed("\(transcript.lastPathComponent) has no text to use as a transcript")
    }
    let dst = attachedTranscriptURL(for: deck)
    try text.write(to: dst, atomically: true, encoding: .utf8)
    return dst
}

/// Study → Attach transcript…: pick a file once; every Study action on the deck uses it from then on.
func attachTranscriptWithPicker(_ decks: [URL]) throws -> [URL] {
    guard let deck = decks.first else { return [] }
    var picked: URL?
    DispatchQueue.main.sync {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Choose your transcript or recording for \(deck.lastPathComponent)"
        panel.prompt = "Attach"
        panel.directoryURL = deck.deletingLastPathComponent()
        panel.allowedContentTypes = [.plainText, .rtf, .pdf, .html, .audio, .movie,
                                     UTType(filenameExtension: "docx"), UTType(filenameExtension: "md"),
                                     UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt")].compactMap { $0 }
        if panel.runModal() == .OK { picked = panel.url }
    }
    guard let transcript = picked else { throw ConvError.cancelled }
    return [try attachTranscript(transcript, to: deck)]
}

// MARK: - Transcribing recordings

/// Transcribes speech in an audio or video file with Apple's on-device recogniser (macOS 26+).
func transcribeRecording(_ url: URL) throws -> String {
    guard #available(macOS 26.0, *) else {
        throw ConvError.failed("Transcribing recordings needs macOS 26 or later — attach a text transcript instead")
    }
    // Video (and anything AVAudioFile can't read) is turned into plain audio first.
    var audio = url
    var cleanup: URL?
    if kind(of: url) == .video || (try? AVAudioFile(forReading: url)) == nil {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ezconvert-\(UUID().uuidString).m4a")
        if ffmpegPath != nil {
            try ffmpeg(["-i", url.path, "-vn", "-ac", "1", "-c:a", "aac", tmp.path])
        } else {
            try exportAudio(url, to: tmp)
        }
        audio = tmp
        cleanup = tmp
    }
    defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
    return try SpeechJob.run(audio)
}

private func exportAudio(_ url: URL, to dst: URL) throws {
    guard let session = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetAppleM4A) else {
        throw ConvError.failed("Can't read the audio in \(url.lastPathComponent)")
    }
    session.outputURL = dst
    session.outputFileType = .m4a
    let done = DispatchSemaphore(value: 0)
    session.exportAsynchronously { done.signal() }
    done.wait()
    if session.status != .completed {
        throw ConvError.failed("Can't read the audio in \(url.lastPathComponent)")
    }
}

@available(macOS 26.0, *)
private enum SpeechJob {
    final class Box: @unchecked Sendable { var result: Result<String, Error> = .failure(ConvError.failed("No speech found")) }

    static func run(_ url: URL) throws -> String {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await transcribe(url)) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        let text = try box.result.get().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ConvError.failed("No speech found in \(url.lastPathComponent)") }
        return text
    }

    static func transcribe(_ url: URL) async throws -> String {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()   // one-time download of the language model
        }
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> String in
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
                if duration > 0 { progress.report(result.range.end.seconds / duration) }
            }
            return text
        }
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}

// MARK: - Picking the relevant part of a long transcript

private let stopWords: Set<String> = [
    "the", "and", "that", "this", "with", "from", "they", "there", "their", "which", "what", "when", "where", "have",
    "will", "would", "could", "should", "about", "into", "than", "then", "them", "these", "those", "were", "been",
    "being", "also", "just", "like", "your", "you're", "okay", "right", "know", "going", "here", "some", "very",
    "because", "really", "thing", "things", "more", "most", "other", "such", "only", "over", "does", "doing",
]

private func contentWords(_ s: String) -> Set<String> {
    Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { $0.count > 3 && !stopWords.contains($0) })
}

/// Splits a transcript into ~600-character passages along sentence boundaries.
func splitIntoPassages(_ text: String) -> [String] {
    var passages: [String] = [], current = ""
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        current += text[range].trimmingCharacters(in: .whitespacesAndNewlines) + " "
        if current.count > 600 { passages.append(current); current = "" }
        return true
    }
    if !current.trimmingCharacters(in: .whitespaces).isEmpty { passages.append(current) }
    return passages
}

/// The passages of `transcript` most relevant to `slides`, in their original order, within `budget` characters.
/// Relevance is shared vocabulary, nudged towards the part of the lecture where these slides fall.
func relevantExcerpt(_ passages: [String], for slides: [Slide], of total: Int, budget: Int) -> String {
    let full = passages.joined()
    if full.count <= budget { return full }
    guard let first = slides.first?.number, let last = slides.last?.number, !passages.isEmpty else { return "" }
    let words = contentWords(slides.map(\.text).joined(separator: " "))
    let center = (Double(first + last) / 2 - 0.5) / Double(max(total, 1))
    let scored = passages.enumerated().map { i, p -> (Int, Double) in
        let overlap = Double(contentWords(p).intersection(words).count)
        let position = (Double(i) + 0.5) / Double(passages.count)
        return (i, overlap * (1 + max(0, 1 - abs(position - center) * 3)))
    }
    var chosen: [Int] = [], size = 0
    for (i, score) in scored.sorted(by: { $0.1 > $1.1 }) where score > 0 {
        if size + passages[i].count > budget { continue }
        chosen.append(i)
        size += passages[i].count
    }
    return chosen.sorted().map { passages[$0] }.joined(separator: "\n…\n")
}
