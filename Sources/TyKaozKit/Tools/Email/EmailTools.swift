import Foundation

/// Mailbox access over IMAP/SMTP. Defaults target **Proton Bridge** (a local
/// server exposing a Proton account as standard IMAP/SMTP with STARTTLS + a
/// self-signed cert + a bridge-specific password). The tools drive `curl`, so
/// STARTTLS, auth and the self-signed cert are handled by curl.
public struct EmailConfig: Sendable {
    public let host: String
    public let smtpPort: Int
    public let imapPort: Int
    public let username: String
    public let password: String
    public let fromAddress: String
    public let starttls: Bool

    public init(
        host: String = "127.0.0.1", smtpPort: Int = 1025, imapPort: Int = 1143,
        username: String, password: String, fromAddress: String, starttls: Bool = true
    ) {
        self.host = host
        self.smtpPort = smtpPort
        self.imapPort = imapPort
        self.username = username
        self.password = password
        self.fromAddress = fromAddress
        self.starttls = starttls
    }

    /// Shared curl flags: credentials + STARTTLS (accepting the Bridge's cert).
    var authTLS: [String] {
        (password.isEmpty ? [] : ["--user", "\(username):\(password)"])
            + (starttls ? ["--ssl-reqd", "--insecure"] : [])
    }
}

private let curlPath = "/usr/bin/curl"

/// Sends an email through SMTP (Proton Bridge by default).
public struct SendEmailTool: Tool {
    public let config: EmailConfig
    public init(config: EmailConfig) { self.config = config }

    public let spec = ToolSpec(
        name: "send_email",
        description: """
        Sends a plain-text email from the user's mailbox. `to` may be a comma-
        separated list. Returns confirmation or the server error.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "to": { "type": "string", "description": "Recipient address(es), comma-separated." },
            "subject": { "type": "string" },
            "body": { "type": "string", "description": "Plain-text message body." }
          },
          "required": ["to", "subject", "body"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable { let to: String; let subject: String; let body: String }

    public func execute(arguments: Data) async throws -> String {
        guard let args = try? JSONDecoder().decode(Args.self, from: arguments) else {
            throw ToolError.invalidArguments(reason: "expected {to, subject, body}")
        }
        let recipients = args.to.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard !recipients.isEmpty else {
            throw ToolError.invalidArguments(reason: "no recipient in `to`")
        }
        let message = Self.rfc822(
            from: config.fromAddress, to: args.to, subject: args.subject, body: args.body)
        var curlArgs = [
            "--silent", "--show-error",
            "--url", "smtp://\(config.host):\(config.smtpPort)",
            "--mail-from", config.fromAddress,
        ]
        for r in recipients { curlArgs += ["--mail-rcpt", r] }
        curlArgs += ["--upload-file", "-"]
        curlArgs += config.authTLS

        let (exit, output) = await Subprocess.run(
            curlPath, curlArgs, stdin: Data(message.utf8), timeout: 60)
        guard exit == 0 else {
            throw ToolError.execution(message: "send_email failed (curl \(exit)): \(output.prefix(500))")
        }
        return "email sent to \(args.to)"
    }

    private static func rfc822(from: String, to: String, subject: String, body: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return [
            "From: \(from)",
            "To: \(to)",
            "Subject: \(subject)",
            "Date: \(df.string(from: Date()))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "",
            body,
        ].joined(separator: "\r\n") + "\r\n"
    }
}

/// Reads the most recent messages from INBOX over IMAP (Proton Bridge default),
/// returning best-effort parsed { from, subject, date, snippet } per message.
public struct ReadEmailTool: Tool {
    public let config: EmailConfig
    public init(config: EmailConfig) { self.config = config }

    public let spec = ToolSpec(
        name: "read_email",
        description: """
        Reads the most recent messages from the INBOX (default 5, max 20),
        newest first, returning { from, subject, date, snippet } for each.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "limit": { "type": "integer", "description": "How many recent messages (default 5).", "minimum": 1, "maximum": 20 }
          },
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable { let limit: Int? }

    public func execute(arguments: Data) async throws -> String {
        let limit = min((try? JSONDecoder().decode(Args.self, from: arguments))?.limit ?? 5, 20)
        let base = "imap://\(config.host):\(config.imapPort)/INBOX"

        // Message count via STATUS.
        let (se, statusOut) = await Subprocess.run(
            curlPath, ["--silent", "--url", base, "--request", "STATUS INBOX (MESSAGES)"] + config.authTLS)
        guard se == 0 else {
            throw ToolError.execution(message: "read_email (status) failed (curl \(se)): \(statusOut.prefix(300))")
        }
        guard let count = Self.parseCount(statusOut), count > 0 else { return "[]" }

        // Fetch the last `limit` messages by sequence number, newest first.
        var results: [[String: Any]] = []
        let start = max(1, count - limit + 1)
        for seq in stride(from: count, through: start, by: -1) {
            let (fe, raw) = await Subprocess.run(
                curlPath, ["--silent", "--url", "\(base);MAILINDEX=\(seq)"] + config.authTLS)
            if fe == 0, !raw.isEmpty { results.append(Self.parseMessage(raw)) }
        }
        let json = (try? JSONSerialization.data(withJSONObject: results))
            .flatMap { String(data: $0, encoding: .utf8) }
        return json ?? "[]"
    }

    /// `* STATUS INBOX (MESSAGES 42)` → 42.
    private static func parseCount(_ s: String) -> Int? {
        guard let r = s.range(of: "MESSAGES ") else { return nil }
        let tail = s[r.upperBound...].prefix { $0.isNumber }
        return Int(tail)
    }

    /// Extract From/Subject/Date headers and a short body snippet from a raw
    /// RFC822 message (best-effort — the agent gets structured fields to act on).
    private static func parseMessage(_ raw: String) -> [String: Any] {
        var headers: [String: String] = [:]
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let headerBlock = parts.first ?? raw
        for line in headerBlock.components(separatedBy: "\r\n") where line.contains(":") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                if ["from", "subject", "date"].contains(key), headers[key] == nil {
                    headers[key] = kv[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        let body = parts.count > 1 ? parts[1...].joined(separator: "\r\n\r\n") : ""
        return [
            "from": headers["from"] ?? "",
            "subject": headers["subject"] ?? "",
            "date": headers["date"] ?? "",
            "snippet": String(body.prefix(300)),
        ]
    }
}
