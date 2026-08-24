// What the viewer's server will and will not hand out. Pure: no socket bound.
//
// The rule under test is the security-relevant half of that module. This process
// exists to serve two things, and a static server that will read any file it can
// reach is not something to leave listening on a socket, however local -- so `..`
// in a request must not walk out of the noVNC tree.

using Passenger;
using Xunit;

namespace Passenger.Tests;

public class WebserveTests
{
    private const string Root = "/usr/share/webapps/novnc";

    [Fact]
    public void TheRootIsTheViewerPage()
    {
        // The empty string means "the page embedded in the assembly", which is
        // how it is served without a path to get wrong.
        Assert.Equal("", Webserve.TranslatePath("/", Root));
        Assert.Equal("", Webserve.TranslatePath("/index.html", Root));
    }

    [Fact]
    public void AQueryStringDoesNotChangeWhichFileIsMeant()
    {
        // The viewer is always fetched as `/?ws=host:port`, so this is the
        // ordinary case rather than an edge one.
        Assert.Equal("", Webserve.TranslatePath("/?ws=127.0.0.1:5900", Root));
    }

    [Fact]
    public void NovncModulesAreServedFromTheirOwnTree() =>
        Assert.Equal($"{Root}/core/rfb.js",
                     Webserve.TranslatePath("/novnc/core/rfb.js", Root));

    [Fact]
    public void ARequestCannotWalkOutOfTheNovncTree()
    {
        Assert.Null(Webserve.TranslatePath("/novnc/../../../etc/passwd", Root));
        Assert.Null(Webserve.TranslatePath("/novnc/../../etc/shadow", Root));
    }

    [Fact]
    public void NothingElseIsServedAtAll()
    {
        // Deliberately not the behaviour of a general static server, which would
        // serve the whole working directory.
        Assert.Null(Webserve.TranslatePath("/etc/passwd", Root));
        Assert.Null(Webserve.TranslatePath("/../secrets", Root));
        Assert.Null(Webserve.TranslatePath("/anything.js", Root));
    }

    [Fact]
    public void TheViewerPageIsInTheAssembly()
    {
        // Embedded rather than read from a path beside the binary, so a
        // single-file publish still serves it. A missing resource is a load-time
        // failure rather than a first-handoff one.
        Assert.Contains("<", Webserve.Page, StringComparison.Ordinal);
    }
}
