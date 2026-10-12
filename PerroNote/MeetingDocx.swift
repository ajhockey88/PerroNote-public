import Foundation

/// Builds a Word (.docx) version of a meeting's notes with no outside library: a .docx is a zip
/// of a few XML files, and the zip here stores them uncompressed.
enum MeetingDocx {
    static let mimeType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    static func fileName(for meeting: Meeting) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var name = meeting.title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return (name.isEmpty ? "Meeting notes" : name) + ".docx"
    }

    static func data(for meeting: Meeting, notes: MeetingNotes) -> Data {
        let dateLine = "\(meeting.date.formatted(date: .complete, time: .shortened))  |  \(formatDuration(meeting.duration))"

        var body = para("Title", meeting.title) + para("Subtitle", dateLine)
        body += para("Heading1", "Summary") + "<w:p>\(run(notes.summary))</w:p>"
        body += section("Attendees", notes.attendees)
        if let topics = notes.topics, !topics.isEmpty {
            body += para("Heading1", "Discussion")
            for t in topics {
                body += "<w:p><w:pPr><w:keepNext/><w:spacing w:before=\"160\" w:after=\"60\"/></w:pPr>\(run(t.title, "<w:b/>"))</w:p>"
                for (i, p) in t.points.enumerated() {
                    body += bullet(p)
                    body += t.subPoints(at: i).map { bullet($0, level: 1) }.joined()
                }
            }
        } else {
            body += section("Discussion", notes.discussion)
        }
        body += section("Decisions", notes.decisions)
        body += section("Risks and Blockers", notes.riskList)

        if !notes.actionItems.isEmpty {
            body += para("Heading1", "Action Items")
            let widths = [560, 5600, 1600, 1600]   // 9360 twips = the 6.5 inch text width
            func border(_ name: String) -> String {
                "<w:\(name) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"D1D1D1\"/>"
            }
            body += "<w:tbl><w:tblPr><w:tblW w:w=\"9360\" w:type=\"dxa\"/><w:tblBorders>"
            body += ["top", "left", "bottom", "right", "insideH", "insideV"].map(border).joined()
            body += "</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblCellMar><w:left w:w=\"100\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
            body += widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined()
            body += "</w:tblGrid>"

            let headerFormat = "<w:b/><w:color w:val=\"605E5C\"/><w:sz w:val=\"20\"/>"
            let header = zip(widths, ["", "Task", "Owner", "Due"]).map {
                cell($0, cellPara($1, headerFormat), shade: "F3F2F1")
            }.joined()
            body += "<w:tr><w:trPr><w:tblHeader/></w:trPr>\(header)</w:tr>"

            let symbolFont = "<w:rFonts w:ascii=\"Segoe UI Symbol\" w:hAnsi=\"Segoe UI Symbol\" w:cs=\"Segoe UI Symbol\"/>"
            for item in notes.actionItems {
                let format = item.done ? "<w:strike/><w:color w:val=\"605E5C\"/>" : ""
                let row = cell(widths[0], cellPara(item.done ? "\u{2611}" : "\u{2610}", symbolFont))
                    + cell(widths[1], cellPara(item.task, format))
                    + cell(widths[2], cellPara(item.owner ?? ""))
                    + cell(widths[3], cellPara(item.due ?? ""))
                body += "<w:tr><w:trPr><w:cantSplit/></w:trPr>\(row)</w:tr>"
            }
            body += "</w:tbl>"
        }

        body += section("Key Dates", notes.keyDateList)
        body += section("Open Questions", notes.openQuestions)
        body += section("Next Steps", notes.nextSteps)
        body += para("Footer", "Drafted with PerroNote")

        let sectPr = "<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1080\" w:right=\"1440\" w:bottom=\"1080\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"
        let document = xmlHeader + "\n<w:document " + ns + "><w:body>" + body + sectPr + "</w:body></w:document>"

        let files: [(String, String)] = [
            ("[Content_Types].xml", contentTypes),
            ("_rels/.rels", packageRels),
            ("docProps/core.xml", core(title: meeting.title)),
            ("word/document.xml", document),
            ("word/styles.xml", styles),
            ("word/numbering.xml", numbering),
            ("word/_rels/document.xml.rels", documentRels),
        ]
        return ZipStore.make(files.map { ($0.0, Data($0.1.utf8)) })
    }

    // MARK: - XML pieces

    private static func esc(_ s: String) -> String {
        let clean = String(String.UnicodeScalarView(s.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF)
        }))
        return clean.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func run(_ text: String, _ extra: String = "") -> String {
        let props = extra.isEmpty ? "" : "<w:rPr>\(extra)</w:rPr>"
        return "<w:r>\(props)<w:t xml:space=\"preserve\">\(esc(text))</w:t></w:r>"
    }

    private static func para(_ style: String, _ text: String, _ extra: String = "") -> String {
        "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>\(run(text, extra))</w:p>"
    }

    private static func bullet(_ text: String, level: Int = 0) -> String {
        "<w:p><w:pPr><w:pStyle w:val=\"ListBullet\"/><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr>\(run(text))</w:p>"
    }

    private static func section(_ title: String, _ items: [String]) -> String {
        items.isEmpty ? "" : para("Heading1", title) + items.map { bullet($0) }.joined()
    }

    private static func cell(_ width: Int, _ content: String, shade: String? = nil) -> String {
        let shading = shade.map { "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\($0)\"/>" } ?? ""
        return "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>\(shading)</w:tcPr>\(content)</w:tc>"
    }

    private static func cellPara(_ text: String, _ extra: String = "") -> String {
        "<w:p><w:pPr><w:spacing w:before=\"40\" w:after=\"40\"/></w:pPr>\(text.isEmpty ? "" : run(text, extra))</w:p>"
    }

    private static func core(title: String) -> String {
        xmlHeader + "\n" + #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">"#
            + "<dc:title>\(esc(title))</dc:title><dc:creator>PerroNote</dc:creator></cp:coreProperties>"
    }

    private static let xmlHeader = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
    private static let ns = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#

    private static let contentTypes = xmlHeader + "\n" + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>"#

    private static let packageRels = xmlHeader + "\n" + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>"#

    private static let documentRels = xmlHeader + "\n" + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/></Relationships>"#

    private static let styles = xmlHeader + "\n<w:styles " + ns + ">" + #"<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="60"/></w:pPr><w:rPr><w:b/><w:color w:val="201F1E"/><w:sz w:val="48"/><w:szCs w:val="48"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="160"/></w:pPr><w:rPr><w:color w:val="605E5C"/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="2" w:color="D1D1D1"/></w:pBdr><w:spacing w:before="320" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:color w:val="0F6CBD"/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="ListBullet"><w:name w:val="List Bullet"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="60"/></w:pPr></w:style><w:style w:type="paragraph" w:styleId="Footer"><w:name w:val="footer"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="360" w:after="0"/></w:pPr><w:rPr><w:color w:val="605E5C"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style></w:styles>"#

    private static let numbering = xmlHeader + "\n<w:numbering " + ns + ">" + #"<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#8226;"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/></w:rPr></w:lvl><w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#8211;"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="1080" w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/></w:rPr></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>"#
}

