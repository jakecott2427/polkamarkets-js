#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════
# create_clob_markets.sh — Batch-create CLOB markets with oracle support
#
# Supports:
#   - No oracle (admin-only resolution)
#   - PriceThreshold oracle (Chainlink — price above/below X)
#   - UpOrDown oracle (Chainlink — price direction)
#   - Realitio oracle (human-answered questions)
#
# Auto-loads defaults from the most recent deploy env file if available.
# ═══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
ROOT_DIR="$(dirname "${REPO_DIR}")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

banner() { echo -e "\n${CYAN}═══════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}═══════════════════════════════════════════════════${NC}\n"; }
info()    { echo -e "${BLUE}ℹ${NC}  $1"; }
success() { echo -e "${GREEN}✓${NC}  $1"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $1"; }
error()   { echo -e "${RED}✗${NC}  $1"; }

prompt_secret() {
  local var_name="$1"
  local prompt="$2"
  if [[ -z "${!var_name:-}" ]]; then
    read -r -s -p "  ${prompt}: " value
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
      read -r -p "  ${prompt} [${default_value}]: " value
      value="${value:-$default_value}"
    else
      read -r -p "  ${prompt}: " value
    fi
    export "${var_name}=${value}"
  fi
}

run_forge() {
  local description="$1"
  shift
  local output=""
  local exit_code=0

  info "${description}..."
  output=$("$@" 2>&1) || exit_code=$?

  echo "${output}"

  if echo "${output}" | grep -q "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL"; then
    success "${description} — confirmed on-chain"
    FORGE_OUTPUT="${output}"
    return 0
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    error "${description} failed (exit code ${exit_code})"
    return 1
  fi

  FORGE_OUTPUT="${output}"
}

# ═══════════════════════════════════════════════════════════════════════
# Load defaults
# ═══════════════════════════════════════════════════════════════════════
banner "Create CLOB Markets"

# Try to load from root .env
if [[ -f "${ROOT_DIR}/.env" ]]; then
  source "${ROOT_DIR}/.env"
  info "Loaded defaults from ${ROOT_DIR}/.env"
fi

# Try to load from most recent deploy env
LATEST_DEPLOY=$(ls -t "${ROOT_DIR}/scripts/.deploy_bnb_"*.env 2>/dev/null | head -1 || true)
if [[ -n "${LATEST_DEPLOY}" && -f "${LATEST_DEPLOY}" ]]; then
  source "${LATEST_DEPLOY}"
  info "Loaded deploy defaults from ${LATEST_DEPLOY}"
fi

# ═══════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════
banner "Configuration"

prompt_secret "PRIVATE_KEY" "Deployer private key (hex)"
PRIVATE_KEY="${PRIVATE_KEY#0x}"
PRIVATE_KEY="0x${PRIVATE_KEY}"

prompt_value "RPC_URL" "RPC URL" "${CLOB_RPC_URL:-${RPC_URL:-}}"
prompt_value "CLOB_MANAGER" "CLOB_MANAGER address" "${CLOB_MANAGER:-}"
prompt_value "CLOB_FEE_MODULE" "CLOB_FEE_MODULE address" "${CLOB_FEE_MODULE:-}"

unset ORACLE CHAINLINK_FEED PRICE_THRESHOLD RESOLVE_ABOVE RESOLVE_UP ARBITRATOR REALITIO_TIMEOUT 2>/dev/null || true

echo ""
echo -e "${YELLOW}Oracle type for all markets:${NC}"
echo "  1) No oracle (admin-only resolution)"
echo "  2) PriceThreshold (Chainlink — price above/below X)"
echo "  3) UpOrDown (Chainlink — price direction)"
echo "  4) Realitio (human-answered questions)"
read -r -p "  Choose [1-4]: " ORACLE_CHOICE
ORACLE_CHOICE="${ORACLE_CHOICE:-1}"

ORACLE_TYPE="none"
ORACLE_ADDR="0x0000000000000000000000000000000000000000"

case "${ORACLE_CHOICE}" in
  2)
    ORACLE_TYPE="price"
    prompt_value "ORACLE" "PriceThresholdOracle address" "${PRICE_THRESHOLD_ORACLE:-}"
    ORACLE_ADDR="${ORACLE}"

    echo ""
    echo -e "  ${YELLOW}Known Chainlink feeds:${NC}"
    [[ -n "${CHAINLINK_BTC_USD:-}" ]] && echo "    BTC/USD: ${CHAINLINK_BTC_USD}"
    [[ -n "${CHAINLINK_ETH_USD:-}" ]] && echo "    ETH/USD: ${CHAINLINK_ETH_USD}"
    [[ -n "${CHAINLINK_BNB_USD:-}" ]] && echo "    BNB/USD: ${CHAINLINK_BNB_USD}"
    echo ""

    prompt_value "CHAINLINK_FEED" "Chainlink feed address"
    prompt_value "PRICE_THRESHOLD" "Price threshold (in feed decimals, e.g. 10000000000000 for \$100k with 8 decimals)"
    read -r -p "  Outcome 0 wins if price is ABOVE threshold? [Y/n]: " RESOLVE_ABOVE_INPUT
    RESOLVE_ABOVE_INPUT="${RESOLVE_ABOVE_INPUT:-y}"
    [[ "${RESOLVE_ABOVE_INPUT}" =~ ^[Yy] ]] && export RESOLVE_ABOVE=true || export RESOLVE_ABOVE=false
    export CHAINLINK_FEED PRICE_THRESHOLD
    ;;
  3)
    ORACLE_TYPE="updown"
    prompt_value "ORACLE" "UpOrDownOracle address" "${UPDOWN_ORACLE:-}"
    ORACLE_ADDR="${ORACLE}"

    echo ""
    echo -e "  ${YELLOW}Known Chainlink feeds:${NC}"
    [[ -n "${CHAINLINK_BTC_USD:-}" ]] && echo "    BTC/USD: ${CHAINLINK_BTC_USD}"
    [[ -n "${CHAINLINK_ETH_USD:-}" ]] && echo "    ETH/USD: ${CHAINLINK_ETH_USD}"
    [[ -n "${CHAINLINK_BNB_USD:-}" ]] && echo "    BNB/USD: ${CHAINLINK_BNB_USD}"
    echo ""

    prompt_value "CHAINLINK_FEED" "Chainlink feed address"
    read -r -p "  Outcome 0 wins if price goes UP? [Y/n]: " RESOLVE_UP_INPUT
    RESOLVE_UP_INPUT="${RESOLVE_UP_INPUT:-y}"
    [[ "${RESOLVE_UP_INPUT}" =~ ^[Yy] ]] && export RESOLVE_UP=true || export RESOLVE_UP=false
    export CHAINLINK_FEED
    ;;
  4)
    ORACLE_TYPE="realitio"
    prompt_value "ORACLE" "RealitioOracle address" "${REALITIO_ORACLE:-}"
    ORACLE_ADDR="${ORACLE}"
    prompt_value "ARBITRATOR" "Reality.eth arbitrator address"
    read -r -p "  Realitio timeout in seconds [3600]: " REALITIO_TIMEOUT_INPUT
    export REALITIO_TIMEOUT="${REALITIO_TIMEOUT_INPUT:-3600}"
    export ARBITRATOR
    ;;
  *)
    ORACLE_TYPE="none"
    ;;
