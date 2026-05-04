#!/usr/bin/env bash
# app-infra-helpers.sh — shell function library for app-infra setup scripts
#
# Sourced via: source "${APP_INFRA_HELPERS}"
#
# Required env vars (injected by app-infra module):
#   BAO_ADDR          — OpenBao address (e.g. https://127.0.0.1:8200)
#   BAO_TOKEN         — OpenBao provisioner token
#   BAO_SKIP_VERIFY   — set "true" to skip TLS verification
#   ZITADEL_URL       — Zitadel address (e.g. https://homeserver:8443)
#   ZITADEL_PAT_KV_PATH — KV path for Zitadel PAT (e.g. kv/setup/zitadel-pat)
#   APP_NAME          — app name (attrset key)
#   SPIFFE_ID         — SPIFFE ID for the workload
#   CLIENT_HOST       — hostname where the workload runs
#   APP_INFRA_HELPERS — nix store path to this file (self-reference for docs)
#
# Binary dependencies: bao, curl, jq — all must be in PATH (set by module ExecStart)

set -euo pipefail

# ── OpenBao helpers ────────────────────────────────────────────────────────────

# bao_ensure_kv_mount <path>
# Enable a kv-v2 secrets engine at <path> if not already mounted. Idempotent.
# Uses bao read sys/mounts/<path> to check existence (avoids needing sys/mounts list).
bao_ensure_kv_mount() {
  local path="$1"
  local mount_path="${path%/}"
  if bao read "sys/mounts/${mount_path}" >/dev/null 2>&1; then
    echo "[app-infra] kv mount '${path}' already exists — skipping"
  else
    echo "[app-infra] enabling kv-v2 at '${path}'"
    bao secrets enable -path="${mount_path}" kv-v2
  fi
}

# bao_ensure_policy <name> <hcl>
# Write an OpenBao policy. Idempotent (bao policy write is always safe to re-run).
bao_ensure_policy() {
  local name="$1"
  local hcl="$2"
  echo "[app-infra] writing policy '${name}'"
  bao policy write "${name}" - <<< "${hcl}"
}

# bao_ensure_jwt_role <name> <spiffe_id> [mount] [policies]
# Create or update a JWT auth role on auth/<mount>/role/<name>. Idempotent.
# Role config: bound_audiences=openbao, user_claim=sub, bound_claims.sub=<spiffe_id>
# token_policies defaults to <name>; pass explicitly when policy name differs from role name.
# mount defaults to "jwt"; pass "jwt-spire" for SPIRE workloads.
bao_ensure_jwt_role() {
  local name="$1"
  local spiffe_id="$2"
  local mount="${3:-jwt}"
  local policies="${4:-${name}}"
  echo "[app-infra] configuring JWT auth role '${name}' for SPIFFE ID '${spiffe_id}' on auth/${mount} (policies=${policies})"
  bao write "auth/${mount}/role/${name}" \
    role_type=jwt \
    bound_audiences=openbao \
    user_claim=sub \
    "bound_claims.sub=${spiffe_id}" \
    token_policies="${policies}" \
    token_ttl=1h \
    token_max_ttl=4h
}

# bao_ensure_zitadel_jwt_role <mount> <role> <client_id> <issuer_url> <policies> [user_claim] [groups_claim]
# Create or update a JWT auth role for Zitadel OIDC tokens. Idempotent.
# NOTE: bound_audiences = zitadel_issuer_url — Zitadel tokens set aud to issuer URL, NOT "openbao"
# NOTE: bound_claims.sub = client_id — Zitadel machine user clientId (omitted if client_id is empty)
# user_claim defaults to "sub". groups_claim is optional; omitted if empty.
bao_ensure_zitadel_jwt_role() {
  local mount="$1" role="$2" client_id="$3" issuer_url="$4" policies="$5"
  local user_claim="${6:-sub}"
  local groups_claim="${7:-}"
  echo "[app-infra] configuring Zitadel JWT auth role '${role}' on auth/${mount}"
  local -a args=(
    role_type=jwt
    bound_audiences="${issuer_url}"
    bound_claims_type=string
    token_policies="${policies}"
    token_ttl=3600
    token_max_ttl=86400
    user_claim="${user_claim}"
  )
  if [[ -n "${client_id}" ]]; then
    args+=("bound_claims.sub=${client_id}")
  fi
  if [[ -n "${groups_claim}" ]]; then
    args+=("groups_claim=${groups_claim}")
  fi
  bao write "auth/${mount}/role/${role}" "${args[@]}"
}

