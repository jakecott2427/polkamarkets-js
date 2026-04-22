#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════
# resolve_clob_market.sh — Resolve a CLOB market or neg-risk event
#
# Modes:
#   1) Regular — resolve/void a single binary CLOB market
#   2) Neg-risk — resolve an entire multi-outcome event
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

# ═══════════════════════════════════════════════════════════════════════
# Load defaults
# ═══════════════════════════════════════════════════════════════════════
banner "Resolve CLOB Market"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  source "${ROOT_DIR}/.env"
  info "Loaded defaults from ${ROOT_DIR}/.env"
fi

LATEST_DEPLOY=$(ls -t "${ROOT_DIR}/scripts/.deploy_bnb_"*.env 2>/dev/null | head -1 || true)
if [[ -n "${LATEST_DEPLOY}" && -f "${LATEST_DEPLOY}" ]]; then
  source "${LATEST_DEPLOY}"
  info "Loaded deploy defaults from ${LATEST_DEPLOY}"
fi

# ═══════════════════════════════════════════════════════════════════════
# Mode selection
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}Resolution type:${NC}"
echo "  1) Regular — resolve a single binary market"
if [[ -n "${CLOB_NEG_RISK_ADAPTER:-}" ]]; then
  echo "  2) Neg-risk — resolve an entire multi-outcome event"
else
  echo -e "  2) Neg-risk ${RED}(unavailable — NEG_RISK_ADAPTER not in deploy env)${NC}"
fi
read -r -p "  Choose [1/2]: " MODE_CHOICE
MODE_CHOICE="${MODE_CHOICE:-1}"

# ═══════════════════════════════════════════════════════════════════════
# Common config
# ═══════════════════════════════════════════════════════════════════════
banner "Configuration"

prompt_secret "PRIVATE_KEY" "Deployer private key (hex)"
PRIVATE_KEY="${PRIVATE_KEY#0x}"
PRIVATE_KEY="0x${PRIVATE_KEY}"

prompt_value "RPC_URL" "RPC URL" "${CLOB_RPC_URL:-${RPC_URL:-}}"

if [[ "${MODE_CHOICE}" == "2" ]]; then
  # ═══════════════════════════════════════════════════════════════════
  # Neg-risk event resolution
  # ═══════════════════════════════════════════════════════════════════
  if [[ -z "${CLOB_NEG_RISK_ADAPTER:-}" ]]; then
    error "NEG_RISK_ADAPTER address not available. Set CLOB_NEG_RISK_ADAPTER."
    exit 1
  fi

  prompt_value "NEG_RISK_ADAPTER" "NegRiskAdapter address" "${CLOB_NEG_RISK_ADAPTER:-}"

  echo ""
  read -r -p "  Event ID (bytes32 hex, e.g. 0x08a7...): " EVENT_ID
  if [[ -z "${EVENT_ID}" ]]; then
    error "Event ID is required."
    exit 1
  fi
  export EVENT_ID

  echo ""
  echo -e "  ${YELLOW}Winning outcome:${NC}"
  echo "    -1 = \"Other\" wins (all markets resolve to NO)"
  echo "     0 = First named outcome wins"
  echo "     1 = Second named outcome wins"
  echo "     N = Nth named outcome wins (0-indexed)"
  read -r -p "  Winning index: " WINNING_INDEX
  if [[ -z "${WINNING_INDEX}" ]]; then
    error "Winning index is required."
    exit 1
  fi
  export WINNING_INDEX

  echo ""
  read -r -p "  Also redeem NO positions? [Y/n]: " REDEEM_INPUT
  REDEEM_INPUT="${REDEEM_INPUT:-y}"
  [[ "${REDEEM_INPUT}" =~ ^[Yy] ]] && export REDEEM=true || export REDEEM=false

  # ─── Summary ───
  echo ""
  success "Resolution:"
  echo -e "  ${YELLOW}Mode:${NC}          Neg-risk event"
  echo -e "  ${YELLOW}Adapter:${NC}       ${NEG_RISK_ADAPTER}"
  echo -e "  ${YELLOW}Event ID:${NC}      ${EVENT_ID}"
  if [[ "${WINNING_INDEX}" == "-1" ]]; then
    echo -e "  ${YELLOW}Winner:${NC}        Other (all markets → NO)"
  else
    echo -e "  ${YELLOW}Winner:${NC}        Outcome #${WINNING_INDEX}"
  fi
  echo -e "  ${YELLOW}Redeem NO:${NC}     ${REDEEM}"
  echo ""

  read -r -p "  Continue? [Y/n]: " CONFIRM
  CONFIRM="${CONFIRM:-y}"
  if [[ ! "${CONFIRM}" =~ ^[Yy] ]]; then
    info "Aborted."
    exit 0
  fi

  cd "${REPO_DIR}"

  forge script script/ResolveNegRiskEvent.s.sol:ResolveNegRiskEvent \
    --rpc-url "${RPC_URL}" \
    --broadcast

  echo ""
  if [[ "${WINNING_INDEX}" == "-1" ]]; then
    success "Event ${EVENT_ID} resolved — Other wins (all markets → NO)."
  else
    success "Event ${EVENT_ID} resolved — Outcome #${WINNING_INDEX} wins."
  fi

  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════
