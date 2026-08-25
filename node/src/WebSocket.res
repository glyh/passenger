// Node's global WebSocket, which has been stable since Node 22 -- so the CDP
// socket costs no dependency either, the way `node:sqlite` costs none.
type t
type event

@new external make: string => t = "WebSocket"
@send external send: (t, string) => unit = "send"
@send external close: t => unit = "close"
@set external onOpen: (t, event => unit) => unit = "onopen"
@set external onMessage: (t, event => unit) => unit = "onmessage"
@set external onError: (t, event => unit) => unit = "onerror"
@set external onClose: (t, event => unit) => unit = "onclose"
@get external data: event => string = "data"