// MARK: - Zip (stored, no compression)

private enum ZipStore {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func make(_ files: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        for (name, data) in files {
            let nameBytes = Data(name.utf8)
            let crc = crc32(data)
            let size = UInt32(data.count)
            let offset = UInt32(out.count)

            out.le32(0x0403_4B50); out.le16(20); out.le16(0); out.le16(0); out.le16(0); out.le16(0x21)
            out.le32(crc); out.le32(size); out.le32(size); out.le16(UInt16(nameBytes.count)); out.le16(0)
            out.append(nameBytes); out.append(data)

            central.le32(0x0201_4B50); central.le16(20); central.le16(20); central.le16(0); central.le16(0)
            central.le16(0); central.le16(0x21); central.le32(crc); central.le32(size); central.le32(size)
            central.le16(UInt16(nameBytes.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(0); central.le32(offset)
            central.append(nameBytes)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.le32(0x0605_4B50); out.le16(0); out.le16(0)
        out.le16(UInt16(files.count)); out.le16(UInt16(files.count))
        out.le32(UInt32(central.count)); out.le32(centralOffset); out.le16(0)
        return out
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8(v >> 8))
    }

    mutating func le32(_ v: UInt32) {
        for shift in stride(from: UInt32(0), to: 32, by: 8) { append(UInt8((v >> shift) & 0xFF)) }
    }
}
