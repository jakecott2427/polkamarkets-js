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
prompt_value "CLOB_FEE_MODULE" "CLOB_FEE_MODULE address"
prompt_value "ARBITRATOR" "ARBITRATOR address"

read -r -p "Number of markets [10]: " MARKET_COUNT
MARKET_COUNT="${MARKET_COUNT:-10}"

read -r -p "Question prefix [Myriad CLOB Market]: " QUESTION_PREFIX
QUESTION_PREFIX="${QUESTION_PREFIX:-Myriad CLOB Market}"

read -r -p "Close offset (seconds from now) [86400]: " CLOSE_OFFSET
CLOSE_OFFSET="${CLOSE_OFFSET:-86400}"

read -r -p "Close spacing (seconds between markets) [60]: " CLOSE_SPACING
CLOSE_SPACING="${CLOSE_SPACING:-60}"

read -r -p "Image URL (optional) []: " IMAGE
IMAGE="${IMAGE:-}"

read -r -p "Set fees after creation? [y/N]: " SET_FEES
SET_FEES="${SET_FEES:-N}"
SET_FEES="$(printf '%s' "${SET_FEES}" | tr '[:upper:]' '[:lower:]')"

if [[ "${SET_FEES}" == "y" || "${SET_FEES}" == "yes" ]]; then
  read -r -p "First MARKET_ID (will increment) [0]: " FIRST_MARKET_ID
  FIRST_MARKET_ID="${FIRST_MARKET_ID:-0}"
  read -r -p "MAKER_FEE_BPS [100]: " MAKER_FEE_BPS
  MAKER_FEE_BPS="${MAKER_FEE_BPS:-100}"
  read -r -p "TAKER_FEE_BPS [200]: " TAKER_FEE_BPS
  TAKER_FEE_BPS="${TAKER_FEE_BPS:-200}"
  read -r -p "Fee curve? Peak at centre, 0 at edges (y/N) [N]: " USE_CURVE
  USE_CURVE="${USE_CURVE:-N}"
  USE_CURVE="$(printf '%s' "${USE_CURVE}" | tr '[:upper:]' '[:lower:]')"
fi

now_ts="$(date +%s)"

for ((i=1; i<=MARKET_COUNT; i++)); do
  export QUESTION="${QUESTION_PREFIX} #${i}"
  export CLOSES_AT="$((now_ts + CLOSE_OFFSET + (i - 1) * CLOSE_SPACING))"
  if [[ -n "${IMAGE:-}" ]]; then
    export IMAGE
  else
    unset IMAGE 2>/dev/null || true
  fi

  echo "Creating market ${i}/${MARKET_COUNT}: ${QUESTION} (closes at ${CLOSES_AT})"
  forge script script/CreateCLOBMarket.s.sol:CreateCLOBMarket \
    --rpc-url "${RPC_URL}" \
    --broadcast

  if [[ "${SET_FEES}" == "y" || "${SET_FEES}" == "yes" ]]; then
    export MARKET_ID="$((FIRST_MARKET_ID + i - 1))"
    export MAKER_FEE_BPS
    export TAKER_FEE_BPS
    if [[ "${USE_CURVE}" == "y" || "${USE_CURVE}" == "yes" ]]; then
      export FEE_CURVE=true
      echo "Setting fees (curve) for market ${MARKET_ID}: peak maker ${MAKER_FEE_BPS} bps / peak taker ${TAKER_FEE_BPS} bps"
    else
      export FEE_CURVE=false
      echo "Setting fees (flat) for market ${MARKET_ID}: maker ${MAKER_FEE_BPS} bps / taker ${TAKER_FEE_BPS} bps"
    fi
    forge script script/SetCLOBFees.s.sol:SetCLOBFees \
      --rpc-url "${RPC_URL}" \
      --broadcast
  fi
done
