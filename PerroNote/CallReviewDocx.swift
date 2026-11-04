import SwiftUI
import UIKit

/// The call review as a Word document: the score, the checklist and moments as Word tables, and the
/// charts drawn on the phone and placed in the file as pictures.
enum CallReviewDocx {
    enum Section: String, CaseIterable, Hashable {
        case scorecard, summary, checklist, guidelines, handling, deadAir, mood, moments, coaching, transcript

        var title: String {
            switch self {
            case .scorecard: return "Scorecard"
            case .summary: return "Summary"
            case .checklist: return "Process checklist"
            case .guidelines: return "Reference document checks"
            case .handling: return "Call handling"
            case .deadAir: return "Talk time and dead air"
            case .mood: return "Mood chart"
            case .moments: return "Flagged moments"
            case .coaching: return "Coaching and pain points"
            case .transcript: return "Transcript"
            }
        }
    }

    static func fileName(for meeting: Meeting) -> String {
        let r = meeting.callReview
        let parts = ["Call review", r?.ticket, r?.agentName].compactMap { $0 }
        let name = parts.count > 1 ? parts.joined(separator: " - ") : "Call review - " + meeting.title
        return exportFileName(name, fallback: "Call review", ext: "docx")
    }

    private struct Picture {
        var data: Data
        var size: CGSize
    }

