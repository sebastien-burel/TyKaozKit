import Foundation

/// Factories for the JS-authored providers, plus the embedded provider modules.
/// Each module sets `globalThis.tyProvider = { chat(request, onEvent) }` and
/// uses the native `XMLHttpRequest` shim for HTTP + SSE. Config
/// (`apiKey`/`model`/`baseURL`) is passed per request via `request.config`.
public enum JSProviders {

    // A JSProvider owns an XS engine, so creating one per SwiftUI render (as a
    // provider factory called in `body` does) would spin up a machine on every
    // token. Cache instances by their config so repeated builds reuse the same
    // engine; the per-request payload (messages/tools) is passed at chat time,
    // not baked into the engine.
    private static let cacheLock = NSLock()
    private static var cache: [String: JSProvider] = [:]

    private static func cached(
        id: String, displayName: String, providerJS: String, config: [String: Any]
    ) -> JSProvider? {
        let key = [id,
                   (config["apiKey"] as? String) ?? "",
                   (config["model"] as? String) ?? "",
                   (config["baseURL"] as? String) ?? ""].joined(separator: "\u{1}")
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = cache[key] { return existing }
        guard let provider = JSProvider(
            id: id, displayName: displayName, providerJS: providerJS, config: config)
        else { return nil }
        cache[key] = provider
        return provider
    }


    /// Anthropic Messages API, written in JavaScript (the JS-first counterpart
    /// of the Swift `AnthropicProvider`). `baseURL` overrides the endpoint (for
    /// tests / proxies); defaults to https://api.anthropic.com.
    public static func anthropic(apiKey: String, model: String, baseURL: String? = nil) -> JSProvider? {
        var config: [String: Any] = ["apiKey": apiKey, "model": model]
        if let baseURL { config["baseURL"] = baseURL }
        return cached(
            id: "anthropic-js", displayName: "Anthropic (JS)",
            providerJS: anthropicJS, config: config)
    }

    /// OpenAI Chat Completions API, written in JavaScript. `baseURL` overrides
    /// the endpoint host (default https://api.openai.com); the path
    /// `/v1/chat/completions` is appended.
    public static func openai(apiKey: String, model: String, baseURL: String? = nil) -> JSProvider? {
        var config: [String: Any] = ["apiKey": apiKey, "model": model]
        if let baseURL { config["baseURL"] = baseURL }
        return cached(
            id: "openai-js", displayName: "OpenAI (JS)",
            providerJS: openaiJS, config: config)
    }

    /// Any OpenAI-compatible Chat Completions endpoint, in JavaScript (Mistral,
    /// DeepSeek, Qwen, Z.AI, local servers…). `baseURL` must include the API
    /// version path (e.g. `https://api.mistral.ai/v1`); `/chat/completions` is
    /// appended.
    public static func openaiCompatible(
        id: String, displayName: String, apiKey: String, model: String, baseURL: String
    ) -> JSProvider? {
        cached(
            id: id, displayName: displayName, providerJS: openaiJS,
            config: ["apiKey": apiKey, "model": model, "baseURL": baseURL])
    }

