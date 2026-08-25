// Drives the server over stdio, the way a client does. Needs Chrome on 9222.
//
// Not a test: it opens a real lane against the shared browser, which the suite
// must never do.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const t = new StdioClientTransport({ command: 'node', args: ['src/Main.res.mjs'], cwd: process.cwd(), stderr: 'inherit' });
const c = new Client({ name: 'probe', version: '0' });
await c.connect(t);
console.log('tools:', (await c.listTools()).tools.map(x => x.name).join(', '));

const call = async (name, args) => {
  try {
    const r = await c.callTool({ name, arguments: args });
    const text = r.content[0].text;
    console.log(`${name} ->`, text.length > 300 ? text.slice(0, 300) + '...' : text);
    return text;
  } catch (e) {
    console.log(`${name} !!`, e.message);
    return null;
  }
};

const lane = await call('openLane', {});

const ran = await call('script', {
  lane,
  source: `await Page.goto('https://www.chinanews.com.cn/');
return { title: await Page.title(), emoji: '😀 腾冲',
         n: await Page.evaluate(() => document.querySelectorAll('a').length) };`,
});
const tab = ran ? JSON.parse(ran).tab : undefined;

// The same tab again, which is what continuing a sequence looks like.
await call('script', { lane, tab, source: `return Page.url();`, checkWall: false });

// The three failures, each naming which one it was.
await call('script', { lane, tab, source: `const a = 1;\nthrow new Error('deliberate, line 2');` });
await call('script', { lane, tab, source: `var x = 1;\nvar y = (;` });
await call('script', { lane, tab, source: `return Page.locator('body');` });

await call('listTabs', { lane });
await call('script', { lane, source: `return 'a second tab';`, checkWall: false });
await call('listTabs', { lane });

// A lane may not touch another lane's tab, and cannot tell that from absent.
const other = await call('openLane', {});
await call('script', { lane: other, tab, source: `return 1;` });
await call('destroyLane', { lane: other });

await call('setTtl', { lane, minutes: 5 });
await call('closeAllTabs', { lane });
await call('destroyLane', { lane });
await call('script', { lane, source: `return 1;` });

await c.close();
