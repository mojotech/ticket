{
  description = "Minimal ticket tracking in bash";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          ticket = pkgs.callPackage ./pkg/nix/default.nix {
            source = self;
            # Include optional dependencies by default in flake
            inherit (pkgs) ripgrep jq;
          };
        in
        {
          default = ticket;
          ticket = ticket;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/tk";
        };
      });

      overlays.default = final: prev: {
        ticket = final.callPackage ./pkg/nix/default.nix {
          source = self;
          inherit (final) ripgrep jq;
        };
      };
    };
}
