{
  description = "MuleSoft tooling packaged for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    {
      overlays.default = final: prev: {
        anypoint-studio = final.callPackage ./anypoint-studio.nix { };
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        # Anypoint Studio is proprietary, so legacyPackages (which carries the
        # default config) would refuse to evaluate it. The overlay above leaves
        # that judgement to the consumer's nixpkgs; this instance exists only to
        # make `nix build`/`nix run` on this flake work, so it opts in here.
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        anypoint-studio = pkgs.callPackage ./anypoint-studio.nix { };
      in
      {
        packages = {
          inherit anypoint-studio;
          default = anypoint-studio;
        };

        formatter = pkgs.nixfmt-tree;
      }
    );
}
