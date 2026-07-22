import Foundation
import XSBridge
import XSBridgeKit
import TyKaozHostC

/// TyKaoz's host capabilities for a running JS agent. The C target
/// (`TyKaozHostC`) installs `host.*` functions that marshal arguments and hand
/// `(bridge, id, json)` to the `@_cdecl` entry points below; each recovers this
/// object from the bridge context and settles the call via `HostReply`
/// (`xsServiceResolve` / `xsServiceEmit`). No `xsSlot` ever crosses into
/// Swift — only opaque ids and UTF-8 JSON.
///
/// Concurrency: the entry points run on the engine's private XS thread. Work
/// touching `@MainActor` state (tools, memory, provider) hops via
/// `Task { @MainActor in … }` and settles through the thread-safe `HostReply`,
/// which wakes the engine's run loop. We never block the XS thread.
/// A provider the host exposes to JS for discovery (`host.providers()`). `model`
/// is the provider's configured/default model, so an agent can instantiate an
/// element directly: `host.provider(item.id, { model: item.model }).chat(...)`
/// (nil for providers that take no model, e.g. Apple Intelligence).
public struct ProviderDescriptor: Sendable {
    public let id: String
    public let name: String
    public let model: String?
    public init(id: String, name: String, model: String? = nil) {
        self.id = id
        self.name = name
        self.model = model
    }
}

