// Live check for Session against whatever Chrome is already running.
// Not a test: it needs a browser, and the suite must not.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const Config = await import("./src/Config.res.mjs");
Config.stateDir.contents = mkdtempSync(join(tmpdir(), "passenger-live-"));

const Lanes = await import("./src/Lanes.res.mjs");
const Session = await import("./src/Session.res.mjs");
const Targets = await import("./src/Targets.res.mjs");
const Errors = await import("./src/Errors.res.mjs");

console.log("isUp:", await Targets.isUp());

const lane = Lanes.openLane(undefined);
console.log("lane:", lane);

const s = await Session.open_();
console.log("contexts attached, pages seen:", s.context.pages().length);

const page = await Session.page(s, lane, undefined);
const tab = await Session.targetId(s, page);
console.log("tab:", tab, "| owner:", Lanes.owner(tab), "| tabsOf:", Lanes.tabsOf(lane));

const same = await Session.pageFor(s, lane, tab);
console.log("pageFor returned the same tab:", (await Session.targetId(s, same)) === tab);

// Reuse: a second ask with the tab still blank must hand back the same one.
const again = await Session.page(s, lane, undefined);
console.log("blank tab reused:", (await Session.targetId(s, again)) === tab);

try {
  await Session.pageFor(s, lane, "deadbeef");
  console.log("pageFor a foreign tab: NO ERROR (wrong)");
} catch (e) {
  console.log("pageFor a foreign tab:", Errors.rendered(e.code, e.message, e.detail));
}

await page.goto("about:blank");
console.log("closeOthers closed:", await Session.closeOthers(s, lane, page));
console.log("closed on destroy:", await Lanes.closeTabs(lane, Lanes.tabsOf(lane)));
await Session.dispose(s);
console.log("detached; chrome still up:", await Targets.isUp());
