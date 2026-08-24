// Imperative shell: Chrome's targets, over the endpoints the browser answers.
//
// Everything here speaks to the CDP *HTTP* endpoint and to a page's own
// websocket, deliberately going around Patchright. That is the whole point: when
// one tab is stuck mid-navigation, Patchright cannot attach at all -- it
// initialises every page that is already open and waits for all of them -- so the
// recovery path cannot be built on the thing that is stuck.
//
// Measured, on a tab left mid-navigation: `Page.getFrameTree` gets no reply at
// all, where a healthy tab answers in under 10ms. `Page.stopLoading` on that same
// tab is answered immediately, and the tab answers everything again afterwards.
// So a stuck tab is *unstuck*, not closed: whatever document it already had --
// the page a human was reading, most often -- survives.
//
// There is a second way to hold the attach open, and it looks like the opposite
// from here (ticket 042). A tab created *at* a URL -- a popup, a target=_blank a
// human clicked, a session restore -- never commits a document if that URL never
// answers. Its renderer has nothing to be busy with, so it answers `getFrameTree`
// in under 10ms and reads as healthy, while the attach hangs just as hard. What
// gives it away is the answer rather than the silence: the frame's URL is the
// empty string, which is Chrome for "no document here at all".

using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Passenger;

public static class Targets
{
    /// <summary>
    /// How long a page gets to answer a question its renderer answers instantly
    /// when it is healthy. Generous by two orders of magnitude, because the cost
    /// of being wrong is stopping a navigation someone wanted.
    /// </summary>
    public const double ProbeDeadlineS = 3.0;

    /// <summary>
    /// The same question asked for a report rather than for a rescue. Shorter,
    /// because `status` walks every tab and nothing is freed on the strength of
    /// the answer: a page that misses this deadline is named, not acted on.
    /// </summary>
    public const double StatusDeadlineS = 1.0;

