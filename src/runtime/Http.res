// The runtime's own `fetch`, bound once.
//
// It was bound three times -- in `Targets`, `Webserve` and `Notify` -- each with
// its own copy of `text`, `ok` and `AbortSignal.timeout`. Three bindings of one
// global is three chances to disagree about its type, and one of them already
// spelled the timeout differently from the other two.
//
// Every call this server makes is to loopback, so a deadline is not optional:
// something that has not answered a local socket in seconds has answered the
// question. Each caller passes its own, because they differ on purpose -- one
// second for "is Chrome up", asked at the top of every tool; five for the CDP
// endpoints; two for the viewer page.

type response

@val external fetchRaw: (string, {..}) => promise<response> = "fetch"
@val external abortSignalTimeout: int => 'signal = "AbortSignal.timeout"

@send external text: response => promise<string> = "text"
@get external ok: response => bool = "ok"
@get external status: response => int = "status"

let get = (url, ~timeoutMs) => fetchRaw(url, {"signal": abortSignalTimeout(timeoutMs)})

let post = (url, ~body, ~timeoutMs) =>
  fetchRaw(
    url,
    {
      "method": "POST",
      "headers": {"content-type": "application/json"},
      "body": body,
      "signal": abortSignalTimeout(timeoutMs),
    },
  )
