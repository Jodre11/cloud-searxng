#!/usr/bin/env bash
# Source this file to load OCI credentials from Bitwarden into env vars.
# Usage: source scripts/env.sh
#
# - Unlocks Bitwarden if needed
# - Exports TF_VAR_* for Terraform
# - Writes the PEM to disk if missing (only secret that must be on disk)

# No set -e — this file is sourced, not executed. Errors are handled inline.

_env_sh_bw_item="OCI - cloud-searxng"
_env_sh_pem_path="$HOME/.oci/oci_api_key.pem"

# --- Unlock Bitwarden ---
if [[ -z "${BW_SESSION:-}" ]]; then
    echo "Unlocking Bitwarden..."
    BW_SESSION=$(bw unlock --raw) || { echo "Failed to unlock Bitwarden."; return 1; }
    export BW_SESSION
fi

echo "Fetching OCI credentials from Bitwarden..."
_env_sh_item_file=$(mktemp)
if ! bw get item "$_env_sh_bw_item" > "$_env_sh_item_file"; then
    echo "Failed to fetch item from Bitwarden."
    rm -f "$_env_sh_item_file"
    return 1
fi

_env_sh_field() {
    jq -r --arg name "$1" '.fields[] | select(.name == $name) | .value' < "$_env_sh_item_file"
}

_env_sh_require_field() {
    local value
    value=$(_env_sh_field "$1")
    if [[ -z "$value" || "$value" == "null" ]]; then
        echo "Error: Bitwarden field '$1' is empty or missing."
        return 1
    fi
    printf '%s' "$value"
}

# --- Export Terraform variables ---
TF_VAR_tenancy_ocid=$(_env_sh_require_field "tenancy_ocid") || { rm -f "$_env_sh_item_file"; return 1; }
TF_VAR_user_ocid=$(_env_sh_require_field "user_ocid") || { rm -f "$_env_sh_item_file"; return 1; }
TF_VAR_fingerprint=$(_env_sh_require_field "fingerprint") || { rm -f "$_env_sh_item_file"; return 1; }
TF_VAR_compartment_ocid=$(_env_sh_require_field "compartment_ocid") || { rm -f "$_env_sh_item_file"; return 1; }
export TF_VAR_tenancy_ocid TF_VAR_user_ocid TF_VAR_fingerprint TF_VAR_compartment_ocid
export TF_VAR_private_key_path="$_env_sh_pem_path"

# --- Write PEM if missing or empty ---
if [[ ! -s "$_env_sh_pem_path" ]]; then
    echo "Writing PEM to $_env_sh_pem_path..."
    mkdir -p "$(dirname "$_env_sh_pem_path")"
    chmod 700 "$(dirname "$_env_sh_pem_path")"
    _env_sh_require_field "private_key_pem" > "$_env_sh_pem_path" || { rm -f "$_env_sh_pem_path" "$_env_sh_item_file"; return 1; }
    chmod 600 "$_env_sh_pem_path"
else
    echo "PEM already exists at $_env_sh_pem_path"
fi

rm -f "$_env_sh_item_file"
unset _env_sh_bw_item _env_sh_pem_path _env_sh_item_file
unset -f _env_sh_field _env_sh_require_field

echo "OCI credentials loaded into environment."
echo "  TF_VAR_tenancy_ocid, TF_VAR_user_ocid, TF_VAR_fingerprint,"
echo "  TF_VAR_compartment_ocid, TF_VAR_private_key_path"
