import Foundation
import NaturalLanguage

/// Fields extracted from one card, plus how much to trust them.
struct ParseResult {
    var fields: [String: String] = [:]
    var confidence = 0.0
    var reasons: [String] = []
}

struct NameParts {
    var full = "", prefix = "", first = "", middle = "", last = "", suffix = "", credentials = ""
    /// Non-credential text after a comma, e.g. the "CEO" in "Jane Doe, CEO".
    var trailing = ""
    /// Name words without prefix, suffix or credentials.
    var core: [String] = []
}

private struct Phone {
    var number: String
    var ext: String?
    var kind: PhoneKind
    var digits: String
}

/// A piece of an OCR line, split on separators such as "|" or "•".
private struct Segment {
    var text: String
    let line: OCRLine
    var consumed = false
}

/// Per-side extraction state.
private final class Side {
    var segs: [Segment] = []
    var emails: [String] = []
    var websites: [String] = []
    var linkedin: [String] = []
    var twitter: [String] = []
    var otherSocial: [String] = []
    var phones: [Phone] = []
    var address: [String: String] = [:]
    var name: NameParts?
    var nameScore = 0.0
    var title: String?
    var department: String?
    var company: String?
    var companyGuessed = false
    var meanConfidence = 0.0
    var charCount = 0

    var richness: Int {
        emails.count * 2 + phones.count + (name == nil ? 0 : 3) + (address.isEmpty ? 0 : 1) + (company == nil ? 0 : 1)
    }
}

/// Scored features of a leftover text segment that might be a name, title or company.
private struct Candidate {
    let seg: Int
    let text: String
    let name: NameParts
    let words: [String]
    var person = 0.0, org = 0.0
    var strongTitle = 0, weakTitle = 0
    var legal = false
    var orgWords = 0
    var domainMatch = false
    var emailMatch = 0.0
    var heightRel = 0.0
    var hasDigit = false
    var lowerRatio = 0.0
    var nameScore = 0.0, titleScore = 0.0, companyScore = 0.0
}

