import AppKit
import NaturalLanguage
import PDFKit
import Vision

// Info: pulls key dates, people, places, organisations, links and contacts out of a file's text,
// with macOS's built-in language tools (instant, offline, no AI). Each item comes with the sentence it was found in.

// MARK: - Getting text out of a file

/// The readable text of a document, PDF, slide deck, e-book, subtitle file or image (via OCR).
func fileText(_ url: URL) throws -> String {
    let ext = url.pathExtension.lowercased()
    switch kind(of: url) {
    case .pdf:
        return try openPDF(url).string ?? ""
    case .slides:
        return try Deck(url).slides.map(\.text).joined(separator: "\n\n")
    case .ebook:
        return try epubText(url)
    case .subtitle:
        return try subtitleText(url)
    case .image:
        return try recognizeText(url)
    case .document where ["txt", "text", "md", "markdown"].contains(ext):
        return try String(contentsOf: url, encoding: .utf8)
    case .document:
        return try shell("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
    case .data where ["csv", "tsv", "json"].contains(ext):
        return try String(contentsOf: url, encoding: .utf8)
    default:
        throw ConvError.failed("Can't read text from \(url.lastPathComponent)")
    }
}

/// On-device OCR for photos of slides, posters, documents.
func recognizeText(_ url: URL) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    do {
        try VNImageRequestHandler(url: url).perform([request])
    } catch {
        // The first request after launch occasionally fails while Vision loads its model; one retry fixes it.
        Thread.sleep(forTimeInterval: 0.5)
        try VNImageRequestHandler(url: url).perform([request])
    }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

// MARK: - Finding things

struct Finding {
    var text: String
    var context: String
    var count = 1
    var date: Date?
    var hasYear = true
}

/// Sentence lookup so each finding can show where it came from.
private struct Sentences {
    let text: String
    private var ranges: [Range<String.Index>] = []

    init(_ text: String) {
        self.text = text
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        ranges = tokenizer.tokens(for: text.startIndex..<text.endIndex)
    }

    func context(for range: Range<String.Index>) -> String {
        let sentence = ranges.first { $0.contains(range.lowerBound) }.map { String(text[$0]) } ?? String(text[range])
        let clean = sentence.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return clean.count > 220 ? String(clean.prefix(217)) + "…" : clean
    }
}

private let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

/// Dates written out in the text (not "today"/"next week"), oldest first, plus years mentioned on their own.
func keyDates(_ text: String) -> [Finding] {
    let s = Sentences(text)
    var found: [String: Finding] = [:]
    let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    let ns = text as NSString
    var covered: [NSRange] = []
    for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let raw = ns.substring(with: m.range)
        let lower = raw.lowercased()
        // Keep real calendar dates; drop relative ones whose meaning depends on when the file is read.
        guard lower.rangeOfCharacter(from: .decimalDigits) != nil || monthNames.contains(where: { lower.contains($0) }),
              let range = Range(m.range, in: text) else { continue }
        covered.append(m.range)
        let hasYear = raw.range(of: #"\b(1[0-9]{3}|20[0-9]{2})\b|'\d{2}\b"#, options: .regularExpression) != nil
        let key = raw.lowercased()
        if found[key] != nil { found[key]!.count += 1; continue }
        found[key] = Finding(text: raw, context: s.context(for: range), date: m.date, hasYear: hasYear)
    }
    // Bare years ("in 1776") that aren't part of a full date.
    let yearRegex = try! NSRegularExpression(pattern: #"\b(1[0-9]{3}|20[0-9]{2})s?\b"#)
    for m in yearRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    where !covered.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
        guard let range = Range(m.range, in: text) else { continue }
        let raw = ns.substring(with: m.range)
        if found[raw] != nil { found[raw]!.count += 1; continue }
        let year = Int(raw.prefix(4)) ?? 0
        found[raw] = Finding(text: raw, context: s.context(for: range),
                             date: Calendar(identifier: .gregorian).date(from: DateComponents(year: year)))
    }
    return found.values.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
}

/// People, places or organisations, most-mentioned first. Short forms ("Curie") are merged into full names.
func entities(_ text: String, _ tag: NLTag) -> [Finding] {
    let s = Sentences(text)
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    var found: [String: Finding] = [:], order: [String] = []
    tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                         options: [.omitWhitespace, .omitPunctuation, .joinNames]) { t, range in
        guard t == tag else { return true }
        let name = text[range].components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard name.count > 1 else { return true }
        if found[name] == nil { found[name] = Finding(text: name, context: s.context(for: range)); order.append(name) }
        else { found[name]!.count += 1 }
        return true
    }
    // Merge one-word mentions into a longer name that contains them.
    for short in order where !short.contains(" ") {
        if let full = order.first(where: { $0 != short && $0.components(separatedBy: " ").contains(short) }),
           let extra = found[short]?.count {
            found[full]?.count += extra
            found[short] = nil
        }
    }
    return order.compactMap { found[$0] }.sorted { $0.count > $1.count }
}

