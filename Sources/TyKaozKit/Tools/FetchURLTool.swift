import Foundation

/// Fetches the body of an HTTP(S) URL and returns the text. HTML pages are
/// stripped of tags + scripts + styles down to a flat text representation —
/// good enough for an LLM to summarise an article without bringing in a
/// proper HTML parser.
public struct FetchURLTool: Tool {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public let spec = ToolSpec(
        name: "fetch_url",
        description: """
        Fetches the textual content at a public HTTP or HTTPS URL and
        returns the body. For HTML pages, tags and inline scripts/styles are
        stripped, leaving the readable text. Use when you need to read the
        content of a web page the user mentions. The result is capped at
        max_chars characters (default 10000).
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "url": {
              "type": "string",
              "description": "The HTTP or HTTPS URL to fetch."
            },
            "max_chars": {
              "type": "integer",
              "description": "Maximum number of characters to return (default 10000).",
              "minimum": 100,
              "maximum": 100000
            }
          },
          "required": ["url"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable {
        let url: String
        let maxChars: Int?

        enum CodingKeys: String, CodingKey {
            case url
            case maxChars = "max_chars"
        }
    }

    public func execute(arguments: Data) async throws -> String {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            let raw = String(data: arguments, encoding: .utf8) ?? "<binary>"
            throw ToolError.invalidArguments(
                reason: "expected {url: string, max_chars?: int}, got: \(raw)"
            )
        }

        guard let url = URL(string: args.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw ToolError.invalidArguments(reason: "url must be http(s)")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // Polite default headers — some sites serve different content
        // depending on Accept / User-Agent.
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("TyKaoz/0.1 (macOS; +https://tykaoz.bzh)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw ToolError.execution(message: "network error: \(urlError.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw ToolError.execution(message: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ToolError.execution(message: "HTTP \(http.statusCode)")
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ToolError.execution(message: "response is not valid UTF-8")
        }

        let text = contentType.contains("html") ? Self.stripHTML(raw) : raw
        let limit = args.maxChars ?? 10_000
        if text.count > limit {
            return String(text.prefix(limit)) + "\n[truncated]"
        }
        return text
    }

    /// Crude HTML → flat text: drops `<script>` / `<style>` blocks, then
    /// every remaining tag, decodes a handful of common entities, and
    /// condenses whitespace. Not a proper parser — good enough for an LLM.
    public static func stripHTML(_ html: String) -> String {
        var s = html

        for tag in ["script", "style"] {
            s = s.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        s = s.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )

        let entities: [(String, String)] = [
            ("&amp;",  "&"),
            ("&lt;",   "<"),
            ("&gt;",   ">"),
            ("&quot;", "\""),
            ("&#39;",  "'"),
            ("&nbsp;", " ")
        ]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }

        s = s.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
