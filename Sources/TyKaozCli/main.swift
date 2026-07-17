import Foundation
import TyKaozKit

// TyKaozCli — runs a standalone JavaScript agent headless on top of TyKaozKit.
//
// Usage:
//   TyKaozCli <agent.js> [--provider anthropic|local] [--model M]
//             [--input JSON] [--library DIR] [--timeout SEC]
//
// Provider config comes from the environment:
//   anthropic: ANTHROPIC_API_KEY (+ --model / TYKAOZ_MODEL)
//   local:     TYKAOZ_LOCAL_BASE_URL (default http://localhost:1234/v1),
//              TYKAOZ_LOCAL_API_KEY (optional), --model / TYKAOZ_MODEL
//   BRAVE_API_KEY (optional) enables the web_search tool.
//
// The agent's result is printed to stdout as a JSON string; errors go to
// stderr with a non-zero exit.

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

// MARK: - Argument parsing

var args = Array(CommandLine.arguments.dropFirst())
func popFlag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

let providerName = popFlag("--provider") ?? "anthropic"
let model = popFlag("--model") ?? ProcessInfo.processInfo.environment["TYKAOZ_MODEL"]
let inputJSON = popFlag("--input")
let libraryDir = popFlag("--library")
let timeout = TimeInterval(popFlag("--timeout") ?? "") ?? 60

// Dev harness for the native __http primitive + XMLHttpRequest shim (C1): runs
// a bare engine (no provider/LLM) and prints the JSON on `globalThis.__result`.
if let probePath = popFlag("--http-eval") {
    guard let probeSrc = try? String(contentsOf: URL(fileURLWithPath: probePath), encoding: .utf8) else {
        die("error: cannot read --http-eval script at \(probePath)")
    }
    print(JSHttpProbe.run(script: probeSrc, timeout: timeout) ?? "null")
    exit(0)
}

guard let scriptPath = args.first else {
    die("""
        usage: TyKaozCli <agent.js> [--provider anthropic|local] [--model M] \
        [--input JSON] [--library DIR] [--timeout SEC]
        """, code: 2)
}

guard let script = try? String(contentsOf: URL(fileURLWithPath: scriptPath), encoding: .utf8) else {
    die("error: cannot read agent script at \(scriptPath)")
}

let env = ProcessInfo.processInfo.environment

// MARK: - Provider (built lazily, off the XS thread)

let makeProvider: @Sendable () -> (any LLMProvider)? = {
    switch providerName {
    case "anthropic":
        guard let key = env["ANTHROPIC_API_KEY"], !key.isEmpty, let model, !model.isEmpty else {
            return nil
        }
        return AnthropicProvider(apiKey: key, model: model)
    case "local":
        let base = env["TYKAOZ_LOCAL_BASE_URL"] ?? "http://localhost:1234/v1"
        guard let url = URL(string: base), let model, !model.isEmpty else { return nil }
        return LocalOpenAIProvider(
            baseURL: url, apiKey: env["TYKAOZ_LOCAL_API_KEY"] ?? "", model: model)
    default:
        return nil
    }
}

// MARK: - Tools + memory (top-level code in main.swift is @MainActor)

let memoryURL = URL(fileURLWithPath: env["TYKAOZ_MEMORY_FILE"]
    ?? (NSHomeDirectory() + "/.tykaoz/cli-memories.json"))
let memory = CLIMemoryStore(fileURL: memoryURL)

var tools: [any Tool] = [
    CurrentDateTimeTool(),
    FetchURLTool(),
    SaveMemoryTool(store: memory),
    ListMemoriesTool(store: memory),
    ReadMemoryTool(store: memory),
]
if let brave = env["BRAVE_API_KEY"], !brave.isEmpty {
    tools.append(BraveSearchTool(apiKey: brave))
}
let registry = ToolRegistry(tools: tools)

// MARK: - Run

let runtime = AgentRuntime(
    makeProvider: makeProvider,
    tools: registry,
    memory: memory,
    log: { FileHandle.standardError.write(Data("[log] \($0)\n".utf8)) })

let input: Any? = inputJSON.flatMap {
    try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed])
}

do {
    let result = try await runtime.run(
        script: script,
        input: input,
        timeout: timeout,
        libraryRoot: libraryDir.map { URL(fileURLWithPath: $0) })
    print(result)
} catch {
    die("error: \(error.localizedDescription)")
}
