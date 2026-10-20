import AppKit
import UniformTypeIdentifiers

// Archives, data files (CSV / TSV / JSON / Excel / plist), subtitles and EPUB e-books.

let archiveExtensions: Set<String> = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "iso", "cpio", "xar"]
let dataExtensions: Set<String> = ["csv", "tsv", "json", "xlsx", "plist"]
let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]
let ebookExtensions: Set<String> = ["epub"]

/// A fresh temp folder, removed by the caller.
private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ezconvert-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A not-yet-existing path next to `src` named `name` (+ `ext`), numbered if taken.
private func freshURL(nextTo src: URL, name: String, ext: String = "") -> URL {
    var dir = src.deletingLastPathComponent()
    if !FileManager.default.isWritableFile(atPath: dir.path) {
        dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
    func make(_ n: String) -> URL { ext.isEmpty ? dir.appendingPathComponent(n) : dir.appendingPathComponent(n).appendingPathExtension(ext) }
    var url = make(name), i = 2
    while FileManager.default.fileExists(atPath: url.path) { url = make("\(name) \(i)"); i += 1 }
    return url
}

// MARK: - Archives

/// "photos.tar.gz" → "photos"
private func archiveBaseName(_ url: URL) -> String {
    var name = url.deletingPathExtension().lastPathComponent
    if name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
    return name
}

/// A lone compressed file (notes.txt.gz) rather than a compressed archive (notes.tar.gz).
private func isSingleCompressed(_ url: URL) -> Bool {
    ["gz", "bz2", "xz"].contains(url.pathExtension.lowercased()) &&
        !url.deletingPathExtension().lastPathComponent.lowercased().hasSuffix(".tar")
}

/// Unpacks into `dir`. bsdtar reads zip, 7z, rar, tar(.gz/.bz2/.xz), iso, cpio and xar, and
/// refuses absolute paths and "../" entries, so a hostile archive can't write outside `dir`.
private func unpack(_ src: URL, into dir: URL) throws {
    try shell("/usr/bin/tar", ["-xf", src.path, "-C", dir.path])
}

func extractArchive(_ src: URL) throws -> URL {
    if isSingleCompressed(src) {
        let tool = ["gz": "/usr/bin/gzip", "bz2": "/usr/bin/bzip2", "xz": "/usr/bin/xz"][src.pathExtension.lowercased()]!
        guard FileManager.default.isExecutableFile(atPath: tool) else { throw ConvError.failed("Can't decompress .xz files on this Mac") }
        let inner = src.deletingPathExtension()
        let dst = freshURL(nextTo: src, name: inner.deletingPathExtension().lastPathComponent, ext: inner.pathExtension)
        let data = try shellData(tool, ["-dc", src.path])
        try data.write(to: dst)
        return dst
    }
    // Unpack into a hidden folder beside the archive (same disk, so the final move is instant).
    let work = src.deletingLastPathComponent().appendingPathComponent(".ezconvert-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    do { try unpack(src, into: work) } catch {
        throw ConvError.failed("Couldn't open \(src.lastPathComponent): \(error.localizedDescription)")
    }
    // If everything is inside one top-level folder, use that folder instead of nesting it twice.
    let items = (try? FileManager.default.contentsOfDirectory(atPath: work.path))?.filter { $0 != ".DS_Store" && $0 != "__MACOSX" } ?? []
    var isDir: ObjCBool = false
    if items.count == 1, FileManager.default.fileExists(atPath: work.appendingPathComponent(items[0]).path, isDirectory: &isDir), isDir.boolValue {
        let target = freshURL(nextTo: src, name: items[0])
        try FileManager.default.moveItem(at: work.appendingPathComponent(items[0]), to: target)
        return target
    }
    let target = freshURL(nextTo: src, name: archiveBaseName(src))
    try FileManager.default.moveItem(at: work, to: target)
    return target
}

func repackArchive(_ src: URL, as format: String) throws -> URL {
    let temp = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: temp) }
    try unpack(src, into: temp)
    let name = archiveBaseName(src)
    switch format {
    case "zip":
        let dst = freshURL(nextTo: src, name: name, ext: "zip")
        try shell("/usr/bin/zip", ["-r", "-q", "-y", "-X", dst.path, "."], cwd: temp)
        return dst
    case "7z":
        let dst = freshURL(nextTo: src, name: name, ext: "7z")
        try shell("/usr/bin/tar", ["--format", "7zip", "-cf", dst.path, "-C", temp.path, "."])
        return dst
    default:
        let dst = freshURL(nextTo: src, name: name, ext: "tar.gz")
        try shell("/usr/bin/tar", ["-czf", dst.path, "-C", temp.path, "."])
        return dst
    }
}

