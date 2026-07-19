// A supervisor spawns and delegates to sub-agents entirely from JS — one script,
// no flags. A relative module specifier resolves against THIS script's own
// directory:  TyKaozCli samples/supervisor.js
export async function run(input) {
  const t   = new Thread("sub");             // spawn a child engine
  const svc = new Service(t, "./sub-agent.mjs");  // resolved against this script's dir
  const a = await svc.double({ n: 21 });
  const b = await svc.now();                 // sub-agent uses host.tool
  return { supervisor: true, a, b };
}
