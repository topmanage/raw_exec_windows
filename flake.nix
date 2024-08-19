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
        goOverlay = final: prev: {
          buildGoModule = {
            # target OS, or null for native
            GOOS ? null,
            # target architecture, or null for native
            GOARCH ? null, ... }@args':
            ((prev.buildGoModule.override {
              go = prev.go // {
                GOOS = if GOOS == null then prev.go.GOOS else GOOS;
                GOARCH = if GOARCH == null then prev.go.GOARCH else GOARCH;
                CGO_ENABLED = true;
              };
            }) args').overrideAttrs (origAttrs: {
              CGO_ENABLED = true;
              configurePhase = origAttrs.configurePhase + ''
                # requires zigStdenv from zig-overlay
                export CC=${prev.zig}/bin/cc
                export LD=${prev.zig}/bin/cc
                export NIX_CFLAGS_COMPILE=
                export NIX_LDFLAGS=

                ${if prev.stdenv.isDarwin then ''
                  buildFlags="$buildFlags -buildmode=pie"
                  ldflags="$ldflags -s -w"
                '' else
                  ""}
              '';
              postConfigure = (origAttrs.postConfigure or "") + ''
                export CGO_CFLAGS="$CFLAGS -Wno-expansion-to-defined -Wno-nullability-completeness"
              '';
              buildPhase = origAttrs.buildPhase + ''
                if ! [ -z ''${ZIG_TARGET+x} ]; then
                  mv $GOPATH/bin/''${GOOS}_$GOARCH/* $GOPATH/bin
                  rmdir $GOPATH/bin/''${GOOS}_$GOARCH
                fi
              '';
            });
        };
        windowsOverlay = final: prev: {
          buildForWindows =
            # the original package to override
            pkg:
            # where to find *.pc files in the given MSYS2 packages.
            { pkgConfigPrefix ? "/clang64/lib/pkgconfig"
              # set of MSYS2 packages to download, patch and put into buildInputs
            , deps ? { }
              # list of executables in /bin where a `.exe` should be appended.
            , appendExe ? [ ]
              # name of the target system (in NixOS terminology)
            , targetSystem }:

            let
              patch-pkg-config = import ./patch-pkg-config.nix;
              fetchMsys = { tail, sha256, ... }:
                builtins.fetchurl {
                  url =
                    "https://mirror.msys2.org/mingw/clang64/mingw-w64-clang-x86_64-${tail}";
                  inherit sha256;
                };
              pkgsFromPacman = name: input:
                let src = fetchMsys input;
                in prev.stdenvNoCC.mkDerivation
                ((builtins.removeAttrs input [ "tail" "sha256" ]) // {
                  name = "msys2-${name}";
                  inherit src;
                  phases = [ "unpackPhase" "patchPhase" "installPhase" ];
                  nativeBuildInputs = [ prev.gnutar prev.zstd ];
                  unpackPhase = ''
                    runHook preUnpack
                    mkdir -p upstream
                    ${prev.gnutar}/bin/tar -xvpf $src -C upstream \
                    --exclude .PKGINFO --exclude .INSTALL --exclude .MTREE --exclude .BUILDINFO
                    runHook postUnpack
                  '';
                  patchPhase = ''
                    runHook prePatch
                    shopt -s globstar
                    for pcFile in upstream/**/pkgconfig/*.pc; do
                      ${patch-pkg-config prev} $pcFile $out
                    done
                    find -type f -name "*.a" -not -name "*.dll.a" -not -name "*main.a" -delete
                    runHook postPatch
                  '';
                  installPhase = ''
                    runHook preInstall
                    mkdir -p $out/
                    cp -rt $out upstream/*
                    runHook postInstall
                  '';
                });
            in pkg.overrideAttrs (origAttrs: {
              inherit pkgConfigPrefix appendExe;
              buildInputs = prev.lib.mapAttrsToList pkgsFromPacman deps;
              targetSharePath = "../share";
              postConfigure = ''
                for item in $buildInputs; do
                  export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$item$pkgConfigPrefix"
                  export CFLAGS="$CFLAGS -I$item/clang64/include"
                done
              '' + (origAttrs.postConfigure or "");
              postInstall = (origAttrs.postInstall or "") + ''
                for item in $buildInputs; do
                  cp -t $out/bin $item/clang64/bin/*.dll | true # allow deps without dlls
                done
                for item in $appendExe; do
                  mv $out/bin/$item $out/bin/$item.exe
                done
              '';
            });

          packageForWindows =
            # the original package to override
            pkg:
            # where to find *.pc files in the given MSYS2 packages.
            { pkgConfigPrefix ? "/clang64/lib/pkgconfig"
              # set of MSYS2 packages to download, patch and put into buildInputs
            , deps ? { }
              # list of executables in /bin where a `.exe` should be appended.
            , appendExe ? [ ]
              # name of the target system (in NixOS terminology)
            , targetSystem }:

            let
              src = final.buildForWindows pkg {
                inherit pkgConfigPrefix deps appendExe targetSystem;
              };
            in prev.stdenvNoCC.mkDerivation {
              name = "${src.name}-win64.zip";
              unpackPhase = ''
                packDir=${src.name}-win64
                mkdir -p $packDir
                cp -rt $packDir --no-preserve=mode ${src}/*
              '';
              buildPhase = ''
                ${prev.zip}/bin/zip -r $packDir.zip $packDir
              '';
              installPhase = ''
                cp $packDir.zip $out
              '';
            };
        };
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ goOverlay windowsOverlay ];
        };

        pname = "nomad-taskdriver-cco";
        version = "0.1.0";
        postUnpack = ''
          mv "$sourceRoot" source
          sourceRoot=source
        '';
      in rec {
        devShells.default = unstable.mkShell {
          shellHook = ''
            export GOOS=windows
            export GOARCH=amd64
          '';
          buildInputs = with unstable; [ nixfmt gopls go ];
        };

        packages = rec {
          nomad-taskdriver-cco = pkgs.buildGoModule {
            inherit pname version;
            src = ../src;
            doCheck = false;
            vendorHash = "sha256-Mn0jykf0xW6Stuqv5Th73+hKKMCX9ew/dH7OmRG4Odw=";

            # workaround for buildGoModule not being able to take sources in a `go`
            # directory as input
            overrideModAttrs = (_: { inherit postUnpack; });
            inherit postUnpack;

          };
          win64Zip = pkgs.packageForWindows (nomad-taskdriver-cco.overrideAttrs
            (origAttrs: {
              GOOS = "windows";
              GOARCH = "amd64";
            })) { targetSystem = "x86_64-windows"; };
        };
        defaultPackage = packages.nomad-taskdriver-cco;
      });
}
