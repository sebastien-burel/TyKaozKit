import Foundation

/// Web search backed by the Brave Search API. The user supplies a
/// subscription token (stored in the Keychain); the model passes a query and
/// gets back a concise list of result titles, URLs and snippets.
public struct BraveSearchTool: Tool {
    public let apiKey: String
    public let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    private static let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!
    private static let defaultCount = 5
    private static let maxCount = 20

    public let spec = ToolSpec(
        name: "web_search",
        description: """
        Searches the web with Brave and returns the top results as title, URL
        and snippet. Use for current events or facts that may be outside your
        knowledge. Returns up to `count` results (default 5).
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "query": {
              "type": "string",
              "description": "The search query."
            },
            "count": {
              "type": "integer",
              "description": "Number of results to return (1-20, default 5).",
              "minimum": 1,
              "maximum": 20
            }
          },
          "required": ["query"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable {
        let query: String
        let count: Int?
    }

    private struct BraveResponse: Decodable {
        struct Web: Decodable { let results: [Result]? }
        struct Result: Decodable {
            let title: String?
            let url: String?
            let description: String?
        }
        let web: Web?
    }

    public func execute(arguments: Data) async throws -> String {
        guard !apiKey.isEmpty else {
            throw ToolError.execution(message: "clé API Brave manquante (réglages → Outils)")
        }

        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            let raw = String(data: arguments, encoding: .utf8) ?? "<binary>"
            throw ToolError.invalidArguments(
                reason: "expected {query: string, count?: int}, got: \(raw)"
            )
        }
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ToolError.invalidArguments(reason: "query ne peut pas être vide")
        }
        let count = min(max(args.count ?? Self.defaultCount, 1), Self.maxCount)

        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(count))
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw ToolError.execution(message: "erreur réseau : \(urlError.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ToolError.execution(message: "réponse non-HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ToolError.execution(message: "HTTP \(http.statusCode)")
        }

        let results = (try? JSONDecoder().decode(BraveResponse.self, from: data))?.web?.results ?? []
        guard !results.isEmpty else { return "Aucun résultat." }

        return results.prefix(count).enumerated().map { index, result in
            let title = result.title ?? "(sans titre)"
            let url = result.url ?? ""
            let snippet = result.description ?? ""
            return "\(index + 1). \(title)\n\(url)\n\(snippet)"
        }
        .joined(separator: "\n\n")
    }
}
