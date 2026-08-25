import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const t = new StdioClientTransport({ command: 'node', args: ['src/Main.res.mjs'], cwd: process.cwd() });
const c = new Client({ name: 'probe', version: '0' });
await c.connect(t);
console.log('tools:', (await c.listTools()).tools.map(x => x.name).join(','));

const call = async (src) => {
  const r = await c.callTool({ name: 'script', arguments: { source: src } });
  console.log('->', r.content[0].text);
};

await call(`await Page.goto('https://www.chinanews.com.cn/');
const t = await Page.title();
return { title: t, emoji: '😀 腾冲', n: (await Page.evaluate(() => document.querySelectorAll('a').length)) };`);

await call(`const a = 1;
throw new Error('deliberate, line 2');`);

await c.close();