func archiveMenu(_ urls: [URL]) -> [MenuItem] {
    if urls.allSatisfy(isSingleCompressed) {
        return [MenuItem(Action(title: "Extract", symbol: "archivebox.fill", run: each(extractArchive)))]
    }
    let exts = Set(urls.map { $0.pathExtension.lowercased() })
    var formats: [Action] = []
    for (title, fmt, ext) in [("ZIP", "zip", "zip"), ("TAR.GZ", "tar.gz", "gz"), ("7Z", "7z", "7z")] where exts != [ext] {
        formats.append(Action(title: title, symbol: "archivebox", run: each { try repackArchive($0, as: fmt) }))
    }
    return [
        MenuItem(Action(title: "Extract", symbol: "archivebox.fill", run: each(extractArchive))),
        MenuItem(group: "Convert", "arrow.triangle.2.circlepath", formats),
        MenuItem(Action(title: "Contents", symbol: "list.bullet", run: each { src in
            let list = try shell("/usr/bin/tar", ["-tf", src.path])
            let dst = outputURL(for: src, ext: "txt", suffix: " (contents)")
            try list.write(to: dst, atomically: true, encoding: .utf8)
            return dst
        })),
    ]
}

// MARK: - Data files

typealias Table = [[String]]

func readTable(_ url: URL) throws -> Table {
    switch url.pathExtension.lowercased() {
    case "csv": return parseDelimited(try readText(url), separator: ",")
    case "tsv": return parseDelimited(try readText(url), separator: "\t")
    case "json": return try jsonTable(try readText(url))
    case "xlsx": return try readXLSX(url)
    default: throw ConvError.failed("Can't read \(url.lastPathComponent) as a table")
    }
}

/// UTF-8 if possible, otherwise Windows-1252 (common for CSVs exported from Excel).
func readText(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    return text
}

/// RFC 4180 CSV (quoted fields, doubled quotes, newlines inside quotes).
func parseDelimited(_ text: String, separator: Character) -> Table {
    var rows: Table = [], row: [String] = [], field = "", inQuotes = false
    var chars = Array(text)[...]
    while let c = chars.popFirst() {
        if inQuotes {
            if c == "\"" {
                if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { inQuotes = false }
            } else { field.append(c) }
        } else if c == "\"" && field.isEmpty {
            inQuotes = true
        } else if c == separator {
            row.append(field); field = ""
        } else if c == "\n" || c == "\r\n" || c == "\r" {
            row.append(field); field = ""
            rows.append(row); row = []
        } else {
            field.append(c)
        }
    }
    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
    return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
}

func writeDelimited(_ table: Table, separator: String) -> String {
    table.map { row in
        row.map { f in
            f.contains(separator) || f.contains("\"") || f.contains("\n") || f.contains("\r")
                ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
        }.joined(separator: separator)
    }.joined(separator: "\r\n") + "\r\n"
}

/// A JSON list of records (or of lists) as a table; the header keeps the keys in the order they appear.
func jsonTable(_ text: String) throws -> Table {
    guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
        throw ConvError.failed("This isn't valid JSON")
    }
    let rows: [Any]
    if let array = json as? [Any] { rows = array }
    else if let dict = json as? [String: Any], let inner = dict.values.first(where: { $0 is [Any] }) as? [Any], dict.count == 1 { rows = inner }
    else if json is [String: Any] { rows = [json] }
    else { throw ConvError.failed("JSON must be a list of records to convert to a table") }

    func cell(_ v: Any?) -> String {
        switch v {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        case let other?:
            let data = (try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
    if rows.allSatisfy({ $0 is [Any] }) { return rows.map { ($0 as! [Any]).map(cell) } }

    // JSONSerialization forgets key order, so recover it from the text itself.
    var keys: [String] = []
    let all = Set(rows.compactMap { $0 as? [String: Any] }.flatMap(\.keys))
    let keyRegex = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"\s*:"#)
    let ns = text as NSString
    for m in keyRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let raw = "\"" + ns.substring(with: m.range(at: 1)) + "\""
        if let key = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed) as? String,
           all.contains(key), !keys.contains(key) { keys.append(key) }
    }
    keys += all.subtracting(keys).sorted()
    return [keys] + rows.map { row in keys.map { cell((row as? [String: Any])?[$0]) } }
}

private func jsonString(_ s: String) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)) ?? Data("\"\"".utf8), as: UTF8.self)
}

