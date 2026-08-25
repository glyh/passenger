import * as Config from './src/Config.res.mjs';
import * as Targets from './src/Targets.res.mjs';
import * as Lanes from './src/Lanes.res.mjs';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';

Config.stateDir.contents = mkdtempSync(tmpdir() + '/passenger-live-');

const pages = await Targets.pages();
console.log('pages:', pages.length, '| first title:', JSON.stringify(pages[0]?.title));
console.log('socket looks right:', /^ws:\/\/127\.0\.0\.1:\d+\/devtools\/page\//.test(pages[0]?.webSocketDebuggerUrl ?? ''));

const openers = await Targets.openers(undefined);
console.log('openers:', JSON.stringify(openers));

console.log('browserSocket:', (await Targets.browserSocket()).slice(0, 40));
console.log('stuckSummary:', await Targets.stuckSummary(undefined));

const [open, orphaned] = await Lanes.counts();
console.log('counts through the live seam: open=' + open, 'orphaned=' + orphaned);
const swept = await Lanes.sweep();
console.log('sweep collected:', JSON.stringify(swept), '| orphan now holds', Lanes.tabsOf(Lanes.orphan).length);
