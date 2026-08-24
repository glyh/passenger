// Functional core: turning caller-supplied source into a value.
//
// The one door onto the browser is a script, not a tool per verb (ticket 004),
// so this module owns the two things that door needs: getting the source to run
// with `return` in it, and deciding what may come back out.
//
// Nothing here touches a browser. It is handed a page by the shell and never
// learns what it is, which is what makes it testable without one.
//
// **The one place the port changes the caller's contract.** The source was
// Python, run with `exec` against a compiled function body. There is no
// in-process Python here, so it is C# on Roslyn instead. Everything else about
// the door is unchanged: `page` is the only name bound, `return` hands a value
// back, and what may cross is still JSON and nothing else. What the caller writes
// is `await page.GotoAsync(url)` where it used to be `page.goto(url)`, because
// Playwright .NET has no sync API -- the same async rewrite the rest of the shell
// took.

using System.Reflection;
using System.Text.Json;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp.Scripting;
using Microsoft.CodeAnalysis.Scripting;
using Microsoft.Playwright;

namespace Passenger;

/// <summary>
/// What a script sees. One member, and it is the page (ticket 004).
///
/// A globals type rather than a bound variable because that is how Roslyn scopes
/// a value into a script. `read` used to be bound beside it on the Python side --
/// this project's own extraction, in scope for the caller to call. Ticket 046
/// retired it: reading a page is a judgement, and judgement is the caller's. The
/// walker survives as a recipe in the skill, pasted into a script by an agent
/// that wants it.
/// </summary>
public sealed class ScriptGlobals
{
    public required IPage Page { get; init; }
}

public static class Script
{
    /// <summary>
    /// What a caller's script may reach without saying so.
    ///
    /// Playwright and the JSON types, because those are what a script is written
    /// against, plus the collection and Linq namespaces that any non-trivial
    /// return value needs. Deliberately not the whole BCL surface by default:
    /// what is missing can still be reached with a fully-qualified name, so this
    /// is a convenience list rather than a sandbox, and it is not pretending to
    /// be one -- a caller-supplied script runs in this process either way.
    /// </summary>
    private static readonly string[] Imports =
    [
        "System",
        "System.Collections.Generic",
        "System.Linq",
        "System.Text.Json",
        "System.Threading.Tasks",
        "Microsoft.Playwright",
    ];

    private static readonly ScriptOptions Options = ScriptOptions.Default
        .WithImports(Imports)
        .WithReferences(
            typeof(object).Assembly,
            typeof(Enumerable).Assembly,
            typeof(JsonSerializer).Assembly,
            typeof(IPage).Assembly)
        // The file path and the debug information are what buy a runtime line
        // number. Ticket 023's measurement found C# gives none without them, and
        // that the `string` overload of Create fails CS8055 when they are asked
        // for -- so the source goes in as a stream.
        .WithFilePath(ScriptPath)
        .WithEmitDebugInformation(true);

    /// <summary>
    /// The name a caller's lines are reported against, matching the Python side's
    /// `"<script>"`. It is what <see cref="Where"/> filters a stack trace on.
    /// </summary>
    public const string ScriptPath = "<script>";

    /// <summary>
    /// Run the script and return what it returned, checked.
    ///
    /// Raises ScriptException for the three ways this goes wrong -- source that
    /// will not compile, a script that raised, and a value that cannot leave --
    /// each naming which one it was, since the caller's next move differs for
    /// each.
    /// </summary>
    public static async Task<object?> ExecuteAsync(string source, IPage page)
    {
        Script<object> compiled = Compile(source);
        ScriptState<object> state;
        try
        {
            state = await compiled.RunAsync(new ScriptGlobals { Page = page },
                                            catchException: _ => true);
        }
        catch (Exception raised)
        {
            throw Raised(raised, source);
        }

        if (state.Exception is { } thrown)
        {
            throw Raised(thrown, source);
        }

        return Crossable(state.ReturnValue);
    }

    private static ScriptException Raised(Exception raised, string source) =>
        new(ErrorCode.ScriptRaised,
            $"{raised.GetType().Name}: {raised.Message}".Split('\n')[0].TrimEnd('\r'),
            Where(raised, source), raised);

