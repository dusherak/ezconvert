import AppKit
import PDFKit
import UniformTypeIdentifiers
import Vision
import CoreImage

// MARK: - File kinds

enum Kind { case image, video, audio, pdf, document, slides, archive, data, subtitle, ebook, other }

let documentExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "txt", "text", "md", "markdown", "html", "htm", "odt", "wordml", "webarchive"]

func kind(of url: URL) -> Kind {
    let ext = url.pathExtension.lowercased()
    if documentExtensions.contains(ext) { return .document }
    if slideExtensions.contains(ext) { return .slides }
    if archiveExtensions.contains(ext) { return .archive }
    if dataExtensions.contains(ext) { return .data }
    if subtitleExtensions.contains(ext) { return .subtitle }
    if ebookExtensions.contains(ext) { return .ebook }
    guard let t = UTType(filenameExtension: ext) else { return .other }
    if t.conforms(to: .pdf) { return .pdf }
    if t.conforms(to: .image) { return .image }
    if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
    if t.conforms(to: .audio) { return .audio }
    return .other
}

// MARK: - Actions and menu

struct Action {
    let title: String
    let symbol: String
    /// Runs on the main thread when true (AppKit printing), otherwise on a background queue.
    var mainThread = false
    let run: ([URL]) throws -> [URL]
}

/// A wedge in the inner ring: either one action, or a group whose actions open in the outer ring.
struct MenuItem {
    let title: String
    let symbol: String
    var action: Action? = nil
    var children: [Action] = []
    var isGroup: Bool { action == nil }

    init(_ action: Action) { title = action.title; symbol = action.symbol; self.action = action }
    init(group title: String, _ symbol: String, _ children: [Action]) {
        self.title = title; self.symbol = symbol; self.children = children
    }
}

enum ConvError: LocalizedError {
    case failed(String)
    /// The user backed out (e.g. closed a file picker); not an error worth a sound.
    case cancelled
    var errorDescription: String? {
        switch self {
        case .failed(let m): return m
        case .cancelled: return "Cancelled"
        }
    }
}

/// The wedges offered for a given set of dropped files.
func menu(for urls: [URL]) -> [MenuItem] {
    let kinds = Set(urls.map(kind(of:)))
    var list: [MenuItem] = []
    if let pair = deckAndTranscript(urls) {
        list = studyWithTranscriptMenu(deck: pair.deck, transcript: pair.transcript)
    } else if kinds.count == 1, let k = kinds.first {
        switch k {
        case .image:    list = imageMenu(urls)
        case .video:    list = videoMenu(urls)
        case .audio:    list = audioMenu(urls)
        case .pdf:      list = pdfMenu(urls)
        case .document: list = documentMenu(urls)
        case .slides:   list = slidesMenu(urls)
        case .archive:  return archiveMenu(urls)   // zipping an archive again isn't useful
        case .data:     list = dataMenu(urls)
        case .subtitle: list = subtitleMenu(urls)
        case .ebook:    list = ebookMenu(urls)
        case .other:    break
        }
    } else if kinds.isSubset(of: [.image, .pdf]) {
        list = [MenuItem(Action(title: "Merge PDF", symbol: "doc.on.doc", run: { [try mergeToPDF($0)] }))]
    }
    list.append(MenuItem(Action(title: "Zip", symbol: "archivebox", run: { [try zip($0)] })))
    return list
}

/// Every runnable action with its menu path ("Convert/PNG", "Zip"), for the command line.
func allActions(for urls: [URL]) -> [(path: String, action: Action)] {
    menu(for: urls).flatMap { item in
        item.action.map { [(item.title, $0)] } ?? item.children.map { ("\(item.title)/\($0.title)", $0) }
    }
}

// MARK: - Progress

