// Imperative shell: Chrome's targets, over the endpoints the browser answers.
//
// Everything here speaks to the CDP *HTTP* endpoint and to a page's own
// websocket, deliberately going around Playwright. That is the whole point:
// when one tab is stuck mid-navigation, Playwright cannot attach at all -- it
// initialises every page that is already open and waits for all of them -- so
// the recovery path cannot be built on the thing that is stuck.
//
// Measured, on a tab left mid-navigation: `Page.getFrameTree` gets no reply at
// all, where a healthy tab answers in under 10ms. `Page.stopLoading` on that
// same tab is answered immediately, and the tab answers everything again
// afterwards. So a stuck tab is *unstuck*, not closed: whatever document it
// already had -- the page a human was reading, most often -- survives.
//
// There is a second way to hold the attach open, and it looks like the opposite
// from here (ticket 042). A tab created *at* a URL -- a popup, a target=_blank a
// human clicked, a session restore -- never commits a document if that URL never
// answers. Its renderer has nothing to be busy with, so it answers
// `getFrameTree` in under 10ms and reads as healthy, while the attach hangs just
// as hard. What gives it away is the answer rather than the silence: the frame's
// URL is the empty string, which is Chrome for "no document here at all".

open Models

/// How long a page gets to answer a question its renderer answers instantly
/// when it is healthy. Generous by two orders of magnitude, because the cost of
/// being wrong is stopping a navigation someone wanted.
let probeDeadlineS = 3.0

/// The same question asked for a report rather than for a rescue. Shorter,
/// because `status` walks every tab and nothing is freed on the strength of the
/// answer: a page that misses this deadline is named, not acted on.
let statusDeadlineS = 1.0

/// Chrome's way of saying a frame holds no document. Not "about:blank", which is
/// a document -- an empty string, which is the absence of one.
let noDocument = ""

/// Pure: the endpoint's JSON as models. Unknown fields are dropped.
let parse = (payload): array<target> =>
  switch JSON.parseOrThrow(payload)->JSON.Decode.array {
  | Some(items) =>
    items->Array.filterMap(item =>
      switch item->JSON.Decode.object {
      | Some(o) =>
        let str = key =>
          o->Dict.get(key)->Option.flatMap(v => v->JSON.Decode.string)->Option.getOr("")
        Some({
          id: str("id"),
          type_: str("type"),
          url: str("url"),
          title: str("title"),
          websocketUrl: str("webSocketDebuggerUrl"),
        })
      | None => None
      }
    )
  | None => []
  | exception _ => []
  }

/// Pure: what one `Page.getFrameTree` answer says about the tab.
///
/// `None` for the reply means the renderer never answered at all.
let verdict = (reply: option<JSON.t>): option<wedge> =>
  switch reply {
  | None => Some(Silent)
  | Some(json) =>
    switch json->JSON.Decode.object->Option.flatMap(o => o->Dict.get("result")) {
    // An error reply is still an answer, so the renderer is alive -- but it is
    // not one this can read a frame out of. Conservative on purpose: the
    // remedies here stop navigations, and a reply nobody planned for is a bad
    // reason to stop one.
    | None => None
    | Some(result) =>
      let url =
        result
        ->JSON.Decode.object
        ->Option.flatMap(o => o->Dict.get("frameTree"))
        ->Option.flatMap(t => t->JSON.Decode.object)
        ->Option.flatMap(o => o->Dict.get("frame"))
        ->Option.flatMap(f => f->JSON.Decode.object)
        ->Option.flatMap(o => o->Dict.get("url"))
        ->Option.flatMap(u => u->JSON.Decode.string)
        ->Option.getOr(noDocument)
      url == noDocument ? Some(Uncommitted) : None
    }
  }

