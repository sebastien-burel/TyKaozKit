/*
 * serviceHost.h — install the client side of the multi-machine service layer
 * (`__callService` + the `service` Proxy) on a machine. Link the target with
 * xsBridgeLinkService. Run on the XS thread (via XSEngine.withMachine).
 */
#ifndef TYKAOZ_SERVICE_HOST_H
#define TYKAOZ_SERVICE_HOST_H

void xsBridgeServiceClientInstall(void* machine);

#endif /* TYKAOZ_SERVICE_HOST_H */
