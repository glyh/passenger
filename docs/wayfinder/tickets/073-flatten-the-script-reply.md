---
id: 073
title: "Flatten the script reply: two tagged unions to one object"
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

The owner, reading the ported code: *"type dispatch on script result is a
leftover from C#. we're doing dynamic typing here instead no?"*

Two things answered to that name and they were separate calls. The first --
the rule that refused a live Playwright handle -- is dealt with under
[071](071-port-to-node.md); it dissolved. This is the second: the reply shape.

A `script` reply was two nested tagged unions.

    {"type":"ran","tab":"A44…","returned":{…},"page":null}
    {"type":"ran","tab":"A44…","returned":"…","page":{"type":"unchecked"}}
    {"type":"ran","tab":"A44…","returned":null,
     "page":{"type":"blocked","name":"cloudflare","kind":"challenge",
             "url":"…","tab":"A44…","hint":"…"}}
    {"type":"failed","tab":"A44…","code":"SCRIPT_RAISED","error":"…",
     "where":"line 3: …","page":null}

Both discriminators were pydantic's, kept through the C# port because
`System.Text.Json` had to be *told* how to spell a union it could not express
-- `[JsonPolymorphic]`, `[JsonDerivedType]`, a base record per family. Neither
was ever a fact about what a caller needed.

## Answer

**Flattened.** One object, fields present or absent:

    {"tab":"255F…","returned":{"title":"…"},"wallChecked":true}
    {"tab":"255F…","returned":"a second tab","wallChecked":false}
    {"tab":"B802…","returned":"Just a moment...","wallChecked":true,
     "blocked":{"name":"cloudflare-interstitial","kind":"challenge",
                "url":"file:///tmp/wall.html","hint":"showBrowser with this tab…"}}
    {"tab":"255F…","code":"SCRIPT_RAISED","error":"Error: deliberate, line 2",
     "where":"line 2: throw new Error('deliberate, line 2');","wallChecked":true}

All four measured on the wire, the third against a page carrying real Cloudflare
markup.

What changed, and why each:

- **One level, not two.** `if (r.blocked)` is the whole test in the language a
  caller is already writing. A discriminator exists to tell a static language
  which branch of a union it holds; a caller here asks whether a field is there.
- **`page: {"type":"unchecked"}` becomes `wallChecked: false`.** The *fact* is
  load-bearing and stays -- ticket 042 is precisely that a check which never ran
  must not read as a page that was fine -- but it does not need a variant to
  carry it. It is now on every reply rather than only when off, which is the
  stronger form: a caller cannot miss it by not looking.
- **`blocked` stops repeating the tab.** It carried one from ticket 018, because
  an agent that wanted to summon a human deliberately was otherwise reading
  `listTabs` and matching on a URL. Flat, the tab is at the top of every reply,
  so the copy inside was the same string twice.
- **`ran` vs `failed` is now the presence of `error`.** This is the one place the
  flat shape is weaker: today they are mutually exclusive by construction, and
  flat it is a convention. It is documented in `Service.encode`, in the skill,
  and there is no collision to worry about -- a script's own data lives under
  `returned`, so a page that returns `{error: …}` cannot be mistaken for a failed
  call.

**The union survives on this side**, where it earns its keep. `encode` is a
`switch` the compiler checks, so a member added later cannot quietly fail to
reach the wire. What was deleted is the *wire's* need to spell it -- which was
never the caller's need, only a serialiser's.

### What it costs

Every existing caller that branches on `type`. Inside this repo that turned out
to be only the skill: `probe.mjs` reads `tab` and prints the rest, so it needed
no change and its output is the transcript above. Outside it, a site skill that parses a
`script` reply reads `type` and `page` and will need one pass -- the owner's
`passenger-xiaohongshu` among them. That cost was weighed and accepted: the
shape has been the same across Python, C# and ReScript, and this is the moment
to change it if it is ever going to change, while the port is the thing being
absorbed anyway.
