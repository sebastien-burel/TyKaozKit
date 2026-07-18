/*
 * serviceHost.c — client side of the multi-machine service layer for TyKaoz.
 *
 * Installs `__callService(method, args)` (which calls the socle's
 * xsServiceInvoke) plus a `globalThis.service` Proxy, so a supervisor agent
 * can call a sub-agent running on a linked machine as `service.run(input)`.
 * The target machine is set with xsServiceLink (flat API).
 */
#include "xsAll.h"
#include "xs.h"
#include "bridge.h"
#include "bridgeXS.h"
#include "serviceHost.h"

static void xs_call_service(xsMachine* the)
{
    const char* method = xsToString(xsArg(0));
    xsServiceInvoke(the, method, &xsArg(1));   /* xsResult = the promise */
}

void xsBridgeServiceClientInstall(void* machine)
{
    xsBeginHost((xsMachine*)machine);
    {
        xsVars(1);
        xsTry {
            xsVar(0) = xsNewHostFunction(xs_call_service, 2);
            xsSet(xsGlobal, xsID("__callService"), xsVar(0));
            xsCall1(xsGlobal, xsID("eval"), xsString(
                "globalThis.service = new Proxy({}, { get: function (t, m) {"
                " return function (a) { return __callService(String(m), a); }; } });"));
        }
        xsCatch {
        }
    }
    xsEndHost((xsMachine*)machine);
}
