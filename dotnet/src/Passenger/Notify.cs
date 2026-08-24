// Imperative shell: telling a human they're needed.
//
// A desktop notification only reaches someone sitting at this machine. In a
// container -- or on a server -- the same event has to travel differently, so the
// mechanism is an interface rather than a hardcoded notify-send.

using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Passenger;

public interface INotifier
{
    void Notify(string title, string message);
}

public static class Notify
{
    private const int WebhookTimeoutS = 5;

    /// <summary>Always available, and the only one guaranteed to be seen in a pipeline.</summary>
    public sealed class StderrNotifier : INotifier
    {
        public void Notify(string title, string message) =>
            Console.Error.WriteLine($"\n!! {title}: {message}");
    }

    public sealed class DesktopNotifier : INotifier
    {
        public void Notify(string title, string message)
        {
            try
            {
                var start = new ProcessStartInfo("notify-send")
                {
                    UseShellExecute = false,
                };
                foreach (string arg in new[] { "-u", "critical", title, message })
                {
                    start.ArgumentList.Add(arg);
                }

                using Process? process = Process.Start(start);
                process?.WaitForExit();
            }
            catch (Exception)
            {
                // `check=False` on the Python side: a notifier that cannot run is
                // not a reason to fail the handoff it was announcing.
            }
        }
    }

    /// <summary>
    /// POSTs to whatever PASSENGER_WEBHOOK points at -- ntfy, Slack, etc.
    ///
    /// This is what makes a headless deployment usable: the browser can be on a
    /// server and still reach you when a challenge needs solving.
    /// </summary>
    public sealed class WebhookNotifier(string url) : INotifier
    {
        private static readonly HttpClient Http =
            new() { Timeout = TimeSpan.FromSeconds(WebhookTimeoutS) };

        public void Notify(string title, string message)
        {
            string payload = JsonSerializer.Serialize(new
            {
                title,
                text = message,
                message,
            });
            try
            {
                using var body = new StringContent(payload, Encoding.UTF8, "application/json");
                using HttpResponseMessage response =
                    Http.PostAsync(url, body).GetAwaiter().GetResult();
            }
            catch (Exception exc)
            {
                Console.Error.WriteLine($"   webhook failed: {exc.Message}");
            }
        }
    }

    public sealed class FanOutNotifier(params INotifier[] targets) : INotifier
    {
        public void Notify(string title, string message)
        {
            foreach (INotifier target in targets)
            {
                target.Notify(title, message);
            }
        }
    }

    /// <summary>Stderr always, plus whatever else can actually reach the user.</summary>
    public static INotifier Select()
    {
        var targets = new List<INotifier> { new StderrNotifier() };
        if (Launch.Which("notify-send") is not null)
        {
            targets.Add(new DesktopNotifier());
        }

        if (Config.Settings.WebhookUrl is { } url)
        {
            targets.Add(new WebhookNotifier(url));
        }

        return new FanOutNotifier([.. targets]);
    }
}
