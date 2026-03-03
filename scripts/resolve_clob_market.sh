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
read -r -p "Winning outcome (0 = outcome 0, 1 = outcome 1, -1 = VOID): " OUTCOME

if [[ "${OUTCOME}" != "0" && "${OUTCOME}" != "1" && "${OUTCOME}" != "-1" ]]; then
  echo "Error: OUTCOME must be 0, 1, or -1"
  exit 1
fi

export MARKET_ID
export OUTCOME

if [[ "${OUTCOME}" == "-1" ]]; then
  read -r -p "Outcome 0 payout % (0-100, outcome 1 gets the remainder) [50]: " OUTCOME0_PAYOUT_PCT
  OUTCOME0_PAYOUT_PCT="${OUTCOME0_PAYOUT_PCT:-50}"
  export OUTCOME0_PAYOUT_PCT
  OUTCOME1_PAYOUT_PCT=$((100 - OUTCOME0_PAYOUT_PCT))
  echo ""
  echo "Voiding market ${MARKET_ID} → outcome 0 ${OUTCOME0_PAYOUT_PCT}% / outcome 1 ${OUTCOME1_PAYOUT_PCT}%"
else
  outcome_label() { case "$1" in 0) echo "outcome 0" ;; 1) echo "outcome 1" ;; esac; }
  echo ""
  echo "Resolving market ${MARKET_ID} → outcome ${OUTCOME} ($(outcome_label "${OUTCOME}"))"
fi

echo ""

forge script script/ResolveMarket.s.sol:ResolveMarket \
  --rpc-url "${RPC_URL}" \
  --broadcast

echo ""
if [[ "${OUTCOME}" == "-1" ]]; then
  echo "✅ Market ${MARKET_ID} voided (outcome 0 ${OUTCOME0_PAYOUT_PCT}% / outcome 1 ${OUTCOME1_PAYOUT_PCT}%)."
else
  echo "✅ Market ${MARKET_ID} resolved to $(outcome_label "${OUTCOME}")."
fi
