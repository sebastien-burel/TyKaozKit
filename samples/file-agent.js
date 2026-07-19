// A provider-free agent exercising the file-space tools. Run it with one or
// more authorised roots:
//
//   TyKaozCli samples/file-agent.js --root /some/dir [--root /another]
//
// Without any --root the file tools aren't registered (they're opt-in), so the
// list_directory call below would fail with "Unknown tool". Paths outside the
// authorised roots are rejected (no `..`/symlink escape).
export async function run(input) {
  const root = (input && input.path) || ".";
  const tools = await host.tool.list();
  const listing = await host.tool.call("list_directory", { path: root });
  host.log("file-agent listed " + root);
  return {
    fileTools: tools.map(t => t.name).filter(n =>
      ["list_directory", "read_file", "grep_files"].includes(n)),
    listing
  };
}
