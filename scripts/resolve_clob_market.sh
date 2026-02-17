#!/usr/bin/env bash
set -euo pipefail

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

prompt_secret "PRIVATE_KEY" "PRIVATE_KEY (hex, no 0x)"
prompt_value "RPC_URL" "RPC_URL"
prompt_value "CLOB_MANAGER" "CLOB_MANAGER address"

read -r -p "Market ID to resolve: " MARKET_ID
read -r -p "Winning outcome (0 = YES, 1 = NO, -1 = VOID): " OUTCOME

if [[ "${OUTCOME}" != "0" && "${OUTCOME}" != "1" && "${OUTCOME}" != "-1" ]]; then
  echo "Error: OUTCOME must be 0, 1, or -1"
  exit 1
fi

export MARKET_ID
export OUTCOME

outcome_label() {
  case "$1" in
    0)  echo "YES" ;;
    1)  echo "NO" ;;
    -1) echo "VOID" ;;
  esac
}

echo ""
echo "Resolving market ${MARKET_ID} → outcome ${OUTCOME} ($(outcome_label "${OUTCOME}"))"
echo ""

forge script script/ResolveMarket.s.sol:ResolveMarket \
  --rpc-url "${RPC_URL}" \
  --broadcast

echo ""
echo "✅ Market ${MARKET_ID} resolved to $(outcome_label "${OUTCOME}")."
