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

        # The interpreter, carrying this project's overlay. Two of the seven
        # Python dependencies are absent or too old in nixpkgs; nix/ says which
        # and why. `self` is threaded through so anything built against this
        # interpreter sees the overridden set rather than the stock one.
        python = pkgs.python314.override {
          self = python;
          packageOverrides = import ./nix/python-overlay.nix;
        };

        pythonDeps = ps: with ps; [
          cyclopts
          mcp
          patchright
          pydantic
          pyicu
          trafilatura
          websockets
        ];

        # .git and the local build detritus are not inputs; without this filter
        # every write to any of them would invalidate the build.
        source = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            !(builtins.elem (baseNameOf (toString path)) [
              ".venv" ".direnv" ".git" ".mypy_cache" ".ruff_cache" "result"
            ]);
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = runtimeDeps ++ [
            (python.withPackages (ps: pythonDeps ps ++ [ ps.pytest ]))
            pkgs.mypy
          ];
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
              echo "run: python -m ab.cli status"
            } >&2
          '';
        };

        # `nix flake check` runs the suite against the pinned interpreter, so
        # "did I break it" is one command from a clean checkout -- there is no
        # remote and no CI to hold that. Kept out of packages.default's
        # checkPhase deliberately: these tests spawn processes and bind a
        # loopback port, and an environment fault should read as a failing
        # check rather than an unbuildable package.
        checks.default = pkgs.runCommand "agent-browser-tests"
          {
            nativeBuildInputs = [
              (python.withPackages (ps: pythonDeps ps ++ [ ps.pytest ]))
            ];
          }
          ''
            cd ${source}
            # HOME is unset in the sandbox, and Settings' state_dir defaults to
            # a path under it. conftest.py overrides that anyway; this keeps
            # import time from failing before conftest gets to run.
            export HOME=$TMPDIR
            # The source is a read-only store path; without this pytest
            # warns twice about a cache directory it cannot create.
            pytest -q -p no:cacheprovider
            touch $out
          '';

        # A real derivation. The closure describes every dependency, so this
        # builds and runs with no network and no compiler. It used to be a
        # shell script that called `uv run`, which resolved the Python side at
        # first use -- reproducible only in the sense that uv.lock was pinned,
        # and unbuildable offline.
        packages.default = python.pkgs.buildPythonApplication {
          pname = "agent-browser";
          version = "0.1.0";
          pyproject = true;
          src = source;

          build-system = [ python.pkgs.hatchling ];
          dependencies = pythonDeps python.pkgs;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          # The suite lives in `nix flake check`, not here -- it spawns
          # processes and binds a port, and packaging should not fail on that.
          # Import-checking both entry points still catches a missing
          # dependency, which is what this stage is for.
          doCheck = false;
          pythonImportsCheck = [ "ab.cli" "ab.mcp_server" ];

          # Both entry points need the compositor on PATH and the viewer's
          # JavaScript findable; neither can be discovered at runtime.
          postFixup = ''
            for exe in $out/bin/*; do
              wrapProgram "$exe" \
                --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps} \
                --set-default AGENT_BROWSER_NOVNC ${novncStatic}
            done
          '';

          meta.mainProgram = "agent-browser";
        };

        # The MCP server is the second entry point, and the one that gets
        # wired into a client's config, so it deserves a name of its own
        # rather than an argv suffix.
        apps.mcp = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/agent-browser-mcp";
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/agent-browser";
        };
      });
}