# bao_seed_secret <kv_path> <key> <value>
# Write <key>=<value> to the KV path only if the key does not already exist.
# Use this for initial secret seeding — does not overwrite existing values.
bao_seed_secret() {
  local kv_path="$1"
  local key="$2"
  local value="$3"
  if bao kv get -field="${key}" "${kv_path}" >/dev/null 2>&1; then
    echo "[app-infra] secret '${kv_path}#${key}' already exists — skipping"
  else
    echo "[app-infra] seeding secret '${kv_path}#${key}'"
    bao kv put "${kv_path}" "${key}=${value}"
  fi
}

# bao_upsert_secret <kv_path> <key> <value>
# Always write <key>=<value>, preserving other keys in the path.
# Use for values derived from external systems (e.g. Zitadel IDs) that must stay current.
bao_upsert_secret() {
  local kv_path="$1"
  local key="$2"
  local value="$3"
  echo "[app-infra] upserting secret '${kv_path}#${key}'"
  bao kv patch "${kv_path}" "${key}=${value}" 2>/dev/null \
    || bao kv put "${kv_path}" "${key}=${value}"
}

# bao_ensure_approle_role <name> <policies> [token_ttl] [token_max_ttl] [secret_id_num_uses]
# Create or update an AppRole role. Idempotent.
# secretId delivery is out-of-band (bao-distribute-secrets.sh).
bao_ensure_approle_role() {
  local name="$1" policies="$2"
  local token_ttl="${3:-1h}" token_max_ttl="${4:-4h}" secret_id_num_uses="${5:-0}"
  echo "[app-infra] configuring AppRole role '${name}'"
  bao write "auth/approle/role/${name}" \
    token_policies="${policies}" \
    token_ttl="${token_ttl}" \
    token_max_ttl="${token_max_ttl}" \
    secret_id_num_uses="${secret_id_num_uses}"
}

# bao_read_field <kv_path> <field>
# Read a single field from a KV v2 path. Outputs the value to stdout.
bao_read_field() {
  local kv_path="$1"
  local field="$2"
  bao kv get -field="${field}" "${kv_path}"
}

# bao_ensure_group_alias <group_name> <mount_path> <alias_name> <policies>
# Create an external identity group and bind an alias from the given JWT mount to it.
# Idempotent: reads before creating both the group and the alias.
# <mount_path>  — auth mount path without leading/trailing slash (e.g. "jwt")
# <alias_name>  — value that must appear in the JWT groups_claim to match this group
# <policies>    — comma-separated OpenBao policies to attach to the group
bao_ensure_group_alias() {
  local group_name="$1" mount_path="$2" alias_name="$3" policies="$4"
  local accessor
  accessor=$(bao auth list -format=json | jq -r ".\"${mount_path}/\".accessor // empty")
  if [[ -z "${accessor}" ]]; then
    echo "[app-infra] ERROR: auth mount '${mount_path}/' not found — cannot create group alias" >&2
    return 1
  fi

  if ! bao read "identity/group/name/${group_name}" >/dev/null 2>&1; then
    echo "[app-infra] creating identity group '${group_name}'"
    bao write "identity/group" \
      name="${group_name}" \
      type=external \
      "policies=${policies}"
  else
    echo "[app-infra] identity group '${group_name}' already exists — skipping creation"
  fi

  local group_id
  group_id=$(bao read -format=json "identity/group/name/${group_name}" | jq -r '.data.id')

  local existing_alias
  existing_alias=$(bao read -format=json "identity/group/name/${group_name}" 2>/dev/null \
    | jq -r --arg acc "${accessor}" \
      '(.data.alias // []) | if type == "array" then .[] else . end
       | select(.mount_accessor == $acc) | .id // empty' \
    2>/dev/null || true)

  if [[ -z "${existing_alias}" ]]; then
    echo "[app-infra] creating group alias '${alias_name}' on ${mount_path}/ for group '${group_name}'"
    bao write identity/group-alias \
      name="${alias_name}" \
      mount_accessor="${accessor}" \
      canonical_id="${group_id}"
  else
    echo "[app-infra] group alias '${alias_name}' on ${mount_path}/ already exists — skipping"
  fi
}

# ── Zitadel helpers ────────────────────────────────────────────────────────────

# _zitadel_curl_opts
# Internal: build curl options array respecting ZITADEL_TLS_SKIP_VERIFY.
_zitadel_curl_opts() {
  local -a opts=(-s -f)
  if [[ "${ZITADEL_TLS_SKIP_VERIFY:-false}" == "true" ]]; then
    opts+=(-k)
  fi
  printf '%s\n' "${opts[@]}"
}

# zitadel_get_token
# Fetch the Zitadel PAT from OpenBao KV. Output the token to stdout.
# Scripts should call: export ZITADEL_TOKEN=$(zitadel_get_token)
zitadel_get_token() {
  bao_read_field "${ZITADEL_PAT_KV_PATH}" token
}

