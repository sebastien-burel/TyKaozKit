# TyKaozKit

TyKaoz's reusable business layer on top of
[XSBridgeKit](https://github.com/sebastien-burel/XSBridgeKit) — the package that
embeds the **XS (Moddable)** JavaScript engine and bridges JS ↔ Swift
(sync / async / streaming) on macOS.

TyKaozKit carries the parts of TyKaoz that aren't UI: the **JavaScript agent
runtime**, the **LLM providers**, and the **tools**. The TyKaoz app imports it;
so does `TyKaozCli`, a headless runner for autonomous agents. It absorbs the
former standalone `TyKaozHostC` package as an internal C target (the XS host
functions).

## Layers

```
XSBridgeKit   engine + Swift↔JS bridge (XSEngine, the flat C settle functions)
   ▲
TyKaozKit     agent runtime · providers · tools · MemoryStoring   (this package)
   ├── TyKaozHostC   C host functions (host.log/__chat/tool.*/memory.*)
   └── TyKaozCli     headless runner for autonomous JS agents
   ▲
TyKaoz.app    SwiftUI UI · wiki/RAG · model & tool testing
```

## What's inside

- **Agent runtime** (`Sources/TyKaozKit/Agents/`) — `AgentRuntime.run(script:…)`
  stages a JS agent (a module exporting `run(input)`), creates one XS engine via
  `XSEngine.tyKaoz(host:)`, installs `host.*`, and reports the result through
  `host.__report` / `host.__fail`. Everything crossing JS ↔ Swift is UTF-8 JSON
  or an opaque call id — never an `xsSlot`.
- **Providers** (`Sources/TyKaozKit/Providers/`) — the external LLM backends
  (Anthropic, OpenAI, OpenAI-compatible, Google, Ollama, Mistral, DeepSeek,
  Qwen, Z.AI, LocalOpenAI, ComfyUI) behind the `LLMProvider` protocol. Local
  runtimes (MLX, Apple Foundation Models) stay in the app.
- **Tools** (`Sources/TyKaozKit/Tools/`) — `Tool` / `ToolRegistry` plus the
  concrete tools (`fetch_url`, `web_search`, dates, files, memory, HTTP plugins,
  location). Wiki tools stay in the app.
- **Seam** — `MemoryStoring`: the runtime and the memory tools depend on this
  protocol, so a consumer injects its own store (the app's `MemoryStore`, or the
  CLI's file-backed `CLIMemoryStore`).

## Setup

Not standalone: it compiles the XS host functions against **XSBridgeKit's**
already-linked XS headers, with **byte-identical** XS compile defines (the
`txMachine` ABI depends on them). Check out **XSBridgeKit as a sibling
directory** and link its XS tree once, then link TyKaozKit at it:

```sh
# 1. XSBridgeKit first (symlinks the Moddable XS sources it compiles)
cd ../XSBridgeKit && export MODDABLE=/path/to/moddable && ./scripts/link-moddable.sh

# 2. Point TyKaozKit's C target at that tree (creates the git-ignored vendor/ links)
cd ../TyKaozKit && ./scripts/link.sh
swift build
```

`vendor/`, `.build/` and `.swiftpm/` are git-ignored; run `scripts/link.sh`
after cloning.

## TyKaozCli

Runs a standalone JS agent headless. The agent drives the LLM, tools and memory
through `host.*` and returns a value (reported as a JSON string on stdout).

```sh
# provider-free (native tool path only — no API key needed)
swift run TyKaozCli samples/tool-agent.js --input '{"hello":"world"}'

# with an LLM provider
ANTHROPIC_API_KEY=… swift run TyKaozCli myagent.js \
  --provider anthropic --model <model-id> --input '{"q":"…"}'
```

Options: `--provider anthropic|local`, `--model`, `--input <json>`,
`--library <dir>` (folder the agent may `import "./x.js"` from), `--timeout`.
Environment: `ANTHROPIC_API_KEY`, `TYKAOZ_LOCAL_BASE_URL` /
`TYKAOZ_LOCAL_API_KEY`, `TYKAOZ_MODEL`, `BRAVE_API_KEY` (enables `web_search`),
`TYKAOZ_MEMORY_FILE`.

## Requirements

macOS 26 (Apple Silicon), a recent Swift toolchain, and a local Moddable
checkout (via `$MODDABLE`) for XSBridgeKit's XS sources.
