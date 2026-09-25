import { browserProbe } from './cdp-adapter.mjs';

function inspectSnapshot(tabId, name) {
  return new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:9222/devtools/page/${tabId}`);
    ws.onopen = () => {
      let msgId = 1;
      const send = (method, params = {}) => {
        return new Promise((res) => {
          const id = msgId++;
          const handler = (evt) => {
            const m = JSON.parse(evt.data);
            if (m.id === id) {
              ws.removeEventListener('message', handler);
              res(m.result);
            }
          };
          ws.addEventListener('message', handler);
          ws.send(JSON.stringify({ id, method, params }));
        });
      };

      (async () => {
        try {
          const evalRes = await send('Runtime.evaluate', {
            expression: `(${browserProbe.toString()})()`,
            awaitPromise: true,
            returnByValue: true
          });
          console.log(`=== ${name} (${tabId}) snapshot ===`);
          const val = evalRes?.result?.value;
          console.log("attachment:", val?.attachment);
          console.log("generating:", val?.generating);
          console.log("conversation_id:", val?.conversation_id);
          console.log("composer_text:", val?.composer_text);
        } catch (e) {
          console.error(`Error inspecting ${name}:`, e.message);
        } finally {
          ws.close();
          resolve();
        }
      })();
    };
  });
}

(async () => {
  await inspectSnapshot('71A1F961247C5A863CF8A81D9758D95F', 'Vitalis');
  await inspectSnapshot('436D74475BFC93E547CF2FAAA157E19A', 'H10');
  process.exit(0);
})();
