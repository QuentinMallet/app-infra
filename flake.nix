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
    { flakelight, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      # beamSmpPath: resolve the beam.smp binary path inside an Erlang derivation.
      # Note: uses IFD (Import From Derivation) — requires erlangPkg to be built at eval time.
      beamSmpPath =
        erlangPkg:
        let
          erts = builtins.head (
            builtins.filter (p: lib.hasPrefix "erts-" p)
              (builtins.attrNames (builtins.readDir "${erlangPkg}/lib/erlang"))
          );
        in
        "${erlangPkg}/lib/erlang/${erts}/bin/beam.smp";

      # mkApparmorProfile: generate a security.apparmor.policies attrset for a BEAM service.
      # See lib/apparmor.nix for full documentation and parameter reference.
      mkApparmorProfile = import ./lib/apparmor.nix { inherit lib; };
    in
    (flakelight ./. {
      # nixosModule (singular) → outputs.nixosModules.default
      # To export multiple modules, use nixosModules = { foo = ./nix/foo.nix; bar = ./nix/bar.nix; };
      nixosModule = ./nix/module.nix;

      packages.app-infra-helpers =
        pkgs: pkgs.writeShellScript "app-infra-helpers" (builtins.readFile ./nix/helpers.sh);
    })
    // {
      lib = { inherit beamSmpPath mkApparmorProfile; };
    };
}