public nonisolated final class TyKaozHost {

    public let makeProvider: @Sendable () -> (any LLMProvider)?
    /// Resolve a provider the JS named via `host.provider(id, opts)`. `id` is
    /// the provider identifier; `options` carries the rest of the selector
    /// (`model`, `baseURL`, …). The consumer maps ids to concrete providers
    /// (HTTP, MLX, Apple), injecting secrets itself — JS never sees API keys.
    /// nil (or a nil result) → `host.llm`'s default `makeProvider` is used.
    public let resolveProvider: (@Sendable (_ id: String, _ options: [String: Any]) -> (any LLMProvider)?)?
    /// The provider ids/names surfaced to JS via `host.providers()`.
    public let providerCatalog: [ProviderDescriptor]
    public let tools: ToolRegistry
    public let memory: MemoryStoring
    public let log: @Sendable (String) -> Void

    /// Set by the owning runtime before a run: the agent's result (`__report`)
    /// and failure (`__fail`) channels. Set once, no real race.
    public nonisolated(unsafe) var onReport: ((String) -> Void)?
    public nonisolated(unsafe) var onFail: ((String) -> Void)?
    /// JS-tool result delivery (`__toolResult`) for `JSToolBundle`.
    public nonisolated(unsafe) var onToolResult: (([Any]) -> Void)?
    /// Resident delivery outcome (`__deliverResult`, keyed by deliveryId) for
    /// `AgentHost` — settles one delivery without ending the run.
    public nonisolated(unsafe) var onDeliverResult: ((UInt32, String, Bool) -> Void)?
    /// Self-scheduling (`host.schedule`/`host.every`): the host arms a timer that
    /// later delivers a `tick`. Returns a cancel handle. `onCancel` disarms it.
    public nonisolated(unsafe) var onSchedule: ((_ delayMs: Double, _ repeating: Bool, _ payloadJSON: String) -> UInt32)?
    public nonisolated(unsafe) var onCancel: ((UInt32) -> Void)?

    public init(
        makeProvider: @escaping @Sendable () -> (any LLMProvider)?,
        resolveProvider: (@Sendable (_ id: String, _ options: [String: Any]) -> (any LLMProvider)?)? = nil,
        providerCatalog: [ProviderDescriptor] = [],
        tools: ToolRegistry,
        memory: MemoryStoring,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.makeProvider = makeProvider
        self.resolveProvider = resolveProvider
        self.providerCatalog = providerCatalog
        self.tools = tools
        self.memory = memory
        self.log = log
    }

    // MARK: - Handlers (settle via HostReply)

    /// Defensive cap on provider → tool → provider iterations, mirroring
    /// `ChatSession.maxToolRounds`.
    private static let maxToolRounds = 20

    public func chat(params: [Any], reply: HostReply) {
        // params: [messages, toolNames, selector]. selector = {id?, model?, …}
        // from host.provider(id, opts); a nil/absent id → the default provider.
        let selector = (params.count > 2 ? params[2] as? [String: Any] : nil) ?? [:]
        let provider: (any LLMProvider)?
        if let id = selector["id"] as? String {
            provider = resolveProvider?(id, selector)
        } else {
            provider = makeProvider()
        }
        guard let provider else {
            reply.reject(AgentJSON.string(
                (selector["id"] as? String).map { "provider indisponible : \($0)" }
                    ?? "no LLM provider configured"))
            return
        }
        var history = AgentJSON.decodeMessages(params.first)
        let requestedNames: [String] = (params.count > 1 ? params[1] as? [Any] : nil)?
            .compactMap { $0 as? String } ?? []

        Task { @MainActor in
            let available = self.tools.specs
            var specs: [ToolSpec] = []
            for name in requestedNames {
                guard let spec = available.first(where: { $0.name == name }) else {
                    reply.reject(AgentJSON.string("unknown tool: \(name)"))
                    return
                }
                specs.append(spec)
            }

            do {
                var lastText = ""
                for _ in 0..<Self.maxToolRounds {
                    var text = ""
                    var reasoning = ""
                    var pendingCalls: [(id: String, name: String, args: String, signature: String?)] = []

                    for try await event in provider.chat(messages: history, tools: specs) {
                        switch event {
                        case .textDelta(let delta):
                            text += delta
                            reply.emit(AgentJSON.string(delta))
                        case .reasoningDelta(let delta):
                            reasoning += delta
                        case .toolCall(let id, let name, let args, let signature):
                            pendingCalls.append((id, name, args, signature))
                        case .imageOutput, .metrics:
                            break
                        }
                    }

                    if pendingCalls.isEmpty {
                        reply.resolve(AgentJSON.string(text))
                        return
                    }

                    if !text.isEmpty || !reasoning.isEmpty {
                        history.append(ChatMessage(
                            role: .assistant,
                            content: text,
                            reasoningContent: reasoning.isEmpty ? nil : reasoning))
                    }
                    for call in pendingCalls {
                        history.append(ChatMessage(
                            role: .toolCall,
                            content: call.args,
                            toolCallID: call.id,
                            toolName: call.name,
                            thoughtSignature: call.signature))
                    }
                    for call in pendingCalls {
                        let result = await self.tools.execute(
                            ToolCall(id: call.id, toolName: call.name, arguments: Data(call.args.utf8)))
                        history.append(ChatMessage(
                            role: .toolResult,
                            content: result.content,
                            toolCallID: result.callID,
                            toolIsError: result.isError))
                    }
                    lastText = text
                }
                reply.resolve(AgentJSON.string(lastText))
            } catch {
                reply.reject(AgentJSON.string(error.localizedDescription))
            }
        }
    }

    public func toolList(reply: HostReply) {
        let tools = self.tools
        Task { @MainActor in reply.resolve(Self.toolListJSON(tools)) }
    }

    public func toolCall(params: [Any], reply: HostReply) {
        guard let name = params.first as? String else {
            reply.reject(AgentJSON.string("tool.call expects [name, args]"))
            return
        }
        let argsJSON = params.count > 1 ? AgentJSON.string(params[1]) : "{}"
        let tools = self.tools
        Task { @MainActor in
            let result = await tools.execute(
                ToolCall(id: UUID().uuidString, toolName: name, arguments: Data(argsJSON.utf8)))
            result.isError
                ? reply.reject(AgentJSON.string(result.content))
                : reply.resolve(AgentJSON.string(result.content))
        }
    }

    public func memorySave(params: [Any], reply: HostReply) {
        let title = (params.first as? String) ?? ""
        let content = (params.count > 1 ? params[1] as? String : nil) ?? ""
        let memory = self.memory
        Task { @MainActor in
            let saved = memory.add(title: title, content: content)
            reply.resolve(AgentJSON.string(saved.id.uuidString))
        }
    }

    public func memoryRead(params: [Any], reply: HostReply) {
        guard let idString = params.first as? String, let id = UUID(uuidString: idString) else {
            reply.reject(AgentJSON.string("memory.read expects a valid id"))
            return
        }
        let memory = self.memory
        Task { @MainActor in
            guard let found = memory.memory(id: id) else { reply.resolve("null"); return }
            reply.resolve(AgentJSON.string([
                "id": found.id.uuidString, "title": found.title, "content": found.content
            ]))
        }
    }

    public func memoryList(reply: HostReply) {
        let memory = self.memory
        Task { @MainActor in
            let list = memory.memories.map { ["id": $0.id.uuidString, "title": $0.title] }
            reply.resolve(AgentJSON.string(list))
        }
    }

    public func memorySearch(params: [Any], reply: HostReply) {
        guard let query = params.first as? String else {
            reply.reject(AgentJSON.string("memory.search expects [query, limit?]"))
            return
        }
        let limit = (params.count > 1 ? (params[1] as? NSNumber)?.intValue : nil) ?? 5
        let memory = self.memory
        Task { @MainActor in
            guard let retriever = memory as? MemoryRetrieving else {
                reply.reject(AgentJSON.string("this memory store has no semantic search"))
                return
            }
            let results = await retriever.search(query, limit: limit)
            reply.resolve(AgentJSON.string(results.map {
                ["id": $0.memory.id.uuidString, "title": $0.memory.title,
                 "content": $0.memory.content, "score": Double($0.score)]
            }))
        }
    }

    // MARK: - Helpers

    @MainActor
    private static func toolListJSON(_ tools: ToolRegistry) -> String {
        let entries: [[String: Any]] = tools.specs.map { spec in
            var schema: Any = [:]
            if let data = spec.inputSchemaJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                schema = parsed
            }
            return ["name": spec.name, "description": spec.description, "input_schema": schema]
        }
        return AgentJSON.string(entries)
    }
}

