// A supervisor spawns and delegates to sub-agents entirely from JS — one script,
// no flags. Modules resolve Moddable-style: a bare specifier (no `./`, no
// extension) is looked up in the module roots, and the agent's own directory is
// the default root — so "sub-agent" finds sub-agent.mjs next to this file:
//   TyKaozCli samples/supervisor.js
export async function run(input) {
  const t   = new Thread("sub");        // spawn a child engine
  const svc = new Service(t, "sub-agent");  // bare specifier, resolved via roots
  const a = await svc.double({ n: 21 });
  const b = await svc.now();            // sub-agent uses host.tool
  return { supervisor: true, a, b };
}