esac

export ORACLE="${ORACLE_ADDR}"
export ORACLE_TYPE

echo ""
read -r -p "  Number of markets [10]: " MARKET_COUNT
MARKET_COUNT="${MARKET_COUNT:-10}"

read -r -p "  Question prefix [Myriad CLOB Market]: " QUESTION_PREFIX
QUESTION_PREFIX="${QUESTION_PREFIX:-Myriad CLOB Market}"

read -r -p "  Close offset (seconds from now) [86400]: " CLOSE_OFFSET
CLOSE_OFFSET="${CLOSE_OFFSET:-86400}"

read -r -p "  Close spacing (seconds between markets) [60]: " CLOSE_SPACING
CLOSE_SPACING="${CLOSE_SPACING:-60}"

read -r -p "  Image URL (optional): " IMAGE
IMAGE="${IMAGE:-}"
export IMAGE

read -r -p "  Set fees after creation? [y/N]: " SET_FEES
SET_FEES="${SET_FEES:-N}"
SET_FEES="$(printf '%s' "${SET_FEES}" | tr '[:upper:]' '[:lower:]')"

if [[ "${SET_FEES}" == "y" || "${SET_FEES}" == "yes" ]]; then
  read -r -p "  First MARKET_ID (will increment) [0]: " FIRST_MARKET_ID
  FIRST_MARKET_ID="${FIRST_MARKET_ID:-0}"
  read -r -p "  MAKER_FEE_BPS [100]: " MAKER_FEE_BPS
  MAKER_FEE_BPS="${MAKER_FEE_BPS:-100}"
  read -r -p "  TAKER_FEE_BPS [200]: " TAKER_FEE_BPS
  TAKER_FEE_BPS="${TAKER_FEE_BPS:-200}"
  read -r -p "  Fee curve? Peak at centre, 0 at edges [y/N]: " USE_CURVE
  USE_CURVE="${USE_CURVE:-N}"
  USE_CURVE="$(printf '%s' "${USE_CURVE}" | tr '[:upper:]' '[:lower:]')"
