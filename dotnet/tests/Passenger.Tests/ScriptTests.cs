// The passthrough door's core. Pure: no browser, no page.
//
// The Python suite passed a string where a page went, because `exec` does not
// care what it binds. Roslyn does: the globals type declares `Page` as an
// `IPage`, so these tests work on sources that never touch it. That is the
// honest consequence of a typed script host, not a gap -- and the two things
// the Python tests used a fake page for, the handle refusal and the bound-name
// check, are asserted directly here instead.

using Microsoft.Playwright;
using Passenger;
using Xunit;

namespace Passenger.Tests;

public class ScriptTests
{
    private static Task<object?> Run(string source) =>
        Script.ExecuteAsync(source, null!);

    [Fact]
    public async Task AScriptReturnsAValue()
    {
        // `return` at the top level of the source, which a plain compile of a
        // method body would refuse. Roslyn allows it; the Python side had to
        // wrap the source in a function to get the same thing, and paid a line
        // of offset in every traceback for it.
        Assert.Equal(2, await Run("return 1 + 1;"));
    }

    [Fact]
    public async Task PageIsTheOnlyBoundName()
    {
        // `read` was bound beside it until ticket 046 retired extraction. A
        // script that still calls it will not compile, and is reported at the
        // caller's own line like any other mistake in their source.
        ScriptException gone = await Assert.ThrowsAsync<ScriptException>(
            () => Run("return Read(Page);"));
        Assert.Equal(ErrorCode.ScriptInvalid, gone.Code);
        Assert.Contains("Read", gone.PlainMessage, StringComparison.Ordinal);
    }

    [Fact]
    public async Task TheScriptCanSeeThePage()
    {
        // The other half of the same claim: `Page` compiles, so the one name
        // that is meant to be in scope really is.
        ScriptException raised = await Assert.ThrowsAsync<ScriptException>(
            () => Run("return Page.Url;"));
        // It compiled and then threw on the null stand-in, which is the proof
        // that the name resolved -- a missing name would have been ScriptInvalid.
        Assert.Equal(ErrorCode.ScriptRaised, raised.Code);
    }

    [Fact]
    public void ATypeNobodyListedIsStillAHandle()
    {
        // The bug the list had. `IAPIResponse` was not among the eight types
        // named by hand, so `return await Page.APIRequest.GetAsync(url)`
        // serialised the driver's own headers and timings and handed them back
        // as if they were the answer -- no error, and not the body the caller
        // asked for. Found by writing the C# skill's picture recipe (ticket 049)
        // and running it, not by review.
        Assert.True(Script.IsHandle(typeof(IAPIResponse)));
        Assert.True(Script.IsHandle(typeof(IAPIRequestContext)));
        Assert.True(Script.IsHandle(typeof(IJSHandle)));
        Assert.True(Script.IsHandle(typeof(IFrameLocator)));
        Assert.True(Script.IsHandle(typeof(IDownload)));
    }

    [Fact]
    public void PlaywrightsOwnDataTypesStillCross()
    {
        // The other edge of the rule. Everything in that namespace which is
        // *data* rather than a handle is a class or a struct, and a script that
        // returns one is doing the right thing.
        Assert.False(Script.IsHandle(typeof(FilePayload)));
        Assert.False(Script.IsHandle(typeof(SelectOptionValue)));
        Assert.False(Script.IsHandle(typeof(LocatorBoundingBoxResult)));
    }

    [Fact]
    public void AHandleIsRefusedByName()
    {
        // Ticket 013: nearly every Playwright call hands back an object that
        // cannot be JSON, so the error has to say what to return instead rather
        // than surfacing a serialisation stack trace. Checked by type because
        // System.Text.Json would not refuse a live handle -- it would happily
        // emit a page of the driver's internals.
        Assert.True(Script.IsHandle(typeof(ILocator)));
        Assert.True(Script.IsHandle(typeof(IElementHandle)));
        Assert.True(Script.IsHandle(typeof(IPage)));
    }

    [Fact]
    public void WhatAScriptIsMeantToReturnIsNotAHandle()
    {
        // The other side of the rule: a script's usual return -- text, a list of
        // hrefs -- must not be caught by it.
        Assert.False(Script.IsHandle(typeof(string)));
        Assert.False(Script.IsHandle(typeof(string[])));
        Assert.False(Script.IsHandle(typeof(Dictionary<string, string>)));
    }

    [Fact]
    public void TheRefusalSaysWhatToReturnInstead()
    {
        ScriptException refused = Assert.Throws<ScriptException>(
            () => Script.Crossable(new Unserialisable()));
        Assert.Equal(ErrorCode.ScriptReturnNotJson, refused.Code);
        Assert.NotNull(refused.Detail);
        Assert.Contains("return what you wanted", refused.Detail,
                        StringComparison.Ordinal);
    }

    [Fact]
    public async Task ASyntaxErrorPointsAtTheCallersOwnLine()
    {
        ScriptException bad = await Assert.ThrowsAsync<ScriptException>(
            () => Run("var x = 1;\nvar y = ("));
        Assert.Equal(ErrorCode.ScriptInvalid, bad.Code);
        Assert.Contains("line 2", bad.PlainMessage, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AThrowReportsTheLineItCameFrom()
    {
        // What ticket 023's measurement 3 found C# gives no line number for
        // without WithEmitDebugInformation, WithFilePath and the Stream
        // overload of Create. All three are set, so this asserts they stay set.
        ScriptException raised = await Assert.ThrowsAsync<ScriptException>(
            () => Run("var a = 1;\nvar b = 2;\n"
                      + "throw new InvalidOperationException(\"nope\");"));
        Assert.Equal(ErrorCode.ScriptRaised, raised.Code);
        Assert.Equal("InvalidOperationException: nope", raised.PlainMessage);
        Assert.NotNull(raised.Detail);
        Assert.Contains("line 3", raised.Detail, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AnEmptyScriptIsNotAnError()
    {
        // Nothing to return is a script that ran, not a script that broke.
        Assert.Null(await Run(""));
    }

    [Fact]
    public void OrdinaryValuesCross()
    {
        Assert.Equal("text", Script.Crossable("text"));
        Assert.Equal(new[] { "a", "b" }, Script.Crossable(new[] { "a", "b" }));
        Assert.Null(Script.Crossable(null));
    }

    [Fact]
    public void TheReportedLineIsTheCallersOwnText()
    {
        // Reported against the source the caller sent, so the line numbers are
        // the ones they can see.
        Assert.Equal("var b = 2;", Script.LineOf("var a = 1;\nvar b = 2;\n", 2));
        Assert.Equal("", Script.LineOf("var a = 1;", 9));
    }

    /// <summary>
    /// Something System.Text.Json genuinely refuses, for the second half of the
    /// check -- the one that catches a value no list of types could name.
    /// </summary>
    private sealed class Unserialisable
    {
        public Unserialisable Self => this;  // a cycle, which the serialiser rejects
    }
}
