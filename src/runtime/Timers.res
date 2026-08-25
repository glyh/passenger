type timeout
@val external setTimeout: (unit => unit, int) => timeout = "setTimeout"
@val external clearTimeout: timeout => unit = "clearTimeout"

/// A promise that settles after a delay.
///
/// Lived on `Sessions` for a while, because the C# side spelled it
/// `Thread.Sleep` inside the module that needed it first. It is not about
/// sessions.
let sleep = ms => Promise.make((resolve, _reject) => setTimeout(() => resolve(), ms)->ignore)
