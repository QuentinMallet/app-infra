# mkApparmorProfile: generate an AppArmor policy attrset for use with
# security.apparmor.policies in a NixOS module.
#
# Usage:
#   security.apparmor.policies = mkApparmorProfile {
#     name = "myapp";
#     executablePath = "${pkgs.myapp}/bin/myapp";
#     extraRules = ''
#       /run/postgresql/.s.PGSQL.* rw,
#     '';
#   };
#
# The returned attrset is { ${name} = { profile = "..."; state = mode; }; }
# which merges directly into security.apparmor.policies.
#
# Mode is controlled via the NixOS security.apparmor.policies.<name>.state field,
# not via flags=() in the profile header. The NixOS module passes --complain to
# apparmor_parser when state == "complain", which is the idiomatic approach.
{ lib }:
{ name
, executablePath
, dataDir ? "/var/lib/${name}"
, extraRules ? ""
, mode ? "complain" # "complain" | "enforce" | "disable"
}:
assert lib.assertOneOf "mode" mode [ "complain" "enforce" "disable" ];
let
  profileText = ''
    #include <tunables/global>

    profile ${name} ${executablePath} {
      #include <abstractions/base>

      # Nix store — all runtimes need read access to their closure
      /nix/store/** r,
      /nix/store/*/bin/* ix,
      /nix/store/*/lib/** mr,

      # Basic system access
      /dev/null rw,
      /dev/urandom r,
      /dev/random r,
      /proc/self/** r,
      /proc/sys/vm/overcommit_memory r,
      /sys/devices/system/cpu/** r,

      # Temp files (BEAM creates erl_* temp files)
      /tmp/** rwk,
      /var/tmp/** rwk,

      # DNS and locale resolution
      /etc/resolv.conf r,
      /etc/hosts r,
      /etc/nsswitch.conf r,
      /etc/localtime r,
      /usr/share/zoneinfo/** r,

      # Agenix secrets — every app-infra consumer reads from here
      /run/agenix/** r,

      # SPIRE secrets-fetch output (written by app-infra secrets-fetch.sh)
      /run/${name}/secrets.env r,

      # BEAM runtime — epmd, ports, proc inspection
      /proc/cpuinfo r,
      /proc/meminfo r,
      network inet stream,
      network inet dgram,
      network inet6 stream,
      network inet6 dgram,
      network unix stream,
      network unix dgram,
      /tmp/erl_* rwk,

      # App data directory
      ${dataDir}/ r,
      ${dataDir}/** rwk,

      # Per-app overrides (database sockets, additional paths, etc.)
      ${extraRules}
    }
  '';
in
{
  ${name} = {
    profile = profileText;
    # state drives the NixOS apparmor_parser --complain flag and aa-status output.
    # "disable" is filtered out by NixOS enabledPolicies — the profile is never loaded.
    state = mode;
  };
}
