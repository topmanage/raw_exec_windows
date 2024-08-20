{
  inputs = {
    zicross.url = "github:flyx/Zicross";
    utils.url = "github:numtide/flake-utils";
    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";
  };
  outputs = { self, zicross, nixpkgs, utils, nixpkgs-unstable }:
    with utils.lib;
    eachSystem allSystems (system:
      let
        unstable = nixpkgs-unstable.legacyPackages.${system};
        pkgs = import nixpkgs { inherit system; };

      in rec {
        devShells.default = unstable.mkShell {
          shellHook = ''
            export GOOS=windows
            export GOARCH=amd64
          '';
          buildInputs = with unstable; [ nixfmt gopls go protoc-gen-go buf ];
        };

      });
}