private func looksNumeric(_ s: String) -> Bool {
    s.range(of: #"^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$"#, options: .regularExpression) != nil
}

/// Table → JSON list of records, header row as keys (numbers and true/false keep their types).
func tableJSON(_ table: Table) -> String {
    guard let header = table.first else { return "[]\n" }
    let records = table.dropFirst().map { row -> String in
        let fields = header.enumerated().map { i, key -> String in
            let v = i < row.count ? row[i] : ""
            let value = looksNumeric(v) || v == "true" || v == "false" ? v : jsonString(v)
            return "    \(jsonString(key)): \(value)"
        }
        return "  {\n" + fields.joined(separator: ",\n") + "\n  }"
    }
    return "[\n" + records.joined(separator: ",\n") + "\n]\n"
}

private func columnName(_ i: Int) -> String {
    var n = i + 1, s = ""
    while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
    return s
}

private func columnIndex(_ ref: String) -> Int {
    ref.prefix(while: { $0.isLetter }).uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
}

/// A minimal one-sheet .xlsx: numbers stay numbers, everything else is inline text.
func writeXLSX(_ table: Table, to dst: URL) throws {
    let temp = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: temp) }
    let rows = table.enumerated().map { r, row -> String in
        let cells = row.enumerated().compactMap { c, v -> String? in
            guard !v.isEmpty else { return nil }
            let ref = "\(columnName(c))\(r + 1)"
            return looksNumeric(v) && r > 0 ? "<c r=\"\(ref)\"><v>\(v)</v></c>"
                : "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(v))</t></is></c>"
        }
        return "<row r=\"\(r + 1)\">\(cells.joined())</row>"
    }.joined()
    let files: [String: String] = [
        "[Content_Types].xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """,
        "_rels/.rels": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """,
        "xl/workbook.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """,
        "xl/_rels/workbook.xml.rels": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """,
        "xl/worksheets/sheet1.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(rows)</sheetData></worksheet>
        """,
    ]
    for (path, content) in files {
        let url = temp.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    try? FileManager.default.removeItem(at: dst)
    try shell("/usr/bin/zip", ["-X", "-q", "-r", dst.path, "[Content_Types].xml", "_rels", "xl"], cwd: temp)
}

/// First worksheet of an .xlsx as a table (values as Excel stored them).
func readXLSX(_ src: URL) throws -> Table {
    let temp = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: temp) }
    try shell("/usr/bin/unzip", ["-q", "-o", src.path, "-d", temp.path], okExitCodes: [0, 1])
    let shared: [String] = (try? loadXML(temp.appendingPathComponent("xl/sharedStrings.xml")))
        .map { doc in elements(doc, "si").map { elements($0, "t").map { $0.stringValue ?? "" }.joined() } } ?? []

    // Find the first sheet through the workbook's relationships.
    var sheet = temp.appendingPathComponent("xl/worksheets/sheet1.xml")
    if let wb = try? loadXML(temp.appendingPathComponent("xl/workbook.xml")),
       let first = elements(wb, "sheet").first as? XMLElement,
       let rid = first.attribute(forLocalName: "id", uri: "http://schemas.openxmlformats.org/officeDocument/2006/relationships")?.stringValue,
       let rels = try? loadXML(temp.appendingPathComponent("xl/_rels/workbook.xml.rels")),
       let rel = elements(rels, "Relationship").first(where: { ($0 as? XMLElement)?.attribute(forName: "Id")?.stringValue == rid }) as? XMLElement,
       let target = rel.attribute(forName: "Target")?.stringValue {
        sheet = target.hasPrefix("/") ? temp.appendingPathComponent(String(target.dropFirst()))
                                      : temp.appendingPathComponent("xl").appendingPathComponent(target)
    }
    guard let doc = try? loadXML(sheet) else { throw ConvError.failed("\(src.lastPathComponent) has no readable sheet") }
    var table: Table = []
    for row in elements(doc, "row") {
        var cells: [String] = []
        for case let c as XMLElement in elements(row, "c") {
            let col = c.attribute(forName: "r")?.stringValue.map(columnIndex) ?? cells.count
            let type = c.attribute(forName: "t")?.stringValue
            let raw = elements(c, "v").first?.stringValue ?? ""
            let value: String
            switch type {
            case "s": value = Int(raw).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
            case "inlineStr": value = elements(c, "t").map { $0.stringValue ?? "" }.joined()
            case "b": value = raw == "1" ? "TRUE" : "FALSE"
            default: value = raw
            }
            while cells.count < col { cells.append("") }
            if cells.count == col { cells.append(value) } else if col < cells.count { cells[col] = value }
        }
        table.append(cells)
    }
    let width = table.map(\.count).max() ?? 0
    return table.map { $0 + Array(repeating: "", count: width - $0.count) }
}