enum Parser {
    // MARK: Patterns

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    private static let separatorRE = re(#"\s*[|•·▪■◦●‧►▶︱┃]\s*|\s+l\s+|\s+I\s+(?=[A-Z0-9+(@])"#)
    private static let emailRE = re(#"(?i)[a-z0-9._%+'\-]+@[a-z0-9\-]+(?:\.[a-z0-9\-]+)*\.[a-z]{2,24}"#)
    private static let urlRE = re(#"(?i)(?<![@\w.\-])((?:https?://)?(?:www\.)?(?:[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\.)+([a-z]{2,24}))((?:/[^\s|,;]*)?)"#)
    private static let linkedinShortRE = re(#"(?i)(?<![\w/])(?:linkedin\s*[:\-]?\s*)?\bin/([a-z0-9\-_%]{3,100})/?"#)
    private static let handleRE = re(#"(?<![\w.@])@([A-Za-z0-9_.]{2,30})\b"#)
    private static let phoneRE = re(#"(?<![\w@])(?:\+|\()?\d[\d\s().\-/]{5,}\d"#)
    private static let extRE = re(#"(?i)^\s*,?\s*(?:ext\.?|extn\.?|extension|x\.?|#)\s*(\d{1,6})"#)
    private static let zip4RE = re(#"^\d{5}-\d{4}$"#)
    private static let parenLabelRE = re(#"^\s*\(([A-Za-z]{1,6})\)"#)
    private static let departmentRE = re(Lexicon.departmentPattern)
    private static let suiteRE = re(#"(?i)^(suite|ste\.?|unit|floor|fl\.?|#\s*\d|room|rm\.?|building|bldg\.?|level|po box|p\.o\. box|\d+(st|nd|rd|th) floor)\b"#)
    private static let streetRE = re(#"(?i)^(\d+[a-z]?(-\d+)?\s+\S.*\b(street|st|avenue|ave|road|rd|boulevard|blvd|drive|dr|lane|ln|way|court|ct|place|pl|parkway|pkwy|highway|hwy|square|sq|terrace|ter|circle|cir|plaza|suite|ste|route|rte|trail|trl|center|centre|crescent|close|row|loop|pike|alley|broadway|expressway|freeway|turnpike)\b\.?.*|p\.?\s?o\.?\s+box\s*\d+.*)$"#)
    private static let usCityRE = re(#"^(.+?),?\s+([A-Z]{2})\.?,?\s+(\d{5}(?:-\d{4})?)$"#)
    private static let caCityRE = re(#"^(.+?),?\s+([A-Z]{2}),?\s+([A-Z]\d[A-Z]\s?\d[A-Z]\d)$"#)
    private static let ukPostcodeRE = re(#"\b([A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2})\b"#)
    private static let euCityRE = re(#"^(?:[A-Z]{1,2}-)?(\d{4,5})\s+([^\d,]{2,40})$"#)

    // MARK: Entry point

    /// Parses the OCR lines of each side (front first) into one set of card fields.
    static func parse(_ pages: [[OCRLine]], debug: Bool = false) -> ParseResult {
        let sides = pages.map { lines -> Side in
            let s = Side()
            s.charCount = lines.reduce(0) { $0 + $1.text.count }
            if s.charCount > 0 {
                s.meanConfidence = lines.reduce(0.0) { $0 + $1.confidence * Double($1.text.count) } / Double(s.charCount)
            }
            for line in lines {
                for part in split(normalize(line.text)) { s.segs.append(Segment(text: part, line: line)) }
            }
            extractContacts(s)
            return s
        }

        let emails = unique(sides.flatMap(\.emails))
        let locals = emails.map { fold(String($0.split(separator: "@")[0])) }
        var hosts = sides.flatMap(\.websites).map(host)
        hosts += emails.map { String($0.split(separator: "@")[1]) }.filter { !Lexicon.freemailDomains.contains($0) }
        let stems = unique(hosts.compactMap(domainStem))

        for s in sides {
            extractAddress(s)
            extractEntities(s, locals: locals, stems: stems, debug: debug)
        }
        return merge(sides, emails: emails, stems: stems, allText: pages.flatMap { $0.map(\.text) }.joined(separator: "\n"))
    }

    // MARK: Normalization

    private static func normalize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // OCR often spaces out email/web punctuation: "jane @ acme. com"
        t = t.replacingOccurrences(of: #"(?<=[\w.])\s*@\s*(?=[\w\-]+\s?\.\s?[A-Za-z]{2,})"#, with: "@", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)(?<=[a-z0-9])\s?\.\s(?=(com|net|org|edu|gov|io|co|us|uk|ca|biz|info|de|fr)\b)"#,
                                   with: ".", options: .regularExpression)
        // "@" is often misread as a lookalike symbol inside an email address.
        t = t.replacingOccurrences(of: #"(?<=[\w.])[¿®©](?=[\w\-]+\.[A-Za-z]{2,}\b)"#, with: "@", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[®™©]"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func split(_ s: String) -> [String] {
        let ns = s as NSString
        var parts: [String] = []
        var start = 0
        for m in separatorRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = NSMaxRange(m.range)
        }
        parts.append(ns.substring(from: start))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Contacts (email, web, social, phone)

    private static let lightJunk = CharacterSet(charactersIn: " :;,|-–—*•·").union(.whitespaces)
    private static let edgeJunk = CharacterSet(charactersIn: " :;,|-–—/\\.·•*>+_~=()[]{}\"'`").union(.whitespaces)

    private static func extractContacts(_ s: Side) {
        for i in s.segs.indices {
            let original = s.segs[i].text
            let lower = original.lowercased()
            var t = original

            t = remove(emailRE, in: t) { m, _ in
                s.emails.append(m.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                return true
            }
            t = remove(urlRE, in: t) { m, r in classifyURL(m, match: r, into: s) }
            t = remove(linkedinShortRE, in: t) { m, _ in
                s.linkedin.append("linkedin.com/in/" + m.components(separatedBy: "in/").last!.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                return true
            }
            let current = t as NSString
            t = remove(handleRE, in: t) { m, r in
                let before = current.substring(to: r.range.location).lowercased()
                    .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
                let label = before.last ?? (lower.contains("twitter") ? "twitter" : lower.contains("insta") ? "ig" : "")
                switch label {
                case "twitter", "x", "tw": s.twitter.append(m)
                case "ig", "insta", "instagram": s.otherSocial.append("Instagram: \(m)")
                case "tiktok", "threads", "telegram", "skype": s.otherSocial.append("\(label.capitalized): \(m)")
                default: s.otherSocial.append(m)
                }
                return true
            }
            t = extractPhones(t, into: s)

            if t != original {
                t = stripEdgeLabels(t).trimmingCharacters(in: edgeJunk)
            } else {
                t = t.trimmingCharacters(in: lightJunk)
            }
            s.segs[i].text = t
            if t.isEmpty || isLabelOnly(t) || !t.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
                s.segs[i].consumed = true
            }
        }
    }

    /// Removes every match `accept` returns true for, replacing it with a space.
    private static func remove(_ re: NSRegularExpression, in text: String,
                               _ accept: (String, NSTextCheckingResult) -> Bool) -> String {
        let ns = text as NSString
        let hits = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .filter { accept(ns.substring(with: $0.range), $0) }
        guard !hits.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for m in hits.reversed() { out.replaceCharacters(in: m.range, with: " ") }
        return out as String
    }

    private static func classifyURL(_ raw: String, match m: NSTextCheckingResult, into s: Side) -> Bool {
        let lower = raw.lowercased()
        let hasScheme = lower.hasPrefix("http")
        let bare = lower.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        let hasWWW = bare.hasPrefix("www.")
        let h = host(bare)
        let labels = h.split(separator: ".")
        guard let tld = labels.last.map(String.init), labels.count >= 2 else { return false }
        guard hasScheme || hasWWW || Lexicon.knownTLDs.contains(tld) else { return false }
        guard labels.dropLast().last.map({ $0.count >= 2 }) ?? false else { return false }

        let value = bare.trimmingCharacters(in: CharacterSet(charactersIn: "/.,"))
        let registrable = labels.suffix(2).joined(separator: ".")
        if registrable == "linkedin.com" {
            s.linkedin.append(value.replacingOccurrences(of: "www.", with: ""))
        } else if registrable == "twitter.com" || registrable == "x.com" {
            let handle = value.split(separator: "/").dropFirst().first.map { "@" + $0 } ?? value
            s.twitter.append(handle)
        } else if let network = Lexicon.socialHosts[registrable] {
            s.otherSocial.append("\(network): \(value)")
        } else {
            s.websites.append(value)
        }
        return true
    }

    private static func extractPhones(_ text: String, into s: Side) -> String {
        let ns = text as NSString
        let ms = phoneRE.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return text }
        var removals: [NSRange] = []
        var prevEnd = 0
        for (k, m) in ms.enumerated() {
            let raw = ns.substring(with: m.range)
            let digits = String(raw.filter { $0.isASCII && $0.isNumber })
            guard digits.count >= 7, zip4RE.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) == nil else { continue }
            // A street number like "12345 678th St" is not a phone.
            if streetRE.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil, !raw.contains("("), !raw.hasPrefix("+"),
               digits.count < 10 { continue }

            let lead = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces).lowercased()
            if lead.hasSuffix("〒") || lead.hasSuffix("zip") || lead.hasSuffix("plz") || lead.hasSuffix("postal") { continue }

            let nextStart = k + 1 < ms.count ? ms[k + 1].range.location : ns.length
            let afterRange = NSRange(location: NSMaxRange(m.range), length: max(0, nextStart - NSMaxRange(m.range)))
            let after = ns.substring(with: afterRange)
            let prefix = ns.substring(with: NSRange(location: prevEnd, length: max(0, m.range.location - prevEnd)))
            var end = NSMaxRange(m.range)
            var ext: String?
            let afterNS = after as NSString
            if let e = extRE.firstMatch(in: after, range: NSRange(location: 0, length: afterNS.length)) {
                ext = afterNS.substring(with: e.range(at: 1))
                end += e.range.length
            } else if let p = parenLabelRE.firstMatch(in: after, range: NSRange(location: 0, length: afterNS.length)),
                      Lexicon.phoneLabels[afterNS.substring(with: p.range(at: 1)).lowercased()] != nil {
                end += p.range.length
            }
            var kind = phoneKind(prefix: prefix, after: after)
            if kind == .unlabeled, digits.range(of: #"^1?8(00|33|44|55|66|77|88)"#, options: .regularExpression) != nil { kind = .other }
            // A bare 7-digit "123-4567" inside address text is a postal code (e.g. Japan), not a phone.
            if kind == .unlabeled, digits.count == 7,
               text.unicodeScalars.filter(CharacterSet.letters.contains).count >= 5 { continue }
            for (j, number) in splitRun(raw).enumerated() {
                let d = String(number.filter { $0.isASCII && $0.isNumber })
                s.phones.append(Phone(number: number, ext: j == 0 ? ext : nil, kind: kind, digits: d))
                kind = .unlabeled
            }
            removals.append(NSRange(location: m.range.location, length: end - m.range.location))
            prevEnd = end
        }
        let out = NSMutableString(string: text)
        for r in removals.reversed() { out.replaceCharacters(in: r, with: " ") }
        return out as String
    }

    /// Splits a run like "555-123-4567 555-987-6543" that swallowed two numbers.
    private static func splitRun(_ raw: String) -> [String] {
        let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: " -./"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let digitCount = clean.filter { $0.isASCII && $0.isNumber }.count
        guard digitCount > 15 else { return [clean] }
        var out: [String] = [], cur: [Substring] = [], curDigits = 0
        for tok in clean.split(separator: " ") {
            cur.append(tok)
            curDigits += tok.filter { $0.isASCII && $0.isNumber }.count
            if curDigits >= 10 { out.append(cur.joined(separator: " ")); cur = []; curDigits = 0 }
        }
        if !cur.isEmpty { out.append(cur.joined(separator: " ")) }
        return out
    }

    private static func phoneKind(prefix: String, after: String) -> PhoneKind {
        let words = prefix.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        if words.suffix(2).joined(separator: " ") == "toll free" { return .other }
        if let w = words.last, let k = Lexicon.phoneLabels[w] { return k }
        let ans = after as NSString
        if let p = parenLabelRE.firstMatch(in: after, range: NSRange(location: 0, length: ans.length)),
           let k = Lexicon.phoneLabels[ans.substring(with: p.range(at: 1)).lowercased()] { return k }
        let next = after.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        if after.trimmingCharacters(in: .whitespaces).first?.isLetter == true, let w = next.first, w.count >= 3,
           let k = Lexicon.phoneLabels[w] { return k }
        return .unlabeled
    }

    private static func tokens(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty }
    }

    private static func isLabelOnly(_ s: String) -> Bool {
        let t = tokens(s)
        return t.allSatisfy { Lexicon.labelWords.contains($0) }
    }

    /// Drops label words left at either end once a value has been extracted ("Jane Doe  M:" → "Jane Doe").
    private static func stripEdgeLabels(_ s: String) -> String {
        var words = s.split(whereSeparator: { $0 == " " }).map(String.init)
        func isLabel(_ w: String) -> Bool {
            let t = tokens(w)
            return t.isEmpty || t.allSatisfy { Lexicon.labelWords.contains($0) }
        }
        while let f = words.first, isLabel(f) { words.removeFirst() }
        while let l = words.last, isLabel(l) { words.removeLast() }
        return words.joined(separator: " ")
    }

    // MARK: Address

    private static func extractAddress(_ s: Side) {
        var joined = ""
        var spans: [(seg: Int, range: NSRange)] = []
        for i in s.segs.indices where !s.segs[i].consumed {
            let start = (joined as NSString).length
            joined += s.segs[i].text + "\n"
            spans.append((i, NSRange(location: start, length: (s.segs[i].text as NSString).length)))
        }
        guard !spans.isEmpty else { return }

        var used: [Int] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue) {
            let matches = detector.matches(in: joined, range: NSRange(location: 0, length: (joined as NSString).length))
            if let m = matches.max(by: { ($0.addressComponents?.count ?? 0) < ($1.addressComponents?.count ?? 0) }),
               let comps = m.addressComponents {
                let values = comps.values.map { $0.lowercased() }
                for (seg, range) in spans where NSIntersectionRange(range, m.range).length > 0 {
                    let text = s.segs[seg].text
                    let lt = text.lowercased()
                    // Don't let the detector swallow a neighbouring name or company line.
                    if text.contains(where: \.isNumber) || values.contains(where: { $0.contains(lt) || lt.contains($0) }) {
                        used.append(seg)
                    }
                }
                func comp(_ k: NSTextCheckingKey) -> String? {
                    comps[k].map { $0.replacingOccurrences(of: "\n", with: ", ").trimmingCharacters(in: edgeJunk) }
                }
                s.address["street"] = comp(.street)
                s.address["city"] = comp(.city)
                s.address["region"] = comp(.state)
                s.address["postal_code"] = comp(.zip)
                s.address["country"] = comp(.country)
            }
        }

        // Fallback rules when the detector found nothing usable.
        if s.address["street"] == nil && s.address["city"] == nil {
            for (seg, _) in spans {
                let text = s.segs[seg].text
                let ns = text as NSString
                let full = NSRange(location: 0, length: ns.length)
                if s.address["street"] == nil, streetRE.firstMatch(in: text, range: full) != nil {
                    s.address["street"] = text; used.append(seg); continue
                }
                if s.address["city"] == nil {
                    if let m = usCityRE.firstMatch(in: text, range: full) ?? caCityRE.firstMatch(in: text, range: full) {
                        s.address["city"] = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: edgeJunk)
                        s.address["region"] = ns.substring(with: m.range(at: 2))
                        s.address["postal_code"] = ns.substring(with: m.range(at: 3))
                        used.append(seg); continue
                    }
                    if let m = ukPostcodeRE.firstMatch(in: text, range: full), s.address["street"] != nil {
                        s.address["postal_code"] = ns.substring(with: m.range(at: 1))
                        let city = ns.replacingCharacters(in: m.range, with: "").trimmingCharacters(in: edgeJunk)
                        if !city.isEmpty { s.address["city"] = city }
                        used.append(seg); continue
                    }
                    if let m = euCityRE.firstMatch(in: text, range: full), s.address["street"] != nil {
                        s.address["postal_code"] = ns.substring(with: m.range(at: 1))
                        s.address["city"] = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: edgeJunk)
                        used.append(seg); continue
                    }
                }
            }
        }
        if used.isEmpty {
            for (seg, _) in spans {
                let parts = s.segs[seg].text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count >= 2, parts.count <= 3, let last = parts.last, Lexicon.countries.contains(fold(last, keepSpaces: true)),
                   !s.segs[seg].text.contains(where: \.isNumber) {
                    s.address["city"] = parts[0]
                    if parts.count == 3 { s.address["region"] = parts[1] }
                    s.address["country"] = last
                    used.append(seg)
                    break
                }
            }
        }
        guard !used.isEmpty else { s.address = [:]; return }
        for i in used { s.segs[i].consumed = true }

        // Suite / floor lines and a bare country line near the address.
        for (seg, _) in spans where !s.segs[seg].consumed {
            let text = s.segs[seg].text
            if suiteRE.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil {
                if let street = s.address["street"], !street.localizedCaseInsensitiveContains(text) {
                    s.address["street"] = street + ", " + text
                } else if s.address["street"] == nil {
                    s.address["street"] = text
                }
                s.segs[seg].consumed = true; used.append(seg)
            } else if s.address["country"] == nil, Lexicon.countries.contains(fold(text, keepSpaces: true)) {
                s.address["country"] = text
                s.segs[seg].consumed = true; used.append(seg)
            }
        }
        s.address["address_full"] = used.sorted().map { s.segs[$0].text }.joined(separator: ", ")
        s.address = s.address.filter { !$0.value.isEmpty }
    }

    // MARK: Name, title, company, department

    private static func extractEntities(_ s: Side, locals: [String], stems: [String], debug: Bool) {
        var cands: [Candidate] = []
        for i in s.segs.indices where !s.segs[i].consumed {
            let text = s.segs[i].text
            guard text.unicodeScalars.filter(CharacterSet.letters.contains).count >= 2 else { continue }
            let name = splitName(text)
            let words = tokens(text)
            var c = Candidate(seg: i, text: text, name: name, words: words)
            let tagText = isAllCaps(text) ? titleCase(text) : text
            (c.person, c.org) = nameTagFractions(name.core.isEmpty ? tagText : titleCaseIfCaps(name.core.joined(separator: " ")),
                                                  whole: tagText)
            c.strongTitle = words.filter(Lexicon.titleStrong.contains).count
            c.weakTitle = words.filter(Lexicon.titleWeak.contains).count
            c.legal = words.suffix(2).contains(where: Lexicon.legalSuffixes.contains) && words.count >= 2
            c.orgWords = words.filter(Lexicon.orgWords.contains).count
            c.domainMatch = matchesDomain(text, stems: stems)
            c.emailMatch = emailNameMatch(name.core, locals: locals)
            c.hasDigit = text.contains(where: \.isNumber)
            let rawWords = text.split(separator: " ")
            let lowerWords = rawWords.filter { w in
                guard let f = w.first, f.isLetter, f.isLowercase else { return false }
                return !["of", "and", "the", "for", "&", "de", "a", "in", "at", "to"].contains(w.lowercased())
            }
            c.lowerRatio = rawWords.isEmpty ? 0 : Double(lowerWords.count) / Double(rawWords.count)
            cands.append(c)
        }
        guard !cands.isEmpty else { return }

        let maxHeight = cands.map { s.segs[$0.seg].line.height }.max() ?? 1
        for k in cands.indices { cands[k].heightRel = s.segs[cands[k].seg].line.height / max(maxHeight, 0.0001) }

        func adjacent(_ a: Int, _ b: Int) -> Bool {
            let la = s.segs[cands[a].seg].line, lb = s.segs[cands[b].seg].line
            if la.top == lb.top && la.x0 == lb.x0 { return true }  // same OCR line, split on a separator
            let gap = max(lb.top - la.bottom, la.top - lb.bottom)
            let h = max(la.height, lb.height)
            let overlap = min(la.x1, lb.x1) - max(la.x0, lb.x0)
            return gap < 1.6 * h && (overlap > -0.02 || abs(la.x0 - lb.x0) < 0.05)
        }

        // Name
        for k in cands.indices {
            var c = cands[k]
            let n = c.name.core.count
            var sc = (2...4).contains(n) ? 1.5 : (n == 5 ? 0 : -3)
            if c.hasDigit { sc -= 4 }
            sc += 2.5 * c.person - 2 * c.org
            let caps = c.name.core.filter { w in
                guard let f = w.first else { return false }
                return f.isUppercase || Lexicon.nameParticles.contains(w.lowercased())
            }.count
            sc += n == 0 ? 0 : Double(caps) / Double(n)
            if c.strongTitle > 0 { sc -= 3 }
            sc -= 0.5 * Double(c.weakTitle)
            if c.legal { sc -= 4 }
            sc -= 1.5 * Double(c.orgWords)
            if c.domainMatch { sc -= 2 }
            sc += c.emailMatch
            sc += 1.5 * c.heightRel
            if !c.name.credentials.isEmpty || !c.name.prefix.isEmpty { sc += 2 }
            sc -= 2 * c.lowerRatio
            if c.text.count > 40 { sc -= 2 }
            if c.text.hasSuffix(".") && c.name.credentials.isEmpty && c.name.suffix.isEmpty { sc -= 1 }
            if cands.indices.contains(where: { $0 != k && cands[$0].strongTitle > 0 && adjacent(k, $0) }) { sc += 1.5 }
            c.nameScore = sc
            cands[k] = c
        }
        var taken = Set<Int>()
        if let best = cands.indices.max(by: { cands[$0].nameScore < cands[$1].nameScore }), cands[best].nameScore >= 1.5 {
            var parts = cands[best].name
            if isAllCaps(parts.full) { parts = splitName(titleCase(cands[best].text)) }
            s.name = parts
            s.nameScore = cands[best].nameScore
            taken.insert(best)
        }
        let nameIdx = taken.first

        // Title
        for k in cands.indices where !taken.contains(k) {
            var sc = 3.0 * Double(cands[k].strongTitle) + Double(min(cands[k].weakTitle, 3))
            if cands[k].legal { sc -= 3 }
            if cands[k].domainMatch { sc -= 2 }
            if cands[k].words.count > 10 { sc -= 3 }
            if cands[k].hasDigit { sc -= 1 }
            if let n = nameIdx, adjacent(n, k) { sc += 1 }
            cands[k].titleScore = sc
        }
        let titleCands = cands.indices.filter { !taken.contains($0) }
        if let best = titleCands.max(by: { cands[$0].titleScore < cands[$1].titleScore }),
           cands[best].titleScore >= 3 || (cands[best].titleScore >= 2 && nameIdx.map { adjacent($0, best) } == true) {
            taken.insert(best)
            // Other title-like pieces of the same OCR line ("REALTOR | Associate Broker").
            let bestLine = s.segs[cands[best].seg].line
            let sameLine = cands.indices.filter { k in
                let l = s.segs[cands[k].seg].line
                return k == best || (!taken.contains(k) && l.top == bestLine.top && l.x0 == bestLine.x0 &&
                                     (cands[k].strongTitle > 0 || cands[k].weakTitle > 0) && !cands[k].legal && !cands[k].domainMatch)
            }
            for k in sameLine { taken.insert(k) }
            var title = sameLine.map { cands[$0].text }.joined(separator: ", ")
            // Titles often wrap onto a second line directly below.
            var last = best
            for _ in 0..<2 {
                let top = s.segs[cands[last].seg].line.top
                guard let next = cands.indices.filter({ !taken.contains($0) && s.segs[cands[$0].seg].line.top > top && adjacent(last, $0) })
                    .min(by: { s.segs[cands[$0].seg].line.top < s.segs[cands[$1].seg].line.top }) else { break }
                let n = cands[next]
                let connector = n.text.lowercased().hasPrefix("&") || n.text.lowercased().hasPrefix("and ") || n.text.lowercased().hasPrefix("of ")
                guard (n.strongTitle > 0 || n.weakTitle > 0 || connector), !n.legal, !n.domainMatch,
                      departmentRE.firstMatch(in: n.text, range: NSRange(location: 0, length: (n.text as NSString).length)) == nil
                else { break }
                let joiner = title.hasSuffix(",") || title.hasSuffix("&") || connector || title.lowercased().hasSuffix(" of") ? " " : ", "
                title += joiner + n.text
                taken.insert(next)
                last = next
            }
            s.title = title
        } else if let n = s.name, !n.trailing.isEmpty {
            s.title = n.trailing
        }

        // Department
        if let d = cands.indices.first(where: { !taken.contains($0) &&
            departmentRE.firstMatch(in: cands[$0].text, range: NSRange(location: 0, length: (cands[$0].text as NSString).length)) != nil &&
            !cands[$0].legal && cands[$0].words.count <= 8 }) {
            s.department = cands[d].text
            taken.insert(d)
        }

        // Company
        for k in cands.indices where !taken.contains(k) {
            let c = cands[k]
            var sc = (c.legal ? 4 : 0) + 1.5 * Double(min(c.orgWords, 2)) + 2 * c.org
            if c.domainMatch { sc += 3.5 }
            sc += c.heightRel
            if c.strongTitle > 0 { sc -= 2.5 }
            if !c.domainMatch { sc -= 1.5 * c.person }
            if c.words.count > 6 { sc -= 2 }
            sc -= 1.5 * c.lowerRatio
            if c.text.hasSuffix(".") && !c.legal { sc -= 1 }
            cands[k].companyScore = sc
        }
        let companyCands = cands.indices.filter { !taken.contains($0) }
        if let best = companyCands.max(by: { cands[$0].companyScore < cands[$1].companyScore }) {
            let c = cands[best]
            if c.companyScore >= 2.5 {
                s.company = c.text
            } else if c.heightRel >= 0.85, c.strongTitle == 0, c.words.count <= 5, c.lowerRatio == 0, c.companyScore >= 0.5 {
                // The largest leftover text is usually the logo/company name.
                s.company = c.text
                s.companyGuessed = true
            }
        }

        if debug {
            var err = FileHandle.standardError
            for c in cands {
                print(String(format: "  name %5.1f  title %5.1f  comp %5.1f  h %.2f  %@", c.nameScore, c.titleScore, c.companyScore,
                             c.heightRel, c.text), to: &err)
            }
        }
    }

    // MARK: Name helpers

    static func splitName(_ raw: String) -> NameParts {
        var p = NameParts()
        let pieces = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var tokens = (pieces.first ?? "").split(separator: " ").map(String.init)
        var creds: [String] = []
        var trailing: [String] = []
        for piece in pieces.dropFirst() where !piece.isEmpty {
            let ws = piece.split(separator: " ").map(String.init)
            if ws.allSatisfy(isCredential) { creds += ws } else if ws.count == 1, Lexicon.nameSuffixes.contains(clean(ws[0])) {
                p.suffix = ws[0]
            } else { trailing.append(piece) }
        }
        while let last = tokens.last, tokens.count > 1, isCredential(last) { creds.insert(last, at: 0); tokens.removeLast() }
        if let last = tokens.last, tokens.count > 2, Lexicon.nameSuffixes.contains(clean(last)) { p.suffix = last; tokens.removeLast() }
        if let first = tokens.first, tokens.count > 1, Lexicon.namePrefixes.contains(clean(first)) { p.prefix = first; tokens.removeFirst() }
        p.core = tokens
        p.credentials = creds.joined(separator: ", ")
        p.trailing = trailing.joined(separator: ", ")
        if tokens.count >= 2 {
            p.first = tokens[0]
            var lastStart = tokens.count - 1
            while lastStart > 1, Lexicon.nameParticles.contains(tokens[lastStart - 1].lowercased()) { lastStart -= 1 }
            p.last = tokens[lastStart...].joined(separator: " ")
            p.middle = tokens[1..<lastStart].joined(separator: " ")
        } else {
            p.first = tokens.first ?? ""
        }
        p.full = ([p.prefix] + tokens + [p.suffix]).filter { !$0.isEmpty }.joined(separator: " ")
        return p
    }

    private static func clean(_ w: String) -> String { w.lowercased().filter { $0.isLetter } }

    private static func isCredential(_ w: String) -> Bool {
        let letters = w.filter { $0.isLetter || $0 == "-" }.replacingOccurrences(of: "-", with: "")
        let key = letters.uppercased()
        guard Lexicon.credentials.contains(key) else { return false }
        return letters == key || Lexicon.mixedCaseCredentials.contains(key)
    }

    private static func isAllCaps(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        return letters.count >= 3 && letters.allSatisfy { $0.isUppercase }
    }

    private static func titleCaseIfCaps(_ s: String) -> String { isAllCaps(s) ? titleCase(s) : s }

    static func titleCase(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { i, w -> String in
            let lw = w.lowercased()
            if i > 0, Lexicon.nameParticles.contains(lw) { return lw }
            if isCredential(String(w)) || Lexicon.nameSuffixes.contains(clean(String(w))) && w.count <= 4 { return String(w) }
            var out = lw.capitalized
            if out.hasPrefix("Mc"), out.count > 2 {
                out = "Mc" + out.dropFirst(2).prefix(1).uppercased() + out.dropFirst(3)
            }
            if out.count > 2, out.dropFirst().first == "'" {
                out = out.prefix(2) + out.dropFirst(2).prefix(1).uppercased() + out.dropFirst(3)
            }
            return out
        }.joined(separator: " ")
    }

    /// Fraction of characters NLTagger labels as a personal name / organization.
    private static func nameTagFractions(_ text: String, whole: String) -> (Double, Double) {
        let tagger = NLTagger(tagSchemes: [.nameType])
        func fractions(_ t: String) -> (Double, Double) {
            tagger.string = t
            var person = 0, org = 0, total = 0
            tagger.enumerateTags(in: t.startIndex..<t.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
                let n = t[range].count
                total += n
                if tag == .personalName { person += n } else if tag == .organizationName { org += n }
                return true
            }
            return total == 0 ? (0, 0) : (Double(person) / Double(total), Double(org) / Double(total))
        }
        let a = fractions(text)
        let b = text == whole ? a : fractions(whole)
        return (max(a.0, b.0), max(a.1, b.1))
    }

    private static func emailNameMatch(_ core: [String], locals: [String]) -> Double {
        let ws = core.map { fold($0) }.filter { !$0.isEmpty }
        guard ws.count >= 2, let first = ws.first, let last = ws.last else { return 0 }
        var best = 0.0
        for l in locals {
            if last.count >= 3, l.contains(last), l.contains(first) || l.hasPrefix(String(first.prefix(1))) { best = max(best, 3) }
            else if last.count >= 3, l.contains(last) { best = max(best, 2.5) }
            else if first.count >= 3, l.contains(first) { best = max(best, 2) }
            else if l.count == ws.count, l == String(ws.compactMap(\.first)) { best = max(best, 1.5) }
        }
        return best
    }

    // MARK: Domain helpers

    private static func host(_ url: String) -> String {
        let bare = url.lowercased().replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        return String(bare.split(separator: "/").first ?? "")
    }

    private static func domainStem(_ host: String) -> String? {
        var labels = host.split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        guard labels.count >= 2 else { return nil }
        labels.removeLast()
        if labels.count >= 2, ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"].contains(labels.last!) { labels.removeLast() }
        guard let stem = labels.last else { return nil }
        let f = fold(stem)
        return f.count >= 2 ? f : nil
    }

    private static func matchesDomain(_ text: String, stems: [String]) -> Bool {
        let words = tokens(text).filter { !Lexicon.legalSuffixes.contains($0) }
        let compact = fold(words.joined())
        let initials = String(words.filter { !["and", "of", "the", "&"].contains($0) }.compactMap(\.first))
        for stem in stems {
            if compact == stem { return true }
            if stem.count >= 4, compact.contains(stem) { return true }
            if compact.count >= 4, stem.contains(compact) { return true }
            if initials.count >= 2, initials == stem { return true }
        }
        return false
    }

    /// Lowercase ASCII-ish letters/digits only, diacritics removed.
    static func fold(_ s: String, keepSpaces: Bool = false) -> String {
        let f = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        if keepSpaces {
            return f.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return String(f.filter { $0.isLetter || $0.isNumber })
    }

    private static func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Card text is short and full of names, so bias toward common business languages and
    /// leave the field blank rather than guess.
    private static func detectLanguage(_ text: String, emails: [String]) -> String? {
        var t = text
        for e in emails { t = t.replacingOccurrences(of: e, with: " ", options: .caseInsensitive) }
        let r = NLLanguageRecognizer()
        r.languageHints = [.english: 0.5, .spanish: 0.08, .french: 0.08, .german: 0.08, .portuguese: 0.04,
                           .italian: 0.04, .dutch: 0.03, .simplifiedChinese: 0.03, .traditionalChinese: 0.02,
                           .japanese: 0.03, .korean: 0.02]
        r.processString(t)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.7 else { return nil }
        return lang.rawValue
    }

    // MARK: Merge

    private static func merge(_ sides: [Side], emails: [String], stems: [String], allText: String) -> ParseResult {
        var r = ParseResult()
        var f: [String: String] = [:]
        // The side with the most contact detail wins conflicts; the other side fills gaps.
        let order = sides.indices.sorted { sides[$0].richness != sides[$1].richness ? sides[$0].richness > sides[$1].richness : $0 < $1 }.map { sides[$0] }

        let nameSide = order.first { $0.name != nil }
        if let n = nameSide?.name {
            f["full_name"] = n.full; f["prefix"] = n.prefix; f["first_name"] = n.first; f["middle_name"] = n.middle
            f["last_name"] = n.last; f["suffix"] = n.suffix; f["credentials"] = n.credentials
        }
        f["job_title"] = (nameSide?.title).flatMap { $0 } ?? order.compactMap(\.title).first
        f["department"] = order.compactMap(\.department).first
        let companySide = order.first { $0.company != nil && !$0.companyGuessed } ?? order.first { $0.company != nil }
        f["company"] = companySide?.company
        if let a = order.first(where: { !$0.address.isEmpty })?.address {
            for (k, v) in a { f[k] = v }
        }

        f["email"] = emails.first
        if emails.count > 1 { f["email_alt"] = emails.dropFirst().joined(separator: "; ") }
        let sites = unique(order.flatMap(\.websites))
        f["website"] = sites.first
        f["linkedin"] = unique(order.flatMap(\.linkedin)).first
        f["twitter"] = unique(order.flatMap(\.twitter)).first
        let social = unique(order.flatMap(\.otherSocial) + sites.dropFirst()
                            + order.flatMap(\.linkedin).dropFirst() + order.flatMap(\.twitter).dropFirst())
        if !social.isEmpty { f["other_social"] = social.joined(separator: "; ") }

        // Phones: dedupe by digits, then assign by label.
        var seen = Set<String>()
        let phones = order.flatMap(\.phones).filter { seen.insert(String($0.digits.suffix(9))).inserted }
        var rest = phones
        func take(_ kind: PhoneKind) -> Phone? {
            guard let i = rest.firstIndex(where: { $0.kind == kind }) else { return nil }
            return rest.remove(at: i)
        }
        if let w = take(.work) ?? take(.unlabeled) { f["phone_work"] = w.number; f["phone_ext"] = w.ext }
        if let m = take(.mobile) { f["phone_mobile"] = m.number }
        if let x = take(.fax) { f["phone_fax"] = x.number }
        if !rest.isEmpty { f["phone_other"] = rest.map { $0.number + ($0.ext.map { " x\($0)" } ?? "") }.joined(separator: "; ") }

        var companyInferred = false
        if f["company"] == nil, let stem = stems.first {
            f["company"] = stem.prefix(1).uppercased() + stem.dropFirst()
            companyInferred = true
        }
        f["language"] = detectLanguage(allText, emails: emails)

        // Confidence
        var c = 1.0
        let charCount = sides.reduce(0) { $0 + $1.charCount }
        let conf = charCount == 0 ? 0 : sides.reduce(0.0) { $0 + $1.meanConfidence * Double($1.charCount) } / Double(charCount)
        if charCount < 15 { c -= 0.6; r.reasons.append("little or no text found") }
        if f["full_name"] == nil { c -= 0.35; r.reasons.append("no name found") }
        else if (nameSide?.nameScore ?? 0) < 3 { c -= 0.15; r.reasons.append("name uncertain") }
        if f["company"] == nil { c -= 0.15; r.reasons.append("no company found") }
        else if companyInferred { c -= 0.15; r.reasons.append("company inferred from domain") }
        else if companySide?.companyGuessed == true { c -= 0.1; r.reasons.append("company guessed from largest text") }
        if f["email"] == nil && phones.isEmpty { c -= 0.2; r.reasons.append("no email or phone") }
        if conf < 0.6 { c -= 0.2; r.reasons.append("low OCR confidence") }
        let letters = allText.unicodeScalars.filter(CharacterSet.letters.contains)
        let nonLatin = letters.filter { $0.value >= 0x0250 }.count
        if !letters.isEmpty, Double(nonLatin) / Double(letters.count) > 0.3 { c -= 0.25; r.reasons.append("non-Latin script") }

        r.fields = f.filter { !$0.value.isEmpty }
        r.confidence = max(0, min(1, c))
        return r
    }
}
