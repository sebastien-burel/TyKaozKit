/*
 * tykaozHost.c — TyKaoz's C host functions for the XS engine.
 *
 * Written against the classic xs.h API (pattern: XSBridgeKit's xsBridgeCliC).
 * Each host function marshals its arguments to plain C and calls a Swift
 * @_cdecl counterpart; async ones create their Promise via xsBridgePromise and
 * are settled later with xsBridgeComplete / xsBridgeEmitToken. The Swift host
 * object is recovered from the bridge context (xsBridgeGetContext), which
 * TyKaoz sets to its host pointer after install.
 *
 * The nested host.* structure (host.tool.*, host.memory.*) is built here; the
 * ergonomic host.llm.chat wrapper + orchestrators (__runAgent, __callTool) are
 * a JS shim installed by the Swift side over the primitives host.__chat etc.
 */
#include "xsAll.h"
#include "xs.h"
#include "bridge.h"
#include "bridgeXS.h"
#include "tykaozHost.h"

#include <stdlib.h>
#include <string.h>

/* Implemented in Swift (@_cdecl, resolved at the app link). */
extern void xsbTyLog(void* bridge, const char* text);
extern void xsbTyReport(void* bridge, const char* json);
extern void xsbTyFail(void* bridge, const char* text);
extern void xsbTyChat(void* bridge, uint32_t id, const char* json);
extern void xsbTyToolList(void* bridge, uint32_t id);
extern void xsbTyToolCall(void* bridge, uint32_t id, const char* json);
extern void xsbTyMemorySave(void* bridge, uint32_t id, const char* json);
extern void xsbTyMemoryRead(void* bridge, uint32_t id, const char* json);
extern void xsbTyMemoryList(void* bridge, uint32_t id);
extern void xsbTyToolResult(void* bridge, const char* json);

/* JSON.stringify([xsArg(0..n-1)]) as a malloc'd string — the positional params
 * array Swift expects (AgentJSON.params). Uses xsResult as scratch, so call it
 * BEFORE xsBridgePromise. */
static char* ty_args_json(xsMachine* the, int n)
{
    xsResult = xsNewArray(n);
    for (int i = 0; i < n; i++)
        xsSetIndex(xsResult, i, xsArg(i));
    xsResult = xsCall1(xsGet(xsGlobal, xsID("JSON")), xsID("stringify"), xsResult);
    return strdup(xsToString(xsResult));
}

/* host.log(...args) — synchronous; joins the args by space and logs. */
static void xs_ty_log(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    int argc = (int)xsToInteger(xsArgc);
    size_t cap = 256, len = 0;
    char* buf = (char*)malloc(cap);
    buf[0] = 0;
    for (int i = 0; i < argc; i++) {
        const char* s = xsToString(xsArg(i));
        size_t sl = strlen(s);
        if (len + sl + 2 > cap) { cap = (len + sl + 2) * 2; buf = (char*)realloc(buf, cap); }
        if (i) buf[len++] = ' ';
        memcpy(buf + len, s, sl);
        len += sl;
        buf[len] = 0;
    }
    xsbTyLog(bridge, buf);
    free(buf);
}

/* host.__report(resultJSON) — the agent's run() result (JSON.stringify'd). */
static void xs_ty_report(xsMachine* the)
{
    xsbTyReport(xsGetContext(the), xsToString(xsArg(0)));
}

/* host.__fail(text) — the agent's run() threw/rejected. */
static void xs_ty_fail(xsMachine* the)
{
    xsbTyFail(xsGetContext(the), xsToString(xsArg(0)));
}

/* host.__toolResult(callId, resultJSON, error) — a JS tool's outcome. */
static void xs_ty_tool_result(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    char* json = ty_args_json(the, 3);
    xsbTyToolResult(bridge, json);
    free(json);
}

/* host.__chat(messages, tools, onToken) — async LLM turn with token stream. */
static void xs_ty_chat(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    char* json = ty_args_json(the, 2);            /* [messages, tools] */
    uint32_t id = xsBridgePromise(the, &xsArg(2)); /* roots onToken */
    xsbTyChat(bridge, id, json);
    free(json);
}

