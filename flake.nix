{
  description = "passenger: web context through a real, logged-in Chrome";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
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
        runtimeDeps = with pkgs; [ cage wayvnc wlr-randr wayland-utils ];

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

        # .git and the local build detritus are not inputs; without this filter
        # every write to any of them would invalidate the build.
        source = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            !(builtins.elem (baseNameOf (toString path)) [
              ".direnv" ".git" "result"
            ]);
        };

        # The three projects, published together into one directory
        # (buildDotnetModule's default `dotnetInstallPath` for every
        # `projectFile` entry) so the CLI and the MCP server share one copy of
        # the Playwright driver rather than two.
        passenger = pkgs.buildDotnetModule {
          pname = "passenger";
          version = "0.1.0";
          src = source;

          projectFile = [
            "src/Passenger.Cli/Passenger.Cli.csproj"
            "src/Passenger.Mcp/Passenger.Mcp.csproj"
          ];
          testProjectFile = "tests/Passenger.Tests/Passenger.Tests.csproj";
          executables = [ "Passenger.Cli" "Passenger.Mcp" ];

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

          meta.mainProgram = "Passenger.Cli";
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = runtimeDeps ++ [ dotnet-sdk ];
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
              echo "run: dotnet run --project src/Passenger.Cli -- status"
            } >&2
          '';
        };

        packages.default = passenger;

        # The MCP server is the second entry point, and the one that gets
        # wired into a client's config, so it deserves a name of its own
        # rather than an argv suffix.
        apps.mcp = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/Passenger.Mcp";
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/Passenger.Cli";
        };
      });
}