# zitadel_ensure_project <name>
# Create a Zitadel project if it doesn't already exist. Echoes the project ID.
# Requires: ZITADEL_TOKEN, ZITADEL_URL, ZITADEL_TLS_SKIP_VERIFY
zitadel_ensure_project() {
  local name="$1"
  local -a curl_opts
  mapfile -t curl_opts < <(_zitadel_curl_opts)

  # Search for existing project by name
  local response
  response=$(curl "${curl_opts[@]}" \
    -X POST \
    -H "Authorization: Bearer ${ZITADEL_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"queries\":[{\"nameQuery\":{\"name\":\"${name}\",\"method\":\"TEXT_QUERY_METHOD_EQUALS\"}}]}" \
    "${ZITADEL_URL}/management/v1/projects/_search")

  local project_id
  project_id=$(echo "${response}" | jq -r '.result[0].id // empty')

  if [[ -n "${project_id}" ]]; then
    echo "[app-infra] project '${name}' already exists: ${project_id}" >&2
    echo "${project_id}"
    return 0
  fi

  # Create project
  echo "[app-infra] creating project '${name}'" >&2
  local create_response
  create_response=$(curl "${curl_opts[@]}" \
    -X POST \
    -H "Authorization: Bearer ${ZITADEL_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${name}\"}" \
    "${ZITADEL_URL}/management/v1/projects")

  echo "${create_response}" | jq -r '.id'
}

# zitadel_ensure_machine_user <username>
# Create a Zitadel machine user if it doesn't already exist. Echoes the user ID.
# Requires: ZITADEL_TOKEN, ZITADEL_URL, ZITADEL_TLS_SKIP_VERIFY
zitadel_ensure_machine_user() {
  local username="$1"
  local -a curl_opts
  mapfile -t curl_opts < <(_zitadel_curl_opts)

  # Search for existing user by username
  local response
  response=$(curl "${curl_opts[@]}" \
    -X POST \
    -H "Authorization: Bearer ${ZITADEL_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"queries\":[{\"userNameQuery\":{\"userName\":\"${username}\",\"method\":\"TEXT_QUERY_METHOD_EQUALS\"}}]}" \
    "${ZITADEL_URL}/v2/users")

  local user_id
  user_id=$(echo "${response}" | jq -r '.result[0].userId // empty')

  if [[ -n "${user_id}" ]]; then
    echo "[app-infra] machine user '${username}' already exists: ${user_id}" >&2
    echo "${user_id}"
    return 0
  fi

  # Create machine user
  echo "[app-infra] creating machine user '${username}'" >&2
  local create_response
  create_response=$(curl "${curl_opts[@]}" \
    -X POST \
    -H "Authorization: Bearer ${ZITADEL_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"userName\":\"${username}\",\"profile\":{\"displayName\":\"${username}\"}}" \
    "${ZITADEL_URL}/management/v1/users/machine")

  echo "${create_response}" | jq -r '.userId'
}

# zitadel_ensure_oidc_app <project_id> <name> <redirect_uri>
# Create an OIDC application in the given project if it doesn't already exist.
# Requires: ZITADEL_TOKEN, ZITADEL_URL, ZITADEL_TLS_SKIP_VERIFY
zitadel_ensure_oidc_app() {
  local project_id="$1"
  local name="$2"
  local redirect_uri="$3"
  local -a curl_opts
  mapfile -t curl_opts < <(_zitadel_curl_opts)

  # Search for existing app in project
  local response
  response=$(curl "${curl_opts[@]}" \
    -X POST \
    -H "Authorization: Bearer ${ZITADEL_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"queries\":[{\"nameQuery\":{\"name\":\"${name}\",\"method\":\"TEXT_QUERY_METHOD_EQUALS\"}}]}" \
    "${ZITADEL_URL}/management/v1/projects/${project_id}/apps/_search")

  local app_id
  app_id=$(echo "${response}" | jq -r '.result[0].id // empty')

  if [[ -n "${app_id}" ]]; then
    echo "[app-infra] OIDC app '${name}' already exists: ${app_id}" >&2
    echo "${app_id}"
    return 0
  fi

  # Create OIDC app
  echo "[app-infra] creating OIDC app '${name}' in project ${project_id}" >&2
  local create_response
  create_response=$(curl "${curl_opts[@]}" \
    -X POST \
    -H "Authorization: Bearer ${ZITADEL_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${name}\",
      \"redirectUris\": [\"${redirect_uri}\"],
      \"responseTypes\": [\"OIDC_RESPONSE_TYPE_CODE\"],
      \"grantTypes\": [\"OIDC_GRANT_TYPE_AUTHORIZATION_CODE\"],
      \"appType\": \"OIDC_APP_TYPE_WEB\",
      \"authMethodType\": \"OIDC_AUTH_METHOD_TYPE_BASIC\"
    }" \
    "${ZITADEL_URL}/management/v1/projects/${project_id}/apps/oidc")

  echo "${create_response}" | jq -r '.appId'
}