    static let openaiJS = #"""
    (function () {
      function buildMessages(messages) {
        const out = [];
        for (const m of messages) {
          if (m.role === "system") { out.push({ role: "system", content: m.content }); continue; }
          if (m.role === "user") { out.push({ role: "user", content: m.content }); continue; }
          if (m.role === "assistant") { out.push({ role: "assistant", content: m.content }); continue; }
          if (m.role === "toolCall") {
            const tc = { id: m.toolCallID, type: "function",
                         function: { name: m.toolName, arguments: m.content || "{}" } };
            const last = out[out.length - 1];
            if (last && last.role === "assistant") {
              if (!last.tool_calls) last.tool_calls = [];
              last.tool_calls.push(tc);
            } else {
              out.push({ role: "assistant", content: null, tool_calls: [tc] });
            }
            continue;
          }
          if (m.role === "toolResult") {
            out.push({ role: "tool", tool_call_id: m.toolCallID, content: m.content });
            continue;
          }
        }
        return out;
      }

      async function chat(req, onEvent) {
        const cfg = req.config || {};
        // baseURL includes the API version path (…/v1, …/v4); we append the route.
        const base = (cfg.baseURL || "https://api.openai.com/v1").replace(/\/+$/, "");
        const body = { model: cfg.model, stream: true, messages: buildMessages(req.messages || []) };
        if (req.tools && req.tools.length) {
          body.tools = req.tools.map((t) => ({
            type: "function",
            function: { name: t.name, description: t.description, parameters: t.input_schema },
          }));
        }

        await new Promise((resolve, reject) => {
          const xhr = new XMLHttpRequest();
          xhr.open("POST", base + "/chat/completions");
          xhr.setRequestHeader("content-type", "application/json");
          xhr.setRequestHeader("authorization", "Bearer " + (cfg.apiKey || ""));

          let cursor = 0, buffer = "";
          const toolCalls = {};

          function flushTools() {
            for (const i of Object.keys(toolCalls)) {
              const t = toolCalls[i];
              onEvent({ type: "toolCall", id: t.id || ("call_" + i), name: t.name, arguments: t.args || "{}" });
              delete toolCalls[i];
            }
          }
          function processLine(raw) {
            const line = raw.replace(/\r$/, "");
            if (!line.startsWith("data:")) return;
            const payload = line.slice(5).trim();
            if (!payload) return;
            if (payload === "[DONE]") { flushTools(); return; }
            let ev; try { ev = JSON.parse(payload); } catch (e) { return; }
            const choice = ev.choices && ev.choices[0];
            if (!choice) return;
            const delta = choice.delta || {};
            if (delta.content) onEvent({ type: "textDelta", text: delta.content });
            if (delta.reasoning_content) onEvent({ type: "reasoningDelta", text: delta.reasoning_content });
            if (delta.tool_calls) {
              for (const tc of delta.tool_calls) {
                const i = tc.index || 0;
                if (!toolCalls[i]) toolCalls[i] = { id: "", name: "", args: "" };
                if (tc.id) toolCalls[i].id = tc.id;
                if (tc.function) {
                  if (tc.function.name) toolCalls[i].name = tc.function.name;
                  if (tc.function.arguments) toolCalls[i].args += tc.function.arguments;
                }
              }
            }
            if (choice.finish_reason === "tool_calls") flushTools();
          }

          xhr.onprogress = () => {
            buffer += xhr.responseText.slice(cursor);
            cursor = xhr.responseText.length;
            let idx;
            while ((idx = buffer.indexOf("\n")) >= 0) {
              processLine(buffer.slice(0, idx));
              buffer = buffer.slice(idx + 1);
            }
          };
          xhr.onload = () => {
            if (buffer) processLine(buffer);
            flushTools();
            if (xhr.status >= 200 && xhr.status < 300) resolve();
            else reject(new Error("openai HTTP " + xhr.status + ": " + xhr.responseText.slice(0, 500)));
          };
          xhr.onerror = (e) => reject(new Error("network error: " + e));
          xhr.send(JSON.stringify(body));
        });
      }

      globalThis.tyProvider = { chat };
    })();
    """#

    static let anthropicJS = #"""
    (function () {
      // Map our neutral ChatMessage[] to Anthropic's messages + system.
      function buildMessages(messages) {
        let system = "";
        const out = [];
        for (const m of messages) {
          if (m.role === "system") { system += (system ? "\n" : "") + m.content; continue; }
          if (m.role === "user") { out.push({ role: "user", content: m.content }); continue; }
          if (m.role === "assistant") { out.push({ role: "assistant", content: m.content }); continue; }
          if (m.role === "toolCall") {
            let input = {};
            try { input = JSON.parse(m.content || "{}"); } catch (e) {}
            const block = { type: "tool_use", id: m.toolCallID, name: m.toolName, input };
            const last = out[out.length - 1];
            if (last && last.role === "assistant") {
              if (typeof last.content === "string") {
                last.content = last.content ? [{ type: "text", text: last.content }] : [];
              }
              last.content.push(block);
            } else {
              out.push({ role: "assistant", content: [block] });
            }
            continue;
          }
          if (m.role === "toolResult") {
            out.push({ role: "user", content: [{
              type: "tool_result",
              tool_use_id: m.toolCallID,
              content: m.content,
              is_error: !!m.toolIsError,
            }]});
            continue;
          }
        }
        return { system, messages: out };
      }

      async function chat(req, onEvent) {
        const cfg = req.config || {};
        const base = (cfg.baseURL || "https://api.anthropic.com").replace(/\/+$/, "");
        const built = buildMessages(req.messages || []);
        const body = {
          model: cfg.model,
          max_tokens: cfg.maxTokens || 4096,
          stream: true,
          messages: built.messages,
        };
        if (built.system) body.system = built.system;
        if (req.tools && req.tools.length) {
          body.tools = req.tools.map((t) => ({
            name: t.name, description: t.description, input_schema: t.input_schema,
          }));
        }

        await new Promise((resolve, reject) => {
          const xhr = new XMLHttpRequest();
          xhr.open("POST", base + "/v1/messages");
          xhr.setRequestHeader("content-type", "application/json");
          xhr.setRequestHeader("x-api-key", cfg.apiKey || "");
          xhr.setRequestHeader("anthropic-version", "2023-06-01");

          let cursor = 0;
          let buffer = "";
          const toolBlocks = {};

          function processLine(raw) {
            const line = raw.replace(/\r$/, "");
            if (!line.startsWith("data:")) return;
            const payload = line.slice(5).trim();
            if (!payload || payload === "[DONE]") return;
            let ev;
            try { ev = JSON.parse(payload); } catch (e) { return; }
            if (ev.type === "content_block_start" && ev.content_block && ev.content_block.type === "tool_use") {
              toolBlocks[ev.index] = { id: ev.content_block.id, name: ev.content_block.name, json: "" };
            } else if (ev.type === "content_block_delta" && ev.delta) {
              if (ev.delta.type === "text_delta") {
                onEvent({ type: "textDelta", text: ev.delta.text });
              } else if (ev.delta.type === "thinking_delta") {
                onEvent({ type: "reasoningDelta", text: ev.delta.thinking || "" });
              } else if (ev.delta.type === "input_json_delta") {
                const b = toolBlocks[ev.index];
                if (b) b.json += ev.delta.partial_json || "";
              }
            } else if (ev.type === "content_block_stop") {
              const b = toolBlocks[ev.index];
              if (b) {
                onEvent({ type: "toolCall", id: b.id, name: b.name, arguments: b.json || "{}" });
                delete toolBlocks[ev.index];
              }
            } else if (ev.type === "error") {
              reject(new Error((ev.error && ev.error.message) || "anthropic error"));
            }
          }

          xhr.onprogress = () => {
            buffer += xhr.responseText.slice(cursor);
            cursor = xhr.responseText.length;
            let idx;
            while ((idx = buffer.indexOf("\n")) >= 0) {
              processLine(buffer.slice(0, idx));
              buffer = buffer.slice(idx + 1);
            }
          };
          xhr.onload = () => {
            if (buffer) processLine(buffer);
            if (xhr.status >= 200 && xhr.status < 300) resolve();
            else reject(new Error("anthropic HTTP " + xhr.status + ": " + xhr.responseText.slice(0, 500)));
          };
          xhr.onerror = (e) => reject(new Error("network error: " + e));
          xhr.send(JSON.stringify(body));
        });
      }

      globalThis.tyProvider = { chat };
    })();
    """#
}
