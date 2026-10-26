import CoreGraphics
import CryptoKit
import Foundation

/// One physical side of a card: an image file, or one page of a PDF.
enum CardSide {
    case image(URL)
    case pdfPage(URL, Int)  // 1-based page number

    var url: URL {
        switch self {
        case .image(let u), .pdfPage(let u, _): return u
        }
    }
}

/// A business card to process: a stable key plus its sides, front first.
struct CardInput {
    let key: String
    let sides: [CardSide]
    let relativeFiles: [String]

    var files: [URL] {
        var seen = Set<URL>()
        return sides.map(\.url).filter { seen.insert($0).inserted }
    }

    /// SHA-256 over the source bytes and the key (which carries any PDF page range).
    func contentHash() throws -> String {
        var h = SHA256()
        for f in files { h.update(data: try Data(contentsOf: f, options: .mappedIfSafe)) }
        h.update(data: Data(key.utf8))
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct ScanOptions {
    var pairPatterns: [String] = InputScanner.defaultPairPatterns
    var pdfPagesPerCard = 2
}

enum InputScanner {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"]

    /// Each pattern captures (base)(side). Files whose bases match and whose sides differ become one card.
    static let defaultPairPatterns = [
        #"(?i)^(.+?)[ _.\-]*(front|back|recto|verso)$"#,
        #"(?i)^(.+?)[ _.\-](a|b|f)$"#,
    ]

    private static let sideRank: [String: Int] = [
        "front": 0, "recto": 0, "a": 0, "f": 0, "1": 0,
        "back": 1, "verso": 1, "b": 1, "2": 1,
    ]

    static func scan(_ root: URL, _ opts: ScanOptions) throws -> [CardInput] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let patterns = try opts.pairPatterns.map { try NSRegularExpression(pattern: $0) }
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { throw CLIError("cannot read directory \(root.path)") }

        var images: [URL] = []
        var pdfs: [URL] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" { pdfs.append(url) } else if imageExtensions.contains(ext) { images.append(url) }
        }

        func rel(_ url: URL) -> String {
            let p = url.standardizedFileURL.resolvingSymlinksInPath().path
            return p.hasPrefix(root.path + "/") ? String(p.dropFirst(root.path.count + 1)) : p
        }

        var cards: [CardInput] = []

        // PDFs: every `pdfPagesPerCard` pages form one card.
        for pdf in pdfs {
            guard let doc = CGPDFDocument(pdf as CFURL), doc.numberOfPages > 0 else {
                cards.append(CardInput(key: rel(pdf), sides: [.pdfPage(pdf, 1)], relativeFiles: [rel(pdf)]))
                continue
            }
            let n = doc.numberOfPages
            let per = max(1, opts.pdfPagesPerCard)
            for start in stride(from: 1, through: n, by: per) {
                let end = min(n, start + per - 1)
                let key = n <= per ? rel(pdf) : "\(rel(pdf))#p\(start)-\(end)"
                cards.append(CardInput(key: key, sides: (start...end).map { .pdfPage(pdf, $0) }, relativeFiles: [rel(pdf)]))
            }
        }

        // Images: group front/back pairs by filename pattern.
        var groups: [String: [(side: String, url: URL)]] = [:]
        var groupBase: [String: String] = [:]
        var singles: [URL] = []
        for img in images {
            let stem = img.deletingPathExtension().lastPathComponent
            let ns = stem as NSString
            var matched = false
            for re in patterns {
                guard let m = re.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)),
                      m.numberOfRanges >= 3 else { continue }
                let base = ns.substring(with: m.range(at: 1))
                let side = ns.substring(with: m.range(at: 2)).lowercased()
                let dir = rel(img.deletingLastPathComponent())
                let gkey = dir + "/" + base.lowercased()
                groups[gkey, default: []].append((side, img))
                groupBase[gkey] = (dir == root.path ? "" : dir + "/") + base
                matched = true
                break
            }
            if !matched { singles.append(img) }
        }
        for (gkey, members) in groups {
            let sides = Set(members.map(\.side))
            guard members.count >= 2, sides.count == members.count else {
                singles.append(contentsOf: members.map(\.url))
                continue
            }
            let ordered = members.sorted {
                let a = sideRank[$0.side] ?? Int($0.side) ?? 99, b = sideRank[$1.side] ?? Int($1.side) ?? 99
                return a != b ? a < b : $0.side < $1.side
            }
            cards.append(CardInput(key: groupBase[gkey]!, sides: ordered.map { .image($0.url) },
                                   relativeFiles: ordered.map { rel($0.url) }))
        }
        for img in singles {
            cards.append(CardInput(key: rel(img), sides: [.image(img)], relativeFiles: [rel(img)]))
        }

        return cards.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