func convertTable(_ src: URL, to ext: String) throws -> URL {
    let dst = outputURL(for: src, ext: ext)
    if src.pathExtension.lowercased() == "plist" || ext == "plist" {
        // Property lists convert through plutil.
        let format = ext == "plist" ? "xml1" : "json"
        try shell("/usr/bin/plutil", ["-convert", format, "-o", dst.path, src.path])
        return dst
    }
    let table = try readTable(src)
    switch ext {
    case "csv": try writeDelimited(table, separator: ",").write(to: dst, atomically: true, encoding: .utf8)
    case "tsv": try writeDelimited(table, separator: "\t").write(to: dst, atomically: true, encoding: .utf8)
    case "json": try tableJSON(table).write(to: dst, atomically: true, encoding: .utf8)
    case "xlsx": try writeXLSX(table, to: dst)
    default: throw ConvError.failed("Unsupported format \(ext)")
    }
    return dst
}

func dataMenu(_ urls: [URL]) -> [MenuItem] {
    let exts = Set(urls.map { $0.pathExtension.lowercased() })
    let targets: [(String, String, String)]
    if exts == ["plist"] {
        targets = [("JSON", "json", "curlybraces"), ("XML plist", "plist", "doc.text")]
    } else {
        targets = [("CSV", "csv", "tablecells"), ("TSV", "tsv", "tablecells.fill"), ("JSON", "json", "curlybraces"),
                   ("Excel", "xlsx", "tablecells.badge.ellipsis")] + (exts == ["json"] ? [("Plist", "plist", "doc.text")] : [])
    }
    return [MenuItem(group: "Convert", "arrow.triangle.2.circlepath", targets.filter { !exts.contains($0.1) || exts.count > 1 }.map { t in
        Action(title: t.0, symbol: t.2, run: each { try convertTable($0, to: t.1) })
    })]
}

// MARK: - Subtitles

/// Spoken text of a subtitle file, one cue per line, without numbers, timings or styling.
func subtitleText(_ url: URL) throws -> String {
    let text = try readText(url)
    var lines: [String] = []
    for raw in text.components(separatedBy: .newlines) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("Dialogue:") {
            // ASS/SSA: the text is everything after the 9th comma.
            let parts = line.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            line = parts.count == 10 ? String(parts[9]) : ""
        } else if line.isEmpty || line.contains("-->") || line == "WEBVTT" || line.hasPrefix("NOTE") || line.hasPrefix(";")
                    || line.hasPrefix("[") || line.contains(": ") && text.contains("[Script Info]")
                    || line.range(of: #"^\d+$"#, options: .regularExpression) != nil {
            continue
        }
        line = line.replacingOccurrences(of: #"\{[^}]*\}|<[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: " ").replacingOccurrences(of: "\\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if !line.isEmpty && lines.last != line { lines.append(line) }
    }
    return lines.joined(separator: "\n")
}

func subtitleMenu(_ urls: [URL]) -> [MenuItem] {
    let exts = Set(urls.map { $0.pathExtension.lowercased() })
    let formats = [("SRT", "srt"), ("VTT", "vtt"), ("ASS", "ass")].filter { !exts.contains($0.1) }.map { t in
        Action(title: t.0, symbol: "captions.bubble", run: each(ffConvert(ext: t.1, [])))
    }
    return [
        MenuItem(group: "Convert", "arrow.triangle.2.circlepath", formats),
        MenuItem(Action(title: "Text only", symbol: "text.alignleft", run: each { src in
            let dst = outputURL(for: src, ext: "txt")
            try subtitleText(src).write(to: dst, atomically: true, encoding: .utf8)
            return dst
        })),
        infoGroup(),
    ]
}

// MARK: - Recordings

/// Audio/video → text, with Apple's on-device speech recognition.
let transcribeAction = Action(title: "Transcribe", symbol: "waveform.and.mic", run: each { src in
    let text = try transcribeRecording(src)
    let dst = outputURL(for: src, ext: "txt", suffix: " (transcript)")
    // One sentence per line reads much better than a single wall of text.
    try text.replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\n", options: .regularExpression)
        .write(to: dst, atomically: true, encoding: .utf8)
    return dst
})

