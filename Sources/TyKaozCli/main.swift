import Foundation
import TyKaozKit
import TyKaozKitMLX

// TyKaozCli — runs a standalone JavaScript agent headless on top of TyKaozKit.
//
// Usage:
//   TyKaozCli <agent.js> [--provider anthropic|local] [--model M]
//             [--input JSON] [--library DIR] [--timeout SEC] [--root DIR ...]
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
/// Collect every occurrence of a repeatable flag (e.g. `--root A --root B`).
func popFlagAll(_ name: String) -> [String] {
    var values: [String] = []
    while let value = popFlag(name) { values.append(value) }
    return values
}

let providerName = popFlag("--provider") ?? "anthropic"
let model = popFlag("--model") ?? ProcessInfo.processInfo.environment["TYKAOZ_MODEL"]
let inputJSON = popFlag("--input")
let libraryDir = popFlag("--library")
let timeout = TimeInterval(popFlag("--timeout") ?? "") ?? 60

// File-space tools: each `--root DIR` authorises a folder the agent may read.
// The CLI has no sandbox, so an AuthorizedRoot is a plain directory URL (the
// tools' security-scoped bracketing is a no-op on non-scoped URLs).
let fileRoots: [AuthorizedRoot] = popFlagAll("--root").map { path in
    let url = URL(fileURLWithPath: path, isDirectory: true)
    return AuthorizedRoot(name: url.lastPathComponent, url: url)
}

// Dev harness for the native __http primitive + XMLHttpRequest shim (C1): runs
// a bare engine (no provider/LLM) and prints the JSON on `globalThis.__result`.
if let probePath = popFlag("--http-eval") {
    guard let probeSrc = try? String(contentsOf: URL(fileURLWithPath: probePath), encoding: .utf8) else {
        die("error: cannot read --http-eval script at \(probePath)")
    }
    print(JSHttpProbe.run(script: probeSrc, timeout: timeout) ?? "null")
    exit(0)
}

// Multi-agent runs are now initiated from the script itself: an agent calls
// `new Thread()` + `new Service(thread, "/abs/sub.mjs")` and `await`s the
// sub-agent's default-export methods (see AgentRuntime / TyKaozThreads).

guard let scriptPath = args.first else {
    die("""
        usage: TyKaozCli <agent.js> [--provider anthropic|local] [--model M] \
        [--input JSON] [--library DIR] [--timeout SEC] [--root DIR ...]
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
    case "js-anthropic":
        guard let key = env["ANTHROPIC_API_KEY"], !key.isEmpty, let model, !model.isEmpty else {
            return nil
        }
        return JSProviders.anthropic(apiKey: key, model: model, baseURL: env["ANTHROPIC_BASE_URL"])
    case "js-openai":
        guard let key = env["OPENAI_API_KEY"], !key.isEmpty, let model, !model.isEmpty else {
            return nil
        }
        return JSProviders.openai(apiKey: key, model: model, baseURL: env["OPENAI_BASE_URL"])
    case "js-ollama":
        guard let model, !model.isEmpty else { return nil }
        return JSProviders.ollama(
            model: model, baseURL: env["OLLAMA_BASE_URL"] ?? "http://localhost:11434")
    case "js-google":
        guard let key = env["GOOGLE_API_KEY"], !key.isEmpty, let model, !model.isEmpty else {
            return nil
        }
        return JSProviders.google(apiKey: key, model: model, baseURL: env["GOOGLE_BASE_URL"])
    case "js-kimi":
        guard let key = env["MOONSHOT_API_KEY"] ?? env["KIMI_API_KEY"], !key.isEmpty else {
            return nil
        }
        return JSProviders.kimi(apiKey: key, model: model ?? "kimi-k3", baseURL: env["KIMI_BASE_URL"])
    case "local":
        let base = env["TYKAOZ_LOCAL_BASE_URL"] ?? "http://localhost:1234/v1"
        guard let url = URL(string: base), let model, !model.isEmpty else { return nil }
        return LocalOpenAIProvider(
            baseURL: url, apiKey: env["TYKAOZ_LOCAL_API_KEY"] ?? "", model: model)
    case "apple":
        return AppleIntelligenceProvider()
    case "mlx":
        guard let model, !model.isEmpty else { return nil }
        return MLXLLMProvider(modelID: model)
    default:
        return nil
    }
}

// MARK: - Tools + memory (top-level code in main.swift is @MainActor)

let memoryURL = URL(fileURLWithPath: env["TYKAOZ_MEMORY_FILE"]
    ?? (NSHomeDirectory() + "/.tykaoz/cli-memories.json"))
let memory = CLIMemoryStore(fileURL: memoryURL)

// Native (OS-bound) tools: memory + files stay in Swift.
var tools: [any Tool] = [
    SaveMemoryTool(store: memory),
    ListMemoriesTool(store: memory),
    ReadMemoryTool(store: memory),
]
if !fileRoots.isEmpty {
    tools.append(ListDirectoryTool(roots: fileRoots))
    tools.append(ReadFileTool(roots: fileRoots))
    tools.append(GrepFilesTool(roots: fileRoots))
}
// HTTP / pure tools are JS modules (datetime, fetch_url, web_search).
var jsToolNames = ["datetime", "fetch-url"]
var toolConfig: [String: Any] = [:]
if let brave = env["BRAVE_API_KEY"], !brave.isEmpty {
    jsToolNames.append("web-search")
    toolConfig["braveApiKey"] = brave
}
if let jsTools = JSToolBundle(
    toolModules: jsToolNames, config: toolConfig,
    tools: ToolRegistry(tools: []), memory: memory) {
    tools.append(contentsOf: jsTools.tools())
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
        libraryRoot: libraryDir.map { URL(fileURLWithPath: $0) },
        // Relative `new Service(t, "./sub.mjs")` specifiers resolve against the
        // agent script's own directory.
        moduleBase: URL(fileURLWithPath: scriptPath).deletingLastPathComponent())
    print(result)
} catch {
    die("error: \(error.localizedDescription)")
}
