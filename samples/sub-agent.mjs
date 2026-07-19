// A sub-agent is a module whose default-export methods are the service. It runs
// in its own engine with the full TyKaoz host surface (host.tool / host.llm /
// memory), spawned by a supervisor's `new Thread()` + `new Service()`. Methods
// may be synchronous or async (return a Promise).
export default {
  double({ n }) { return { doubled: n * 2 }; },
  async now() {
    const dt = await host.tool.call("current_datetime", {});
    return { now: dt };
  }
};