/// Reports 0...1 progress for the running action. Converters call `report` with progress within the
/// current file; `each` advances the file index.
final class ProgressReporter {
    var onUpdate: ((Double) -> Void)?
    /// The slice of the current file's progress that `report` fills (for multi-phase work).
    var span: ClosedRange<Double> = 0...1
    private var index = 0, count = 1

    func begin(_ i: Int, of n: Int) { index = i; count = max(n, 1); span = 0...1; report(0) }
    func report(_ fraction: Double) {
        let f = span.lowerBound + min(max(fraction, 0), 1) * (span.upperBound - span.lowerBound)
        onUpdate?((Double(index) + f) / Double(count))
    }
}

let progress = ProgressReporter()

// MARK: - Output naming

func outputURL(for src: URL, ext: String, suffix: String = "") -> URL {
    var dir = src.deletingLastPathComponent()
    if !FileManager.default.isWritableFile(atPath: dir.path) {
        dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
    let base = src.deletingPathExtension().lastPathComponent + suffix
    var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
        n += 1
    }
    return url
}

func outputFolder(for src: URL, suffix: String) throws -> URL {
    let dir = outputURL(for: src, ext: "", suffix: suffix)
    let clean = URL(fileURLWithPath: String(dir.path.dropLast(dir.path.hasSuffix(".") ? 1 : 0)))
    try FileManager.default.createDirectory(at: clean, withIntermediateDirectories: true)
    return clean
}

/// Applies `f` to each file independently and collects the outputs.
func each(_ f: @escaping (URL) throws -> URL) -> ([URL]) throws -> [URL] {
    { urls in
        try urls.enumerated().map { i, url in
            progress.begin(i, of: urls.count)
            return try f(url)
        }
    }
}

// MARK: - Process helpers

@discardableResult
func shell(_ path: String, _ args: [String], cwd: URL? = nil, okExitCodes: Set<Int32> = [0],
           onLine: ((Substring) -> Void)? = nil) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    // Drain stderr on another thread so neither pipe can fill up and block.
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    var outData = Data()
    if let onLine {
        // Stream stdout line by line (ffmpeg -progress output).
        var pending = Data()
        while case let chunk = out.fileHandleForReading.availableData, !chunk.isEmpty {
            outData.append(chunk)
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 10) {
                onLine(Substring(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)))
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
    } else {
        outData = out.fileHandleForReading.readDataToEndOfFile()
    }
    group.wait()
    p.waitUntilExit()
    if !okExitCodes.contains(p.terminationStatus) {
        let msg = String(decoding: errData, as: UTF8.self)
            .split(separator: "\n").last.map(String.init) ?? "\(path) exited with \(p.terminationStatus)"
        throw ConvError.failed(msg)
    }
    return String(decoding: outData, as: UTF8.self)
}

/// Runs a tool and returns its raw stdout (for binary output such as decompressed files).
func shellData(_ path: String, _ args: [String]) throws -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw ConvError.failed("\((path as NSString).lastPathComponent) failed") }
    return data
}

let ffmpegPath: String? = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

let ffprobePath = ffmpegPath.map { ($0 as NSString).deletingLastPathComponent + "/ffprobe" }

/// Runs ffmpeg and turns its -progress output into progress for the current file.
func ffmpeg(_ args: [String]) throws {
    guard let ffmpegPath else { throw ConvError.failed("ffmpeg not found — run: brew install ffmpeg") }
    let inputs = args.indices.filter { args[$0] == "-i" && $0 + 1 < args.count }.map { args[$0 + 1] }
    let total = inputs.map(mediaDuration).reduce(0, +)
    try shell(ffmpegPath, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-nostats", "-progress", "pipe:1"] + args) { line in
        guard total > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) else { return }
        progress.report(us / 1_000_000 / total)
    }
}

func mediaDuration(_ path: String) -> Double {
    guard let ffprobePath else { return 0 }
    let out = (try? shell(ffprobePath, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path])) ?? ""
    return Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

