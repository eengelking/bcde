import Foundation

/// Writes database rows to CSV and to a minimal, dependency-free XLSX.
enum Exporter {
    static func writeCSV(header: [String], rows: [[String]], to url: URL) throws {
        func field(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var out = "\u{FEFF}"  // BOM so Excel opens UTF-8 correctly
        out += header.map(field).joined(separator: ",") + "\r\n"
        for r in rows { out += r.map(field).joined(separator: ",") + "\r\n" }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Header row bold and frozen, autofilter on, rows flagged `needs_review` shaded.
    static func writeXLSX(header: [String], rows: [[String]], to url: URL) throws {
        let reviewCol = header.firstIndex(of: "needs_review")
        let numeric: Set<Int> = Set(header.indices.filter {
            Schema.integerColumns.contains(header[$0]) || Schema.realColumns.contains(header[$0])
        })
        let lastCol = columnName(header.count - 1)
        let lastRow = rows.count + 1

        var sheet = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>\
            </sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/><cols>
            """
        for (i, h) in header.enumerated() {
            let width = h.hasSuffix("_text") ? 50 : (["address_full", "source_files", "review_reasons", "other_social", "card_key"].contains(h) ? 36 : 18)
            sheet += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
        }
        sheet += "</cols><sheetData>"
        sheet += row(1, header, style: 1, numeric: [])
        for (i, r) in rows.enumerated() {
            let flagged = reviewCol.map { r[$0] == "1" } ?? false
            sheet += row(i + 2, r, style: flagged ? 2 : 0, numeric: numeric)
        }
        sheet += "</sheetData><autoFilter ref=\"A1:\(lastCol)\(lastRow)\"/></worksheet>"

        let workbook = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets><sheet name="Cards" sheetId="1" r:id="rId1"/></sheets>\
            <definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">Cards!$A$1:$\(lastCol)$\(lastRow)</definedName></definedNames>\
            </workbook>
            """
        let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
            <fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>\
            <fill><patternFill patternType="solid"><fgColor rgb="FFFCE4D6"/><bgColor indexed="64"/></patternFill></fill>\
            <fill><patternFill patternType="solid"><fgColor rgb="FFD9E1F2"/><bgColor indexed="64"/></patternFill></fill></fills>\
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
            <cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
            <xf numFmtId="0" fontId="1" fillId="3" borderId="0" xfId="0" applyFont="1" applyFill="1"/>\
            <xf numFmtId="0" fontId="0" fillId="2" borderId="0" xfId="0" applyFill="1"/></cellXfs>\
            <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
            """
        let contentTypes = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
            </Types>
            """
        let rootRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """
        let workbookRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
            </Relationships>
            """

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", rootRels)
        zip.add("xl/workbook.xml", workbook)
        zip.add("xl/_rels/workbook.xml.rels", workbookRels)
        zip.add("xl/styles.xml", styles)
        zip.add("xl/worksheets/sheet1.xml", sheet)
        try zip.finish().write(to: url, options: .atomic)
    }

    private static func row(_ n: Int, _ values: [String], style: Int, numeric: Set<Int>) -> String {
        var out = "<row r=\"\(n)\">"
        let s = style == 0 ? "" : " s=\"\(style)\""
        for (i, v) in values.enumerated() {
            let ref = "\(columnName(i))\(n)"
            if v.isEmpty {
                if style != 0 { out += "<c r=\"\(ref)\"\(s)/>" }
            } else if numeric.contains(i), Double(v) != nil {
                out += "<c r=\"\(ref)\"\(s)><v>\(v)</v></c>"
            } else {
                out += "<c r=\"\(ref)\"\(s) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(v))</t></is></c>"
            }
        }
        return out + "</row>"
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(65 + r)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    private static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(u)
            default:
                // Drop characters XML 1.0 forbids (other control chars, U+FFFE/FFFF).
                if u.value < 0x20 || u.value == 0xFFFE || u.value == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }
}

/// Minimal ZIP writer (deflate via Foundation) — enough for an XLSX package.
struct ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var count: UInt16 = 0

    mutating func add(_ name: String, _ text: String) {
        let raw = Data(text.utf8)
        let deflated = (try? (raw as NSData).compressed(using: .zlib) as Data) ?? raw
        let method: UInt16 = deflated.count < raw.count ? 8 : 0
        let stored = method == 8 ? deflated : raw
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(raw)
        let offset = UInt32(body.count)

        body.le(UInt32(0x0403_4b50)); body.le(UInt16(20)); body.le(UInt16(0x0800)); body.le(method)
        body.le(UInt16(0)); body.le(UInt16(0x0021))  // time, date = 1980-01-01
        body.le(crc); body.le(UInt32(stored.count)); body.le(UInt32(raw.count))
        body.le(UInt16(nameData.count)); body.le(UInt16(0))
        body.append(nameData); body.append(stored)

        directory.le(UInt32(0x0201_4b50)); directory.le(UInt16(20)); directory.le(UInt16(20))
        directory.le(UInt16(0x0800)); directory.le(method); directory.le(UInt16(0)); directory.le(UInt16(0x0021))
        directory.le(crc); directory.le(UInt32(stored.count)); directory.le(UInt32(raw.count))
        directory.le(UInt16(nameData.count)); directory.le(UInt16(0)); directory.le(UInt16(0))
        directory.le(UInt16(0)); directory.le(UInt16(0)); directory.le(UInt32(0)); directory.le(offset)
        directory.append(nameData)
        count += 1
    }

    func finish() -> Data {
        var out = body
        out.append(directory)
        out.le(UInt32(0x0605_4b50)); out.le(UInt16(0)); out.le(UInt16(0))
        out.le(count); out.le(count); out.le(UInt32(directory.count)); out.le(UInt32(body.count)); out.le(UInt16(0))
        return out
    }
}

private enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