/* host.tool.list() — async. */
static void xs_ty_tool_list(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    uint32_t id = xsBridgePromise(the, NULL);
    xsbTyToolList(bridge, id);
}

/* host.tool.call(name, args) — async. */
static void xs_ty_tool_call(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    char* json = ty_args_json(the, 2);
    uint32_t id = xsBridgePromise(the, NULL);
    xsbTyToolCall(bridge, id, json);
    free(json);
}

/* host.memory.save(title, content) — async. */
static void xs_ty_memory_save(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    char* json = ty_args_json(the, 2);
    uint32_t id = xsBridgePromise(the, NULL);
    xsbTyMemorySave(bridge, id, json);
    free(json);
}

/* host.memory.read(id) — async. */
static void xs_ty_memory_read(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    char* json = ty_args_json(the, 1);
    uint32_t id = xsBridgePromise(the, NULL);
    xsbTyMemoryRead(bridge, id, json);
    free(json);
}

/* host.memory.list() — async. */
static void xs_ty_memory_list(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    uint32_t id = xsBridgePromise(the, NULL);
    xsbTyMemoryList(bridge, id);
}

/* Frozen, append-only host table for snapshot callback projection. */
static const XSBridgeHostFn gTyHostTable[] = {
    { "log", xs_ty_log },
    { "__report", xs_ty_report },
    { "__fail", xs_ty_fail },
    { "__toolResult", xs_ty_tool_result },
    { "__chat", xs_ty_chat },
    { "tool.list", xs_ty_tool_list },
    { "tool.call", xs_ty_tool_call },
    { "memory.save", xs_ty_memory_save },
    { "memory.read", xs_ty_memory_read },
    { "memory.list", xs_ty_memory_list },
};

static void ty_register(void)
{
    xsBridgeRegisterHostTable(gTyHostTable,
                              (int)(sizeof(gTyHostTable) / sizeof(gTyHostTable[0])));
}

void xsBridgeTyKaozInstall(void* machine)
{
    ty_register();
    xsBeginHost((xsMachine*)machine);
    {
        xsVars(3);
        xsTry {
            xsVar(0) = xsNewObject();
            xsSet(xsGlobal, xsID("host"), xsVar(0));

            xsVar(2) = xsNewHostFunction(xs_ty_log, 1);
            xsSet(xsVar(0), xsID("log"), xsVar(2));
            xsVar(2) = xsNewHostFunction(xs_ty_report, 1);
            xsSet(xsVar(0), xsID("__report"), xsVar(2));
            xsVar(2) = xsNewHostFunction(xs_ty_fail, 1);
            xsSet(xsVar(0), xsID("__fail"), xsVar(2));
            xsVar(2) = xsNewHostFunction(xs_ty_tool_result, 3);
            xsSet(xsVar(0), xsID("__toolResult"), xsVar(2));
            xsVar(2) = xsNewHostFunction(xs_ty_chat, 3);
            xsSet(xsVar(0), xsID("__chat"), xsVar(2));

            xsVar(1) = xsNewObject();
            xsSet(xsVar(0), xsID("tool"), xsVar(1));
            xsVar(2) = xsNewHostFunction(xs_ty_tool_list, 0);
            xsSet(xsVar(1), xsID("list"), xsVar(2));
            xsVar(2) = xsNewHostFunction(xs_ty_tool_call, 2);
            xsSet(xsVar(1), xsID("call"), xsVar(2));

            xsVar(1) = xsNewObject();
            xsSet(xsVar(0), xsID("memory"), xsVar(1));
            xsVar(2) = xsNewHostFunction(xs_ty_memory_save, 2);
            xsSet(xsVar(1), xsID("save"), xsVar(2));
            xsVar(2) = xsNewHostFunction(xs_ty_memory_read, 1);
            xsSet(xsVar(1), xsID("read"), xsVar(2));
            xsVar(2) = xsNewHostFunction(xs_ty_memory_list, 0);
            xsSet(xsVar(1), xsID("list"), xsVar(2));
        }
        xsCatch {
        }
    }
    xsEndHost((xsMachine*)machine);
}

void xsBridgeTyKaozRegister(void)
{
    ty_register();
}
