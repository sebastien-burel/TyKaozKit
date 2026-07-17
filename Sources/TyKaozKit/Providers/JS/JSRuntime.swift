import Foundation
import XSBridgeKit
import TyKaozHostC

/// Shared JavaScript snippets and helpers for the JS-first runtime (providers
/// written in JavaScript on top of the native `__http` primitive).
enum JSRuntime {

    /// A minimal `XMLHttpRequest` implemented over the native `__http(request,
    /// onChunk)` primitive. Supports the subset LLM providers need: open /
    /// setRequestHeader / send, `onprogress` (streamed body via `responseText`),
    /// `onload` / `onerror`, `status`, `readyState`. Response body is delivered
    /// as chunks so SSE parsers can consume `responseText` incrementally.
    static let xmlHttpRequestShim = #"""
    globalThis.XMLHttpRequest = class XMLHttpRequest {
      constructor() {
        this.readyState = 0;
        this.status = 0;
        this.responseText = "";
        this._headers = {};
        this._responseHeaders = {};
        this.onprogress = null;
        this.onload = null;
        this.onerror = null;
        this.onreadystatechange = null;
      }
      _setState(s) {
        this.readyState = s;
        if (this.onreadystatechange) this.onreadystatechange();
      }
      open(method, url) {
        this._method = method;
        this._url = url;
        this._setState(1);
      }
      setRequestHeader(key, value) { this._headers[key] = value; }
      getAllResponseHeaders() {
        return Object.keys(this._responseHeaders)
          .map((k) => k + ": " + this._responseHeaders[k]).join("\r\n");
      }
      getResponseHeader(name) {
        const lower = String(name).toLowerCase();
        for (const k of Object.keys(this._responseHeaders)) {
          if (k.toLowerCase() === lower) return this._responseHeaders[k];
        }
        return null;
      }
      send(body) {
        const req = {
          method: this._method || "GET",
          url: this._url,
          headers: this._headers,
          body: body == null ? null : String(body),
        };
        __http(req, (chunk) => {
          this.responseText += chunk;
          this._setState(3);
          if (this.onprogress) this.onprogress();
        }).then((res) => {
          this.status = res.status;
          this._responseHeaders = res.headers || {};
          this._setState(4);
          if (this.onload) this.onload();
        }).catch((err) => {
          this.status = 0;
          this._setState(4);
          if (this.onerror) this.onerror(err);
        });
      }
      abort() {}
    };
    """#

    /// Drives a JS-authored provider (`globalThis.tyProvider.chat(request,
    /// onEvent)`) and bridges its outcome to Swift via `__emit` / `__done` /
    /// `__providerError`. Installed once per JSProvider engine.
    static let providerOrchestrator = #"""
    globalThis.__runProviderChat = function(requestJSON) {
      let req;
      try { req = JSON.parse(requestJSON); }
      catch (e) { __providerError("invalid provider request JSON"); return; }
      Promise.resolve()
        .then(() => {
          if (!globalThis.tyProvider || typeof globalThis.tyProvider.chat !== "function") {
            throw new Error("provider module did not define tyProvider.chat");
          }
          return globalThis.tyProvider.chat(req, (event) => { __emit(event); });
        })
        .then(() => { __done(); })
        .catch((err) => { __providerError(String((err && err.stack) || err)); });
    };
    """#
}

/// A tiny harness to exercise the native `__http` primitive + the
/// `XMLHttpRequest` shim in isolation, without a provider or an LLM. Creates a
/// bare engine, installs `__http`, evals the shim then `script`, waits until
/// idle, and returns the JSON value the script left on `globalThis.__result`.
public enum JSHttpProbe {
    public static func run(script: String, timeout: TimeInterval = 15) -> String? {
        guard let engine = XSEngine() else { return nil }
        engine.withMachine { xsBridgeHttpInstall($0) }
        _ = try? engine.eval(JSRuntime.xmlHttpRequestShim)
        _ = try? engine.eval(script)
        engine.runUntilIdle(timeout: timeout)
        return try? engine.eval("JSON.stringify(globalThis.__result ?? null)")
    }
}
