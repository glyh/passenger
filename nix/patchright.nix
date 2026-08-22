# patchright, built from the published wheel.
#
# nixpkgs carries this package but marks it broken, and the reason is not a
# build failure: it packages the GitHub repository, whose own pyproject says
# it is "Only for test Runs, does not relate to actual Patchright package".
# The real artefact is assembled by a release workflow and only ever published
# to PyPI, so the wheel is the source -- there is no sdist to prefer.
#
# The wheel carries a 132 MiB `driver/` -- a patched Playwright driver plus a
# prebuilt Node binary linked against /lib64/ld-linux-x86-64.so.2, which does
# not exist here. Substituting nixpkgs' node is both the fix and a large size
# win; the bundled copy is v24.18.1 and the driver asks only for >=20.
{
  lib,
  stdenv,
  buildPythonPackage,
  fetchurl,
  greenlet,
  nodejs,
  pyee,
  python,
}:

let
  version = "1.62.1";

  # Platform-specific only because of the bundled driver; the Python is pure.
  wheels = {
    x86_64-linux = {
      path = "f9/94/7b367bd063fe665461758402b7bb1560ce686d116536ca0e5d8445e9bea4";
      suffix = "manylinux1_x86_64";
      hash = "sha256-rpCNCmmIXzRLw2QEoCu/13L8ZMKB+bt3lX28Ub45VZI=";
    };
    aarch64-linux = {
      path = "9d/b9/d27d47400b9b77bf8600fd71f68049d4f1f838e297595f1af0111d22f9e0";
      suffix = "manylinux_2_17_aarch64.manylinux2014_aarch64";
      hash = "sha256-jx5j1QmfWG3dS2r1bWJMcrC1YcbPheikc9jXu5YrD1Q=";
    };
    x86_64-darwin = {
      path = "29/8b/459c7bdafd2e9e6e87db9f2fad69c98ec46a26e5ecc5f7e86ea597478fde";
      suffix = "macosx_10_13_x86_64";
      hash = "sha256-tX/nB0vNUB8mm8gMV5gLaJWibTp2WhhS32gvaNb/QGg=";
    };
    aarch64-darwin = {
      path = "50/38/57c1bb35858238295c6c78cd7460ea16dd9f9215e57860a1cc37980cca5d";
      suffix = "macosx_11_0_arm64";
      hash = "sha256-yCbK28oSmM3PZkGlHF6ddP5aEROfNWmivtN0caw2y78=";
    };
  };

  wheel =
    wheels.${stdenv.hostPlatform.system}
      or (throw "patchright: no wheel published for ${stdenv.hostPlatform.system}");
in
buildPythonPackage {
  pname = "patchright";
  inherit version;
  format = "wheel";

  src = fetchurl {
    url =
      "https://files.pythonhosted.org/packages/${wheel.path}/"
      + "patchright-${version}-py3-none-${wheel.suffix}.whl";
    inherit (wheel) hash;
  };

  dependencies = [
    greenlet
    pyee
  ];

  # The import writes to the filesystem, so it cannot run in the sandbox --
  # the same reason nixpkgs disables it. Nothing here has tests to run.
  doCheck = false;
  pythonImportsCheck = [ ];

  postFixup = ''
    driver="$out/${python.sitePackages}/patchright/driver"
    rm "$driver/node"
    ln -s ${lib.getExe nodejs} "$driver/node"
  '';

  meta = {
    description = "Undetected Python version of the Playwright automation library";
    homepage = "https://github.com/Kaliiiiiiiiii-Vinyzu/patchright-python";
    license = lib.licenses.asl20;
    platforms = builtins.attrNames wheels;
  };
}