let extractSubtitlesAction = Action(title: "Subtitles", symbol: "captions.bubble", run: each { src in
    let dst = outputURL(for: src, ext: "srt")
    do { try ffmpeg(["-i", src.path, "-map", "0:s:0", dst.path]) } catch {
        try? FileManager.default.removeItem(at: dst)
        throw ConvError.failed("No subtitle track in \(src.lastPathComponent)")
    }
    return dst
})

// MARK: - E-books (EPUB)

/// Unpacks an EPUB and joins its chapters, in reading order, into one HTML file inside `temp`.
private func epubHTML(_ src: URL, in temp: URL) throws -> (html: URL, title: String) {
    try shell("/usr/bin/unzip", ["-q", "-o", src.path, "-d", temp.path], okExitCodes: [0, 1])
    guard let container = try? loadXML(temp.appendingPathComponent("META-INF/container.xml")),
          let rootPath = (elements(container, "rootfile").first as? XMLElement)?.attribute(forName: "full-path")?.stringValue,
          let opf = try? loadXML(temp.appendingPathComponent(rootPath)) else {
        throw ConvError.failed("\(src.lastPathComponent) isn't a readable EPUB")
    }
    let opfDir = temp.appendingPathComponent(rootPath).deletingLastPathComponent()
    var manifest: [String: String] = [:]
    for case let item as XMLElement in elements(opf, "item") {
        if let id = item.attribute(forName: "id")?.stringValue, let href = item.attribute(forName: "href")?.stringValue {
            manifest[id] = href.removingPercentEncoding ?? href
        }
    }
    let title = elements(opf, "title").first?.stringValue ?? src.deletingPathExtension().lastPathComponent
    let bodyRegex = try! NSRegularExpression(pattern: #"<body[^>]*>(.*)</body>"#, options: [.dotMatchesLineSeparators, .caseInsensitive])
    var chapters: [String] = []
    for case let ref as XMLElement in elements(opf, "itemref") {
        guard let id = ref.attribute(forName: "idref")?.stringValue, let href = manifest[id] else { continue }
        let chapterURL = opfDir.appendingPathComponent(href)
        guard let page = try? String(contentsOf: chapterURL, encoding: .utf8) else { continue }
        let ns = page as NSString
        var body = bodyRegex.firstMatch(in: page, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) } ?? page
        body = body.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
        // Image paths are relative to each chapter; point them at the chapter's folder.
        let base = chapterURL.deletingLastPathComponent().path
        body = body.replacingOccurrences(of: #"src="(?!https?:|data:|/)([^"]+)""#, with: "src=\"file://\(base)/$1\"", options: .regularExpression)
        chapters.append(body)
    }
    guard !chapters.isEmpty else { throw ConvError.failed("No chapters found in \(src.lastPathComponent)") }
    let html = temp.appendingPathComponent("ezconvert-book.html")
    try """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(xmlEscape(title))</title>
    <style>body { font-family: Georgia, serif; font-size: 12pt; line-height: 1.5; }</style></head><body>
    \(chapters.joined(separator: "\n<hr/>\n"))
    </body></html>
    """.write(to: html, atomically: true, encoding: .utf8)
    return (html, title)
}

func epubText(_ src: URL) throws -> String {
    let temp = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: temp) }
    return try shell("/usr/bin/textutil", ["-convert", "txt", "-stdout", try epubHTML(src, in: temp).html.path])
}

private func epubConvert(_ format: String, ext: String) -> (URL) throws -> URL {
    { src in
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let book = try epubHTML(src, in: temp)
        let dst = outputURL(for: src, ext: ext)
        if format == "pdf" {
            let text = try NSAttributedString(url: book.html, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                        .characterEncoding: String.Encoding.utf8.rawValue],
                                              documentAttributes: nil)
            try printToPDF(text, to: dst)
        } else {
            try shell("/usr/bin/textutil", ["-convert", format, "-output", dst.path, book.html.path])
        }
        return dst
    }
}

func ebookMenu(_ urls: [URL]) -> [MenuItem] {
    [
        MenuItem(group: "Convert", "arrow.triangle.2.circlepath", [
            Action(title: "PDF", symbol: "doc.richtext", mainThread: true, run: each(epubConvert("pdf", ext: "pdf"))),
            Action(title: "DOCX", symbol: "doc.text", run: each(epubConvert("docx", ext: "docx"))),
            Action(title: "TXT", symbol: "text.alignleft", run: each(epubConvert("txt", ext: "txt"))),
            Action(title: "RTF", symbol: "doc.richtext.fill", run: each(epubConvert("rtf", ext: "rtf"))),
        ]),
        infoGroup(),
    ]
}