    /// <summary>
    /// Compile, reporting a syntax error against the caller's own line numbers.
    ///
    /// Roslyn reports a column as well as a line, and reports it before the
    /// browser is touched at all -- which the Python side could not do, since a
    /// SyntaxError there arrived only when the source was compiled at call time.
    /// The line needs no offset here: unlike the Python version there is no
    /// wrapper function to indent the body into, because a Roslyn script already
    /// allows `return` at the top level.
    /// </summary>
    private static Script<object> Compile(string source)
    {
        Script<object> compiled = CSharpScript.Create<object>(
            Stream(source), Options, typeof(ScriptGlobals));
        Diagnostic? bad = compiled.Compile()
            .FirstOrDefault(d => d.Severity == DiagnosticSeverity.Error);
        if (bad is null)
        {
            return compiled;
        }

        // Roslyn counts lines from zero and the caller counts from one. No
        // further offset: unlike the Python version there is no wrapper function
        // the body was indented into, so the number is already theirs.
        int line = bad.Location.GetLineSpan().StartLinePosition.Line + 1;
        throw new ScriptException(
            ErrorCode.ScriptInvalid,
            $"{bad.GetMessage()} (line {line})",
            LineOf(source, line));
    }

    /// <summary>
    /// The source as a stream, which is the overload that accepts debug
    /// information. The `string` overload fails CS8055 when asked for it.
    /// </summary>
    private static Stream Stream(string source) =>
        new MemoryStream(System.Text.Encoding.UTF8.GetBytes(source));

    /// <summary>
    /// A tool result is JSON. Playwright hands back handles, which are not.
    ///
    /// Returning an ILocator or an IElementHandle is the obvious mistake to make
    /// against an API where nearly every call returns one, so it gets an error
    /// that says what to return instead rather than a serialisation stack trace.
    /// </summary>
    public static object? Crossable(object? value)
    {
        // Checked by type before serialisation is attempted, because a Playwright
        // handle is a live object that System.Text.Json will happily walk into --
        // it would not throw, it would emit a page of the driver's internals.
        // That is the .NET-specific half of this check: Python's json.dumps
        // refused a Locator outright.
        if (value is not null && IsHandle(value.GetType()))
        {
            throw NotJson(value.GetType().Name);
        }

        try
        {
            JsonSerializer.Serialize(value);
        }
        catch (Exception exc) when (exc is JsonException or NotSupportedException)
        {
            throw NotJson(value?.GetType().Name ?? "null");
        }

        return value;
    }

    /// <summary>
    /// The Playwright handles a script must not return.
    ///
    /// A list of interfaces rather than a pattern over an instance, so the rule
    /// can be asserted without constructing one -- hand-implementing ILocator to
    /// get a test subject would be a hundred members that break on every driver
    /// update, to check a rule that is really about these eight types.
    /// </summary>
    private static readonly Type[] Handles =
    [
        typeof(ILocator), typeof(IElementHandle), typeof(IPage), typeof(IFrame),
        typeof(IBrowser), typeof(IBrowserContext), typeof(IResponse), typeof(IRequest),
    ];

    /// <summary>Is this one of the live handles that cannot cross the boundary?</summary>
    public static bool IsHandle(Type type) =>
        Array.Exists(Handles, handle => handle.IsAssignableFrom(type));

    private static ScriptException NotJson(string typeName) =>
        new(ErrorCode.ScriptReturnNotJson,
            $"a {typeName} cannot cross the tool boundary",
            "return what you wanted from it instead -- page.Url, "
            + "await locator.InnerTextAsync(), a list of hrefs");

    /// <summary>
    /// The script's own lines out of a stack trace that also holds this file.
    ///
    /// Reported against the source the caller sent, not the machinery it was
    /// compiled into, so the line numbers are the ones they can see.
    /// </summary>
    public static string Where(Exception raised, string source)
    {
        var lines = new List<string>();
        foreach (System.Diagnostics.StackFrame frame in
                 new System.Diagnostics.StackTrace(raised, fNeedFileInfo: true).GetFrames())
        {
            if (frame.GetFileName() != ScriptPath)
            {
                continue;
            }

            int number = frame.GetFileLineNumber();
            if (number <= 0)
            {
                continue;
            }

            lines.Add($"line {number}: {LineOf(source, number)}");
        }

        return string.Join("\n", lines);
    }

    /// <summary>One line of the caller's source, trimmed, or "" if out of range.</summary>
    public static string LineOf(string source, int number)
    {
        string[] body = source.Trim('\n').Split('\n');
        return number >= 1 && number <= body.Length ? body[number - 1].Trim() : "";
    }

    /// <summary>
    /// Kept so the assembly is loaded before the first script compiles.
    ///
    /// Roslyn resolves its references lazily, and the first `CSharpScript.Create`
    /// in a process pays several hundred milliseconds for it. Touching the
    /// assembly here means that cost lands at start-up rather than inside a
    /// caller's first timed call.
    /// </summary>
    public static void Warm() => _ = typeof(CSharpScript).GetTypeInfo();
}
