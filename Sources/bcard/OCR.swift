import CoreGraphics
import Foundation
import ImageIO
import Vision

/// One recognized line of text. Coordinates are normalized (0...1) with the origin at the top-left.
struct OCRLine {
    var text: String
    var confidence: Double
    var x0: Double, x1: Double, top: Double, bottom: Double

    var height: Double { bottom - top }
    var midY: Double { (top + bottom) / 2 }
}

struct OCROptions {
    var fast = false
    var languages: [String] = []
    /// Longest edge, in pixels, that images and PDF pages are scaled to before OCR.
    var maxPixels = 2400
}

enum OCR {
    // MARK: Loading

    static func image(for side: CardSide, maxPixels: Int) throws -> CGImage {
        switch side {
        case .image(let url): return try loadImage(url, maxPixels: maxPixels)
        case .pdfPage(let url, let page): return try renderPDFPage(url, page: page, maxPixels: maxPixels)
        }
    }

    /// Decodes an image, applying its EXIF orientation and downscaling large photos.
    static func loadImage(_ url: URL, maxPixels: Int) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw CLIError("cannot open image \(url.lastPathComponent)")
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw CLIError("cannot decode image \(url.lastPathComponent)")
        }
        return img
    }

    /// Rasterizes one PDF page so its longest edge is about `maxPixels`, honoring the page's /Rotate.
    static func renderPDFPage(_ url: URL, page number: Int, maxPixels: Int) throws -> CGImage {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: number) else {
            throw CLIError("cannot open PDF page \(number) of \(url.lastPathComponent)")
        }
        let box = page.getBoxRect(.cropBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        let (w, h) = rotation % 180 == 0 ? (box.width, box.height) : (box.height, box.width)
        let scale = min(8, max(1, Double(maxPixels) / Double(max(w, h))))
        let pw = Int((w * scale).rounded()), ph = Int((h * scale).rounded())
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CLIError("cannot render PDF page \(number) of \(url.lastPathComponent)") }

        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        switch rotation {
        case 90: ctx.translateBy(x: 0, y: box.width); ctx.rotate(by: -.pi / 2)
        case 180: ctx.translateBy(x: box.width, y: box.height); ctx.rotate(by: .pi)
        case 270: ctx.translateBy(x: box.height, y: 0); ctx.rotate(by: .pi / 2)
        default: break
        }
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        guard let img = ctx.makeImage() else { throw CLIError("cannot render PDF page \(number)") }
        return img
    }

    // MARK: Recognition

    /// Recognizes text in reading order. A sideways or upside-down card is re-read in its upright
    /// orientation so that line geometry (top, height, adjacency) is meaningful to the parser.
    static func recognize(_ image: CGImage, _ opts: OCROptions) throws -> [OCRLine] {
        var (best, rotation) = try run(image, .up, opts)
        if opts.fast {
            // The fast recognizer cannot read rotated text at all, so fall back to trying each orientation.
            if quality(best) < 40 {
                for o in [CGImagePropertyOrientation.right, .left, .down] {
                    let alt = try run(image, o, opts).lines
                    if quality(alt) > quality(best) * 1.3 { best = alt }
                }
            }
        } else if rotation != 0 {
            // The accurate recognizer reads rotated text but reports rotated boxes; re-run upright.
            let guesses: [CGImagePropertyOrientation] = rotation == 180 ? [.down] : rotation == 90 ? [.right, .left] : [.left, .right]
            for o in guesses {
                let alt = try run(image, o, opts)
                if alt.rotation == 0 { best = alt.lines; break }
            }
        }
        return readingOrder(best)
    }

    /// Returns the lines plus the dominant text direction in degrees (0, 90, 180, 270).
    private static func run(_ image: CGImage, _ orientation: CGImagePropertyOrientation, _ opts: OCROptions) throws -> (lines: [OCRLine], rotation: Int) {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = opts.fast ? .fast : .accurate
        req.usesLanguageCorrection = true
        if opts.languages.isEmpty {
            req.automaticallyDetectsLanguage = true
        } else {
            req.recognitionLanguages = opts.languages
        }
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([req])
        let sideways = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let (w, h) = sideways ? (Double(image.height), Double(image.width)) : (Double(image.width), Double(image.height))
        var votes = [0: 0, 90: 0, 180: 0, 270: 0]
        let lines: [OCRLine] = (req.results ?? []).compactMap { obs in
            guard let cand = obs.topCandidates(1).first else { return nil }
            let text = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let quad = try? cand.boundingBox(for: cand.string.startIndex..<cand.string.endIndex) {
                let dx = (quad.topRight.x - quad.topLeft.x) * w, dy = (quad.topRight.y - quad.topLeft.y) * h
                let deg = (atan2(dy, dx) * 180 / .pi + 405).truncatingRemainder(dividingBy: 360)
                votes[Int(deg / 90) * 90 % 360, default: 0] += text.count
            }
            let b = obs.boundingBox
            return OCRLine(text: text, confidence: Double(cand.confidence),
                           x0: b.minX, x1: b.maxX, top: 1 - b.maxY, bottom: 1 - b.minY)
        }
        let rotation = votes.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? 0
        return (lines, votes[rotation, default: 0] > votes[0, default: 0] ? rotation : 0)
    }

    /// Confidence-weighted count of alphanumerics; a sideways card scores near zero.
    private static func quality(_ lines: [OCRLine]) -> Double {
        lines.reduce(0) { $0 + $1.confidence * Double($1.text.unicodeScalars.filter(CharacterSet.alphanumerics.contains).count) }
    }

    /// Top-to-bottom rows, left-to-right within a row.
    private static func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        var rows: [[OCRLine]] = []
        for l in lines.sorted(by: { $0.top < $1.top }) {
            if let ref = rows.last?.first, abs(l.midY - ref.midY) < min(l.height, ref.height) * 0.5 {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        return rows.flatMap { $0.sorted { $0.x0 < $1.x0 } }
    }
}