    /// Draws a SwiftUI view to a PNG at twice its size, on white, in light mode.
    @MainActor
    private static func picture<V: View>(_ view: V, width: CGFloat) -> Picture? {
        let renderer = ImageRenderer(content: view
            .padding(14)
            .frame(width: width)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.uiImage, let data = image.pngData() else { return nil }
        return Picture(data: data, size: image.size)
    }

    @MainActor
    static func data(for meeting: Meeting, review: CallReview, sections: Set<Section>) -> Data {
        typealias D = MeetingDocx
        var pictures: [Picture] = []
        var body = D.para("Title", "Call review: \(meeting.title)")
        let when = meeting.date.formatted(date: .complete, time: .shortened)
        body += D.para("Subtitle", "\(when)  |  \(formatDuration(meeting.duration))  |  Process: \(review.processName)")
        if review.agentName != nil || review.ticket != nil {
            var line = "<w:p><w:pPr><w:spacing w:after=\"160\"/></w:pPr>"
            if let agent = review.agentName { line += D.run("Agent: ", "<w:b/>") + D.run(agent + "    ") }
            if let ticket = review.ticket { line += D.run("Ticket: ", "<w:b/>") + D.run(ticket) }
            body += line + "</w:p>"
        }

        func image(_ p: Picture?) {
            guard let p else { return }
            pictures.append(p)
            body += drawing(index: pictures.count, size: p.size)
        }

        if sections.contains(.scorecard) {
            image(picture(ReviewScoreTiles(review: review), width: 640))
        }
        if sections.contains(.summary), !review.summary.isEmpty {
            body += D.para("Heading1", "Summary") + "<w:p>\(D.run(review.summary))</w:p>"
        }
        if sections.contains(.checklist), !review.steps.isEmpty {
            body += D.para("Heading1", "Process checklist")
            body += table(widths: [2900, 1100, 900, 4460], header: ["Step", "Result", "Time", "Detail"],
                          rows: review.steps.map { s in
                              let detail = s.importance == .critical && s.result == .missed ? "\(s.detail) (critical step)" : s.detail
                              return [Cell(s.name), Cell(s.result.title, fill: fill(s.result), bold: true),
                                      Cell(s.at.map(formatDuration) ?? "\u{2014}"), Cell(detail)]
                          })
        }
        if sections.contains(.guidelines), let checks = review.guidelines, !checks.isEmpty {
            body += D.para("Heading1", "Reference document checks")
            body += table(widths: [2900, 1100, 900, 2560, 1900], header: ["Requirement", "Result", "Time", "Detail", "Source"],
                          rows: checks.map { c in
                              [Cell(c.requirement), Cell(c.result.title, fill: fill(c.result), bold: true),
                               Cell(c.at.map(formatDuration) ?? "\u{2014}"), Cell(c.detail), Cell(c.source)]
                          })
        }
        if sections.contains(.handling), !review.handling.isEmpty {
            body += D.para("Heading1", "Call handling")
            image(picture(HandlingBars(review: review, big: true), width: 640))
            body += table(widths: [1800, 900, 6660], header: ["Area", "Score", "Note"],
                          rows: review.handling.map { [Cell($0.area), Cell("\($0.score) of 5", bold: true), Cell($0.note)] })
        }
        if sections.contains(.deadAir), let stats = CallTalkStats.measure(meeting, review: review) {
            body += D.para("Heading1", "Talk time and dead air")
            image(picture(TalkTimeChart(stats: stats, big: true), width: 640))
            if !stats.deadAir.isEmpty {
                body += table(widths: [800, 2000, 900, 5660], header: ["Time", "Type", "Length", "Why"],
                              rows: stats.ordered.map { g in
                                  var why = g.note?.reason ?? "Not reviewed yet. Review the call again to fill this in."
                                  if let quote = g.note?.quote { why += " \u{201C}\(quote)\u{201D}" }
                                  return [Cell(formatDuration(g.start)), Cell(g.title, fill: g.explained ? "E7EFFF" : "FDE8E0", bold: true),
                                          Cell("\(Int(g.length.rounded()))s"), Cell(why)]
                              })
            } else {
                body += "<w:p>\(D.run("No silences of \(Int(stats.threshold)) seconds or more."))</w:p>"
            }
        }
        if sections.contains(.mood), review.mood.count > 1 {
            body += D.para("Heading1", "Mood over the call")
            image(picture(MoodChart(review: review, duration: meeting.duration, big: true), width: 640))
        }
        if sections.contains(.moments), !review.moments.isEmpty {
            body += D.para("Heading1", "Flagged moments")
            body += table(widths: [800, 1800, 3700, 3060], header: ["Time", "Type", "What was said", "Coaching note"],
                          rows: review.moments.map { m in
                              [Cell(m.at.map(formatDuration) ?? ""), Cell(m.label, fill: fill(m.kind), bold: true),
                               Cell("\(m.speaker == "agent" ? "Agent" : "Caller"): \u{201C}\(m.quote)\u{201D}"), Cell(m.note)]
                          })
        }
        if sections.contains(.coaching) {
            body += D.section("Coaching points", review.coaching)
            body += D.section("Caller pain points", review.painPoints)
        }
        if sections.contains(.transcript) {
            let lines = (meeting.hasVoices ? meeting.lines : meeting.timeline) ?? []
            if !lines.isEmpty {
                body += D.para("Heading1", "Transcript")
                for line in lines where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    let who = meeting.hasVoices ? speakerName(meeting, review, line.speaker) + ": " : ""
                    body += "<w:p><w:pPr><w:spacing w:after=\"60\"/></w:pPr>"
                        + D.run("[\(formatDuration(line.start))] ", "<w:color w:val=\"605E5C\"/>")
                        + D.run(who, "<w:b/>") + D.run(line.text) + "</w:p>"
                }
            }
        }
        body += D.para("Footer", "Drafted with PerroNote. Reviewed from the transcript only, so mood and tone are read from words and pacing. Please check flagged moments against the recording before acting on them.")

        let sectPr = "<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1080\" w:right=\"1440\" w:bottom=\"1080\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"
        let document = D.xmlHeader + "\n<w:document " + D.ns + " " + extraNamespaces + "><w:body>" + body + sectPr + "</w:body></w:document>"

        var rels = #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>"#
        for i in pictures.indices {
            rels += "<Relationship Id=\"rIdImg\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image\(i + 1).png\"/>"
        }
        let documentRels = D.xmlHeader + "\n" + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# + rels + "</Relationships>"
        let contentTypes = D.contentTypes.replacingOccurrences(
            of: #"<Default Extension="xml" ContentType="application/xml"/>"#,
            with: #"<Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>"#)

        var files: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(D.packageRels.utf8)),
            ("docProps/core.xml", Data(D.core(title: "Call review: \(meeting.title)").utf8)),
            ("word/document.xml", Data(document.utf8)),
            ("word/styles.xml", Data(D.styles.utf8)),
            ("word/numbering.xml", Data(D.numbering.utf8)),
            ("word/_rels/document.xml.rels", Data(documentRels.utf8)),
        ]
        for (i, p) in pictures.enumerated() { files.append(("word/media/image\(i + 1).png", p.data)) }
        return ZipStore.make(files)
    }

    // MARK: - Pieces

    private static let extraNamespaces = #"xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture""#

    /// A picture the full text width (6.5 inches), keeping its shape.
    private static func drawing(index: Int, size: CGSize) -> String {
        let cx = 5_943_600
        let cy = Int(Double(cx) * Double(size.height) / Double(max(size.width, 1)))
        return "<w:p><w:pPr><w:spacing w:after=\"120\"/></w:pPr><w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
            + "<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"\(index)\" name=\"Chart \(index)\"/>"
            + "<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
            + "<pic:nvPicPr><pic:cNvPr id=\"\(index)\" name=\"image\(index).png\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"rIdImg\(index)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
    }

    private struct Cell {
        var text: String
        var fill: String?
        var bold = false
        init(_ text: String, fill: String? = nil, bold: Bool = false) {
            self.text = text
            self.fill = fill
            self.bold = bold
        }
    }

    private static func fill(_ r: CallReview.StepResult) -> String? {
        switch r {
        case .pass: return "E3F5E7"
        case .partial: return "FFF1D6"
        case .missed: return "FDE8E8"
        case .notApplicable: return nil
        }
    }

    private static func fill(_ k: CallReview.MomentKind) -> String {
        switch k {
        case .good: return "E3F5E7"
        case .frustration: return "FDE8E8"
        default: return "FFF1D6"
        }
    }

    private static func table(widths: [Int], header: [String], rows: [[Cell]]) -> String {
        typealias D = MeetingDocx
        func border(_ name: String) -> String { "<w:\(name) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"D1D1D1\"/>" }
        var out = "<w:tbl><w:tblPr><w:tblW w:w=\"9360\" w:type=\"dxa\"/><w:tblBorders>"
        out += ["top", "left", "bottom", "right", "insideH", "insideV"].map(border).joined()
        out += "</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblCellMar><w:left w:w=\"100\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
        out += widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"
        let headFormat = "<w:b/><w:color w:val=\"605E5C\"/><w:sz w:val=\"20\"/>"
        out += "<w:tr><w:trPr><w:tblHeader/><w:cantSplit/></w:trPr>"
            + zip(widths, header).map { D.cell($0, D.cellPara($1, headFormat), shade: "F3F2F1") }.joined() + "</w:tr>"
        for row in rows {
            out += "<w:tr><w:trPr><w:cantSplit/></w:trPr>"
            out += zip(widths, row).map { w, c in D.cell(w, D.cellPara(c.text, c.bold ? "<w:b/>" : ""), shade: c.fill) }.joined()
            out += "</w:tr>"
        }
        return out + "</w:tbl><w:p><w:pPr><w:spacing w:after=\"0\"/></w:pPr></w:p>"
    }

    private static func speakerName(_ meeting: Meeting, _ review: CallReview, _ speaker: String?) -> String {
        let label = meeting.label(for: speaker)
        guard let agent = review.agentSpeaker, let speaker else { return label }
        let role = speaker == agent ? "Agent" : "Caller"
        return MeetingNotes.isSpeakerLabel(label) ? role : "\(label) (\(role.lowercased()))"
    }
}

