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
        // Always reuse the cached instance. A provider factory is called per
        // SwiftUI render (including per streamed token, while a chat is in
        // flight): returning a fresh instance then would spin up a new XS engine
        // on every token. Re-renders only pass the provider around; the actual
        // chat() (sequential) is guarded separately, and a cancelled stream
        // self-heals via onTermination.
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

    /// Ollama's `/api/chat` (NDJSON stream, no auth) in JavaScript. `baseURL`
    /// is the server root (e.g. http://localhost:11434); `/api/chat` is appended.
    public static func ollama(model: String, baseURL: String) -> JSProvider? {
        cached(
            id: "ollama-js", displayName: "Ollama (JS)", providerJS: ollamaJS,
            config: ["apiKey": "", "model": model, "baseURL": baseURL])
    }

    static let ollamaJS = #"""
    (function () {
      function buildMessages(messages) {
        const out = [];
        for (const m of messages) {
          if (m.role === "system" || m.role === "user") {
            out.push({ role: m.role, content: m.content });
          } else if (m.role === "assistant") {
            out.push({ role: "assistant", content: m.content });
          } else if (m.role === "toolCall") {
            let args = {};
            try { args = JSON.parse(m.content || "{}"); } catch (e) {}
            const call = { function: { name: m.toolName, arguments: args } };
            const last = out[out.length - 1];
            if (last && last.role === "assistant") {
              if (!last.tool_calls) last.tool_calls = [];
              last.tool_calls.push(call);
            } else {
              out.push({ role: "assistant", content: "", tool_calls: [call] });
            }
          } else if (m.role === "toolResult") {
            out.push({ role: "tool", content: m.content });
          }
        }
        return out;
      }

      async function chat(req, onEvent) {
        const cfg = req.config || {};
        const base = (cfg.baseURL || "http://localhost:11434").replace(/\/+$/, "");
        const body = { model: cfg.model, stream: true, messages: buildMessages(req.messages || []) };
        if (req.tools && req.tools.length) {
          body.tools = req.tools.map((t) => ({
            type: "function",
            function: { name: t.name, description: t.description, parameters: t.input_schema },
          }));
        }

        await new Promise((resolve, reject) => {
          const xhr = new XMLHttpRequest();
          xhr.open("POST", base + "/api/chat");
          xhr.setRequestHeader("content-type", "application/json");

          let cursor = 0, buffer = "";
          let counter = 0;
          function processLine(raw) {
            const line = raw.trim();
            if (!line) return;
            let ev; try { ev = JSON.parse(line); } catch (e) { return; }
            if (ev.error) { reject(new Error(String(ev.error))); return; }
            const msg = ev.message;
            if (msg) {
              if (msg.content) onEvent({ type: "textDelta", text: msg.content });
              if (msg.tool_calls) {
                for (const tc of msg.tool_calls) {
                  const fn = tc.function || {};
                  const args = typeof fn.arguments === "string"
                    ? fn.arguments : JSON.stringify(fn.arguments || {});
                  onEvent({ type: "toolCall", id: "call_" + (counter++), name: fn.name, arguments: args });
                }
              }
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
            else reject(new Error("ollama HTTP " + xhr.status + ": " + xhr.responseText.slice(0, 500)));
          };
          xhr.onerror = (e) => reject(new Error("network error: " + e));
          xhr.send(JSON.stringify(body));
        });
      }

      globalThis.tyProvider = { chat };
    })();
    """#

    /// Google Gemini's `:streamGenerateContent?alt=sse` in JavaScript. `baseURL`
    /// defaults to the v1beta endpoint. The API key goes in `x-goog-api-key`.
    public static func google(apiKey: String, model: String, baseURL: String? = nil) -> JSProvider? {
        var config: [String: Any] = ["apiKey": apiKey, "model": model]
        if let baseURL { config["baseURL"] = baseURL }
        return cached(
            id: "google-js", displayName: "Google (JS)", providerJS: googleJS, config: config)
    }

    static let googleJS = #"""
    (function () {
      function sanitizeSchema(s) {
        if (Array.isArray(s)) return s.map(sanitizeSchema);
        if (s && typeof s === "object") {
          const out = {};
          for (const k of Object.keys(s)) {
            if (k === "additionalProperties" || k === "$schema" || k === "$id"
                || k === "$defs" || k === "definitions") continue;
            out[k] = sanitizeSchema(s[k]);
          }
          return out;
        }
        return s;
      }

      function buildContents(messages) {
        const nameByCallId = {};
        for (const m of messages) {
          if (m.role === "toolCall" && m.toolCallID) nameByCallId[m.toolCallID] = m.toolName;
        }
        const out = [];
        for (const m of messages) {
          if (m.role === "system") continue;
          if (m.role === "user") {
            out.push({ role: "user", parts: [{ text: m.content }] });
          } else if (m.role === "assistant") {
            if (m.content) out.push({ role: "model", parts: [{ text: m.content }] });
          } else if (m.role === "toolCall") {
            let args = {};
            try { args = JSON.parse(m.content || "{}"); } catch (e) {}
            const part = { functionCall: { name: m.toolName, args: args } };
            if (m.thoughtSignature) part.thoughtSignature = m.thoughtSignature;
            const last = out[out.length - 1];
            if (last && last.role === "model") last.parts.push(part);
            else out.push({ role: "model", parts: [part] });
          } else if (m.role === "toolResult") {
            const part = { functionResponse: {
              name: nameByCallId[m.toolCallID] || "",
              response: { content: m.content } } };
            const last = out[out.length - 1];
            if (last && last.role === "user" && last.parts[0] && last.parts[0].functionResponse) {
              last.parts.push(part);
            } else {
              out.push({ role: "user", parts: [part] });
            }
          }
        }
        return out;
      }

      async function chat(req, onEvent) {
        const cfg = req.config || {};
        const base = (cfg.baseURL || "https://generativelanguage.googleapis.com/v1beta")
          .replace(/\/+$/, "");
        const messages = req.messages || [];
        const systemBits = messages.filter((m) => m.role === "system").map((m) => m.content);
        const body = { contents: buildContents(messages) };
        if (systemBits.length) body.systemInstruction = { parts: [{ text: systemBits.join("\n\n") }] };
        if (req.tools && req.tools.length) {
          body.tools = [{ functionDeclarations: req.tools.map((t) => ({
            name: t.name, description: t.description, parameters: sanitizeSchema(t.input_schema),
          })) }];
        }

        await new Promise((resolve, reject) => {
          const xhr = new XMLHttpRequest();
          xhr.open("POST", base + "/models/" + encodeURIComponent(cfg.model)
            + ":streamGenerateContent?alt=sse");
          xhr.setRequestHeader("content-type", "application/json");
          xhr.setRequestHeader("x-goog-api-key", cfg.apiKey || "");

          let cursor = 0, buffer = "", counter = 0;
          function processLine(raw) {
            const line = raw.replace(/\r$/, "");
            if (!line.startsWith("data:")) return;
            const payload = line.slice(5).trim();
            if (!payload) return;
            let ev; try { ev = JSON.parse(payload); } catch (e) { return; }
            if (ev.error) { reject(new Error((ev.error && ev.error.message) || "gemini error")); return; }
            const cand = ev.candidates && ev.candidates[0];
            const parts = (cand && cand.content && cand.content.parts) || [];
            for (const p of parts) {
              if (typeof p.text === "string") onEvent({ type: "textDelta", text: p.text });
              if (p.functionCall) {
                onEvent({ type: "toolCall", id: "call_" + (counter++),
                  name: p.functionCall.name,
                  arguments: JSON.stringify(p.functionCall.args || {}),
                  thoughtSignature: p.thoughtSignature });
              }
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
            else reject(new Error("gemini HTTP " + xhr.status + ": " + xhr.responseText.slice(0, 500)));
          };
          xhr.onerror = (e) => reject(new Error("network error: " + e));
          xhr.send(JSON.stringify(body));
        });
      }

      globalThis.tyProvider = { chat };
    })();
    """#

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
