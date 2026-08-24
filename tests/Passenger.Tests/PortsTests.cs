// Reading /proc/net/tcp: which process is holding a local port.
//
// Only the column arithmetic is testable here -- the fd scan needs a real
// process holding a real socket -- and it is the half that is easy to get
// wrong, because the table is hex throughout and the port is the tail of the
// local address rather than a field of its own.

using Passenger;
using Xunit;

namespace Passenger.Tests;

public class PortsTests
{
    // Verbatim shape of the table, header included: 6080 is 0x17C0, and the
    // inode is the tenth column.
    private static readonly string[] Table =
    [
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode",
        "   0: 0100007F:17C0 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 913874 1 0000000000000000 100 0 0 10 0",
        "   1: 0100007F:1770 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 913875 1 0000000000000000 100 0 0 10 0",
        "   2: 0100007F:17C0 0100007F:B3F2 01 00000000:00000000 00:00000000 00000000  1000        0 999999 1 0000000000000000 20 4 30 10 -1",
    ];

    [Fact]
    public void TheListenerOnAPortIsFoundByItsInode() =>
        Assert.Equal(913874L, Sessions.ListeningInode(Table, 6080));

    [Fact]
    public void AConnectionToThatPortIsNotAListenerOnIt()
    {
        // The last row is a client talking *to* 6080, state 01 rather than 0A.
        // Taking it for the listener would name the browser as the squatter.
        Assert.Equal(913874L, Sessions.ListeningInode([Table[3], Table[1]], 6080));
        Assert.Null(Sessions.ListeningInode([Table[0], Table[3]], 6080));
    }

    [Fact]
    public void APortNobodyHoldsHasNoInode() =>
        Assert.Null(Sessions.ListeningInode(Table, 6081));
}
