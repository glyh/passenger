// The viewer server, in this process, on a scratch port. Not a test: it needs a
// real noVNC installation, which the suite must not.
const Config = await import("./src/Config.res.mjs");
const W = await import("./src/Webserve.res.mjs");
const port = 6099;
const root = W.novncRoot();
if (!root) { console.log("no novnc here; run under nix develop"); process.exit(0); }
Config.novncPort.contents = port;
W.serve(port, root);
await new Promise(r => setTimeout(r, 200));
console.log("serving() says ours:", await W.serving(port));
const rfb = await fetch(`http://127.0.0.1:${port}/novnc/core/rfb.js`);
console.log("novnc module:", rfb.status, rfb.headers.get("content-type"));
const walk = await fetch(`http://127.0.0.1:${port}/novnc/../../../etc/passwd`);
console.log("walking out:", walk.status);
const other = await fetch(`http://127.0.0.1:${port}/etc/passwd`);
console.log("anything else:", other.status);
process.exit(0);
