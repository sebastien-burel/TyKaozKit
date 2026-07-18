import Foundation
import XSBridge
import XSBridgeKit
import TyKaozHostC

/// Runs a supervisor agent that delegates to a sub-agent over the multi-machine
/// service layer (Part D). The sub-agent runs in its own XS engine exposed as a
/// service; the supervisor calls it JS-to-JS as `await service.run(input)`, with
/// values crossing as alien-marshalled data — no Swift round-trip and no shared
/// engine preparation. Both are plain JS agents that define `globalThis.run`.
public enum MultiAgent {

    /// - Returns: the supervisor's result as a JSON string, or nil on engine
    ///   creation failure.
    public static func superviseRun(
        supervisor: String,
        subAgent: String,
        input: Any? = nil,
        timeout: TimeInterval = 15
    ) -> String? {
        guard let sub = XSEngine(), let sup = XSEngine() else { return nil }

        // Sub-agent = service server: its run(input) answers incoming calls.
        sub.installServiceServer()
        _ = try? sub.eval(subAgent)
        _ = try? sub.eval(
            "globalThis.__serviceHandler = function (method, args) { return globalThis.run(args); };")

        // Supervisor = service client, linked to the sub-agent.
        sup.withMachine { xsBridgeServiceClientInstall($0) }
        sup.linkService(to: sub)
        _ = try? sup.eval(supervisor)

        let inputJSON = AgentJSON.string(input ?? NSNull())
        _ = try? sup.eval("""
            globalThis.__result = 'pending';
            Promise.resolve(globalThis.run(\(inputJSON)))
                .then(function (r) { globalThis.__result = r; })
                .catch(function (e) { globalThis.__result = { error: String((e && e.stack) || e) }; });
            """)
        sup.runUntilIdle(timeout: timeout)
        return try? sup.eval("globalThis.__result")
    }
}