/// Pure: the opener map out of one `Target.getTargets` answer.
///
/// A page that calls `window.open`, or a link with `target="_blank"`, creates a
/// target nobody asked this tool for. Attributing it to the lane that caused it
/// needs a record of causation, and Chrome has one: `openerId`. Guessing from
/// timing or URL was the alternative, and it is the kind of heuristic this
/// project keeps deleting.
let openersOf = (reply: option<JSON.t>): Dict.t<string> => {
  let openers = Dict.make()
  let infos =
    reply
    ->Option.flatMap(r => r->JSON.Decode.object)
    ->Option.flatMap(o => o->Dict.get("result"))
    ->Option.flatMap(r => r->JSON.Decode.object)
    ->Option.flatMap(o => o->Dict.get("targetInfos"))
    ->Option.flatMap(t => t->JSON.Decode.array)
    ->Option.getOr([])

  infos->Array.forEach(info =>
    switch info->JSON.Decode.object {
    | None => ()
    | Some(o) =>
      let str = key =>
        o->Dict.get(key)->Option.flatMap(v => v->JSON.Decode.string)->Option.getOr("")
      if str("type") == "page" && str("openerId") != "" && str("targetId") != "" {
        openers->Dict.set(str("targetId"), str("openerId"))
      }
    }
  )
  openers
}

/// Pure: how a browser's wedges read on one line.
///
/// Iterated in declaration order rather than in the order encountered, so the
/// line reads the same way twice for the same browser.
let summaryOf = (found: array<wedge>) =>
  if found->Array.length == 0 {
    "none"
  } else {
    wedges
    ->Array.filterMap(w => {
      let n = found->Array.filter(f => f == w)->Array.length
      n == 0 ? None : Some(`${n->Int.toString} ${wedgeName(w)}`)
    })
    ->Array.join(", ")
  }

// --- talking to the browser -------------------------------------------------

@val external fetch: (string, {..}) => promise<'res> = "fetch"
@send external text: 'res => promise<string> = "text"
@get external ok: 'res => bool = "ok"
@val external abortSignalTimeout: int => 'signal = "AbortSignal.timeout"

/// Every target Chrome currently holds, browser UI and workers included.
let listing = async () => {
  let res = await fetch(
    `${Config.cdpUrl()}/json/list`,
    {"signal": abortSignalTimeout(5000)},
  )
  parse(await res->text)
}

let pages = async () => (await listing())->Array.filter(isPage)

/// Close one target through the browser process. True if it answered.
///
/// Goes around Playwright for the same reason the rest of this module does: tab
/// bookkeeping must keep working when a renderer does not, and an attach that
/// initialises every open tab is a strange price to pay for closing one.
let close = async targetId =>
  switch await fetch(
    `${Config.cdpUrl()}/json/close/${targetId}`,
    {"signal": abortSignalTimeout(5000)},
  ) {
  | res => res->ok
  | exception _ => false
  }

let browserSocket = async () =>
  switch await fetch(`${Config.cdpUrl()}/json/version`, {"signal": abortSignalTimeout(5000)}) {
  | res =>
    (await res->text)
    ->JSON.parseOrThrow
    ->JSON.Decode.object
    ->Option.flatMap(o => o->Dict.get("webSocketDebuggerUrl"))
    ->Option.flatMap(v => v->JSON.Decode.string)
    ->Option.getOr("")
  | exception _ => ""
  }

