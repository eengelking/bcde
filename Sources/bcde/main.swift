import Foundation

let usage = """
    bcde — extract contact details from business-card scans with on-device OCR (Apple Vision).

    USAGE
      bcde scan <input-dir> [options]    OCR every card, save to SQLite, export CSV + XLSX
      bcde export [options]              Re-export CSV and/or XLSX from an existing database
      bcde ocr <file> [<back-file>]      Show OCR lines, candidate scores and parsed fields for one card

    Inputs: JPEG, PNG, HEIC, TIFF and PDF. A PDF is one card (page 1 = front, page 2 = back).
    Images named like card1_front/card1_back or card1_a/card1_b are paired into one card.

    OPTIONS
      --db <path>               SQLite database (default: ./cards.db)
      --out <dir>               Directory for cards.csv / cards.xlsx (default: current directory)
      --jobs <n>                Worker processes (default: CPU cores - 2, max 8)
      --force                   Re-process cards already in the database
      --limit <n>               Only process the first n cards (for trial runs)
      --fast                    Faster, less accurate OCR
      --languages <list>        OCR languages, e.g. en-US,fr-FR (default: automatic)
      --pair-regex <regex>      Filename-stem regex with groups (base)(side) for front/back pairs;
                                may be repeated. Default: (base)_(front|back) and (base)_(a|b|f)
      --pdf-pages-per-card <n>  Pages per card in multi-page PDFs (default: 2)
      --format <csv|xlsx|both>  Which export files to write (default: both)
      --no-export               Don't write CSV/XLSX after scanning
    """

struct Options {
    var command = ""
    var positional: [String] = []
    var db = "cards.db"
    var out = "."
    /// Worker processes; throughput levels off around 6–8 on Apple silicon.
    var jobs = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    var force = false
    var limit: Int?
    var export = true
    var formats: Set<String> = ["csv", "xlsx"]
    var ocr = OCROptions()
    var scan = ScanOptions()
}

func parseArgs(_ args: [String]) throws -> Options {
    var o = Options()
    var customPatterns: [String] = []
    var it = args.makeIterator()
    func value(_ flag: String) throws -> String {
        guard let v = it.next() else { throw CLIError("\(flag) needs a value") }
        return v
    }
    func int(_ flag: String) throws -> Int {
        guard let n = Int(try value(flag)), n > 0 else { throw CLIError("\(flag) needs a positive number") }
        return n
    }
    while let a = it.next() {
        switch a {
        case "--db": o.db = try value(a)
        case "--out": o.out = try value(a)
        case "--jobs": o.jobs = try int(a)
        case "--force": o.force = true
        case "--limit": o.limit = try int(a)
        case "--fast": o.ocr.fast = true
        case "--languages": o.ocr.languages = try value(a).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case "--pair-regex": customPatterns.append(try value(a))
        case "--pdf-pages-per-card": o.scan.pdfPagesPerCard = try int(a)
        case "--no-export": o.export = false
        case "--format":
            let v = try value(a).lowercased()
            let f = v == "both" ? ["csv", "xlsx"] : v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !f.isEmpty, f.allSatisfy({ $0 == "csv" || $0 == "xlsx" }) else { throw CLIError("--format must be csv, xlsx or both") }
            o.formats = Set(f)
        case "-h", "--help", "help": o.command = "help"
        default:
            if a.hasPrefix("--") { throw CLIError("unknown option \(a)") }
            if o.command.isEmpty { o.command = a } else { o.positional.append(a) }
        }
    }
    if !customPatterns.isEmpty { o.scan.pairPatterns = customPatterns }
    return o
}

var stderr = FileHandle.standardError
extension FileHandle: @retroactive TextOutputStream {
    public func write(_ string: String) { write(Data(string.utf8)) }
}

// MARK: Pipeline

