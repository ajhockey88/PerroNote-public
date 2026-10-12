import Foundation
import Network

/// Where the notes are sent from: your Gmail address and a Google app password.
/// The address is kept in the app's settings and the app password in the iPhone Keychain.
enum MailSettings {
    private static let addressKey = "mail-sender-address"
    private static let passwordKey = "mail-app-password"

    static var address: String {
        get { UserDefaults.standard.string(forKey: addressKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: addressKey) }
    }

    /// Google shows app passwords in groups of four letters; the spaces are not part of the password.
    static var appPassword: String {
        get { Keychain.get(passwordKey) ?? "" }
        set { Keychain.set(newValue.filter { !$0.isWhitespace }, for: passwordKey) }
    }

    static var isConfigured: Bool { !address.isEmpty && !appPassword.isEmpty }
}

enum MailError: LocalizedError {
    case rejected(String)
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let why), .connection(let why): return why
        }
    }
}

/// Sends an email through Gmail's mail server (smtp.gmail.com) using an app password.
enum GmailMailer {
    struct Credentials {
        var address: String
        var appPassword: String
    }

    struct Attachment {
        var name: String
        var mimeType: String
        var data: Data
    }

    static func send(from credentials: Credentials, to recipient: OutlookAccount, subject: String,
                     html: String, plain: String, attachment: Attachment?) async throws {
        guard !credentials.address.isEmpty, !credentials.appPassword.isEmpty else {
            throw MailError.rejected("Add your Gmail address and app password in Settings first.")
        }
        let message = MIME.build(from: credentials.address, to: recipient, subject: subject,
                                 html: html, plain: plain, attachment: attachment)

        let smtp = SMTPConnection(host: "smtp.gmail.com", port: 465)
        defer { smtp.close() }
        do {
            try await smtp.open()
            try await smtp.expect(220)
            try await smtp.command("EHLO perronote.app", expect: 250)

            let auth = Data("\0\(credentials.address)\0\(credentials.appPassword)".utf8).base64EncodedString()
            let reply = try await smtp.command("AUTH PLAIN \(auth)", expect: nil)
            guard reply.code == 235 else {
                if reply.code == 534 || reply.code == 535 {
                    throw MailError.rejected("Gmail did not accept the address or app password. Check that you pasted the 16-letter app password (not your normal password) and that 2-Step Verification is on.")
                }
                throw MailError.rejected("Gmail refused the sign-in: \(reply.text)")
            }

            try await smtp.command("MAIL FROM:<\(credentials.address)>", expect: 250)
            let rcpt = try await smtp.command("RCPT TO:<\(recipient.email)>", expect: nil)
            guard rcpt.code == 250 || rcpt.code == 251 else {
                throw MailError.rejected("Gmail did not accept \(recipient.email): \(rcpt.text)")
            }
            try await smtp.command("DATA", expect: 354)
            try await smtp.sendRaw(message + "\r\n.\r\n")
            let done = try await smtp.readReply()
            guard done.code == 250 else {
                throw MailError.rejected("Gmail did not send the message: \(done.text)")
            }
            _ = try? await smtp.command("QUIT", expect: nil)
        } catch let error as MailError {
            throw error
        } catch {
            throw MailError.connection("Could not reach Gmail. Check your internet connection and try again. (\(error.localizedDescription))")
        }
    }
}

// MARK: - Building the email

private enum MIME {
    static func build(from: String, to: OutlookAccount, subject: String, html: String, plain: String,
                      attachment: GmailMailer.Attachment?) -> String {
        let id = UUID().uuidString
        let outer = "perronote-mixed-" + id
        let inner = "perronote-alt-" + id

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var lines: [String] = [
            "From: <\(from)>",
            "To: \(encodedWord(to.name)) <\(to.email)>",
            "Subject: \(encodedWord(subject))",
            "Date: \(dateFormatter.string(from: Date()))",
            "Message-ID: <\(id)@perronote.app>",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"\(outer)\"",
            "",
            "--\(outer)",
            "Content-Type: multipart/alternative; boundary=\"\(inner)\"",
            "",
            "--\(inner)",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
            "",
            wrapped(Data(plain.utf8)),
            "--\(inner)",
            "Content-Type: text/html; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
            "",
            wrapped(Data(html.utf8)),
            "--\(inner)--",
        ]
        if let attachment {
            let ascii = String(attachment.name.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0 != "\\" ? Character($0) : "_" })
            let pct = attachment.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ascii
            lines += [
                "--\(outer)",
                "Content-Type: \(attachment.mimeType); name=\"\(ascii)\"",
                "Content-Disposition: attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(pct)",
                "Content-Transfer-Encoding: base64",
                "",
                wrapped(attachment.data),
            ]
        }
        lines.append("--\(outer)--")
        return lines.joined(separator: "\r\n")
    }

    /// Base64 in lines of 76 characters, which also keeps any line from starting with a dot.
    private static func wrapped(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    /// Makes a header value safe for any character, such as accents in a name or title.
    private static func encodedWord(_ text: String) -> String {
        "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
    }
}

// MARK: - A minimal SMTP connection

private final class SMTPConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "perronote.smtp")
    private var buffer = Data()

    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tls)
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            connection.stateUpdateHandler = { [connection] state in
                guard !finished else { return }
                switch state {
                case .ready:
                    finished = true
                    continuation.resume()
                case .failed(let error):
                    finished = true
                    continuation.resume(throwing: error)
                case .waiting(let error):
                    finished = true
                    connection.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    finished = true
                    continuation.resume(throwing: MailError.connection("The connection was closed."))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func close() { connection.cancel() }

    func sendRaw(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Sends a command and checks the reply code, unless `expect` is nil (the caller checks).
    @discardableResult
    func command(_ text: String, expect: Int?) async throws -> (code: Int, text: String) {
        try await sendRaw(text + "\r\n")
        let reply = try await readReply()
        if let expect, reply.code != expect {
            throw MailError.rejected("Gmail said: \(reply.text)")
        }
        return reply
    }

    func expect(_ code: Int) async throws {
        let reply = try await readReply()
        if reply.code != code { throw MailError.rejected("Gmail said: \(reply.text)") }
    }

    /// Reads one complete reply, which may span several lines.
    func readReply() async throws -> (code: Int, text: String) {
        while true {
            if let reply = takeReply() { return reply }
            buffer.append(try await receive())
        }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: MailError.connection("Gmail closed the connection."))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// Pulls a finished reply off the front of the buffer. A reply ends at the first line that has a
    /// three-digit code followed by a space; earlier lines use a dash after the code.
    private func takeReply() -> (code: Int, text: String)? {
        guard let text = String(data: buffer, encoding: .utf8) else { return nil }
        var pieces = text.components(separatedBy: "\r\n")
        _ = pieces.removeLast()   // an unfinished line, or empty
        var consumed = 0
        var collected: [String] = []
        for line in pieces {
            consumed += line.utf8.count + 2
            collected.append(line)
            let chars = Array(line)
            if chars.count >= 3, let code = Int(String(chars[0..<3])), chars.count == 3 || chars[3] == " " {
                buffer.removeFirst(consumed)
                return (code, collected.joined(separator: " "))
            }
        }
        return nil
    }
}
