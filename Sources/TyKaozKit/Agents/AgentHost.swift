import Foundation
import XSBridgeKit
import XSBridge   // xsBridgeAddModuleRoot / xsBridgeClearModuleRoots (module roots)

/// A **resident** agent: one `XSEngine` kept alive across many deliveries.
///
/// Unlike the one-shot `AgentSession` (run → report → teardown), the engine and
/// its JS heap persist between calls. The agent module is imported once; each
/// `deliver(kind:payload:)` routes to its handler (`onMessage`/`onEvent`/
/// `onTick`, or a legacy `run`/default function) and settles that one delivery
/// by id — the engine stays alive for the next one, so JS-side state (counters,
/// conversation, caches) survives across turns.
///
/// Thread model unchanged: all XS access is marshalled onto the engine's
/// dedicated run-loop thread; `deliver` is `async` and returns the handler's
/// JSON result. Deliveries may overlap (each awaits its own id) — the JS side is
/// single-threaded, so handlers interleave only at `await` boundaries, exactly
/// like a browser event loop.
public nonisolated final class AgentHost {

    private let engine: XSEngine
    private let host: TyKaozHost

    private let lock = NSLock()
    private var pending: [UInt32: CheckedContinuation<String, Error>] = [:]
    private var nextId: UInt32 = 1
    private var closed = false

    /// Create a resident agent from a bare entry specifier resolved against
    /// `roots` (Moddable-style, like `AgentRuntime.runRooted`). Returns nil if
    /// the engine can't be created. The module is imported once, kept alive.
    public init?(
        entryModule: String,
        roots: [(prefix: String, dir: String)],
        makeProvider: @escaping @Sendable () -> (any LLMProvider)?,
        resolveProvider: (@Sendable (String, [String: Any]) -> (any LLMProvider)?)? = nil,
        providerCatalog: [ProviderDescriptor] = [],
        tools: ToolRegistry,
        memory: MemoryStoring,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        // Sub-agents spawned from JS share this host wiring.
        TyKaozThreads.register { [makeProvider, resolveProvider, providerCatalog, tools, memory, log] in
            TyKaozHost(
                makeProvider: makeProvider, resolveProvider: resolveProvider,
                providerCatalog: providerCatalog, tools: tools, memory: memory, log: log)
        }
        let host = TyKaozHost(
            makeProvider: makeProvider, resolveProvider: resolveProvider,
            providerCatalog: providerCatalog, tools: tools, memory: memory, log: log)
        self.host = host
        guard let engine = XSEngine.tyKaoz(host: host) else { return nil }
        self.engine = engine
        engine.installThreads()   // `Thread` / `Service` globals for JS-initiated spawn
        engine.withMachine { _ in
            xsBridgeClearModuleRoots()
            for root in roots { xsBridgeAddModuleRoot(root.prefix, root.dir) }
        }
        wireDelivery()
        // Import the agent module once — import() resolves within the eval drain,
        // so __agent/__agentReady are set (or in flight) by the time this returns.
        _ = try? engine.eval("__loadAgent(\(AgentJSON.jsLiteral(entryModule)))")
    }

    private func wireDelivery() {
        host.onDeliverResult = { [weak self] id, json, isError in
            guard let self else { return }
            self.lock.lock()
            let cont = self.pending.removeValue(forKey: id)
            self.lock.unlock()
            guard let cont else { return }
            if isError { cont.resume(throwing: AgentError.script(json)) }
            else { cont.resume(returning: json) }
        }
    }

    /// Deliver one event to the resident agent and await its handler's JSON
    /// result. `kind`: `"message"` (→ onMessage/run), `"event"` (→ onEvent),
    /// `"tick"` (→ onTick). Throws `AgentError.script` if the handler rejects.
    @discardableResult
    public func deliver(kind: String = "message", payload: Any? = nil) async throws -> String {
        let id: UInt32 = {
            lock.lock(); defer { lock.unlock() }
            let v = nextId; nextId &+= 1; return v
        }()
        let inputJSON = AgentJSON.string(payload ?? NSNull())
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if closed {
                lock.unlock()
                cont.resume(throwing: AgentError.script("agent host closed"))
                return
            }
            pending[id] = cont
            lock.unlock()
            // Kicks off the handler on the XS thread; the promise settles later
            // via host.__deliverResult → onDeliverResult → this continuation.
            do {
                _ = try engine.eval(
                    "__deliver(\(AgentJSON.jsLiteral(kind)), \(id), "
                    + "\(AgentJSON.jsLiteral(inputJSON)))")
            } catch {
                lock.lock(); pending.removeValue(forKey: id); lock.unlock()
                cont.resume(throwing: error)
            }
        }
    }

    /// Number of async host calls still in flight on this engine (0 == idle).
    public var pendingCount: Int { engine.pendingCount }

    /// Drain to idle, fail any still-pending deliveries, and stop accepting new
    /// ones. The engine itself is released when this `AgentHost` is deallocated
    /// (its deinit joins the XS thread, so drop the last reference off it).
    public func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let orphans = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for cont in orphans { cont.resume(throwing: AgentError.script("agent host closed")) }
        host.onDeliverResult = nil
        let engine = self.engine
        DispatchQueue.global().async {
            engine.runUntilIdle(timeout: 2)
            withExtendedLifetime(engine) {}
        }
    }
}
