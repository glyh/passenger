# mcp-types: the wire types mcp 2.0 split out of itself, pinned by `mcp` to
# exactly its own version. Not in nixpkgs, which still carries mcp 1.29.
{
  lib,
  buildPythonPackage,
  fetchPypi,
  hatchling,
  uv-dynamic-versioning,
  pydantic,
  typing-extensions,
}:

buildPythonPackage rec {
  pname = "mcp-types";
  version = "2.0.0";
  pyproject = true;

  src = fetchPypi {
    pname = "mcp_types";
    inherit version;
    hash = "sha256-19k5uShcmWGuiGa6de+F2jTRK6/idu+/TrahMXhtg3k=";
  };

  # The version comes from a git tag upstream; from an sdist the plugin has
  # to be present even though it reads the version straight out of PKG-INFO.
  build-system = [
    hatchling
    uv-dynamic-versioning
  ];

  dependencies = [
    pydantic
    typing-extensions
  ];

  pythonImportsCheck = [ "mcp_types" ];

  # The sdist ships no test suite.
  doCheck = false;

  meta = {
    description = "Type definitions for the Model Context Protocol";
    homepage = "https://github.com/modelcontextprotocol/python-sdk";
    license = lib.licenses.mit;
  };
}
