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

        # The nested compositor, its VNC server, and a client to view it.
        # These are the packages you would otherwise install with a system
        # package manager.
        #
        # wlvncc rather than gtk-vnc: nixpkgs' gtk-vnc ships only gvnccapture,
        # not the gvncviewer binary, so it would silently fall through to a
        # host-installed client -- exactly what this flake exists to avoid.
        # wlr-randr resizes the nested output at runtime: cage implements
        # wlr-output-management, and the alternative -- letting the VNC client
        # ask for a size -- is not available, since wlvncc never asks and
        # wayvnc refuses the request when a client does. wayland-utils reads
        # the host's screen through core wl_output, so the target size does
        # not depend on which compositor is running.
        runtimeDeps = with pkgs; [ cage wayvnc wlvncc wlr-randr wayland-utils ];

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
          shellHook = ''
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