extension XSEngine {
    /// Create an engine with TyKaoz's host functions installed, the bridge
    /// context pointed at `host`, and the JS orchestrator (`host.llm.chat`,
    /// `__runAgent`, `__callTool`) installed. All XS access on the XS thread.
    public static func tyKaoz(host: TyKaozHost) -> XSEngine? {
        _ = JSResource.registerTrustedPrefix   // bundle JS trusted for absolute import
        guard let engine = XSEngine() else { return nil }
        let hostPtr = Unmanaged.passUnretained(host).toOpaque()
        engine.withMachine { machine in
            xsBridgeTyKaozInstall(machine)
            xsBridgeSetContext(machine, hostPtr)
        }
        // The agent orchestrator ships as a bundled ES module; importing it
        // (side effect) wires host.llm / __runAgent / __callTool. The dynamic
        // import resolves within eval's drain.
        if let orchestratorImport = JSResource.importStatement("agent-orchestrator") {
            _ = try? engine.eval(orchestratorImport)
        }
        // Publish the provider catalog for host.providers() discovery.
        if !host.providerCatalog.isEmpty {
            let catalog = host.providerCatalog.map { d -> [String: Any] in
                var e: [String: Any] = ["id": d.id, "name": d.name]
                if let model = d.model { e["model"] = model }
                return e
            }
            _ = try? engine.eval("globalThis.__providerCatalog = \(AgentJSON.string(catalog))")
        }
        return engine
    }
}

/// Settles or streams an in-flight async host call from any thread — the flat-C
/// replacement for the old `HostResponder`. Thread-safe: the settle functions
/// queue the result and wake the engine's run loop.
public nonisolated struct HostReply {
    public let bridge: UnsafeMutableRawPointer
    public let id: UInt32
    public func resolve(_ json: String) { json.withCString { xsServiceResolve(bridge, id, $0) } }
    public func reject(_ json: String) { json.withCString { xsServiceReject(bridge, id, $0) } }
    public func emit(_ json: String) { json.withCString { xsServiceEmit(bridge, id, $0) } }
}

/// Recover the `TyKaozHost` a bridge points at (set via `xsBridgeSetContext`
/// after install). Unretained — the host outlives the engine by construction.
private func tyHost(_ bridge: UnsafeMutableRawPointer) -> TyKaozHost? {
    guard let ctx = xsBridgeGetContext(bridge) else { return nil }
    return Unmanaged<TyKaozHost>.fromOpaque(ctx).takeUnretainedValue()
}

private func string(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }

// MARK: - C-callable entry points (installed by TyKaozHostC, resolved at link)

@_cdecl("xsbTyLog")
func xsbTyLog(_ bridge: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?) {
    guard let bridge, let host = tyHost(bridge) else { return }
    host.log(string(text))
}

