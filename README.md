# app-infra-module

Standalone NixOS module for provisioning app-infra (OpenBao setup, Zitadel setup, SPIRE workload
entries) for workloads. Extracted from machines\_conf.

For each declared instance the module generates:

- A `openbao-setup-<name>` oneshot systemd service that runs the app-owned OpenBao setup script
  with idempotency (stamp-file based on script hash).
- A `zitadel-setup-<name>` oneshot systemd service (standard tier only) that runs the app-owned
  Zitadel setup script.
- SPIRE workload entry auto-wiring into `services.spire-infra.server.entries` when the
  `spire-infra` module is also present.


## Usage

```nix
# flake.nix
inputs.app-infra-module.url = "path:/path/to/app-infra-module";
# (use github: or git+ssh: URL when published)

outputs = { self, nixpkgs, app-infra-module, ... }: {
  nixosModules.default = { config, pkgs, ... }: {
    imports = [ app-infra-module.nixosModules.default ];

    services.app-infra.instances.myapp = {
      enable = true;
      tier   = "standard";
      openbao.script = ./openbao-setup.sh;
      spire = {
        workloadUser = "myapp";
        # For BEAM apps: workloadExecutable = app-infra-module.lib.beamSmpPath pkgs.erlang;
      };
    };
  };
};
```

The setup scripts receive a standard set of environment variables injected by the module
(`BAO_ADDR`, `BAO_TOKEN`, `BAO_SKIP_VERIFY`, `ZITADEL_URL`, `APP_NAME`, `SPIFFE_ID`,
`CLIENT_HOST`, `APP_INFRA_HELPERS`). Source `${APP_INFRA_HELPERS}` at the top of each script to
get the shared helper library (`bao_ensure_policy`, `bao_ensure_jwt_role`,
`zitadel_ensure_project`, etc.).


## Tiers

### `standard` (default)

M2M authentication via SPIRE JWT-SVID → OpenBao `auth/jwt-spire`. Zitadel setup is enabled by
default and can be used for human user login (OIDC web app). Suitable for most workloads.

```nix
services.app-infra.instances.myapp = {
  enable = true;
  tier   = "standard";          # default; may be omitted
  openbao.script  = ./openbao-setup.sh;
  zitadel.script  = ./zitadel-setup.sh;   # optional — disable with zitadel.enable = false
  spire.workloadUser = "myapp";
};
```

### `core`

OpenBao AppRole + secretId. No SPIRE or Zitadel dependency. Intended for bootstrap-critical
services (e.g. SPIRE itself, OpenBao itself) that cannot depend on those services being available
at startup. `spire.enable` and `zitadel.enable` must both be `false` (enforced by assertion).

```nix
services.app-infra.instances.spire = {
  enable = true;
  tier   = "core";
  openbao.script = ./openbao-setup.sh;
  # spire.enable and zitadel.enable default to false for core tier
};
```

The AppRole role name defaults to the instance name (`openbao.approle.roleName`). SecretId
delivery is out-of-band (handled by `bao-secret-distributor` or equivalent).


## SPIRE attestation

SPIRE workload selectors are derived from `spire.workloadUser` and `spire.workloadExecutable`:

| Option | Selector generated | Use when |
|---|---|---|
| `workloadUser = "myapp"` | `unix:user:myapp` | Service runs as a static Unix user |
| `workloadExecutable = "/nix/store/.../bin/myapp"` | `unix:path:<path>` | Selector on the `/proc/<pid>/exe` path |
| Both set | Both selectors applied | Combined attestation |

**DynamicUser services:** when `workloadUser = null`, the `unix:user` selector is omitted
entirely. `systemd`'s `DynamicUser=true` assigns an ephemeral UID that SPIRE cannot predict, so
`workloadExecutable` must be set as the sole selector in this case.

At least one of `workloadUser` or `workloadExecutable` must be non-null when `spire.enable = true`
(enforced by assertion).

**BEAM apps:** use `lib.beamSmpPath` from this flake to resolve the `beam.smp` executable path
inside an Erlang derivation. Note that `beamSmpPath` uses IFD (Import From Derivation): it calls
`builtins.readDir` on the built Erlang package at eval time, so the Erlang derivation must be
realised before evaluation completes. This can slow down or break `nix flake check` and remote
evaluation if the package is not already in the Nix store.

```nix
spire.workloadExecutable = app-infra-module.lib.beamSmpPath pkgs.erlang;
```