fi

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
echo ""
success "Configuration:"
echo -e "  ${YELLOW}Manager:${NC}    ${CLOB_MANAGER}"
echo -e "  ${YELLOW}FeeModule:${NC}  ${CLOB_FEE_MODULE}"
echo -e "  ${YELLOW}Oracle:${NC}     ${ORACLE_TYPE} (${ORACLE_ADDR})"
echo -e "  ${YELLOW}Markets:${NC}    ${MARKET_COUNT}"
echo -e "  ${YELLOW}Prefix:${NC}     ${QUESTION_PREFIX}"
echo -e "  ${YELLOW}Close:${NC}      +${CLOSE_OFFSET}s, spacing ${CLOSE_SPACING}s"
[[ "${SET_FEES}" == "y" || "${SET_FEES}" == "yes" ]] && echo -e "  ${YELLOW}Fees:${NC}       maker ${MAKER_FEE_BPS} bps / taker ${TAKER_FEE_BPS} bps"
echo ""

read -r -p "  Continue? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-y}"
if [[ ! "${CONFIRM}" =~ ^[Yy] ]]; then
  info "Aborted."
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════
# Create markets
# ═══════════════════════════════════════════════════════════════════════
banner "Creating Markets"

cd "${REPO_DIR}"

now_ts="$(date +%s)"
CREATED_IDS=()

for ((i=1; i<=MARKET_COUNT; i++)); do
  export QUESTION="${QUESTION_PREFIX} #${i}"
  export CLOSES_AT="$((now_ts + CLOSE_OFFSET + (i - 1) * CLOSE_SPACING))"

  echo ""
  info "Market ${i}/${MARKET_COUNT}: ${QUESTION}"
  echo -e "  Closes at: ${CLOSES_AT} ($(date -r "${CLOSES_AT}" 2>/dev/null || date -d "@${CLOSES_AT}" 2>/dev/null || echo "${CLOSES_AT}"))"

  FORGE_OUTPUT=""
  if ! run_forge "Create market #${i}" \
    forge script script/CreateCLOBMarket.s.sol:CreateCLOBMarket \
      --rpc-url "${RPC_URL}" \
      --broadcast; then
    warn "Market #${i} creation failed, skipping..."
    continue
  fi

  MARKET_ID=$(echo "${FORGE_OUTPUT}" | sed -n 's/.*Market created with ID: \([0-9]*\).*/\1/p' | head -1) || true
  MARKET_ID="${MARKET_ID:-?}"
  CREATED_IDS+=("${MARKET_ID}")
  success "Market #${MARKET_ID} created"

  if [[ "${SET_FEES}" == "y" || "${SET_FEES}" == "yes" ]]; then
    if [[ "${MARKET_ID}" == "?" ]]; then
      export MARKET_ID="$((FIRST_MARKET_ID + i - 1))"
    fi
    export MAKER_FEE_BPS TAKER_FEE_BPS
    if [[ "${USE_CURVE}" == "y" || "${USE_CURVE}" == "yes" ]]; then
      export FEE_CURVE=true
    else
      export FEE_CURVE=false
    fi

    if ! run_forge "Set fees for market #${MARKET_ID}" \
      forge script script/SetCLOBFees.s.sol:SetCLOBFees \
        --rpc-url "${RPC_URL}" \
        --broadcast; then
      warn "Fee setting failed for market #${MARKET_ID}, continuing..."
    fi
  fi
done

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
banner "Done!"

echo -e "${GREEN}Created ${#CREATED_IDS[@]} market(s):${NC}"
if [[ ${#CREATED_IDS[@]} -gt 0 ]]; then
  for mid in "${CREATED_IDS[@]}"; do
    echo "  - Market #${mid}"
  done
fi
echo ""
echo -e "${YELLOW}Oracle:${NC} ${ORACLE_TYPE} (${ORACLE_ADDR})"
echo ""
echo -e "${YELLOW}Next:${NC} Run importClobMarkets to sync to the API database:"
echo "  cd myriad-protocol-api && npx tsx src/scripts/importClobMarkets.ts"
echo ""
