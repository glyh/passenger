{
  description = "agent-browser: web context through a real, logged-in Chrome";

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
        # tool's own Python. Copying the tree into its own derivation is what
        # keeps that closure out; plain files reference nothing.
        novncStatic = pkgs.runCommand "novnc-static" { } ''
          cp -r ${pkgs.novnc}/share/webapps/novnc $out
        '';

        # The nested compositor and its VNC server. These are the packages you
        # would otherwise install with a system package manager.
        #
        # No VNC client: the viewer is a page in the host's own browser (see
        # present.py). That is not only lighter than every native client that
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
          agent-browser uses the host's Chrome (AGENT_BROWSER_CHROME,
          default google-chrome-stable) so it keeps its own update cadence.
        '';

        pythonEnv = pkgs.python314;
      in
      {
        devShells.default = pkgs.mkShell {
          packages = runtimeDeps ++ [ pythonEnv pkgs.uv pkgs.mypy ];
          # Everything the hook prints goes to stderr. `nix develop --command`
          # forwards hook output to stdout, which would corrupt any program
          # speaking a protocol there -- the MCP server talks JSON-RPC on stdio.
          # The viewer page needs noVNC's modules; the dev shell points at the
          # same store path the wrapper does.
          NOVNC_STATIC = novncStatic;
          shellHook = ''
            export AGENT_BROWSER_NOVNC="''${AGENT_BROWSER_NOVNC:-${novncStatic}}"
            {
              echo "agent-browser dev shell"
              echo "${chromeNote}"
              echo "run: uv run agent-browser status"
            } >&2
          '';
        };

        # A wrapper that puts the runtime deps on PATH and hands off to the
        # CLI. uv resolves the Python side from the committed uv.lock.
        packages.default = pkgs.writeShellApplication {
          name = "agent-browser";
          runtimeInputs = runtimeDeps ++ [ pythonEnv pkgs.uv ];
          text = ''
            export AGENT_BROWSER_NOVNC="''${AGENT_BROWSER_NOVNC:-${novncStatic}}"
            exec uv run --project "''${AGENT_BROWSER_SRC:-${self}}" \
              agent-browser "$@"
          '';
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/agent-browser";
        };
      });
}