**Provisioning entries:** set `spire.provisioningUser` to auto-generate a second SPIRE entry for
boot-time scripts that call `spiffe-agent api fetch jwt` (e.g. `secrets-fetch.sh`). The entry uses
`unix:user:<provisioningUser>` and `unix:path:<spire>/bin/spiffe-agent` as selectors.


## WARNING: path: inputs are dev-only

```
inputs.app-infra-module.url = "path:/path/to/app-infra-module";
```

`path:` (and `path:/absolute/...`) inputs embed an absolute filesystem path that only exists on
the developer workstation. They will fail to evaluate on any other machine, in CI, or during
remote NixOS builds.

**Switch to `github:` or `git+ssh:` before any of the following:**

- Deploying from a machine other than the developer workstation
- Running in CI
- Using `nix copy` or remote build caches

```nix
# After publishing:
inputs.app-infra-module.url = "github:your-org/app-infra-module";
# or private repo:
inputs.app-infra-module.url = "git+ssh://git@github.com/your-org/app-infra-module";
```


## Exports

### `nixosModules.default`

The NixOS module. Import it and configure via `services.app-infra.*`.

### `packages.<system>.app-infra-helpers`

The `helpers.sh` shell function library as a Nix derivation. Sourced automatically by the
generated setup scripts via `${APP_INFRA_HELPERS}`. Can also be referenced directly for
inspection or standalone testing.

### `lib.beamSmpPath`

```nix
beamSmpPath : derivation -> string
```

Resolves the absolute path to the `beam.smp` binary inside a given Erlang derivation. Used as
`spire.workloadExecutable` for BEAM workloads. See the IFD caveat above.


## Top-level module options

| Option | Default | Description |
|---|---|---|
| `services.app-infra.trustDomain` | `"infra.tailnet"` | SPIFFE trust domain for this machine |
| `services.app-infra.defaults.openbao.address` | `"https://127.0.0.1:8200"` | Default OpenBao address for all instances |
| `services.app-infra.defaults.openbao.skipVerify` | `false` | Default TLS skip-verify for all instances |
| `services.app-infra.defaults.openbao.tokenFile` | `"/var/lib/openbao/provisioner-token"` | Default provisioner token file path |
| `services.app-infra.instances.<name>` | — | Instance declarations (see below) |

### Instance options (`services.app-infra.instances.<name>`)

| Option | Default | Description |
|---|---|---|
| `enable` | — | Enable this instance |
| `tier` | `"standard"` | Authentication tier: `"standard"` or `"core"` |
| `runOnEachDeploy` | `false` | Delete stamp files on activation so setup services always re-run |
| `openbao.script` | — | Path to the app-owned OpenBao setup script |
| `openbao.address` | (inherits default) | OpenBao address override for this instance |
| `openbao.skipVerify` | (inherits default) | TLS skip-verify override for this instance |
| `openbao.tokenFile` | (inherits default) | Provisioner token file override for this instance |
| `openbao.approle.roleName` | (instance name) | AppRole role name (core tier) |
| `openbao.approle.tokenTtl` | `"1h"` | AppRole token TTL |
| `openbao.approle.tokenMaxTtl` | `"4h"` | AppRole token max TTL |
| `openbao.approle.secretIdNumUses` | `0` (unlimited) | AppRole secretId use limit |
| `zitadel.enable` | `true` for standard, `false` for core | Enable Zitadel setup service |
| `zitadel.script` | — | Path to the app-owned Zitadel setup script |
| `zitadel.address` | `"https://homeserver:8443"` | Zitadel server address |
| `zitadel.skipVerify` | `false` | Skip TLS verification for Zitadel |
| `zitadel.patKvPath` | `"kv/setup/zitadel-pat"` | OpenBao KV path for the Zitadel PAT |
| `zitadel.projectName` | (instance name) | Zitadel project name override |
| `spire.enable` | `true` for standard, `false` for core | Enable SPIRE workload entry auto-wiring |
| `spire.workloadUser` | `null` | Unix user for `unix:user` selector |
| `spire.workloadExecutable` | `null` | Executable path for `unix:path` selector |
| `spire.clientHostName` | (machine hostname) | Hostname where the workload runs |
| `spire.spiffeIdSuffix` | `"workload/<name>"` | Suffix appended to the trust domain for the SPIFFE ID |
| `spire.provisioningUser` | `null` | Unix user for the provisioning-script SPIRE entry |
