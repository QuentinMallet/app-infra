{
  description = "NixOS module flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flakelight = {
      url = "github:nix-community/flakelight";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { flakelight, ... }:
    flakelight ./. {
      # nixosModule (singular) → outputs.nixosModules.default
      # To export multiple modules, use nixosModules = { foo = ./nix/foo.nix; bar = ./nix/bar.nix; };
      nixosModule = ./nix/module.nix;
    };
}
