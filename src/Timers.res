type timeout
@val external setTimeout: (unit => unit, int) => timeout = "setTimeout"
@val external clearTimeout: timeout => unit = "clearTimeout"
