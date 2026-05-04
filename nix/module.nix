{
  lib,
  pkgs,
  config,
  options,
  ...
}:

with lib;

let
  cfg = config.services.app-infra;
  outerConfig = config;

  appInfraHelpers = pkgs.writeShellScript "app-infra-helpers" (builtins.readFile ./helpers.sh);

  trustDomain =
    if options ? services && options.services ? spire-infra then
      config.services.spire-infra.agent.trustDomain
    else
      "infra.tailnet";

  instanceModule =
    { name, config, ... }:
    {
      options = {
        enable = mkEnableOption "app-infra instance '${name}'";

        openbao = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to generate an openbao-setup service for this instance.";
          };
          address = mkOption {
            type = types.str;
            default = "https://127.0.0.1:8200";
            description = "OpenBao server address.";
          };
          skipVerify = mkOption {
            type = types.bool;
            default = false;
            description = "Whether to skip TLS verification for OpenBao.";
          };
          tokenFile = mkOption {
            type = types.str;
            default = "/var/lib/openbao/provisioner-token";
            description = "Path to the OpenBao provisioner token file.";
          };
          script = mkOption {
            type = types.path;
            description = "Path to app-owned OpenBao setup script.";
          };
        };

        zitadel = {
          enable = mkOption {
            type = types.bool;
            description = "Whether to generate a zitadel-setup service for this instance.";
          };
          address = mkOption {
            type = types.str;
            default = "https://homeserver:8443";
            description = "Zitadel server address.";
          };
          skipVerify = mkOption {
            type = types.bool;
            default = false;
            description = "Whether to skip TLS verification for Zitadel.";
          };
          patKvPath = mkOption {
            type = types.str;
            default = "kv/setup/zitadel-pat";
            description = "OpenBao KV path for the Zitadel PAT.";
          };
          script = mkOption {
            type = types.path;
            description = "Path to app-owned Zitadel setup script.";
          };
          projectName = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Zitadel project name. Defaults to the app-infra instance name if null.";
          };
        };

        spire = {
          enable = mkOption {
            type = types.bool;
            description = "Whether to auto-wire SPIRE workload entries for this instance.";
          };
          clientHostName = mkOption {
            type = types.str;
            description = "Hostname of the machine where the workload runs. Used for SPIRE parentId derivation.";
          };
        };

        tier = mkOption {
          type = types.enum [
            "core"
            "standard"
          ];
          default = "standard";
          description = ''
            Authentication tier for this app-infra instance.

            All M2M auth uses the same 2-step pipeline: SPIRE JWT-SVID → OpenBao auth/jwt-spire.
            Zitadel token exchange (RFC 8693) is not used — unsupported on Zitadel 2.71.7.

            - core: No auth dependencies (e.g. SPIRE itself, OpenBao itself).
                    Must have spire.enable = false and zitadel.enable = false.
            - standard: M2M auth via SPIRE JWT → OpenBao auth/jwt-spire.
                        May also have Zitadel setup for human user login (OIDC web app).
          '';
        };

        runOnEachDeploy = mkOption {
          type = types.bool;
          default = false;
          description = "If true, stamp files are deleted on activation so setup services always re-run.";
        };
      };

      config = {
        zitadel.enable = mkDefault (config.tier != "core");
        spire.enable = mkDefault (config.tier != "core");
        spire.clientHostName = mkDefault outerConfig.networking.hostName;
      };
    };

  enabledInstances = filterAttrs (_: inst: inst.enable) cfg;

  enabledBaoInstances = filterAttrs (_: inst: inst.enable && inst.openbao.enable) cfg;
  enabledZitInstances = filterAttrs (_: inst: inst.enable && inst.zitadel.enable) cfg;
  enabledSpireInstances = filterAttrs (_: inst: inst.enable && inst.spire.enable) cfg;
  runOnDeployInstances = filterAttrs (_: inst: inst.enable && inst.runOnEachDeploy) cfg;

  mkBaoSetupScript =
    name: inst:
    pkgs.writeShellScript "openbao-setup-${name}" ''
      set -euo pipefail
      STAMP=/var/lib/app-infra/${name}/openbao.stamp
      SCRIPT_HASH=$(${pkgs.coreutils}/bin/sha256sum ${inst.openbao.script} | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      if [ -f "$STAMP" ] && [ "$(${pkgs.coreutils}/bin/cat "$STAMP")" = "$SCRIPT_HASH" ]; then
        echo "openbao-setup-${name}: script unchanged, skipping"
        exit 0
      fi
      export BAO_ADDR="${inst.openbao.address}"
      export BAO_TOKEN=$(${pkgs.coreutils}/bin/cat ${toString inst.openbao.tokenFile})
      ${optionalString inst.openbao.skipVerify "export BAO_SKIP_VERIFY=true"}
      export ZITADEL_URL="${inst.zitadel.address}"
      export APP_NAME="${name}"
      export CLIENT_HOST="${inst.spire.clientHostName}"
      export SPIFFE_ID="spiffe://${trustDomain}/workload/${name}"
      export APP_INFRA_HELPERS="${appInfraHelpers}"
      export PATH="${
        makeBinPath [
          pkgs.openbao
          pkgs.curl
          pkgs.jq
          pkgs.coreutils
        ]
      }:$PATH"
      ${pkgs.bash}/bin/bash ${inst.openbao.script}
      ${pkgs.coreutils}/bin/mkdir -p /var/lib/app-infra/${name}
      echo "$SCRIPT_HASH" > "$STAMP"
    '';

  mkZitSetupScript =
    name: inst:
    pkgs.writeShellScript "zitadel-setup-${name}" ''
      set -euo pipefail
      STAMP=/var/lib/app-infra/${name}/zitadel.stamp
      SCRIPT_HASH=$(${pkgs.coreutils}/bin/sha256sum ${inst.zitadel.script} | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      if [ -f "$STAMP" ] && [ "$(${pkgs.coreutils}/bin/cat "$STAMP")" = "$SCRIPT_HASH" ]; then
        echo "zitadel-setup-${name}: script unchanged, skipping"
        exit 0
      fi
      export BAO_ADDR="${inst.openbao.address}"
      export BAO_TOKEN=$(${pkgs.coreutils}/bin/cat ${toString inst.openbao.tokenFile})
      ${optionalString inst.openbao.skipVerify "export BAO_SKIP_VERIFY=true"}
      export ZITADEL_URL="${inst.zitadel.address}"
      export ZITADEL_PAT_KV_PATH="${inst.zitadel.patKvPath}"
      ${optionalString inst.zitadel.skipVerify "export ZITADEL_TLS_SKIP_VERIFY=true"}
      export APP_NAME="${name}"
      export ZITADEL_PROJECT_NAME="${
        if inst.zitadel.projectName != null then inst.zitadel.projectName else name
      }"
      export CLIENT_HOST="${inst.spire.clientHostName}"
      export SPIFFE_ID="spiffe://${trustDomain}/workload/${name}"
      export APP_INFRA_HELPERS="${appInfraHelpers}"
      export PATH="${
        makeBinPath [
          pkgs.openbao
          pkgs.curl
          pkgs.jq
          pkgs.coreutils
        ]
      }:$PATH"
      ${pkgs.bash}/bin/bash ${inst.zitadel.script}
      ${pkgs.coreutils}/bin/mkdir -p /var/lib/app-infra/${name}
      echo "$SCRIPT_HASH" > "$STAMP"
    '';
