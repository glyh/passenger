// The MCP entry point, and since ticket 057 the only entry point there is.
//
// Everything the server says about itself is here; everything it can do is in
// Tools.cs. stdio because that is what an MCP client launches, and it is why
// nothing in this process may write to stdout except the protocol -- the flake's
// shell hook carries the same warning for the same reason.
//
// Two things run before the server and neither one starts it: the viewer re-exec,
// and the human's `stop`. Both are argv checks, deliberately ahead of anything
// that could write a byte to stdout.

using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using ModelContextProtocol;
using ModelContextProtocol.Server;
using Passenger;
using Passenger.Mcp;
using System.Text.Encodings.Web;
using System.Text.Json;

// Before anything else: the detached re-exec that serves the viewer page. This
// process is the one that ends up serving it.
if (Webserve.ServeIfAsked(args))
{
    return 0;
}

// The one verb a person types, and the only argv this binary accepts. Null means
// there was none, so the server starts as a client expects it to.
if (Stop.IfAsked(args) is { } status)
{
    return status;
}

// Roslyn's first compile in a process costs several hundred milliseconds of
// reference resolution. Paying it at start-up keeps it out of the caller's
// first timed `script` call.
Script.Warm();

HostApplicationBuilder builder = Host.CreateApplicationBuilder(args);

// What goes on the wire, character by character. The SDK's default encoder
// leaves only BasicLatin alone and escapes everything else to \uXXXX -- six
// bytes for a CJK character that UTF-8 writes in three, on every `script`
// reply read straight into a caller's context. Ticket 056 measured that.
//
// It has to be said twice because a reply is written twice. A tool's return
// value becomes a JSON *document* inside a content block, written with the
// options the tool registration carries; the JSON-RPC envelope that wraps
// that document is written separately, with the server's. Set one and the
// other re-escapes what it was handed, which is why 056 found the tool
// options alone had no effect on the bytes.
JsonSerializerOptions wireOptions = new(McpJsonUtilities.DefaultOptions)
{
    Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
};

// Every log line goes to stderr. The protocol owns stdout, and a stray info
// line there corrupts the JSON-RPC stream -- the same hazard the flake's shell
// hook is written around.
builder.Logging.ClearProviders();
builder.Logging.AddConsole(options => options.LogToStandardErrorThreshold = LogLevel.Trace);

builder.Services
    .AddMcpServer(options =>
    {
        // The name a client shows and configures this by. Without it the SDK
        // uses the assembly name, which is Passenger.Mcp.
        options.ServerInfo = new ModelContextProtocol.Protocol.Implementation
        {
            Name = "passenger",
            Version = "0.1.0",
        };
        options.ServerInstructions =
            "Reach web pages through a real, logged-in Chrome that sites cannot "
            + "distinguish from an ordinary browser. Use this instead of a plain "
            + "HTTP fetch when a page needs a login, is behind anti-bot protection, "
            + "or renders its content with JavaScript.\n\n"
            + "Call `openLane` first: every tab you open lives in your lane, and "
            + "no other caller can see or close it.\n\n"
            + "`script` is the only door onto a page: it navigates, drives and hands "
            + "back what you return. This server does not interpret pages -- there "
            + "is no extraction here, and reading one is yours to write.\n\n"
            + "How to operate it -- the recipes for reading a page, what `blocked` "
            + "does and does not catch, recognising a wall it cannot name, why a "
            + "read is only the first screen, and why reading beats driving -- is "
            + "the `using-passenger` skill. Load it before the first call.";

        // The envelope's half. Upstream 2.2.0 has no such property -- reaching
        // this encoder is the whole reason this repo builds a forked SDK.
        options.JsonSerializerOptions = wireOptions;
    })
    .WithStdioServerTransport()
    // The content block's half, and this one upstream has always accepted.
    .WithToolsFromAssembly(serializerOptions: wireOptions);

await builder.Build().RunAsync();
return 0;