# Regular market resolution
# ═══════════════════════════════════════════════════════════════════════
prompt_value "CLOB_MANAGER" "CLOB_MANAGER address" "${CLOB_MANAGER:-}"

echo ""
read -r -p "  Market ID to resolve: " MARKET_ID
if [[ -z "${MARKET_ID}" ]]; then
  error "Market ID is required."
  exit 1
fi

echo ""
echo -e "  ${YELLOW}Resolution mode:${NC}"
echo "    -2 = Use oracle (permissionless resolveMarket)"
echo "     0 = Admin resolve to outcome 0 (YES)"
echo "     1 = Admin resolve to outcome 1 (NO)"
echo "    -1 = Void (split payout between outcomes)"
read -r -p "  Outcome: " OUTCOME

if [[ "${OUTCOME}" != "0" && "${OUTCOME}" != "1" && "${OUTCOME}" != "-1" && "${OUTCOME}" != "-2" ]]; then
  error "OUTCOME must be -2, -1, 0, or 1"
  exit 1
fi

export MARKET_ID
export OUTCOME

if [[ "${OUTCOME}" == "-1" ]]; then
  read -r -p "  Outcome 0 payout % (0-100, outcome 1 gets the remainder) [50]: " OUTCOME0_PAYOUT_PCT
  OUTCOME0_PAYOUT_PCT="${OUTCOME0_PAYOUT_PCT:-50}"
  export OUTCOME0_PAYOUT_PCT
  OUTCOME1_PAYOUT_PCT=$((100 - OUTCOME0_PAYOUT_PCT))
fi

# ─── Summary ───
echo ""
success "Resolution:"
echo -e "  ${YELLOW}Mode:${NC}       Regular market"
echo -e "  ${YELLOW}Manager:${NC}    ${CLOB_MANAGER}"
echo -e "  ${YELLOW}Market ID:${NC}  ${MARKET_ID}"
if [[ "${OUTCOME}" == "-2" ]]; then
  echo -e "  ${YELLOW}Method:${NC}     Oracle (permissionless)"
elif [[ "${OUTCOME}" == "-1" ]]; then
  echo -e "  ${YELLOW}Method:${NC}     Void — outcome 0: ${OUTCOME0_PAYOUT_PCT}% / outcome 1: ${OUTCOME1_PAYOUT_PCT}%"
elif [[ "${OUTCOME}" == "0" ]]; then
  echo -e "  ${YELLOW}Winner:${NC}     Outcome 0 (YES)"
elif [[ "${OUTCOME}" == "1" ]]; then
  echo -e "  ${YELLOW}Winner:${NC}     Outcome 1 (NO)"
fi
echo ""

read -r -p "  Continue? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-y}"
if [[ ! "${CONFIRM}" =~ ^[Yy] ]]; then
  info "Aborted."
  exit 0
fi

cd "${REPO_DIR}"

forge script script/ResolveMarket.s.sol:ResolveMarket \
  --rpc-url "${RPC_URL}" \
  --broadcast

echo ""
if [[ "${OUTCOME}" == "-2" ]]; then
  success "Market ${MARKET_ID} resolved via oracle."
elif [[ "${OUTCOME}" == "-1" ]]; then
  success "Market ${MARKET_ID} voided (outcome 0: ${OUTCOME0_PAYOUT_PCT}% / outcome 1: ${OUTCOME1_PAYOUT_PCT}%)."
else
  label="outcome ${OUTCOME}"
  [[ "${OUTCOME}" == "0" ]] && label="outcome 0 (YES)"
  [[ "${OUTCOME}" == "1" ]] && label="outcome 1 (NO)"
  success "Market ${MARKET_ID} resolved to ${label}."
fi
