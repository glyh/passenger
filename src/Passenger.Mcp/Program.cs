// The MCP entry point.
//
// Everything the server says about itself is here; everything it can do is in
// Tools.cs. stdio because that is what an MCP client launches, and it is why
// nothing in this process may write to stdout except the protocol -- the flake's
// shell hook carries the same warning for the same reason.

using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using ModelContextProtocol;
using ModelContextProtocol.Server;
using Passenger;
using System.Text.Encodings.Web;
using System.Text.Json;

// Before anything else: the detached re-exec that serves the viewer page.
// Either frontend can be the one that ends up serving it.
if (Webserve.ServeIfAsked(args))
{
    return;
}

// Roslyn's first compile in a process costs several hundred milliseconds of
// reference resolution. Paying it at start-up keeps it out of the caller's
// first timed `script` call.
Script.Warm();

HostApplicationBuilder builder = Host.CreateApplicationBuilder(args);

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

        // What goes on the wire, character by character. The SDK's default
        // encoder leaves only BasicLatin alone and escapes everything else to
        // \uXXXX -- six bytes for a CJK character that UTF-8 writes in three,
        // on every `script` reply read straight into a caller's context.
        // Ticket 056 measured that and found no way to reach the envelope's
        // encoder; this property is the fork's answer to it.
        options.JsonSerializerOptions = new JsonSerializerOptions(McpJsonUtilities.DefaultOptions)
        {
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        };
    })
    .WithStdioServerTransport()
    .WithToolsFromAssembly();

await builder.Build().RunAsync();
