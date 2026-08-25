{
  description = "passenger: web context through a real, logged-in Chrome";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # The MCP C# SDK, forked. Upstream's stdio transport writes the JSON-RPC
    # envelope through a frozen JsonSerializerOptions whose encoder escapes
    # every non-ASCII character (ticket 056, csharp-sdk#795); the fork adds the
    # hook that lets a server choose the encoder. Pinned as a source input, not
    # a flake, and built into nupkgs below.
    mcp-csharp-sdk = {
      url = "github:glyh/csharp-sdk/utf8-wire-encoding";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, mcp-csharp-sdk }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # noVNC's static files, and nothing else from that package. The
        # package itself carries websockify -- and so numpy -- for 471 MiB,
        # where the viewer needs 1.8 MB of JavaScript: wayvnc serves the
        # websocket itself (--websocket), and the page is served by this
        # tool's own webserver. Copying the tree into its own derivation is
        # what keeps that closure out; plain files reference nothing.
        novncStatic = pkgs.runCommand "novnc-static" { } ''
          cp -r ${pkgs.novnc}/share/webapps/novnc $out
        '';

        # The nested compositor and its VNC server. These are the packages you
        # would otherwise install with a system package manager.
        #
        # sway rather than cage since ticket 063, and the swap costs 33 MiB on a
        # 896 MiB closure -- cage was never the light one, since wlroots, Xwayland
        # and mesa dominate either way. What the 33 MiB buys is a data-control
        # protocol (so wayvnc's clipboard has something to talk to), text-input
        # and input-method (so an IME can exist in the session at all), several
        # headless outputs on request, and swaymsg to ask for any of it. `sway`
        # brings swaymsg with it, which the session script needs.
        #
        # dbus is here for `dbus-send`: the session asks the human's own fcitx5
        # to serve its display too, over the D-Bus interface fcitx5 already
        # exposes for serving more than one compositor (ticket 066). No IME is
        # started here and none is pinned -- theirs is the one that runs.
        #
        # No VNC client: the viewer is a page in the host's own browser (see
        # Present.cs). That is not only lighter than every native client that
        # would do, it is the only one that sizes itself correctly -- noVNC
        # asks for the framebuffer its window needs and keeps asking as the
        # window changes. The light native clients cannot be sized at all, and
        # the one that can costs 1.2 GiB to do the same job.
        #
        # wlr-randr and wayland-utils remain for the one thing a viewer cannot
        # ask for: the output scale, which decides the density the nested
        # Chrome renders at.
        runtimeDeps = with pkgs; [ sway wayvnc wlr-randr wayland-utils dbus ];

        # Deliberately NOT pinned here: Chrome is taken from the host.
        #
        # Pinning the browser would freeze its version, and the version string
        # is one of the most visible fingerprint fields there is -- a Chrome
        # that drifts months behind what real users run becomes a tell in
        # itself, and stops receiving security updates. Everything else in this
        # flake is pinned; the browser is the one thing that should keep
        # updating on the vendor's schedule.
        chromeNote = ''
          passenger uses the host's Chrome (PASSENGER_CHROME,
          default google-chrome-stable) so it keeps its own update cadence.
        '';

        dotnet-sdk = pkgs.dotnetCorePackages.sdk_10_0;

        # The forked SDK, packed as nupkgs rather than referenced as projects:
        # passenger keeps a PackageReference, and this derivation is what that
        # reference resolves against. `mcpSdkVersion` is the version those
        # packages carry, and Passenger.Mcp.csproj must ask for exactly it.
        mcpSdkVersion = "2.2.0-utf8wire.1";

        mcpSdk = pkgs.buildDotnetModule {
          pname = "ModelContextProtocol";
          version = mcpSdkVersion;
          src = mcp-csharp-sdk;

          projectFile = [
            "src/ModelContextProtocol.Core/ModelContextProtocol.Core.csproj"
            "src/ModelContextProtocol/ModelContextProtocol.csproj"
          ];

          inherit dotnet-sdk;
          nugetDeps = ./mcp-sdk-deps.json;

          # Libraries, not an application: nothing to publish or wrap, and the
          # nupkgs are the whole output.
          dontPublish = true;
          packNupkg = true;
          executables = [ ];

          # Without this the fixup hooks rewrite each packed nupkg down to its
          # .nuspec, on the assumption that the only consumer is a nix build
          # -- which gets the real contents from a fallback packages folder
          # the hooks fill in separately. A `dotnet restore` run by hand has
          # no such folder, and a nuspec-only package restores to a project
          # that cannot see a single type in it. Keep the contents.
          createInstallableNugetSource = true;

          # buildDotnetModule derives -p:Version from the derivation's version
          # by keeping only its numeric components, which would drop the
          # prerelease tag that keeps these packages distinguishable from
          # nuget.org's 2.2.0. Pack flags come last on the command line, so
          # this is the version that lands in the nupkg.
          dotnetPackFlags = [
            "-p:Version=${mcpSdkVersion}"
            # The baseline package this validates against is not in the
            # offline source, and the fork's changes are additive anyway.
            "-p:EnablePackageValidation=false"
          ];
        };

        # .git and the local build detritus are not inputs; without this filter
        # every write to any of them would invalidate the build.
        source = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            !(builtins.elem (baseNameOf (toString path)) [
              ".direnv" ".git" "result"
            ]);
        };

        # One published binary, since ticket 057 deleted the CLI. `projectFile`
        # stays a list because the test project is built beside it, not because
        # there is a second entry point any more.
        passenger = pkgs.buildDotnetModule {
          pname = "passenger";
          version = "0.1.0";
          src = source;

          projectFile = [ "src/Passenger.Mcp/Passenger.Mcp.csproj" ];
          testProjectFile = "tests/Passenger.Tests/Passenger.Tests.csproj";
          executables = [ "Passenger.Mcp" ];

          # Where the forked ModelContextProtocol packages come from: nupkgs
          # in a build input, not nuget.org, so they are absent from deps.json.
          projectReferences = [ mcpSdk ];

          inherit dotnet-sdk;
          nugetDeps = ./deps.json;

          # None of the suite drives a real Chrome, so it needs no pinned
          # browser the way a DOM-walker test would: it is unit tests over the
          # pure core and over sockets/temp dirs the Sandbox fixture redirects
          # first. Safe to run in the sandbox, and kept in the same derivation
          # as the build rather than a separate `checks` output, because there
          # is no browser dependency forcing them apart.
          doCheck = true;

          # Both entry points need the compositor on PATH and the viewer's
          # JavaScript findable; neither can be discovered at runtime.
          makeWrapperArgs = [
            "--prefix" "PATH" ":" (pkgs.lib.makeBinPath runtimeDeps)
            "--set-default" "PASSENGER_NOVNC" novncStatic
          ];

          # The Patchright NuGet package bundles its own Node -- the thing
          # that actually drives Playwright's wire protocol -- as a
          # platform-specific binary linked against
          # /lib64/ld-linux-x86-64.so.2, which does not exist here.
          # Substitute nixpkgs' own node for the bundled one rather than patch
          # the ELF interpreter.
          postFixup = ''
            for node in $out/lib/passenger/.playwright/node/*/node; do
              rm "$node"
              ln -s ${pkgs.lib.getExe pkgs.nodejs} "$node"
            done
          '';

          meta.mainProgram = "Passenger.Mcp";
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = runtimeDeps ++ [ dotnet-sdk ];
          # `dotnet build` outside the sandbox restores from nuget.org, which
          # has never heard of the forked packages. Directory.Build.props adds
          # this to the restore sources when it is set.
          MCP_SDK_NUGET_SOURCE = "${mcpSdk}/share/nuget/source";
          # Everything the hook prints goes to stderr. `nix develop --command`
          # forwards hook output to stdout, which would corrupt any program
          # speaking a protocol there -- the MCP server talks JSON-RPC on stdio.
          # The viewer page needs noVNC's modules; the dev shell points at the
          # same store path the wrapper does.
          NOVNC_STATIC = novncStatic;
          shellHook = ''
            export PASSENGER_NOVNC="''${PASSENGER_NOVNC:-${novncStatic}}"
            {
              echo "passenger dev shell"
              echo "${chromeNote}"
              echo "run: dotnet run --project src/Passenger.Mcp -- stop"
            } >&2
          '';
        };

        packages.default = passenger;

        # Exposed so `nix run .#mcp-sdk.passthru.fetch-deps` can regenerate
        # mcp-sdk-deps.json when the fork moves.
        packages.mcp-sdk = mcpSdk;

        # One binary, one app, one name. `apps.mcp` was the address a client's
        # config named while `apps.default` pointed at the CLI; with the CLI gone
        # there is nothing for the two to distinguish, and keeping `mcp` as an
        # alias would be a second name for the only thing there is. A registration
        # that still says `#mcp` needs its line changed to plain `nix run`.
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/Passenger.Mcp";
        };
      });
}