func hasAudioStream(_ url: URL) -> Bool {
    guard let ffprobePath else { return false }
    let out = (try? shell(ffprobePath, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", url.path])) ?? ""
    return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

// MARK: - Images

func pixelSize(_ url: URL) throws -> (w: Int, h: Int) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { throw ConvError.failed("Can't read image size of \(url.lastPathComponent)") }
    return (w, h)
}

func sipsConvert(_ format: String, ext: String, quality: Int? = nil, suffix: String = "") -> (URL) throws -> URL {
    { src in
        let dst = outputURL(for: src, ext: ext, suffix: suffix)
        var args = ["-s", "format", format]
        if let quality { args += ["-s", "formatOptions", String(quality)] }
        try shell("/usr/bin/sips", args + [src.path, "--out", dst.path])
        return dst
    }
}

/// WebP via ImageIO, if this macOS can encode it.
func imageIOConvert(_ type: UTType) -> (URL) throws -> URL {
    { src in
        let dst = outputURL(for: src, ext: type.preferredFilenameExtension ?? "img")
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let dest = CGImageDestinationCreateWithURL(dst as CFURL, type.identifier as CFString, 1, nil)
        else { throw ConvError.failed("Can't encode \(type.localizedDescription ?? "image")") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvError.failed("Encoding failed") }
        return dst
    }
}

func canEncode(_ type: UTType) -> Bool {
    (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(type.identifier) ?? false
}

func removeBackground(_ src: URL) throws -> URL {
    let handler = VNImageRequestHandler(url: src)
    let request = VNGenerateForegroundInstanceMaskRequest()
    try handler.perform([request])
    guard let obs = request.results?.first, !obs.allInstances.isEmpty else {
        throw ConvError.failed("No subject found in \(src.lastPathComponent)")
    }
    let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false)
    let dst = outputURL(for: src, ext: "png", suffix: " (cutout)")
    try CIContext().writePNGRepresentation(of: CIImage(cvPixelBuffer: buffer), to: dst,
                                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    return dst
}

/// Rewrites an image in place-format with a sips operation, saving it with a suffix.
func sipsEdit(_ suffix: String, _ args: @escaping (URL) throws -> [String]) -> (URL) throws -> URL {
    { src in
        let dst = outputURL(for: src, ext: src.pathExtension, suffix: suffix)
        try shell("/usr/bin/sips", try args(src) + [src.path, "--out", dst.path])
        return dst
    }
}

func scaleBy(_ percent: Int) -> (URL) throws -> URL {
    sipsEdit(" (\(percent)%)") { src in ["--resampleWidth", String(max(1, try pixelSize(src).w * percent / 100))] }
}

func grayscale(_ src: URL) throws -> URL {
    guard let image = CIImage(contentsOf: src, options: [.applyOrientationProperty: true]) else {
        throw ConvError.failed("Can't read \(src.lastPathComponent)")
    }
    let mono = image.applyingFilter("CIPhotoEffectMono")
    let isJPEG = ["jpg", "jpeg"].contains(src.pathExtension.lowercased())
    let dst = outputURL(for: src, ext: isJPEG ? "jpg" : "png", suffix: " (gray)")
    let ctx = CIContext(), cs = CGColorSpace(name: CGColorSpace.sRGB)!
    if isJPEG { try ctx.writeJPEGRepresentation(of: mono, to: dst, colorSpace: cs) }
    else { try ctx.writePNGRepresentation(of: mono, to: dst, format: .RGBA8, colorSpace: cs) }
    return dst
}

func imageMenu(_ urls: [URL]) -> [MenuItem] {
    var formats = [
        Action(title: "PNG", symbol: "photo", run: each(sipsConvert("png", ext: "png"))),
        Action(title: "JPEG", symbol: "photo.fill", run: each(sipsConvert("jpeg", ext: "jpg", quality: 90))),
        Action(title: "HEIC", symbol: "photo.stack", run: each(sipsConvert("heic", ext: "heic"))),
        Action(title: "TIFF", symbol: "doc.richtext", run: each(sipsConvert("tiff", ext: "tiff"))),
        Action(title: "GIF", symbol: "sparkles", run: each(sipsConvert("gif", ext: "gif"))),
        Action(title: "BMP", symbol: "square.grid.3x3", run: each(sipsConvert("bmp", ext: "bmp"))),
    ]
    if canEncode(.webP) {
        formats.insert(Action(title: "WebP", symbol: "globe", run: each(imageIOConvert(.webP))), at: 3)
    }
    return [
        MenuItem(group: "Convert", "arrow.triangle.2.circlepath", formats),
        MenuItem(group: "Compress", "arrow.down.right.and.arrow.up.left", [
            Action(title: "High", symbol: "circle.fill", run: each(sipsConvert("jpeg", ext: "jpg", quality: 80, suffix: " (compressed)"))),
            Action(title: "Medium", symbol: "circle.lefthalf.filled", run: each(sipsConvert("jpeg", ext: "jpg", quality: 60, suffix: " (compressed)"))),
            Action(title: "Small", symbol: "circle", run: each(sipsConvert("jpeg", ext: "jpg", quality: 35, suffix: " (small)"))),
        ]),
        MenuItem(group: "Resize", "arrow.down.left.and.arrow.up.right.square", [
            Action(title: "75%", symbol: "square.resize", run: each(scaleBy(75))),
            Action(title: "50%", symbol: "square.resize", run: each(scaleBy(50))),
            Action(title: "25%", symbol: "square.resize", run: each(scaleBy(25))),
            Action(title: "2048 px", symbol: "rectangle.expand.vertical", run: each(sipsEdit(" (2048)") { _ in ["-Z", "2048"] })),
            Action(title: "1080 px", symbol: "rectangle.compress.vertical", run: each(sipsEdit(" (1080)") { _ in ["-Z", "1080"] })),
        ]),
        MenuItem(group: "Edit", "wand.and.stars", [
            Action(title: "Rotate", symbol: "rotate.right", run: each(sipsEdit(" (rotated)") { _ in ["-r", "90"] })),
            Action(title: "Flip ↔", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", run: each(sipsEdit(" (flipped)") { _ in ["-f", "horizontal"] })),
            Action(title: "Flip ↕", symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", run: each(sipsEdit(" (flipped)") { _ in ["-f", "vertical"] })),
            Action(title: "Grayscale", symbol: "circle.lefthalf.striped.horizontal", run: each(grayscale)),
            Action(title: "Square", symbol: "crop", run: each(sipsEdit(" (square)") { src in
                let (w, h) = try pixelSize(src); let s = String(min(w, h)); return ["-c", s, s]
            })),
        ]),
        MenuItem(Action(title: "Remove BG", symbol: "person.crop.circle.badge.minus", run: each(removeBackground))),
        MenuItem(Action(title: urls.count > 1 ? "Merge PDF" : "PDF", symbol: "doc.richtext", run: { [try mergeToPDF($0)] })),
        MenuItem(Action(title: "Text (OCR)", symbol: "text.viewfinder", run: each { src in
            let text = try recognizeText(src)
            guard !text.isEmpty else { throw ConvError.failed("No text found in \(src.lastPathComponent)") }
            let dst = outputURL(for: src, ext: "txt")
            try text.write(to: dst, atomically: true, encoding: .utf8)
            return dst
        })),
        infoGroup(),
    ]
}

// MARK: - Video

func ffConvert(ext: String, suffix: String = "", _ args: [String]) -> (URL) throws -> URL {
    { src in
        let dst = outputURL(for: src, ext: ext, suffix: suffix)
        try ffmpeg(["-i", src.path] + args + [dst.path])
        return dst
    }
}

let h264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]

func mergeVideos(_ urls: [URL]) throws -> URL {
    let withAudio = urls.allSatisfy(hasAudioStream)
    var inputs: [String] = [], filter = "", streams = ""
    for (i, u) in urls.enumerated() {
        inputs += ["-i", u.path]
        filter += "[\(i):v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v\(i)];"
        if withAudio { filter += "[\(i):a]aresample=48000[a\(i)];" }
        streams += "[v\(i)]" + (withAudio ? "[a\(i)]" : "")
    }
    filter += "\(streams)concat=n=\(urls.count):v=1:a=\(withAudio ? 1 : 0)[v]" + (withAudio ? "[a]" : "")
    let dst = outputURL(for: urls[0], ext: "mp4", suffix: " (merged)")
    var map = ["-map", "[v]"]
    if withAudio { map += ["-map", "[a]"] }
    try ffmpeg(inputs + ["-filter_complex", filter] + map + h264 + [dst.path])
    return dst
}

func compressVideo(_ height: Int, crf: Int) -> (URL) throws -> URL {
    ffConvert(ext: "mp4", suffix: " (\(height)p)",
              ["-vf", "scale=-2:'min(\(height),ih)'", "-c:v", "libx264", "-preset", "slow", "-crf", String(crf),
               "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"])
}

func videoMenu(_ urls: [URL]) -> [MenuItem] {
    var list = [
        MenuItem(group: "Convert", "arrow.triangle.2.circlepath", [
            Action(title: "MP4", symbol: "film", run: each(ffConvert(ext: "mp4", h264))),
            Action(title: "MOV", symbol: "film.stack", run: each(ffConvert(ext: "mov", h264))),
            Action(title: "MKV", symbol: "shippingbox", run: each(ffConvert(ext: "mkv", h264))),
            Action(title: "WebM", symbol: "globe", run: each(ffConvert(ext: "webm",
                ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus"]))),
            Action(title: "AVI", symbol: "tv", run: each(ffConvert(ext: "avi",
                ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]))),
        ]),
        MenuItem(group: "Compress", "arrow.down.right.and.arrow.up.left", [
            Action(title: "1080p", symbol: "4k.tv", run: each(compressVideo(1080, crf: 26))),
            Action(title: "720p", symbol: "tv", run: each(compressVideo(720, crf: 28))),
            Action(title: "480p", symbol: "iphone", run: each(compressVideo(480, crf: 30))),
        ]),
        MenuItem(Action(title: "GIF", symbol: "sparkles.tv", run: each(ffConvert(ext: "gif",
            ["-vf", "fps=12,scale='min(480,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"])))),
        MenuItem(group: "Audio", "music.note", [
            Action(title: "MP3", symbol: "music.note", run: each(ffConvert(ext: "mp3", ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]))),
            Action(title: "M4A", symbol: "music.note.list", run: each(ffConvert(ext: "m4a", ["-vn", "-c:a", "aac", "-b:a", "192k"]))),
            Action(title: "WAV", symbol: "waveform", run: each(ffConvert(ext: "wav", ["-vn", "-c:a", "pcm_s16le"]))),
        ]),
        MenuItem(group: "Edit", "wand.and.stars", [
            extractSubtitlesAction,
            Action(title: "Mute", symbol: "speaker.slash", run: each { src in
                let dst = outputURL(for: src, ext: src.pathExtension, suffix: " (muted)")
                try ffmpeg(["-i", src.path, "-an", "-c:v", "copy", dst.path])
                return dst
            }),
            Action(title: "Rotate", symbol: "rotate.right", run: each(ffConvert(ext: "mp4", suffix: " (rotated)", ["-vf", "transpose=1"] + h264))),
            Action(title: "2× speed", symbol: "hare", run: each { src in
                let dst = outputURL(for: src, ext: "mp4", suffix: " (2x)")
                let audio = hasAudioStream(src) ? ["-filter:a", "atempo=2.0"] : []
                try ffmpeg(["-i", src.path, "-filter:v", "setpts=0.5*PTS"] + audio + h264 + [dst.path])
                return dst
            }),
        ]),
        MenuItem(Action(title: "Thumbnail", symbol: "photo.on.rectangle", run: each(ffConvert(ext: "jpg", suffix: " (frame)",
            ["-ss", "1", "-frames:v", "1", "-q:v", "2"])))),
        MenuItem(transcribeAction),
    ]
    if urls.count > 1 {
        list.insert(MenuItem(Action(title: "Merge", symbol: "rectangle.stack.badge.plus", run: { [try mergeVideos($0)] })), at: 0)
    }
    return list
}

// MARK: - Audio

func audioEdit(_ suffix: String, _ filter: String) -> (URL) throws -> URL {
    ffConvert(ext: "m4a", suffix: suffix, ["-vn", "-af", filter, "-c:a", "aac", "-b:a", "192k"])
}

func audioMenu(_ urls: [URL]) -> [MenuItem] {
    let trimSilence = "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse"
    var list = [
        MenuItem(group: "Convert", "arrow.triangle.2.circlepath", [
            Action(title: "MP3", symbol: "music.note", run: each(ffConvert(ext: "mp3", ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]))),
            Action(title: "M4A", symbol: "music.note.list", run: each(ffConvert(ext: "m4a", ["-vn", "-c:a", "aac", "-b:a", "192k"]))),
            Action(title: "WAV", symbol: "waveform", run: each(ffConvert(ext: "wav", ["-vn", "-c:a", "pcm_s16le"]))),
            Action(title: "FLAC", symbol: "waveform.path", run: each(ffConvert(ext: "flac", ["-vn", "-c:a", "flac"]))),
            Action(title: "AIFF", symbol: "waveform.circle", run: each(ffConvert(ext: "aiff", ["-vn", "-c:a", "pcm_s16be"]))),
            Action(title: "Opus", symbol: "dot.radiowaves.left.and.right", run: each(ffConvert(ext: "opus", ["-vn", "-c:a", "libopus", "-b:a", "128k"]))),
        ]),
        MenuItem(group: "Compress", "arrow.down.right.and.arrow.up.left", [
            Action(title: "192 kbps", symbol: "circle.fill", run: each(ffConvert(ext: "mp3", suffix: " (192k)", ["-vn", "-c:a", "libmp3lame", "-b:a", "192k"]))),
            Action(title: "128 kbps", symbol: "circle.lefthalf.filled", run: each(ffConvert(ext: "mp3", suffix: " (128k)", ["-vn", "-c:a", "libmp3lame", "-b:a", "128k"]))),
            Action(title: "64 kbps", symbol: "circle", run: each(ffConvert(ext: "mp3", suffix: " (64k)", ["-vn", "-ac", "1", "-c:a", "libmp3lame", "-b:a", "64k"]))),
        ]),
        MenuItem(group: "Edit", "wand.and.stars", [
            Action(title: "Normalize", symbol: "speaker.wave.3", run: each(audioEdit(" (normalized)", "loudnorm=I=-16:TP=-1.5:LRA=11"))),
            Action(title: "Trim silence", symbol: "scissors", run: each(audioEdit(" (trimmed)", trimSilence))),
            Action(title: "1.5× speed", symbol: "hare", run: each(audioEdit(" (1.5x)", "atempo=1.5"))),
        ]),
        MenuItem(transcribeAction),
    ]
    if urls.count > 1 {
        list.insert(MenuItem(Action(title: "Merge", symbol: "rectangle.stack.badge.plus", run: { urls in
            var inputs: [String] = [], streams = ""
            for (i, u) in urls.enumerated() { inputs += ["-i", u.path]; streams += "[\(i):a]" }
            let dst = outputURL(for: urls[0], ext: "m4a", suffix: " (merged)")
            try ffmpeg(inputs + ["-filter_complex", "\(streams)concat=n=\(urls.count):v=0:a=1[a]", "-map", "[a]",
                                 "-c:a", "aac", "-b:a", "192k", dst.path])
            return [dst]
        })), at: 0)
    }
    return list
}

// MARK: - PDF

func openPDF(_ url: URL) throws -> PDFDocument {
    guard let doc = PDFDocument(url: url) else { throw ConvError.failed("Can't open \(url.lastPathComponent)") }
    return doc
}

/// Combines PDFs and images (in drop order) into one PDF.
func mergeToPDF(_ urls: [URL]) throws -> URL {
    let out = PDFDocument()
    for u in urls {
        if kind(of: u) == .pdf {
            let doc = try openPDF(u)
            for i in 0..<doc.pageCount { if let p = doc.page(at: i) { out.insert(p, at: out.pageCount) } }
        } else {
            guard let img = NSImage(contentsOf: u), let page = PDFPage(image: img) else {
                throw ConvError.failed("Can't read \(u.lastPathComponent)")
            }
            out.insert(page, at: out.pageCount)
        }
    }
    let dst = outputURL(for: urls[0], ext: "pdf", suffix: urls.count > 1 ? " (merged)" : "")
    guard out.write(to: dst) else { throw ConvError.failed("Couldn't write PDF") }
    return dst
}

func renderPages(_ src: URL, type: NSBitmapImageRep.FileType, ext: String) throws -> URL {
    let doc = try openPDF(src)
    let folder = doc.pageCount > 1 ? try outputFolder(for: src, suffix: " pages") : nil
    var last = src
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i) else { continue }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: type, properties: [.compressionFactor: 0.9])
        else { throw ConvError.failed("Couldn't render page \(i + 1)") }
        let dst = folder.map { $0.appendingPathComponent(String(format: "Page %03d.%@", i + 1, ext)) }
            ?? outputURL(for: src, ext: ext)
        try data.write(to: dst)
        last = folder ?? dst
        progress.report(Double(i + 1) / Double(doc.pageCount))
    }
    return last
}

func pdfMenu(_ urls: [URL]) -> [MenuItem] {
    var list = [
        studyGroup(urls),
        infoGroup(),
        MenuItem(group: "Images", "photo.on.rectangle", [
            Action(title: "PNG", symbol: "photo", run: each { try renderPages($0, type: .png, ext: "png") }),
            Action(title: "JPEG", symbol: "photo.fill", run: each { try renderPages($0, type: .jpeg, ext: "jpg") }),
            Action(title: "TIFF", symbol: "doc.richtext", run: each { try renderPages($0, type: .tiff, ext: "tiff") }),
        ]),
        MenuItem(Action(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", run: each { src in
            let doc = try openPDF(src)
            let dst = outputURL(for: src, ext: "pdf", suffix: " (compressed)")
            guard doc.write(to: dst, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
            else { throw ConvError.failed("Couldn't write PDF") }
            return dst
        })),
        MenuItem(Action(title: "Text", symbol: "text.alignleft", run: each { src in
            let dst = outputURL(for: src, ext: "txt")
            try (try openPDF(src).string ?? "").write(to: dst, atomically: true, encoding: .utf8)
            return dst
        })),
        MenuItem(Action(title: "Split", symbol: "square.split.2x1", run: each { src in
            let doc = try openPDF(src)
            let folder = try outputFolder(for: src, suffix: " split")
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                single.write(to: folder.appendingPathComponent(String(format: "Page %03d.pdf", i + 1)))
            }
            return folder
        })),
        MenuItem(Action(title: "Rotate", symbol: "rotate.right", run: each { src in
            let doc = try openPDF(src)
            for i in 0..<doc.pageCount { if let p = doc.page(at: i) { p.rotation = (p.rotation + 90) % 360 } }
            let dst = outputURL(for: src, ext: "pdf", suffix: " (rotated)")
            guard doc.write(to: dst) else { throw ConvError.failed("Couldn't write PDF") }
            return dst
        })),
    ]
    if urls.count > 1 {
        list.insert(MenuItem(Action(title: "Merge", symbol: "doc.on.doc", run: { [try mergeToPDF($0)] })), at: 0)
    }
    return list
}

