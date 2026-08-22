# The Python packages this project needs that its pinned nixpkgs does not
# carry, or carries too old.
#
# Every entry here is a liability: it is a package nobody else maintains, and
# it has to be re-checked by hand whenever the pin moves. Keep the list short,
# and delete an entry the moment nixpkgs catches up -- `nix eval
# nixpkgs#python314Packages.<name>.version` is the check.
final: prev: {
  # New. mcp 2.0 depends on it with `==`, so it moves in lockstep with mcp.
  mcp-types = final.callPackage ./mcp-types.nix { };

  # nixpkgs has 1.29.0; this project needs 2.0, which is a different API.
  mcp = prev.mcp.overridePythonAttrs (old: rec {
    version = "2.0.0";
    src = final.fetchPypi {
      pname = "mcp";
      inherit version;
      hash = "sha256-D0QOc1wT7Oi7GbxizwuG9DE0SEMvu3fTXhQDT04FByg=";
    };
    dependencies = old.dependencies ++ [
      final.mcp-types
      final.httpx2
      final.opentelemetry-api
      final.typing-inspection
    ];
    # 2.0 replaced httpx with httpx2; the 1.29 argument list still passes the
    # old one, which is harmless but should not be claimed as a dependency.
    #
    # The test suite is skipped rather than ported: the disabledTests list
    # inherited from 1.29 names tests that no longer exist, and maintaining a
    # new one is the upstream packager's job, not this project's.
    doCheck = false;
    disabledTests = [ ];
  });

  # nixpkgs marks its patchright broken, and packages the wrong source. See
  # the file for why this one is built from a wheel.
  patchright = final.callPackage ./patchright.nix { };
}
