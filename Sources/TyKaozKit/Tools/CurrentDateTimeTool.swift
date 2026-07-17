import Foundation

/// Returns the current date and time in ISO 8601 format. No arguments.
/// Useful so the LLM can ground answers that depend on "now" without having
/// to guess from its training cutoff.
public struct CurrentDateTimeTool: Tool {
    public init() {}

    public let spec = ToolSpec(
        name: "current_datetime",
        description: """
        Returns the current date and time in ISO 8601 format, including the
        local timezone offset. Use this whenever an answer depends on the
        current moment (today's date, day of week, time until/since an event).
        Takes no arguments.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """
    )

    public func execute(arguments: Data) async throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        return formatter.string(from: Date())
    }
}
