import { createHost } from './host.mjs';

const host = createHost();
(async () => {
  try {
    console.log("=== Reconciling h10 ===");
    const rec = await host.pull('h10');
    console.log("Reconciled result:", rec?.state, rec?.binding?.turn_id, rec?.hold_reason);
  } catch (e) {
    console.error("Reconcile error:", e.message);
  }
  process.exit(0);
})();
