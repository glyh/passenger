// Imperative shell: asking a human to solve what the agent must not.
//
// Nothing here tries to solve a challenge. Solver services get profiles burned
// and make the browser *more* detectable; a human solving it once into a
// persistent profile is both more robust and the defensible version of this.

using Microsoft.Playwright;

namespace Passenger;

public static class Handoff
{
    private const int PollIntervalMs = 2000;

    /// <summary>
    /// Poll until the vendor's signature stops matching, and say what ended it.
    ///
    /// The other half of asking for a human. <see cref="WaitForDismissalAsync"/>
    /// waits on the human saying they are done; this waits on the *page* saying
    /// the wall is gone, which is a different fact and a stronger one -- a human
    /// can close the viewer without having solved anything.
    ///
    /// This is a measurement, not a judgement, and only because the signature
    /// table is fixed (ticket 038): a vendor either serves that markup or does
    /// not. It used to live inside `fetch`, re-extracting the page on every tick
    /// to hand the content back in the same call. `fetch` is gone (ticket 046) and
    /// so is the extraction -- what is polled now is the signature alone, and the
    /// caller reads the page itself afterwards.
    /// </summary>
    public static async Task<string> WaitUntilUnblockedAsync(IPage page, int? timeoutS = null)
    {
        int budget = timeoutS ?? Config.HandoffTimeoutS;
        DateTime deadline = DateTime.UtcNow.AddSeconds(budget);
        while (DateTime.UtcNow < deadline)
        {
            await Task.Delay(PollIntervalMs);
            if (await ClearAsync(page))
            {
                int waited = budget - (int)(deadline - DateTime.UtcNow).TotalSeconds;
                return $"wall cleared after {waited}s";
            }
        }

        return $"still blocked after {budget}s";
    }

    /// <summary>
    /// Block until the human closes the viewer, and say what ended the wait.
    ///
    /// The deliberate half of asking for a human (ticket 018). Nothing here looks
    /// at the page: with no signature to re-check there is no fact this side can
    /// read that says "solved", and every proxy for one -- the URL changed, the
    /// word count moved -- is the guess ticket 005 deleted, made again on weaker
    /// evidence. The caller recognised the wall well enough to ask for a human;
    /// it can read the page afterwards and see whether the wall is gone.
    ///
    /// So the only thing waited on is the human saying they are done, which they
    /// say by closing the window. A presenter that cannot see its own window is
    /// told to poll instead of being handed a wait that would return instantly.
    /// </summary>
    public static async Task<string> WaitForDismissalAsync(IPresenter presenter, int timeoutS)
    {
        if (!presenter.ObservesPresence)
        {
            return $"cannot wait on the {presenter.Name.Value()} presenter: it "
                   + "cannot see whether the viewer is open. Poll the tab with "
                   + "`script` instead";
        }

        DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutS);
        while (DateTime.UtcNow < deadline)
        {
            await Task.Delay(PollIntervalMs);
            if (!presenter.Presented())
            {
                int waited = timeoutS - (int)(deadline - DateTime.UtcNow).TotalSeconds;
                return $"viewer closed after {waited}s";
            }
        }

        return $"still open after {timeoutS}s";
    }

    /// <summary>One poll. False means the signature still matches, or mid-navigation.</summary>
    private static async Task<bool> ClearAsync(IPage page)
    {
        try
        {
            return Detect.Classify(await Probe.MeasureAsync(page)) is null;
        }
        catch (Exception)
        {
            return false;  // navigating; try again next tick
        }
    }

    public static async Task BringToFrontAsync(IPage page)
    {
        try
        {
            await page.BringToFrontAsync();
        }
        catch (Exception)
        {
            // A tab that will not come forward is not a reason to fail the
            // handoff: the window is still going up, on some tab.
        }
    }
}
