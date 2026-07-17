// A provider-free agent: exercises the CLI runtime end-to-end via the native
// tool path (no host.llm.chat, so no API key needed).
export async function run(input) {
  const now = await host.tool.call("current_datetime", {});
  const tools = await host.tool.list();
  host.log("tool-agent ran with input " + JSON.stringify(input));
  return { input, now, toolNames: tools.map(t => t.name) };
}
