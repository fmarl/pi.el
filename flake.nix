{
  description = "Lets Pi and Emacs talk to each other";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      inherit (lib.importJSON ./package.json) version;

      pi =
        { melpaBuild }:
        melpaBuild {
          pname = "pi";
          inherit version;
          src = lib.fileset.toSource {
            root = ./.;
            fileset = ./pi.el;
          };
        };

      emacs-bridge =
        { runCommandLocal }:
        runCommandLocal "pi-emacs-bridge-${version}"
          {
            src = lib.fileset.toSource {
              root = ./emacs-bridge;
              fileset = lib.fileset.unions [
                ./emacs-bridge/index.ts
                ./emacs-bridge/bridge.ts
              ];
            };
          }
          ''
            install -D -m 644 -t $out/share/pi/extensions/emacs-bridge $src/*.ts
          '';
    in
    {
      # Adds pi to every Emacs package set, so that it is built with the
      # Emacs that loads it.
      overlays.default = final: prev: {
        emacsPackagesFor =
          emacs:
          (prev.emacsPackagesFor emacs).overrideScope (
            efinal: _: {
              pi = efinal.callPackage pi { };
            }
          );
        pi-emacs-bridge = final.callPackage emacs-bridge { };
      };

      packages = lib.genAttrs lib.systems.flakeExposed (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.emacsPackages.callPackage pi { };
          emacs-bridge = pkgs.callPackage emacs-bridge { };
        }
      );
    };
}