// MARK: - Documents

func textutil(_ format: String, ext: String) -> (URL) throws -> URL {
    { src in
        let dst = outputURL(for: src, ext: ext)
        var args = ["-convert", format]
        if ["md", "markdown", "text"].contains(src.pathExtension.lowercased()) { args += ["-format", "txt"] }
        try shell("/usr/bin/textutil", args + ["-output", dst.path, src.path])
        return dst
    }
}

/// Lays the document out on US Letter pages and prints it straight to a PDF file.
func documentToPDF(_ src: URL) throws -> URL {
    let ext = src.pathExtension.lowercased()
    var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
    if ["txt", "text", "md", "markdown"].contains(ext) { opts[.documentType] = NSAttributedString.DocumentType.plain }
    let text = try NSAttributedString(url: src, options: opts, documentAttributes: nil)
    let dst = outputURL(for: src, ext: "pdf")
    try printToPDF(text, to: dst)
    return dst
}

/// Lays out styled text on US Letter pages and saves it as a PDF. Main thread only.
func printToPDF(_ text: NSAttributedString, to dst: URL) throws {
    let info = NSPrintInfo(dictionary: [.jobSavingURL: dst])
    info.jobDisposition = .save
    info.paperSize = NSSize(width: 612, height: 792)
    for m in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] { info[keyPath: m] = 54 }
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    info.isVerticallyCentered = false

    let width = info.paperSize.width - info.leftMargin - info.rightMargin
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
    view.textStorage?.setAttributedString(text)
    if let lm = view.layoutManager, let tc = view.textContainer {
        lm.ensureLayout(for: tc)
        view.frame.size.height = max(lm.usedRect(for: tc).height + 20, 100)
    }
    let op = NSPrintOperation(view: view, printInfo: info)
    op.showsPrintPanel = false
    op.showsProgressPanel = false
    guard op.run() else { throw ConvError.failed("Couldn't create PDF") }
}

