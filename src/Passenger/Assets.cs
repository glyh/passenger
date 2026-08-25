// The files that ship inside the assembly, and how to read one.
//
// Everything here is a template or a page rather than code: the viewer a human
// takes the browser over in, and the session's own shell script, sway config and
// IME snippet. They are embedded so that a single-file publish still carries
// them and there is no path to get wrong when this is installed outside a source
// tree -- and they are *files* in the source tree rather than string literals in
// C#, so a shell script can be read, diffed and linted as one.

using System.Reflection;

namespace Passenger;

internal static class Assets
{
    /// <summary>
    /// An embedded resource, by its logical name.
    ///
    /// Missing is a build error that got as far as running, not a condition any
    /// caller can do anything about, so it throws rather than returning null.
    /// </summary>
    public static string Read(string name)
    {
        using Stream stream = Assembly.GetExecutingAssembly()
            .GetManifestResourceStream(name)
            ?? throw new InvalidOperationException(
                $"{name} is missing from the assembly");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}