/// One CDP command over its own socket. `None` means the renderer never answered.
///
/// Replies have to be picked out of the event stream by id: a page under
/// navigation emits lifecycle events continuously, and reading the next frame
/// would read one of those instead of the answer.
let call = (socketUrl, ident, method, deadlineS, params) =>
  Promise.make((resolve, _reject) => {
    let settled = ref(false)
    let socket = WebSocket.make(socketUrl)
    let finish = value =>
      if !settled.contents {
        settled := true
        // Best effort: the socket is being dropped either way, and a close
        // handshake against a renderer that is not answering would itself need a
        // deadline.
        try socket->WebSocket.close catch {
        | _ => ()
        }
        resolve(value)
      }

    let timer = Timers.setTimeout(() => finish(None), Int.fromFloat(deadlineS *. 1000.0))

    socket->WebSocket.onOpen(_ =>
      socket->WebSocket.send(
        JSON.stringifyAny({"id": ident, "method": method, "params": params})->Option.getOr("{}"),
      )
    )
    socket->WebSocket.onError(_ => {
      Timers.clearTimeout(timer)
      finish(None)
    })
    socket->WebSocket.onClose(_ => {
      Timers.clearTimeout(timer)
      finish(None) // the socket closed before the answer came
    })
    socket->WebSocket.onMessage(event => {
      let message = try Some(JSON.parseOrThrow(WebSocket.data(event))) catch {
      | _ => None
      }
      let isMine =
        message
        ->Option.flatMap(m => m->JSON.Decode.object)
        ->Option.flatMap(o => o->Dict.get("id"))
        ->Option.flatMap(v => v->JSON.Decode.float)
        ->Option.getOr(-1.0) == Int.toFloat(ident)
      if isMine {
        Timers.clearTimeout(timer)
        finish(message)
      }
    })
  })

/// Ask one page to describe itself. `None` means it is fine.
let diagnose = async (page, deadlineS) =>
  switch await call(page.websocketUrl, 1, "Page.getFrameTree", deadlineS, Dict.make()) {
  | reply => verdict(reply)
  // A target that cannot even be connected to is not one we can rescue, and
  // guessing at it would risk stopping a navigation that is fine.
  | exception _ => None
  }

/// Every page that is holding the attach open, and which way it is doing it.
///
/// Read-only: this is the half `status` can call.
let stuck = async (~deadlineS=probeDeadlineS) => {
  let found = []
  for i in 0 to (await pages())->Array.length - 1 {
    let page = (await pages())->Array.getUnsafe(i)
    // Nothing to ask; Chrome withholds a socket for its own UI.
    if page.websocketUrl != "" {
      switch await diagnose(page, deadlineS) {
      | Some(w) => found->Array.push((page, w))->ignore
      | None => ()
      }
    }
  }
  found
}

let stuckSummary = async (~deadlineS=statusDeadlineS) =>
  summaryOf((await stuck(~deadlineS))->Array.map(((_, w)) => w))

/// What frees each wedge, measured one against the other on a server that
/// accepts and then answers nothing. Neither remedy works on the other's tab.
let remedy = w =>
  switch w {
  | Silent => ("Page.stopLoading", Dict.make())
  | Uncommitted => ("Page.navigate", Dict.fromArray([("url", JSON.Encode.string("about:blank"))]))
  }

/// Free every page that is holding the attach open, each its own way.
///
/// Called only after an attach has already timed out, and that is what makes the
/// Uncommitted remedy affordable. A tab that has yet to commit a document is
/// indistinguishable from a tab on a merely slow host -- both are waiting on
/// headers, and no field separates them -- so this does stop a navigation
/// someone may have wanted. What it weighs against is that the same navigation
/// has been failing every call in every lane for the whole attach timeout, and
/// that re-navigating is cheap where a bricked tool is not.
let unstick = async (~deadlineS=probeDeadlineS) => {
  let freed = []
  let wedged = await stuck(~deadlineS)
  for i in 0 to wedged->Array.length - 1 {
    let (page, wedge) = wedged->Array.getUnsafe(i)
    let (method, params) = remedy(wedge)
    switch await call(page.websocketUrl, 1, method, deadlineS, params) {
    | _ => freed->Array.push(page)->ignore
    | exception _ => ()
    }
  }
  freed
}

/// Which tab opened which, as Chrome itself records it.
///
/// Not available from `/json/list`, which is why this goes to the websocket. An
/// empty map on any failure: adoption is an improvement over leaving a tab
/// unowned, never a precondition for the caller's actual work.
let openers = async (~deadlineS=probeDeadlineS) =>
  switch await browserSocket() {
  | "" => Dict.make()
  | socketUrl =>
    switch await call(socketUrl, 1, "Target.getTargets", deadlineS, Dict.make()) {
    | reply => openersOf(reply)
    | exception _ => Dict.make()
    }
  | exception _ => Dict.make()
  }