func documentMenu(_ urls: [URL]) -> [MenuItem] {
    let targets: [(String, String, String)] = [
        ("DOCX", "docx", "doc.text"), ("RTF", "rtf", "doc.richtext.fill"), ("TXT", "txt", "text.alignleft"),
        ("HTML", "html", "chevron.left.forwardslash.chevron.right"), ("ODT", "odt", "doc"),
    ]
    let sourceExts = Set(urls.map { $0.pathExtension.lowercased() })
    var list = [MenuItem(Action(title: "PDF", symbol: "doc.richtext", mainThread: true, run: each(documentToPDF))), infoGroup()]
    for (title, ext, symbol) in targets where sourceExts != [ext] {
        list.append(MenuItem(Action(title: title, symbol: symbol, run: each(textutil(ext, ext: ext)))))
    }
    return list
}

// MARK: - Anything

func zip(_ urls: [URL]) throws -> URL {
    let parents = Set(urls.map { $0.deletingLastPathComponent() })
    let dst = outputURL(for: urls[0], ext: "zip", suffix: urls.count > 1 ? " and \(urls.count - 1) more" : "")
    if parents.count == 1, let parent = parents.first {
        // "./" prefix so a file named like "-TT=cmd" can never be read as a zip option.
        try shell("/usr/bin/zip", ["-r", "-q", "-X", dst.path] + urls.map { "./" + $0.lastPathComponent }, cwd: parent)
    } else {
        try shell("/usr/bin/zip", ["-r", "-q", "-X", "-j", dst.path] + urls.map(\.path))
    }
    return dst
}
