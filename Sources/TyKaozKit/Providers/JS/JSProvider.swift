import Foundation
import XSBridge
import XSBridgeKit
import TyKaozHostC

/// An `LLMProvider` whose logic is written in JavaScript. It owns a dedicated XS
/// engine with the native `__http` primitive + the JS→Swift event channel
/// installed, evals the `XMLHttpRequest` shim, the provider module (which sets
/// `globalThis.tyProvider = { chat(request, onEvent) }`) and the orchestrator,
/// then maps the provider's emitted events into `StreamEvent`s. This is how
/// external HTTP+SSE providers move off Swift and into JavaScript (JS-first),
/// while the app and the agent runtime keep consuming the plain `LLMProvider`
/// interface (mirrors how `JSToolBundle` adapts JS tools to `Tool`).
public final class JSProvider: LLMProvider, @unchecked Sendable {

    public let id: String
    public let displayName: String

    private let config: [String: Any]
    private let engine: XSEngine
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation?
    private var callToken: UInt64 = 0

    public init?(id: String, displayName: String, providerJS: String, config: [String: Any]) {
        guard let engine = XSEngine() else { return nil }
        self.id = id
        self.displayName = displayName
        self.config = config
        self.engine = engine

        let ptr = Unmanaged.passUnretained(self).toOpaque()
        engine.withMachine { machine in
            xsBridgeHttpInstall(machine)
            xsBridgeJSProviderInstall(machine)
            xsBridgeSetContext(machine, ptr)
        }
        guard (try? engine.eval(JSRuntime.xmlHttpRequestShim)) != nil,
              (try? engine.eval(providerJS)) != nil,
              (try? engine.eval(JSRuntime.providerOrchestrator)) != nil
        else { return nil }
    }

    public func availability() async -> ProviderAvailability {
        (config["apiKey"] as? String)?.isEmpty == false
            ? .ready
            : .unavailable(reason: "clé API manquante pour \(displayName).")
    }

    public func chat(
        messages: [ChatMessage], tools: [ToolSpec]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            // The cached engine serves one chat at a time; the factory hands out
            // a fresh instance when busy, so this guard is a last resort.
            if self.continuation != nil {
                lock.unlock()
                continuation.finish(throwing: XSError(message: "JS provider busy"))
                return
            }
            callToken &+= 1
            let token = callToken
            self.continuation = continuation
            lock.unlock()

            // Self-heal if the consumer cancels the stream before the JS side
            // settles it — otherwise the shared instance would stay "busy".
            continuation.onTermination = { [weak self] _ in
                self?.clearContinuation(token: token)
            }

            let request: [String: Any] = [
                "messages": messages.map(Self.encode),
                "tools": tools.map(Self.encode),
                "config": config,
            ]
            let json = AgentJSON.string(request)
            do {
                _ = try engine.eval("__runProviderChat(\(AgentJSON.jsLiteral(json)))")
            } catch let error as XSError {
                finishOnce(throwing: error)
            } catch {
                finishOnce(throwing: error)
            }
        }
    }

    // MARK: - Event delivery (called from the XS thread via @_cdecl)

    fileprivate func emit(_ eventJSON: String) {
        guard let obj = Self.parse(eventJSON), let type = obj["type"] as? String else { return }
        lock.lock(); let cont = continuation; lock.unlock()
        switch type {
        case "textDelta":
            if let text = obj["text"] as? String { cont?.yield(.textDelta(text)) }
        case "reasoningDelta":
            if let text = obj["text"] as? String { cont?.yield(.reasoningDelta(text)) }
        case "toolCall":
            cont?.yield(.toolCall(
                id: obj["id"] as? String ?? UUID().uuidString,
                name: obj["name"] as? String ?? "",
                argumentsJSON: obj["arguments"] as? String ?? "{}",
                thoughtSignature: obj["thoughtSignature"] as? String))
        default:
            break
        }
    }

    fileprivate func done() { finishOnce(throwing: nil) }
    fileprivate func failed(_ message: String) { finishOnce(throwing: XSError(message: message)) }

    private func finishOnce(throwing error: Error?) {
        lock.lock(); let cont = continuation; continuation = nil; lock.unlock()
        if let error { cont?.finish(throwing: error) } else { cont?.finish() }
    }

    /// Clear the in-flight continuation on stream termination (cancellation),
    /// but only if a newer chat hasn't already taken over (token guard).
    private func clearContinuation(token: UInt64) {
        lock.lock()
        if token == callToken { continuation = nil }
        lock.unlock()
    }

    // MARK: - Encoding

    static func encode(_ m: ChatMessage) -> [String: Any] {
        var d: [String: Any] = ["role": roleString(m.role), "content": m.content]
        if let x = m.toolCallID { d["toolCallID"] = x }
        if let x = m.toolName { d["toolName"] = x }
        if let x = m.toolIsError { d["toolIsError"] = x }
        if let x = m.reasoningContent { d["reasoningContent"] = x }
        if let x = m.thoughtSignature { d["thoughtSignature"] = x }
        return d
    }

    static func encode(_ s: ToolSpec) -> [String: Any] {
        var schema: Any = [:]
        if let data = s.inputSchemaJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            schema = parsed
        }
        return ["name": s.name, "description": s.description, "input_schema": schema]
    }

    private static func roleString(_ r: ChatMessage.Role) -> String {
        switch r {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        case .toolCall: return "toolCall"
        case .toolResult: return "toolResult"
        }
    }

    private static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - C-callable entry points (installed by jsProviderHost.c)

private func provider(_ bridge: UnsafeMutableRawPointer) -> JSProvider? {
    guard let ctx = xsBridgeGetContext(bridge) else { return nil }
    return Unmanaged<JSProvider>.fromOpaque(ctx).takeUnretainedValue()
}

@_cdecl("xsbJSProviderEmit")
func xsbJSProviderEmit(_ bridge: UnsafeMutableRawPointer?, _ eventJSON: UnsafePointer<CChar>?) {
    guard let bridge, let p = provider(bridge) else { return }
    p.emit(eventJSON.map { String(cString: $0) } ?? "")
}

@_cdecl("xsbJSProviderDone")
func xsbJSProviderDone(_ bridge: UnsafeMutableRawPointer?) {
    guard let bridge, let p = provider(bridge) else { return }
    p.done()
}

@_cdecl("xsbJSProviderError")
func xsbJSProviderError(_ bridge: UnsafeMutableRawPointer?, _ message: UnsafePointer<CChar>?) {
    guard let bridge, let p = provider(bridge) else { return }
    p.failed(message.map { String(cString: $0) } ?? "provider error")
}
