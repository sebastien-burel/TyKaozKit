// A supervisor spawns and delegates to sub-agents entirely from JS — no CLI
// flags, one script. Pass the sub-agent module's ABSOLUTE path as input:
//   TyKaozCli samples/supervisor.js --input '{"module":"/abs/path/samples/sub-agent.mjs"}'
export async function run(input) {
  const modulePath = input && input.module;
  if (!modulePath) throw new Error("pass {module: '/abs/path/sub-agent.mjs'} as --input");
  const t   = new Thread("sub");             // spawn a child engine
  const svc = new Service(t, modulePath);    // bind a Service to its module
  const a = await svc.double({ n: 21 });
  const b = await svc.now();                 // sub-agent uses host.tool
  return { supervisor: true, a, b };
}