in
{
  options.services.app-infra = mkOption {
    type = types.attrsOf (types.submodule instanceModule);
    default = { };
    description = "App infrastructure setup instances. Each instance generates systemd oneshot services for OpenBao and Zitadel provisioning.";
  };

  config = mkIf (enabledInstances != { }) (mkMerge [
    # Tier enforcement: core instances must not use SPIRE or Zitadel
    {
      assertions = mapAttrsToList (name: inst: {
        assertion = inst.tier != "core" || (!inst.spire.enable && !inst.zitadel.enable);
        message = "app-infra: instance '${name}' has tier 'core' but spire.enable or zitadel.enable is true; core instances must have both disabled";
      }) enabledInstances;
    }

    # OpenBao setup services
    {
      systemd.services = mapAttrs' (
        name: inst:
        nameValuePair "openbao-setup-${name}" {
          description = "OpenBao setup for ${name}";
          after = [
            "openbao-unseal.service"
            "network-online.target"
          ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "+${mkBaoSetupScript name inst}";
            StateDirectory = "app-infra";
            StateDirectoryMode = "0700";
          };
        }
      ) enabledBaoInstances;
    }

    # Zitadel setup services
    {
      systemd.services = mapAttrs' (
        name: inst:
        nameValuePair "zitadel-setup-${name}" {
          description = "Zitadel setup for ${name}";
          after = [
            "zitadel.service"
            "openbao-setup-${name}.service"
            "network-online.target"
          ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "+${mkZitSetupScript name inst}";
            StateDirectory = "app-infra";
            StateDirectoryMode = "0700";
          };
        }
      ) enabledZitInstances;
    }

    # runOnEachDeploy: activation script to remove stamp files
    (mkIf (runOnDeployInstances != { }) {
      system.activationScripts.app-infra-clear-stamps = stringAfter [ "var" ] (
        concatStringsSep "\n" (
          mapAttrsToList (name: _: ''
            rm -f /var/lib/app-infra/${name}/openbao.stamp
            rm -f /var/lib/app-infra/${name}/zitadel.stamp
          '') runOnDeployInstances
        )
      );
    })

    # SPIRE auto-wiring
    (optionalAttrs (options ? services && options.services ? spire-infra) {
      services.spire-infra.server.entries = mkIf (config.services.spire-infra.server.enable or false) (
        concatLists (
          mapAttrsToList (name: inst: [
            {
              spiffeId = "spiffe://${trustDomain}/workload/${name}";
              parentId = "spiffe://${trustDomain}/spire/agent/host/${inst.spire.clientHostName}";
              selectors = [ "unix:uid:0" ];
            }
          ]) enabledSpireInstances
        )
      );
    })

  ]);
}