func process(_ card: CardInput, hash: String, _ ocr: OCROptions, debug: Bool = false) -> CardRecord {
    var rec = CardRecord()
    rec["card_key"] = card.key
    rec["source_files"] = card.relativeFiles.joined(separator: "; ")
    rec["sides"] = String(card.sides.count)
    rec["content_hash"] = hash
    let start = DispatchTime.now().uptimeNanoseconds
    do {
        var pages: [[OCRLine]] = []
        for side in card.sides {
            let image = try OCR.image(for: side, maxPixels: ocr.maxPixels)
            pages.append(try OCR.recognize(image, ocr))
        }
        if debug {
            for (i, page) in pages.enumerated() {
                print("── side \(i + 1) ──", to: &stderr)
                for l in page {
                    print(String(format: "  [y %.2f h %.3f c %.2f] %@", l.top, l.height, l.confidence, l.text), to: &stderr)
                }
            }
            print("── candidates ──", to: &stderr)
        }
        let result = Parser.parse(pages, debug: debug)
        for (k, v) in result.fields { rec[k] = v }
        rec["confidence"] = String(format: "%.2f", result.confidence)
        rec["needs_review"] = result.confidence < 0.7 ? "1" : "0"
        rec["review_reasons"] = result.reasons.joined(separator: "; ")
        rec["front_text"] = pages.first?.map(\.text).joined(separator: "\n")
        rec["back_text"] = pages.dropFirst().map { $0.map(\.text).joined(separator: "\n") }.joined(separator: "\n---\n")
    } catch {
        rec["error"] = "\(error)"
        rec["confidence"] = "0"
        rec["needs_review"] = "1"
        rec["review_reasons"] = "processing error"
    }
    rec["ocr_ms"] = String((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    rec["processed_at"] = ISO8601DateFormatter().string(from: Date())
    return rec
}

func export(_ db: Database, to dir: String, formats: Set<String>) throws {
    let outDir = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let rows = db.allRows()
    var written: [String] = []
    if formats.contains("csv") {
        let csv = outDir.appendingPathComponent("cards.csv")
        try Exporter.writeCSV(header: Schema.columns, rows: rows, to: csv)
        written.append(csv.path)
    }
    if formats.contains("xlsx") {
        let xlsx = outDir.appendingPathComponent("cards.xlsx")
        try Exporter.writeXLSX(header: Schema.columns, rows: rows, to: xlsx)
        written.append(xlsx.path)
    }
    print("Exported \(rows.count) cards → \(written.joined(separator: ", "))", to: &stderr)
}

/// Vision serializes recognition within a process, so throughput comes from running several
/// worker processes (`bcde __worker`). Each worker reads one JSON job per line on stdin and
/// writes one JSON record per line on stdout; only this parent process touches the database.
func runScan(_ o: Options) throws {
    guard let dir = o.positional.first else { throw CLIError("scan needs an input directory") }
    var cards = try InputScanner.scan(URL(fileURLWithPath: dir, isDirectory: true), o.scan)
    if let limit = o.limit { cards = Array(cards.prefix(limit)) }
    let db = try Database(path: o.db)
    let done = o.force ? [:] : db.processedHashes()

    var hashes = [String](repeating: "", count: cards.count)
    hashes.withUnsafeMutableBufferPointer { buf in
        DispatchQueue.concurrentPerform(iterations: cards.count) { i in buf[i] = (try? cards[i].contentHash()) ?? "" }
    }
    let jobs = cards.indices.filter { hashes[$0].isEmpty || done[cards[$0].key] != hashes[$0] }
        .map { Job(card: cards[$0], hash: hashes[$0]) }
    let skipped = cards.count - jobs.count
    let workers = max(1, min(o.jobs, jobs.count))
    let sideCount = jobs.reduce(0) { $0 + $1.sides.count }
    print("Found \(cards.count) cards; \(skipped) already done, \(jobs.count) to process (\(sideCount) sides) with \(workers) workers.",
          to: &stderr)

    let lock = NSLock()
    var next = 0, finished = 0, failed = 0, flagged = 0
    let started = Date()
    var lastPrint = Date.distantPast
    func report(_ final: Bool = false) {
        let rate = Double(finished) / max(Date().timeIntervalSince(started), 0.001)
        stderr.write(String(format: "\r[%d/%d] %.1f cards/s  needs review %d  errors %d   ", finished, jobs.count, rate, flagged, failed)
                     + (final ? "\n" : ""))
    }
    func take() -> Job? {
        lock.lock(); defer { lock.unlock() }
        guard next < jobs.count else { return nil }
        next += 1
        return jobs[next - 1]
    }
    func record(_ rec: CardRecord) {
        do { try db.save(rec) } catch { print("\nDB error for \(rec["card_key"] ?? "?"): \(error)", to: &stderr) }
        lock.lock(); defer { lock.unlock() }
        finished += 1
        if let e = rec["error"] { failed += 1; print("\n\(rec["card_key"] ?? "?"): \(e)", to: &stderr) }
        if rec["needs_review"] == "1" { flagged += 1 }
        if Date().timeIntervalSince(lastPrint) > 0.25 { report(); lastPrint = Date() }
    }

    // The first run of a new binary compiles Vision's text model (~25 s). If every worker does that at
    // once they slow each other down several-fold, so one worker warms the cache before the rest start.
    let warmedUp = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    for index in 0..<workers {
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            var worker: WorkerProcess?
            var waiting = index == 0
            defer { if waiting { for _ in 1..<workers { warmedUp.signal() } } }
            if index > 0 { warmedUp.wait() }
            while let job = take() {
                defer {
                    if waiting { waiting = false; for _ in 1..<workers { warmedUp.signal() } }
                }
                do {
                    if worker == nil { worker = try WorkerProcess(ocr: o.ocr) }
                    record(try worker!.run(job))
                } catch {
                    // The worker died (e.g. a decoder crash on a corrupt file): log the card and start a fresh one.
                    worker?.terminate()
                    worker = nil
                    record(job.failure("worker failed: \(error)"))
                }
            }
            worker?.finish()
        }
    }
    group.wait()
    report(true)
    print(String(format: "Done in %.1fs.", Date().timeIntervalSince(started)), to: &stderr)
    if o.export { try export(db, to: o.out, formats: o.formats) }
}

/// One unit of work sent to a worker process.
struct Job: Codable {
    struct Side: Codable { let path: String; let page: Int? }
    let key: String
    let sides: [Side]
    let files: [String]
    let hash: String

    init(card: CardInput, hash: String) {
        key = card.key
        sides = card.sides.map {
            switch $0 {
            case .image(let u): return Side(path: u.path, page: nil)
            case .pdfPage(let u, let p): return Side(path: u.path, page: p)
            }
        }
        files = card.relativeFiles
        self.hash = hash
    }

    var card: CardInput {
        CardInput(key: key, sides: sides.map { s in
            let u = URL(fileURLWithPath: s.path)
            return s.page.map { .pdfPage(u, $0) } ?? .image(u)
        }, relativeFiles: files)
    }

    func failure(_ message: String) -> CardRecord {
        var r = CardRecord()
        r["card_key"] = key; r["source_files"] = files.joined(separator: "; "); r["sides"] = String(sides.count)
        r["content_hash"] = hash; r["error"] = message; r["confidence"] = "0"; r["needs_review"] = "1"
        r["review_reasons"] = "processing error"; r["processed_at"] = ISO8601DateFormatter().string(from: Date())
        return r
    }
}

/// A `bcde __worker` child process, driven one job at a time.
final class WorkerProcess {
    private let proc = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()

    init(ocr: OCROptions) throws {
        proc.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var args = ["__worker"]
        if ocr.fast { args.append("--fast") }
        if !ocr.languages.isEmpty { args += ["--languages", ocr.languages.joined(separator: ",")] }
        proc.arguments = args
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.standardError
        try proc.run()
    }

    func run(_ job: Job) throws -> CardRecord {
        var line = try JSONEncoder().encode(job)
        line.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: line)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let row = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                return CardRecord(values: try JSONDecoder().decode([String: String].self, from: row))
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw CLIError("worker exited (status \(proc.isRunning ? -1 : proc.terminationStatus))") }
            buffer.append(chunk)
        }
    }

    func finish() {
        try? input.fileHandleForWriting.close()
        proc.waitUntilExit()
    }

    func terminate() {
        if proc.isRunning { proc.terminate() }
    }
}

