#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
# Setup CLOB Operator
# Grants OPERATOR_ROLE to the matcher wallet and FEE_ADMIN_ROLE to
# the deployer.  Safe to re-run (idempotent).
# ─────────────────────────────────────────────────────────────────────

prompt_secret() {
  local var_name="$1"
  local prompt="$2"
  if [[ -z "${!var_name:-}" ]]; then
    read -r -s -p "${prompt}: " value
    echo
    export "${var_name}=${value}"
  fi
}

prompt_value() {
  local var_name="$1"
  local prompt="$2"
  local default_value="${3:-}"
  if [[ -z "${!var_name:-}" ]]; then
    if [[ -n "${default_value}" ]]; then
      read -r -p "${prompt} [${default_value}]: " value
      value="${value:-$default_value}"
    else
      read -r -p "${prompt}: " value
    fi
    export "${var_name}=${value}"
  fi
}

echo "=== CLOB Operator Setup ==="
echo ""

# Required inputs
prompt_secret "PRIVATE_KEY" "PRIVATE_KEY (deployer/admin, hex, no 0x)"
prompt_value  "RPC_URL"          "RPC_URL"
prompt_value  "CLOB_FEE_MODULE"  "CLOB_FEE_MODULE address"
prompt_value  "OPERATOR"         "OPERATOR address (matcher wallet)"

echo ""
echo "Running forge script..."
echo ""

forge script script/SetupCLOBOperator.s.sol:SetupCLOBOperator \
  --rpc-url "${RPC_URL}" \
  --broadcast \
  -vvvv

echo ""
echo "Done!"