    /// <summary>
    /// Chrome's way of saying a frame holds no document. Not "about:blank", which
    /// is a document -- an empty string, which is the absence of one.
    /// </summary>
    public const string NoDocument = "";

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(5) };

    /// <summary>Every target Chrome currently holds, browser UI and workers included.</summary>
    public static IReadOnlyList<Target> Listing()
    {
        string payload = Http.GetStringAsync($"{Config.CdpUrl}/json/list")
                             .GetAwaiter().GetResult();
        return Parse(payload);
    }

    /// <summary>Pure: the endpoint's JSON as models. Unknown fields are dropped.</summary>
    public static IReadOnlyList<Target> Parse(string payload) =>
        JsonSerializer.Deserialize<List<Target>>(payload) ?? [];

    public static IReadOnlyList<Target> Pages() =>
        [.. Listing().Where(t => t.IsPage)];

    /// <summary>
    /// Every page that is holding the attach open, and which way it is doing it.
    ///
    /// Read-only: this is the half `status` can call. Freeing them is
    /// <see cref="Unstick"/>.
    /// </summary>
    public static IReadOnlyList<(Target Page, Wedge Wedge)> Stuck(
        double deadlineS = ProbeDeadlineS)
    {
        var found = new List<(Target, Wedge)>();
        foreach (Target page in Pages())
        {
            if (string.IsNullOrEmpty(page.WebsocketUrl))
            {
                // Nothing to ask; Chrome withholds a socket for its own UI.
                continue;
            }

            Wedge? wedge = Diagnose(page, deadlineS);
            if (wedge is not null)
            {
                found.Add((page, wedge.Value));
            }
        }

        return found;
    }

    /// <summary>
    /// Free every page that is holding the attach open, each its own way.
    ///
    /// Returns the pages that were stuck, which is also the answer to "was there
    /// anything wrong with the browser, or is the attach failing for some other
    /// reason". An empty result means the hang is not this.
    ///
    /// Called only after an attach has already timed out, and that is what makes
    /// the Uncommitted remedy affordable. A tab that has yet to commit a document
    /// is indistinguishable from a tab on a merely slow host -- both are waiting
    /// on headers, and no field separates them -- so this does stop a navigation
    /// someone may have wanted. What it has to weigh against is that the same
    /// navigation has been failing every call in every lane for the whole attach
    /// timeout, and that re-navigating is cheap where a bricked tool is not.
    /// </summary>
    public static IReadOnlyList<Target> Unstick(double deadlineS = ProbeDeadlineS)
    {
        var freed = new List<Target>();
        foreach ((Target page, Wedge wedge) in Stuck(deadlineS))
        {
            if (Free(page, wedge, deadlineS))
            {
                freed.Add(page);
            }
        }

        return freed;
    }

    /// <summary>
    /// One line naming the wedged tabs, for `status`. "none" when there are none.
    ///
    /// A tab that has been navigating for minutes is the thing a human staring at
    /// a tool that will not answer would want named, and until now nothing said
    /// it: `status` reported a tab count, and a wedged tab counts the same as a
    /// working one. A count per wedge and no more -- which tab, in whose lane, is
    /// a listing, and a lane's tabs are nobody else's business (ticket 040).
    ///
    /// Counting Uncommitted here counts a tab that is merely mid-navigation, which
    /// is honest: it is navigating, and this says so rather than ruling on whether
    /// it is stuck. Nothing is freed on the strength of it.
    /// </summary>
    public static string StuckSummary(double deadlineS = StatusDeadlineS)
    {
        var counts = new Dictionary<Wedge, int>();
        foreach ((_, Wedge wedge) in Stuck(deadlineS))
        {
            counts[wedge] = counts.GetValueOrDefault(wedge) + 1;
        }

        if (counts.Count == 0)
        {
            return "none";
        }

        // Iterated in declaration order rather than in the order encountered, so
        // the line reads the same way twice for the same browser.
        return string.Join(", ", Enum.GetValues<Wedge>()
            .Where(counts.ContainsKey)
            .Select(w => $"{counts[w]} {w.Value()}"));
    }

    /// <summary>Ask one page to describe itself. Null means it is fine.</summary>
    private static Wedge? Diagnose(Target page, double deadlineS)
    {
        try
        {
            return Verdict(CallAsync(page.WebsocketUrl, 1, "Page.getFrameTree",
                                     deadlineS).GetAwaiter().GetResult());
        }
        catch (Exception)
        {
            // A target that cannot even be connected to is not one we can rescue,
            // and guessing at it would risk stopping a navigation that is fine.
            return null;
        }
    }

    /// <summary>
    /// Pure: what one `Page.getFrameTree` answer says about the tab.
    ///
    /// Null for the reply means the renderer never answered at all.
    /// </summary>
    public static Wedge? Verdict(JsonNode? reply)
    {
        if (reply is null)
        {
            return Wedge.Silent;
        }

        if (reply["result"] is not JsonNode result)
        {
            // An error reply is still an answer, so the renderer is alive -- but it
            // is not one this can read a frame out of. Conservative on purpose:
            // the remedies here stop navigations, and a reply nobody planned for is
            // a bad reason to stop one.
            return null;
        }

        string? url = result["frameTree"]?["frame"]?["url"]?.GetValue<string>();
        return (url ?? NoDocument) == NoDocument ? Wedge.Uncommitted : null;
    }

    /// <summary>
    /// What frees each wedge, measured one against the other on a server that
    /// accepts and then answers nothing. Neither remedy works on the other's tab.
    /// </summary>
    private static readonly Dictionary<Wedge, (string Method, JsonObject Params)> Remedy =
        new()
        {
            [Wedge.Silent] = ("Page.stopLoading", []),
            [Wedge.Uncommitted] = ("Page.navigate", new JsonObject
            {
                ["url"] = "about:blank",
            }),
        };

    /// <summary>Apply this wedge's remedy. True if the page took it.</summary>
    private static bool Free(Target page, Wedge wedge, double deadlineS)
    {
        (string method, JsonObject parameters) = Remedy[wedge];
        try
        {
            // The params object is cloned per call: a JsonNode carries a parent,
            // so handing the same instance to two sockets would reparent it.
            _ = CallAsync(page.WebsocketUrl, 1, method, deadlineS,
                          parameters.DeepClone().AsObject())
                .GetAwaiter().GetResult();
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// One CDP command over its own socket. Null means the renderer never answered.
    ///
    /// Replies have to be picked out of the event stream by id: a page under
    /// navigation emits lifecycle events continuously, and reading the next frame
    /// would read one of those instead of the answer.
    ///
    /// The Python side's hand-rolled deadline -- a loop recomputing what is left
    /// of the budget before every recv -- collapses into one CancellationToken
    /// here, which covers the connect and every read alike.
    /// </summary>
    internal static async Task<JsonNode?> CallAsync(
        string socketUrl, int ident, string method, double deadlineS,
        JsonObject? parameters = null)
    {
        using var deadline = new CancellationTokenSource(
            TimeSpan.FromSeconds(deadlineS));
        using var socket = new ClientWebSocket();
        try
        {
            await socket.ConnectAsync(new Uri(socketUrl), deadline.Token);
            var request = new JsonObject
            {
                ["id"] = ident,
                ["method"] = method,
                ["params"] = parameters ?? [],
            };
            await socket.SendAsync(
                Encoding.UTF8.GetBytes(request.ToJsonString()),
                WebSocketMessageType.Text, endOfMessage: true, deadline.Token);

            while (true)
            {
                string? frame = await ReceiveAsync(socket, deadline.Token);
                if (frame is null)
                {
                    return null;  // the socket closed before the answer came
                }

                JsonNode? message = JsonNode.Parse(frame);
                if (message?["id"]?.GetValue<int>() == ident)
                {
                    return message;
                }
            }
        }
        catch (OperationCanceledException)
        {
            return null;  // the budget ran out: the renderer never answered
        }
        finally
        {
            // Best effort: the socket is being dropped either way, and a close
            // handshake against a renderer that is not answering would itself
            // need a deadline.
            if (socket.State == WebSocketState.Open)
            {
                try
                {
                    await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "",
                                            CancellationToken.None);
                }
                catch (Exception)
                {
                    // Nothing left to do about it.
                }
            }
        }
    }

    /// <summary>One whole websocket text message, however many frames it took.</summary>
    private static async Task<string?> ReceiveAsync(ClientWebSocket socket,
                                                    CancellationToken token)
    {
        var buffer = new byte[8192];
        var whole = new MemoryStream();
        while (true)
        {
            WebSocketReceiveResult received =
                await socket.ReceiveAsync(new ArraySegment<byte>(buffer), token);
            if (received.MessageType == WebSocketMessageType.Close)
            {
                return null;
            }

            whole.Write(buffer, 0, received.Count);
            if (received.EndOfMessage)
            {
                return Encoding.UTF8.GetString(whole.ToArray());
            }
        }
    }

    /// <summary>
    /// The *browser* process's own websocket, which no page owns.
    ///
    /// `/json/list` describes pages and hands out a socket per page; the browser
    /// endpoint is only in `/json/version`, and it is the one that can answer
    /// `Target.getTargets` -- the question with `openerId` in the reply.
    /// </summary>
    public static string BrowserSocket()
    {
        string payload = Http.GetStringAsync($"{Config.CdpUrl}/json/version")
                             .GetAwaiter().GetResult();
        return JsonNode.Parse(payload)?["webSocketDebuggerUrl"]?.GetValue<string>() ?? "";
    }

    /// <summary>
    /// Which tab opened which, as Chrome itself records it.
    ///
    /// A page that calls `window.open`, or a link with `target="_blank"`, creates
    /// a target nobody asked this tool for. Attributing it to the lane that
    /// caused it needs a record of causation, and Chrome has one: `openerId` on
    /// `Target.getTargets`. Guessing from timing or URL was the alternative, and
    /// it is the kind of heuristic this project keeps deleting.
    ///
    /// Not available from `/json/list`, which is why this goes to the websocket.
    /// An empty map on any failure: adoption is an improvement over leaving a tab
    /// unowned, never a precondition for the caller's actual work.
    /// </summary>
    public static IReadOnlyDictionary<string, string> Openers(
        double deadlineS = ProbeDeadlineS)
    {
        var empty = new Dictionary<string, string>();
        JsonNode? reply;
        try
        {
            string socketUrl = BrowserSocket();
            if (string.IsNullOrEmpty(socketUrl))
            {
                return empty;
            }

            reply = CallAsync(socketUrl, 1, "Target.getTargets", deadlineS)
                .GetAwaiter().GetResult();
        }
        catch (Exception)
        {
            return empty;
        }

        return OpenersOf(reply);
    }

    /// <summary>Pure: the opener map out of one `Target.getTargets` answer.</summary>
    public static IReadOnlyDictionary<string, string> OpenersOf(JsonNode? reply)
    {
        var openers = new Dictionary<string, string>();
        if (reply?["result"]?["targetInfos"] is not JsonArray infos)
        {
            return openers;
        }

        foreach (JsonNode? info in infos)
        {
            if (info?["type"]?.GetValue<string>() != "page")
            {
                continue;
            }

            string? opener = info["openerId"]?.GetValue<string>();
            string? target = info["targetId"]?.GetValue<string>();
            if (!string.IsNullOrEmpty(opener) && !string.IsNullOrEmpty(target))
            {
                openers[target] = opener;
            }
        }

        return openers;
    }

    /// <summary>
    /// Close one target through the browser process. True if it answered.
    ///
    /// Goes around Patchright for the same reason the rest of this module does:
    /// tab bookkeeping must keep working when a renderer does not, and an attach
    /// that initialises every open tab is a strange price to pay for closing one.
    /// </summary>
    public static bool Close(string targetId)
    {
        try
        {
            using HttpResponseMessage response =
                Http.GetAsync($"{Config.CdpUrl}/json/close/{targetId}")
                    .GetAwaiter().GetResult();
            return response.IsSuccessStatusCode;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
