import Foundation

/// Materializes an agent run's module graph on disk so the XS engine's
/// filesystem module loader can import it. The agent script is written as
/// `agent.js`, and the user's chosen libraries folder (the confinement
/// boundary) is copied next to it so relative imports (`./util.js`) resolve.
///
/// Confinement note: only files under `libraryRoot` are copied, so relative
/// imports can't escape it; absolute-path imports (`import "/…"`) are NOT
/// blocked by the engine's loader (accepted tradeoff — see the migration plan).
/// The staging dir is removed after the run.
public nonisolated struct AgentModuleStaging {
    public let root: URL
    /// Absolute path of the staged agent module (import target).
    public let agentPath: String

    public init(agentSource: String, libraryRoot: URL?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "tykaoz-agent-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        if let lib = libraryRoot?.standardizedFileURL,
           let items = try? fm.contentsOfDirectory(
               at: lib, includingPropertiesForKeys: nil) {
            for item in items {
                try? fm.copyItem(at: item, to: root.appending(path: item.lastPathComponent))
            }
        }

        let agentURL = root.appending(path: "agent.js")
        try agentSource.write(to: agentURL, atomically: true, encoding: .utf8)

        self.root = root
        self.agentPath = agentURL.path
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// JS installed once per engine (via `eval`) to provide the ergonomic
/// `host.llm.chat` wrapper over the C primitive `host.__chat`, plus the
/// `__runAgent` / `__callTool` orchestrators that drive an agent or a JS tool
/// and report back through the C host functions `host.__report` / `__fail` /
/// `__toolResult`.
public nonisolated enum AgentOrchestrator {
    public static let js = """
    (function () {
      host.llm = {
        chat: function (messages, opts, onToken) {
          if (typeof opts === 'function') { onToken = opts; opts = {}; }
          opts = opts || {};
          if (typeof onToken !== 'function') onToken = function () {};
          return host.__chat(messages, opts.tools || [], onToken);
        }
      };

      globalThis.__runAgent = function (path, inputJSON) {
        var input = JSON.parse(inputJSON);
        import(path)
          .then(function (ns) {
            var run = (ns && (ns.run || ns.default)) || globalThis.run;
            if (typeof run !== 'function')
              throw new Error("l'agent ne définit pas run(input)");
            return run(input);
          })
          .then(function (r) {
            host.__report(JSON.stringify(r === undefined ? null : r));
          })
          .catch(function (e) {
            host.__fail(String((e && e.stack) || e));
          });
      };

      globalThis.__callTool = function (name, argsJSON, callId) {
        var list = globalThis.tools || [];
        var tool = list.find(function (t) { return t.name === name; });
        if (!tool || typeof tool.run !== 'function') {
          host.__toolResult(callId, null, 'unknown tool: ' + name);
          return;
        }
        Promise.resolve()
          .then(function () { return tool.run(JSON.parse(argsJSON)); })
          .then(function (r) {
            host.__toolResult(callId, JSON.stringify(r === undefined ? null : r), null);
          })
          .catch(function (e) {
            host.__toolResult(callId, null, String((e && e.stack) || e));
          });
      };
    })();
    """
}
