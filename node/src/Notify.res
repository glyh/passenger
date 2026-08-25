// Imperative shell: telling a human they're needed.
//
// A desktop notification only reaches someone sitting at this machine. In a
// container -- or on a server -- the same event has to travel differently, so the
// mechanism is a record of functions rather than a hardcoded notify-send.

type notifier = {notify: (string, string) => unit}

let webhookTimeoutMs = 5000

/// Always available, and the only one guaranteed to be seen in a pipeline.
///
/// stderr, and that is not a stylistic choice: stdout is the JSON-RPC transport,
/// and a notification written there would corrupt the stream it was announcing
/// itself on.
let stderr = {
  notify: (title, message) => Console.error(`\n!! ${title}: ${message}`),
}

let desktop = {
  notify: (title, message) =>
    // A notifier that cannot run is not a reason to fail the handoff it was
    // announcing -- `check=False` on the Python side.
    Proc.status("notify-send", ["-u", "critical", title, message])->ignore,
}

@val external fetch: (string, {..}) => promise<'res> = "fetch"
@val external abortSignalTimeout: int => 'signal = "AbortSignal.timeout"

/// POSTs to whatever PASSENGER_WEBHOOK points at -- ntfy, Slack, etc.
///
/// This is what makes a headless deployment usable: the browser can be on a
/// server and still reach you when a challenge needs solving.
let webhook = url => {
  notify: (title, message) => {
    let payload =
      JSON.stringifyAny({"title": title, "text": message, "message": message})->Option.getOr("{}")
    fetch(
      url,
      {
        "method": "POST",
        "headers": {"content-type": "application/json"},
        "body": payload,
        "signal": abortSignalTimeout(webhookTimeoutMs),
      },
    )
    ->Promise.catch(e => {
      let why = switch e {
      | JsExn(err) => JsExn.message(err)->Option.getOr("unknown")
      | _ => "unknown"
      }
      Console.error(`   webhook failed: ${why}`)
      Promise.resolve(%raw(`undefined`))
    })
    ->Promise.ignore
  },
}

let fanOut = targets => {
  notify: (title, message) => targets->Array.forEach(t => t.notify(title, message)),
}

/// Stderr always, plus whatever else can actually reach the user.
let select = () => {
  let targets = [stderr]
  if Launch.which("notify-send")->Option.isSome {
    targets->Array.push(desktop)
  }
  switch Config.webhookUrl.contents {
  | Some(url) => targets->Array.push(webhook(url))
  | None => ()
  }
  fanOut(targets)
}
