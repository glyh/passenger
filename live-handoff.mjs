// showBrowser on the `web` presenter: it hands back a URL and opens no window,
// which is what makes it safe to drive here. What it does exercise is the whole
// handoff path -- the screen claim, `Webserve.ensure` re-execing this same module
// as a detached viewer server, and hideBrowser releasing the claim again.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const port = String(6096);
const t = new StdioClientTransport({
  command: 'node', args: ['src/Main.res.mjs'], cwd: process.cwd(), stderr: 'inherit',
  env: { ...process.env, PASSENGER_PRESENTER: 'web', PASSENGER_NOVNC_PORT: port },
});
const c = new Client({ name: 'probe', version: '0' });
await c.connect(t);

const call = async (name, args) => {
  try {
    const r = await c.callTool({ name, arguments: args });
    console.log(`${name} ->`, r.content[0].text);
    return r.content[0].text;
  } catch (e) { console.log(`${name} !!`, e.message); return null; }
};

const lane = await call('openLane', {});
await call('browserStatus', {});
await call('showBrowser', { lane });
await call('browserStatus', {});
await call('hideBrowser', { lane });
await call('destroyLane', { lane });

const held = (await import('./src/Sessions.res.mjs')).listenerOn(Number(port));
console.log('viewer server:', held ? held[1] : 'none');
if (held) process.kill(held[0], 'SIGTERM');
await c.close();