/// The email that carries the Word report.
enum CallReviewExport {
    static func subject(_ meeting: Meeting, _ review: CallReview) -> String {
        let who = [review.ticket, review.agentName].compactMap { $0 }.joined(separator: " \u{00B7} ")
        return "Call review: \(who.isEmpty ? meeting.title : who) (\(review.score), \(review.verdict.lowercased()))"
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func plain(_ meeting: Meeting, _ review: CallReview) -> String {
        var out = "Call review: \(meeting.title)\n\(meeting.date.formatted(date: .long, time: .shortened)) \u{00B7} \(formatDuration(meeting.duration))\n"
        if let info = review.callerInfo { out += info + "\n" }
        out += "\n"
        out += "Score: \(review.score) of 100 (\(review.verdict))\nOutcome: \(review.outcome.title)\n"
        out += "Steps missed: \(review.missedSteps.count)\nFlagged moments: \(review.flags.count)\n\n"
        if !review.summary.isEmpty { out += review.summary + "\n\n" }
        if !review.missedSteps.isEmpty {
            out += "Missed steps:\n" + review.missedSteps.map { "- \($0.name): \($0.detail)" }.joined(separator: "\n") + "\n\n"
        }
        if !review.missedGuidelines.isEmpty {
            out += "Missed from reference documents:\n" + review.missedGuidelines.map { "- \($0.requirement) (\($0.source))" }.joined(separator: "\n") + "\n\n"
        }
        if !review.coaching.isEmpty {
            out += "Coaching points:\n" + review.coaching.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        out += "The full review with charts is in the attached Word document.\n"
        return out
    }

    static func html(_ meeting: Meeting, _ review: CallReview) -> String {
        let color: String
        switch review.level {
        case .good: color = "#259a45"
        case .fair: color = "#c27c00"
        case .poor: color = "#d93a3a"
        }
        var h = "<div style=\"font-family:Calibri,Arial,sans-serif;font-size:14px;color:#201F1E\">"
        h += "<h2 style=\"margin:0 0 4px\">Call review: \(esc(meeting.title))</h2>"
        h += "<div style=\"color:#605E5C;font-size:12px;margin-bottom:12px\">\(esc(meeting.date.formatted(date: .long, time: .shortened))) \u{00B7} \(formatDuration(meeting.duration)) \u{00B7} \(esc(review.processName))</div>"
        if let info = review.callerInfo { h += "<p style=\"margin:0 0 10px\">\(esc(info))</p>" }
        h += "<p style=\"font-size:18px;margin:0 0 6px\"><b style=\"color:\(color)\">\(review.score) of 100</b> \u{00B7} \(esc(review.verdict))</p>"
        h += "<p style=\"margin:0 0 12px\">Outcome: <b>\(review.outcome.title)</b> \u{00B7} Steps missed: <b>\(review.missedSteps.count)</b> \u{00B7} Flagged moments: <b>\(review.flags.count)</b></p>"
        if !review.summary.isEmpty { h += "<p>\(esc(review.summary))</p>" }
        if !review.missedSteps.isEmpty {
            h += "<p style=\"margin-bottom:2px\"><b>Missed steps</b></p><ul>" + review.missedSteps.map { "<li>\(esc($0.name)): \(esc($0.detail))</li>" }.joined() + "</ul>"
        }
        if !review.missedGuidelines.isEmpty {
            h += "<p style=\"margin-bottom:2px\"><b>Missed from reference documents</b></p><ul>" + review.missedGuidelines.map { "<li>\(esc($0.requirement)) <span style=\"color:#605E5C\">(\(esc($0.source)))</span></li>" }.joined() + "</ul>"
        }
        if !review.coaching.isEmpty {
            h += "<p style=\"margin-bottom:2px\"><b>Coaching points</b></p><ul>" + review.coaching.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
        }
        h += "<p style=\"color:#605E5C;font-size:12px\">The full review with charts is in the attached Word document. Drafted with PerroNote from the transcript only.</p></div>"
        return h
    }
}