/// Web links, email addresses, phone numbers and street addresses.
func linksAndContacts(_ text: String) -> [(label: String, items: [Finding])] {
    let s = Sentences(text)
    let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber, .address]
    let detector = try! NSDataDetector(types: types.rawValue)
    let ns = text as NSString
    var links: [Finding] = [], emails: [Finding] = [], phones: [Finding] = [], addresses: [Finding] = []
    var seen = Set<String>()
    for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let raw = ns.substring(with: m.range)
        guard seen.insert(raw.lowercased()).inserted, let range = Range(m.range, in: text) else { continue }
        let f = Finding(text: raw, context: s.context(for: range))
        switch m.resultType {
        case .link where m.url?.scheme == "mailto": emails.append(f)
        case .link: links.append(f)
        case .phoneNumber: phones.append(f)
        case .address: addresses.append(f)
        default: break
        }
    }
    return [("Links", links), ("Email addresses", emails), ("Phone numbers", phones), ("Addresses", addresses)]
}

// MARK: - Writing it up

private func list(_ items: [Finding], showCount: Bool = false, dates: Bool = false) -> String {
    guard !items.isEmpty else { return "*None found.*\n" }
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMMM yyyy"
    return items.map { f in
        var head = "**\(f.text)**"
        if dates, let d = f.date, f.hasYear, f.text.rangeOfCharacter(from: .letters) == nil || f.text.count > 4 {
            let pretty = formatter.string(from: d)
            if pretty.lowercased() != f.text.lowercased() && f.text.count > 4 { head += " (\(pretty))" }
        }
        if showCount && f.count > 1 { head += " — mentioned \(f.count)×" }
        return "- \(head): “\(f.context)”"
    }.joined(separator: "\n") + "\n"
}

private func datesSection(_ text: String) -> String { "## Key dates\n\n" + list(keyDates(text), dates: true) }
private func namesSection(_ text: String) -> String { "## Key names\n\n" + list(entities(text, .personalName), showCount: true) }
private func placesSection(_ text: String) -> String {
    "## Places\n\n" + list(entities(text, .placeName), showCount: true) +
    "\n## Organisations\n\n" + list(entities(text, .organizationName), showCount: true)
}
private func contactsSection(_ text: String) -> String {
    linksAndContacts(text).map { "## \($0.label)\n\n" + list($0.items) }.joined(separator: "\n")
}

private func infoAction(_ title: String, _ symbol: String, suffix: String,
                        _ section: @escaping (String) -> String) -> Action {
    Action(title: title, symbol: symbol, run: each { src in
        let text = try fileText(src)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConvError.failed("No text found in \(src.lastPathComponent)")
        }
        progress.report(0.5)
        let name = src.deletingPathExtension().lastPathComponent
        return try writeDocx("# \(name)\n\n*\(title) found in \(src.lastPathComponent)*\n\n" + section(text), for: src, suffix: suffix)
    })
}

func infoGroup() -> MenuItem {
    MenuItem(group: "Info", "info.circle", [
        infoAction("Key dates", "calendar", suffix: " (key dates)", datesSection),
        infoAction("Key names", "person.2", suffix: " (key names)", namesSection),
        infoAction("Places & orgs", "building.2", suffix: " (places)", placesSection),
        infoAction("Links & contacts", "link", suffix: " (contacts)", contactsSection),
        infoAction("All info", "list.bullet.rectangle", suffix: " (info)") {
            [datesSection($0), namesSection($0), placesSection($0), contactsSection($0)].joined(separator: "\n")
        },
    ])
}
