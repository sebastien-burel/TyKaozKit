import Foundation
import XSBridgeKit

public enum AgentError: Error, LocalizedError {
    case engineCreationFailed
    case evaluation(String)
    /// The agent's own `run(input)` threw or rejected.
    case script(String)
    /// The agent did not settle within its time budget.
    case timeout

    public var errorDescription: String? {
        switch self {
        case .engineCreationFailed: return "Impossible de créer le moteur JavaScript."
        case .evaluation(let m):    return "Erreur d'évaluation : \(m)"
        case .script(let m):        return m
        case .timeout:              return "L'agent n'a pas terminé dans le délai imparti."
        }
    }
}

/// Runs a standalone JavaScript agent: a module that exports
/// `async function run(input)` (or `default`) and drives the LLM, tools and
/// memory through `host.*`. One engine per run, torn down when the agent
/// finishes. The agent's returned value is reported via `host.__report`
/// (success) or `host.__fail` (throw/rejection); `run` returns it as a JSON
/// string (a string result comes back JSON-quoted).
public nonisolated final class AgentRuntime {

    private let makeProvider: @Sendable () -> (any LLMProvider)?
    private let tools: ToolRegistry
    private let memory: MemoryStoring
    private let log: @Sendable (String) -> Void

    public init(
        makeProvider: @escaping @Sendable () -> (any LLMProvider)?,
        tools: ToolRegistry,
        memory: MemoryStoring,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.makeProvider = makeProvider
        self.tools = tools
        self.memory = memory
        self.log = log
    }

    /// - Parameter libraryRoot: folder whose `.js` files the agent may `import`
    ///   with explicit relative specifiers (`./util.js`); nil disables imports.
    public func run(
        script: String,
        input: Any? = nil,
        timeout: TimeInterval = 10,
        libraryRoot: URL? = nil
    ) async throws -> String {
        let staging = try AgentModuleStaging(agentSource: script, libraryRoot: libraryRoot)
        // Enable JS-initiated spawn: a script may `new Thread()` + `new Service()`
        // to run sub-agents, each a child engine with this same host wiring.
        TyKaozThreads.register { [makeProvider, tools, memory, log] in
            TyKaozHost(makeProvider: makeProvider, tools: tools, memory: memory, log: log)
        }
        let host = TyKaozHost(
            makeProvider: makeProvider, tools: tools, memory: memory, log: log)
        return try await withCheckedThrowingContinuation { continuation in
            let session = AgentSession(host: host, staging: staging, continuation: continuation)
            session.start(input: input, timeout: timeout)
        }
    }
}

/// Owns one engine + host for the lifetime of a single agent run. Retains
/// itself until the continuation is resumed, then releases the engine off the
/// XS thread (its deinit joins that thread, so it must not run on it).
private nonisolated final class AgentSession {

    private let host: TyKaozHost
    private let staging: AgentModuleStaging
    private var engine: XSEngine?
    private var continuation: CheckedContinuation<String, Error>?
    private var selfRef: AgentSession?
    private var timeoutItem: DispatchWorkItem?
    private let lock = NSLock()

    init(host: TyKaozHost, staging: AgentModuleStaging,
         continuation: CheckedContinuation<String, Error>) {
        self.host = host
        self.staging = staging
        self.continuation = continuation
    }

    func start(input: Any?, timeout: TimeInterval) {
        selfRef = self

        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.complete(.failure(AgentError.timeout))
        }
        self.timeoutItem = timeoutItem
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        host.onReport = { [weak self] result in self?.complete(.success(result)) }
        host.onFail = { [weak self] err in self?.complete(.failure(AgentError.script(err))) }

        guard let engine = XSEngine.tyKaoz(host: host) else {
            complete(.failure(AgentError.engineCreationFailed))
            return
        }
        self.engine = engine
        engine.installThreads()   // `Thread` / `Service` globals for JS-initiated spawn

        do {
            // The staged agent runs in module goal (dynamic import in __runAgent),
            // so it can use static `import ... from`.
            let inputJSON = AgentJSON.string(input ?? NSNull())
            _ = try engine.eval(
                "__runAgent(\(AgentJSON.jsLiteral(staging.agentPath)), "
                + "\(AgentJSON.jsLiteral(inputJSON)))")
        } catch let error as XSError {
            complete(.failure(AgentError.evaluation(error.message)))
        } catch {
            complete(.failure(error))
        }
    }

    /// Resume the continuation at most once, then tear down.
    private func complete(_ result: Result<String, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let engine = self.engine
        self.engine = nil
        lock.unlock()

        timeoutItem?.cancel()
        timeoutItem = nil
        continuation.resume(with: result)
        host.onReport = nil
        host.onFail = nil

        let staging = self.staging
        // Release the engine off the XS thread (its deinit joins that thread,
        // which would deadlock if we're on it now — __report fires there). Drain
        // the run loop so the reporting call settles before the machine is
        // deleted, then drop the last reference and clean up the staging dir.
        if let engine {
            DispatchQueue.global().async {
                engine.runUntilIdle(timeout: 2)
                withExtendedLifetime(engine) {}
                staging.cleanup()
            }
        } else {
            staging.cleanup()
        }
        selfRef = nil
    }
}
