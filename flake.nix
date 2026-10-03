{
  description = "passenger: web context through a real, logged-in Chrome";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  # There was a third input here until ticket 071: the MCP C# SDK, forked,
  # because upstream's stdio transport wrote the JSON-RPC envelope through a
  # frozen JsonSerializerOptions whose encoder escaped every non-ASCII character
  # (056, csharp-sdk#795). `JSON.stringify` escapes nothing, so the fork and the
  # two lockfiles that fed it are gone rather than replaced.
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

        # The nested compositor, trimmed twice before it is used (ticket 060):
        # once in the reference graph, where libinput's tools follow its headers
        # around, and once in what is built, where Xwayland is compiled out.
        #
        # libinput's command-line tools, kept out of everything that merely
        # compiles against it.
        #
        # libinput splits into out/bin/dev, and nixpkgs' multiple-outputs setup
        # has `dev` propagate `bin`, so a package that builds against the
        # library also gets the tools on PATH. Eleven of those tools are Python
        # -- mouse-button and touchpad analysers -- and their shebang makes
        # CPython, setuptools, pyyaml, pyudev and libevdev a *runtime*
        # dependency of anything holding the headers. Here that is wlroots,
        # which sway links, which this server starts: 135 MiB of interpreter
        # reachable from an MCP binary, for tools nothing invokes and nothing
        # could use anyway -- Launch.cs starts the compositor with
        # WLR_LIBINPUT_NO_DEVICES=1, so there are no input devices to analyse.
        #
        # Dropping the propagation rather than deleting the tools: they are
        # still built, still installed, still work for anyone who asks for
        # libinput by name. What stops is a header consumer inheriting them.
        # Nothing in this closure runs a libinput binary at build time.
        #
        # `propagatedBuildOutputs` is the supported knob for it -- naming the
        # outputs `dev` passes on, where the default is bin+include+lib. Editing
        # the propagated-build-inputs file from postFixup does not work and
        # looks like it does: the hook that writes it runs *after* postFixup, so
        # the sed lands and is then overwritten.
        trimmedLibinput = pkgs.libinput.overrideAttrs (_: {
          propagatedBuildOutputs = [ "out" ];
        });

        # No Xwayland, and so no gtk+3 behind it.
        #
        # wlroots takes Xwayland as a build input when enableXWayland is on,
        # Xwayland takes libdecor to draw client-side decorations, and libdecor
        # takes gtk+3 -- a toolkit nothing in this repo links, arriving because
        # nothing stopped it. The X path was load-bearing for exactly one
        # reason: a Chrome that fell back to X11 inside the session needed
        # something to answer it. Since ticket 061 the browser is told
        # `--ozone-platform=wayland` outright, so there is no fallback left to
        # catch. A window opened by a human on the *host* is unaffected: that is
        # their own desktop's compositor, not this one.
        trimmedWlroots = pkgs.wlroots_0_20.override { libinput = trimmedLibinput; };

        # sway wraps sway-unwrapped, which overrides wlroots itself to pass
        # enableXWayland down -- so the trimmed wlroots has to be handed in as
        # the package to override, and `enableXWayland = false` goes to the
        # wrapper, which forwards it to both.
        trimmedSway = pkgs.sway.override {
          enableXWayland = false;
          sway-unwrapped = pkgs.sway-unwrapped.override {
            libinput = trimmedLibinput;
            wlroots_0_20 = trimmedWlroots;
          };
        };

        # The nested compositor and its VNC server. These are the packages you
        # would otherwise install with a system package manager.
        #
        # sway rather than cage since ticket 063, and the swap costs 33 MiB --
        # cage was never the light one, since wlroots and mesa dominate either
        # way. What the 33 MiB buys is a data-control protocol (so wayvnc's
        # clipboard has something to talk to), text-input and input-method (so
        # an IME can exist in the session at all), several headless outputs on
        # request, and swaymsg to ask for any of it. `sway` brings swaymsg with
        # it, which the session script needs.
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
        runtimeDeps = [ trimmedSway ]
          ++ (with pkgs; [ wayvnc wlr-randr wayland-utils dbus ]);

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

        # .git and the local build detritus are not inputs; without this filter
        # every write to any of them would invalidate the build.
        source = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            !(builtins.elem (baseNameOf (toString path)) [
              ".direnv" ".git" "result" "node_modules" "lib"
            ]);
        };

        # The whole server, compiled from ReScript to ES modules and run by node.
        #
        # `buildNpmPackage` rather than a hand-rolled derivation because the only
        # unusual thing here is the compiler, and it turned out not to be unusual:
        # ReScript ships its binaries statically linked (`static-pie`, measured on
        # @rescript/linux-x64), so there is nothing to patchelf and it runs in the
        # sandbox as it comes off npm. Ticket 071 planned for worse.
        passenger = pkgs.buildNpmPackage {
          pname = "passenger";
          version = "0.1.0";
          src = source;

          npmDepsHash = "sha256-Z3HsAArY+qdmJayRo9A2qDzYj80f+Q5u122/qS/YjtM=";

          # `npm run build` is `rescript build`, which emits each module's
          # JavaScript beside its source.
          npmBuildScript = "build";

          nativeBuildInputs = [ pkgs.makeWrapper ];

          # None of the suite drives a real Chrome, so it needs no pinned browser:
          # it is unit tests over the pure core, plus a handful that spawn
          # `/bin/sh` and bind a loopback port, both of which the sandbox has.
          # Kept in the same derivation as the build rather than a separate
          # `checks` output, because there is no browser dependency forcing them
          # apart.
          doCheck = true;
          checkPhase = ''
            runHook preCheck
            node --test test/*_test.res.mjs
            runHook postCheck
          '';

          # Written out rather than left to the default, which packs an npm
          # package and installs it globally. What ships here is four things --
          # the emitted modules, the assets read beside them, the manifest, and
          # the runtime dependencies -- and the compiler is not among them.
          installPhase = ''
            runHook preInstall

            npm prune --omit=dev

            # The compiler is a devDependency; its *runtime* is not, and they
            # ship as separate npm packages. Emitted code imports
            # `@rescript/runtime/lib/es6/*`, so a prune that took the runtime
            # with the compiler left a binary that could not start -- measured,
            # after moving `rescript` to devDependencies.
            #
            # What the emitted code never touches is that package's `lib/ocaml`,
            # 18 MiB of stdlib .res/.cmi that exists for the compiler, and
            # `lib/js`, which is the CommonJS half of a build that emits ES
            # modules. Both go.
            rm -rf node_modules/@rescript/runtime/lib/ocaml \
                   node_modules/@rescript/runtime/lib/js

            mkdir -p $out/lib/passenger
            cp -r src assets node_modules package.json $out/lib/passenger/

            # Both the server and the viewer's own re-exec need the compositor on
            # PATH and noVNC findable; neither can be discovered at runtime.
            makeWrapper ${pkgs.lib.getExe pkgs.nodejs-slim} $out/bin/passenger \
              --add-flags $out/lib/passenger/src/cli/Entry.res.mjs \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps} \
              --set-default PASSENGER_NOVNC ${novncStatic}

            runHook postInstall
          '';

          # nodejs-slim above, which is the same interpreter without npm and
          # corepack. Nothing installs anything at runtime, and a package manager
          # in a closure whose job is to speak MCP on a machine that never builds
          # is 20 MiB of nothing.
          #
          # The C# build had a `postFixup` here that replaced the Node bundled
          # inside the Playwright driver, because that binary was linked against
          # an interpreter this system does not have. There is no bundled Node any
          # more: playwright-core is a library in this process now, not a driver
          # on the other end of a pipe.

          meta.mainProgram = "passenger";
        };
      in
      {
        devShells.default = pkgs.mkShell {
          # `nodejs`, not `nodejs-slim`: a dev shell needs npm, where the
          # runtime does not.
          packages = runtimeDeps ++ [ pkgs.nodejs ];
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
              echo "run: node src/cli/Entry.res.mjs serve   (or: stop [--force])"
            } >&2
          '';
        };

        packages.default = passenger;

        # One binary, one app, one name. `apps.mcp` was the address a client's
        # config named while `apps.default` pointed at the CLI; with the CLI gone
        # there is nothing for the two to distinguish, and keeping `mcp` as an
        # alias would be a second name for the only thing there is. A registration
        # that still says `#mcp` needs its line changed to plain `nix run`.
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/passenger";
        };
      });
}
