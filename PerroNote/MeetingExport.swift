import Foundation

/// Builds the email versions of a meeting's notes.
/// The HTML sticks to what Outlook (desktop, web and mobile) renders reliably: nested tables,
/// inline styles, point font sizes, web-safe fonts, and no flexbox, classes or external CSS.
enum MeetingExport {
    static func subject(_ meeting: Meeting) -> String {
        "Meeting notes: \(meeting.title) (\(meeting.date.formatted(date: .abbreviated, time: .omitted)))"
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static let font = "Calibri, 'Segoe UI', Arial, sans-serif"
    private static let ink = "#201f1e"
    private static let muted = "#605e5c"
    private static let blue = "#0f6cbd"
    private static let rule = "#d1d1d1"

    static func html(for meeting: Meeting, notes: MeetingNotes) -> String {
        func heading(_ text: String) -> String {
            """
            <tr><td style="padding:20px 0 6px 0;font-family:\(font);font-size:13pt;font-weight:bold;color:\(blue);\
            border-bottom:1px solid \(rule);">\(esc(text))</td></tr>
            """
        }
        func bullets(_ items: [String]) -> String {
            let lis = items.map {
                "<li style=\"margin:0 0 4px 0;font-family:\(font);font-size:11pt;color:\(ink);\">\(esc($0))</li>"
            }.joined()
            return "<tr><td style=\"padding:8px 0 0 0;\"><ul style=\"margin:0;padding-left:22px;\">\(lis)</ul></td></tr>"
        }
        func section(_ title: String, _ items: [String]) -> String {
            items.isEmpty ? "" : heading(title) + bullets(items)
        }

        var rows = ""
        rows += """
        <tr><td style="padding:0 0 4px 0;font-family:\(font);font-size:20pt;font-weight:bold;color:\(ink);">\(esc(meeting.title))</td></tr>
        <tr><td style="padding:0 0 8px 0;font-family:\(font);font-size:10pt;color:\(muted);">\
        \(esc(meeting.date.formatted(date: .complete, time: .shortened))) &nbsp;|&nbsp; \(formatDuration(meeting.duration))</td></tr>
        """
        rows += heading("Summary")
        rows += "<tr><td style=\"padding:8px 0 0 0;font-family:\(font);font-size:11pt;line-height:1.4;color:\(ink);\">\(esc(notes.summary))</td></tr>"
        rows += section("Attendees", notes.attendees)
        if let topics = notes.topics, !topics.isEmpty {
            rows += heading("Discussion")
            for t in topics {
                rows += "<tr><td style=\"padding:12px 0 0 0;font-family:\(font);font-size:11pt;font-weight:bold;color:\(ink);\">\(esc(t.title))</td></tr>"
                let lis = t.points.enumerated().map { i, p -> String in
                    let inner = t.subPoints(at: i).map {
                        "<li style=\"margin:0 0 2px 0;font-family:\(font);font-size:10.5pt;color:\(muted);\">\(esc($0))</li>"
                    }.joined()
                    let nested = inner.isEmpty ? "" : "<ul style=\"margin:3px 0 0 0;padding-left:20px;list-style-type:circle;\">\(inner)</ul>"
                    return "<li style=\"margin:0 0 4px 0;font-family:\(font);font-size:11pt;color:\(ink);\">\(esc(p))\(nested)</li>"
                }.joined()
                rows += "<tr><td style=\"padding:8px 0 0 0;\"><ul style=\"margin:0;padding-left:22px;\">\(lis)</ul></td></tr>"
            }
        } else {
            rows += section("Discussion", notes.discussion)
        }
        rows += section("Decisions", notes.decisions)

        if !notes.actionItems.isEmpty {
            rows += heading("Action Items")
            let th = "padding:6px 8px;font-family:\(font);font-size:10pt;font-weight:bold;color:\(muted);text-align:left;border-bottom:1px solid \(rule);"
            var table = """
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;width:100%;">
            <tr bgcolor="#f3f2f1"><td width="28" style="\(th)">&nbsp;</td><td style="\(th)">Task</td>\
            <td width="110" style="\(th)">Owner</td><td width="110" style="\(th)">Due</td></tr>
            """
            for item in notes.actionItems {
                let td = "padding:7px 8px;font-family:\(font);font-size:11pt;color:\(item.done ? muted : ink);vertical-align:top;border-bottom:1px solid #edebe9;"
                let task = item.done ? "<s>\(esc(item.task))</s>" : esc(item.task)
                table += """
                <tr><td width="28" style="\(td)">\(item.done ? "&#9745;" : "&#9744;")</td><td style="\(td)">\(task)</td>\
                <td width="110" style="\(td)">\(esc(item.owner ?? ""))</td><td width="110" style="\(td)">\(esc(item.due ?? ""))</td></tr>
                """
            }
            table += "</table>"
            rows += "<tr><td style=\"padding:8px 0 0 0;\">\(table)</td></tr>"
        }

        rows += section("Open Questions", notes.openQuestions)
        rows += section("Next Steps", notes.nextSteps)
        rows += """
        <tr><td style="padding:24px 0 0 0;font-family:\(font);font-size:9pt;color:\(muted);">Drafted with PerroNote</td></tr>
        """

        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">\
        <title>\(esc(meeting.title))</title></head>
        <body style="margin:0;padding:0;background-color:#ffffff;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#ffffff"><tr><td align="left" style="padding:0;">
        <table role="presentation" width="640" cellpadding="0" cellspacing="0" border="0" style="width:640px;max-width:100%;">
        \(rows)
        </table></td></tr></table></body></html>
        """
    }

    static func plainText(for meeting: Meeting, notes: MeetingNotes) -> String {
        var out = "\(meeting.title)\n\(meeting.date.formatted(date: .complete, time: .shortened)) | \(formatDuration(meeting.duration))\n\n"
        out += "SUMMARY\n\(notes.summary)\n\n"
        func list(_ heading: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            out += heading.uppercased() + "\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        list("Attendees", notes.attendees)
        if let topics = notes.topics, !topics.isEmpty {
            out += "DISCUSSION\n"
            for t in topics {
                out += "\(t.title)\n"
                for (i, p) in t.points.enumerated() {
                    out += "  - \(p)\n"
                    for s in t.subPoints(at: i) { out += "      - \(s)\n" }
                }
                out += "\n"
            }
        } else {
            list("Discussion", notes.discussion)
        }
        list("Decisions", notes.decisions)
        if !notes.actionItems.isEmpty {
            out += "ACTION ITEMS\n"
            for i in notes.actionItems {
                var line = "[\(i.done ? "x" : " ")] \(i.task)"
                if let o = i.owner, !o.isEmpty { line += " (\(o))" }
                if let d = i.due, !d.isEmpty { line += " - due \(d)" }
                out += line + "\n"
            }
            out += "\n"
        }
        list("Open questions", notes.openQuestions)
        list("Next steps", notes.nextSteps)
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