/// Worker side of the protocol: read jobs from stdin, write records to stdout.
func runWorker(_ o: Options) {
    signal(SIGPIPE, SIG_IGN)
    let out = FileHandle.standardOutput
    while let line = readLine(strippingNewline: true) {
        guard let job = try? JSONDecoder().decode(Job.self, from: Data(line.utf8)) else { continue }
        let rec = autoreleasepool { process(job.card, hash: job.hash, o.ocr) }
        guard var data = try? JSONEncoder().encode(rec.values) else { continue }
        data.append(0x0A)
        out.write(data)
    }
}

func runOCR(_ o: Options) throws {
    guard !o.positional.isEmpty else { throw CLIError("ocr needs a file") }
    let urls = o.positional.map { URL(fileURLWithPath: $0) }
    var sides: [CardSide] = []
    for u in urls {
        if u.pathExtension.lowercased() == "pdf", let doc = CGPDFDocument(u as CFURL) {
            sides += (1...max(1, min(doc.numberOfPages, o.scan.pdfPagesPerCard))).map { .pdfPage(u, $0) }
        } else {
            sides.append(.image(u))
        }
    }
    let card = CardInput(key: urls[0].lastPathComponent, sides: sides, relativeFiles: urls.map(\.lastPathComponent))
    let rec = process(card, hash: "", o.ocr, debug: true)
    print("── fields ──")
    for col in Schema.columns where !["front_text", "back_text", "content_hash"].contains(col) {
        if let v = rec[col], !v.isEmpty { print("  \(col.padding(toLength: 15, withPad: " ", startingAt: 0)) \(v)") }
    }
}

import CoreGraphics

do {
    let o = try parseArgs(Array(CommandLine.arguments.dropFirst()))
    switch o.command {
    case "scan": try runScan(o)
    case "export":
        guard FileManager.default.fileExists(atPath: o.db) else { throw CLIError("no database at \(o.db); run a scan first") }
        try export(try Database(path: o.db), to: o.out, formats: o.formats)
    case "ocr": try runOCR(o)
    case "__worker": runWorker(o)
    default: print(usage)
    }
} catch {
    print("error: \(error)", to: &stderr)
    exit(1)
}