@_cdecl("xsbTyReport")
func xsbTyReport(_ bridge: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>?) {
    guard let bridge, let host = tyHost(bridge) else { return }
    host.onReport?(string(json))
}

@_cdecl("xsbTyFail")
func xsbTyFail(_ bridge: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?) {
    guard let bridge, let host = tyHost(bridge) else { return }
    host.onFail?(string(text))
}

@_cdecl("xsbTyChat")
func xsbTyChat(_ bridge: UnsafeMutableRawPointer?, _ id: UInt32, _ json: UnsafePointer<CChar>?) {
    guard let bridge, let host = tyHost(bridge) else { return }
    host.chat(params: AgentJSON.params(string(json)), reply: HostReply(bridge: bridge, id: id))
}

@_cdecl("xsbTyToolList")
func xsbTyToolList(_ bridge: UnsafeMutableRawPointer?, _ id: UInt32) {
    guard let bridge, let host = tyHost(bridge) else { return }
    host.toolList(reply: HostReply(bridge: bridge, id: id))
}

@_cdecl("xsbTyToolCall")
func xsbTyToolCall(_ bridge: UnsafeMutableRawPointer?, _ id: UInt32, _ json: UnsafePointer<CChar>?) {
    guard let bridge, let host = tyHost(bridge) else { return }
    host.toolCall(params: AgentJSON.params(string(json)), reply: HostReply(bridge: bridge, id: id))
}

@_cdecl("xsbTyMemorySave")
func xsbTyMemorySave(_ bridge: UnsafeMutableRawPointer?, _ id: UInt32, _ json: UnsafePointer<CChar>?) {
    guard let bridge, let host = tyHost(bridge) else { return }
    host.memorySave(params: AgentJSON.params(string(json)), reply: HostReply(bridge: bridge, id: id))
}

@_cdecl("xsbTyMemoryRead")
func xsbTyMemoryRead(_ bridge: UnsafeMutableRawPointer?, _ id: UInt32, _ json: UnsafePointer<CChar>?) {
    guard let bridge, let host = tyHost(bridge) else { return }
    host.memoryRead(params: AgentJSON.params(string(json)), reply: HostReply(bridge: bridge, id: id))
}

@_cdecl("xsbTyMemoryList")
func xsbTyMemoryList(_ bridge: UnsafeMutableRawPointer?, _ id: UInt32) {
    guard let bridge, let host = tyHost(bridge) else { return }
    host.memoryList(reply: HostReply(bridge: bridge, id: id))
}

@_cdecl("xsbTyToolResult")
func xsbTyToolResult(_ bridge: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>?) {
    guard let bridge, let host = tyHost(bridge) else { return }
    host.onToolResult?(AgentJSON.params(string(json)))
}

@_cdecl("xsbTyDeliverResult")
func xsbTyDeliverResult(
    _ bridge: UnsafeMutableRawPointer?, _ id: UInt32,
    _ json: UnsafePointer<CChar>?, _ isError: Int32
) {
    guard let bridge, let host = tyHost(bridge) else { return }
    host.onDeliverResult?(id, string(json), isError != 0)
}

@_cdecl("xsbTySchedule")
func xsbTySchedule(
    _ bridge: UnsafeMutableRawPointer?, _ delayMs: Double,
    _ repeating: Int32, _ payload: UnsafePointer<CChar>?
) -> UInt32 {
    guard let bridge, let host = tyHost(bridge) else { return 0 }
    return host.onSchedule?(delayMs, repeating != 0, string(payload)) ?? 0
}

@_cdecl("xsbTyCancel")
func xsbTyCancel(_ bridge: UnsafeMutableRawPointer?, _ handle: UInt32) {
    guard let bridge, let host = tyHost(bridge) else { return }
    host.onCancel?(handle)
}

@_cdecl("xsbTyMemorySearch")
func xsbTyMemorySearch(
    _ bridge: UnsafeMutableRawPointer?, _ id: UInt32, _ json: UnsafePointer<CChar>?
) {
    guard let bridge, let host = tyHost(bridge) else { return }
    host.memorySearch(
        params: AgentJSON.params(string(json)), reply: HostReply(bridge: bridge, id: id))
}
