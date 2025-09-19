#!/usr/bin/env bash
set -Eeuo pipefail

# Pretty display (optional)
curl -s https://raw.githubusercontent.com/Wawanahayy/JawaPride-all.sh/refs/heads/main/display.sh | bash || true
sleep 1

BOLD=$(tput bold || echo "")
NORMAL=$(tput sgr0 || echo "")
PINK='\033[1;35m'
YELLOW='\033[1;33m'

show() {
  local msg="${1:-}"; local kind="${2:-ok}"
  case "$kind" in
    error)    echo -e "${PINK}${BOLD}❌ $msg${NORMAL}";;
    progress) echo -e "${PINK}${BOLD}⏳ $msg${NORMAL}";;
    *)        echo -e "${PINK}${BOLD}✅ $msg${NORMAL}";;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

### Helpers
rand_alpha() { head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "${1:-10}"; }
rand_caps3() { head -c 32 /dev/urandom | tr -dc 'A-Z' | head -c 3; }
have() { command -v "$1" >/dev/null 2>&1; }

reset_workspace() {
  rm -rf contracts out cache target .last_deploy.json .last_deploy.err 2>/dev/null || true
  mkdir -p contracts
}

final_cleanup() {
  rm -rf contracts out cache target .last_deploy.json .last_deploy.err 2>/dev/null || true
}

ensure_git() {
  if [ ! -d ".git" ]; then
    show "Initializing Git repository…" progress
    git init >/dev/null 2>&1 || true
  fi
}

# ==== Foundry via official installer ====
ensure_foundry() {
  if command -v forge >/dev/null 2>&1; then
    show "Foundry sudah terpasang: $(forge --version | head -n1)"
    return
  fi
  show "Installing Foundry (resmi) …" progress
  curl -L https://foundry.paradigm.xyz | bash
  export PATH="$HOME/.foundry/bin:$PATH"
  if [ -x "$HOME/.foundry/bin/foundryup" ]; then
    "$HOME/.foundry/bin/foundryup"
  else
    foundryup
  fi
  show "Foundry: $(forge --version | head -n1)"
}

ensure_oz() {
  mkdir -p lib
  if [ ! -d "lib/openzeppelin-contracts" ]; then
    show "Installing OpenZeppelin (via forge) …" progress
    set +e
    forge install OpenZeppelin/openzeppelin-contracts --no-commit >/dev/null 2>&1
    local rc=$?
    set -e
    if [ $rc -ne 0 ]; then
      show "forge install failed. Fallback to git clone…" progress
      git clone --depth=1 https://github.com/OpenZeppelin/openzeppelin-contracts.git lib/openzeppelin-contracts
    fi
  else
    show "OpenZeppelin already present."
  fi
}

write_foundry_toml() {
  cat > foundry.toml <<'TOML'
[profile.default]
src = "contracts"
out = "out"
libs = ["lib"]
remappings = ["@openzeppelin/=lib/openzeppelin-contracts/"]
solc_version = "0.8.26"
optimizer = true
optimizer_runs = 200
TOML
}

ensure_env() {
  mkdir -p token_deployment
  local ENV="token_deployment/.env"

  ask() {
    local prompt="$1" default="$2" secret="${3:-no}" val
    if [ "$secret" = "yes" ]; then
      read -r -s -p "$prompt" val; echo
    else
      read -r -p "$prompt" val
    fi
    echo "${val:-$default}"
  }

  # load existing if any
  if [ -f "$ENV" ]; then
    # shellcheck disable=SC1090
    source "$ENV" || true
  fi

  local _PK="${PRIVATE_KEY:-}"
  local _RPC="${RPC_URL:-}"
  local _DELAY="${DELAY_TIME:-}"
  local _MAX="${ENV_MAX_USES:-}"
  local _LEFT="${ENV_USES_LEFT:-}"

  if [ -z "$_PK" ];   then _PK=$(ask "Enter your Private Key (0x… 64 hex, hidden): " "" yes); fi
  if [ -z "$_RPC" ];  then _RPC=$(ask "Enter the RPC URL: " ""); fi
  if [ -z "$_DELAY" ]; then _DELAY=$(ask "Delay between deployments (seconds) [2]: " "2"); fi
  if [ -z "$_MAX" ];  then _MAX=$(ask "How many deployments before wiping .env? [1]: " "1"); fi

  # normalize/validate
  _DELAY="${_DELAY:-2}"
  _MAX="${_MAX:-1}"
  if ! [[ "$_PK" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    show "Private key tidak valid (harus 0x + 64 hex)." error; exit 1
  fi
  if ! [[ "$_RPC" =~ ^https?:// ]]; then
    show "RPC URL tidak valid (harus http/https)." error; exit 1
  fi
  if ! [[ "$_DELAY" =~ ^[0-9]+$ ]]; then
    show "DELAY_TIME harus angka (detik)." error; exit 1
  fi
  if ! [[ "$_MAX" =~ ^[0-9]+$ ]] || [ "$_MAX" -lt 1 ]; then
    show "ENV_MAX_USES harus angka >=1." error; exit 1
  fi

  # init uses_left if missing
  if [ -z "$_LEFT" ]; then _LEFT="$_MAX"; fi

  # write back
  cat > "$ENV" <<EOF
PRIVATE_KEY="$_PK"
RPC_URL="$_RPC"
DELAY_TIME="$_DELAY"
ENV_MAX_USES="$_MAX"
ENV_USES_LEFT="$_LEFT"
EOF
  chmod 600 "$ENV" || true

  export PRIVATE_KEY="$_PK" RPC_URL="$_RPC" DELAY_TIME="$_DELAY" ENV_MAX_USES="$_MAX" ENV_USES_LEFT="$_LEFT"
  show "Saved credentials to $ENV (uses left: $ENV_USES_LEFT)"
}

mk_contract_file() {
  local CONTRACT_NAME="$1"; local TOKEN_NAME="$2"; local TOKEN_SYMBOL="$3"; local SUPPLY_WEI="$4"
  mkdir -p contracts
  cat > "contracts/${CONTRACT_NAME}.sol" <<SOL
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ${CONTRACT_NAME} is ERC20 {
    constructor() ERC20("${TOKEN_NAME}", "${TOKEN_SYMBOL}") {
        _mint(msg.sender, ${SUPPLY_WEI});
    }
}
SOL
}

forge_build() {
  show "Compiling contracts…" progress
  forge build -q
}

json_get() {
  local key="$1"
  if have jq; then
    jq -r ".${key} // empty"
  elif have python3; then
    python3 - "$key" <<'PY'
import sys, json
k = sys.argv[1]
try:
    d = json.load(sys.stdin)
    for part in k.split('.'):
        d = d.get(part, {})
    if isinstance(d, (dict, list)): print("")
    else: print(d if d is not None else "")
except Exception:
    print("")
PY
  else
    sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p" | head -n1
  fi
}

_after_success_decrement_or_wipe() {
  local ENV="token_deployment/.env"
  local left="${ENV_USES_LEFT:-1}"
  local max="${ENV_MAX_USES:-1}"
  if ! [[ "$left" =~ ^[0-9]+$ ]]; then left=1; fi
  if ! [[ "$max"  =~ ^[0-9]+$ ]]; then max=1; fi

  if [ "$left" -le 1 ]; then
    # wipe .env
    rm -f "$ENV"
    unset PRIVATE_KEY RPC_URL DELAY_TIME ENV_MAX_USES ENV_USES_LEFT
    show "ENV wiped after reaching max uses ($max)."
  else
    left=$(( left - 1 ))
    ENV_USES_LEFT="$left"
    export ENV_USES_LEFT
    # update file
    # shellcheck disable=SC1090
    {
      echo "PRIVATE_KEY=\"${PRIVATE_KEY:-}\""
      echo "RPC_URL=\"${RPC_URL:-}\""
      echo "DELAY_TIME=\"${DELAY_TIME:-2}\""
      echo "ENV_MAX_USES=\"${ENV_MAX_USES:-$max}\""
      echo "ENV_USES_LEFT=\"$left\""
    } > "$ENV"
    chmod 600 "$ENV" || true
    show "ENV uses left: $left"
  fi
}

deploy_one() {
  local CONTRACT_NAME="$1"
  local TOKEN_NAME="$2"
  local TOKEN_SYMBOL="$3"
  local SUPPLY_TOKENS="$4"
  local SUPPLY_WEI="(${SUPPLY_TOKENS} * (10 ** decimals()))"

  # fresh workspace
  reset_workspace
  mk_contract_file "$CONTRACT_NAME" "$TOKEN_NAME" "$TOKEN_SYMBOL" "$SUPPLY_WEI"
  forge_build

  show "Deploying $CONTRACT_NAME (${TOKEN_NAME}/${TOKEN_SYMBOL})…" progress

  : > .last_deploy.err
  set +e
  forge create "contracts/${CONTRACT_NAME}.sol:${CONTRACT_NAME}" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --json > .last_deploy.json 2> .last_deploy.err
  local rc=$?
  set -e

  if [ $rc -ne 0 ]; then
    cat .last_deploy.err >&2 || true
    [ -s .last_deploy.json ] && sed -n '1,120p' .last_deploy.json || true
    final_cleanup
    show "Deployment failed." error
    exit 1
  fi

  local TX_HASH ADDR
  TX_HASH=$(cat .last_deploy.json | json_get transactionHash)
  ADDR=$(cat .last_deploy.json | json_get deployedTo)

  if [[ ! "$ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] && [ -n "$TX_HASH" ] && have cast; then
    ADDR=$(cast receipt "$TX_HASH" contractAddress --rpc-url "$RPC_URL" 2>/dev/null || true)
    if [[ ! "$ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
      ADDR=$(cast receipt "$TX_HASH" --json --rpc-url "$RPC_URL" 2>/dev/null | json_get contractAddress)
    fi
  fi
  if [[ ! "$ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    ADDR=$(sed -n 's/.*Deployed to:[[:space:]]*\(0x[0-9a-fA-F]\{40\}\).*/\1/p' .last_deploy.json | tail -n1)
  fi

  if [[ ! "$ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    final_cleanup
    show "Could not parse contract address." error
    echo "Hints:"
    echo "  • TX hash di .last_deploy.json → cast receipt <txhash> contractAddress --rpc-url \"$RPC_URL\""
    echo "  • compute: cast compute-address <deployer> --nonce <nonce>"
    exit 1
  fi

  echo "$(date -Iseconds) | $CONTRACT_NAME | $TOKEN_NAME/$TOKEN_SYMBOL | $ADDR" | tee -a deployed.txt >/dev/null
  show "$CONTRACT_NAME deployed at: $ADDR"

  # Bersih total dan kurangi counter .env
  final_cleanup
  _after_success_decrement_or_wipe

  echo "Waiting ${DELAY_TIME:-2} seconds…"
  sleep "${DELAY_TIME:-2}"
}

install_dependencies() {
  ensure_git
  ensure_foundry
  ensure_oz
  write_foundry_toml
  show "Dependencies ready."
}

input_required_details() {
  echo "-----------------------------------"
  ensure_env
  write_foundry_toml
  show "Updated foundry & env."
}

deploy_contract_random() {
  echo "-----------------------------------"
  ensure_env
  local CONTRACT_NAME="RandomToken"
  local RANDOM_NAME="Token_$(rand_alpha 10)"
  local RANDOM_SYMBOL="$(rand_caps3)"
  local SUPPLY="10000000000" # 10B tokens
  deploy_one "$CONTRACT_NAME" "$RANDOM_NAME" "$RANDOM_SYMBOL" "$SUPPLY"
}

deploy_contract_manual() {
  echo "-----------------------------------"
  ensure_env
  read -r -p "Contract name (e.g., RandomToken): " CONTRACT_NAME
  case "$CONTRACT_NAME" in this|super|_*) show "Nama kontrak '$CONTRACT_NAME' terlarang." error; exit 1;; esac
  read -r -p "Token name: " TOKEN_NAME
  read -r -p "Token symbol (3–6 caps): " TOKEN_SYMBOL
  read -r -p "Initial supply (token units, e.g., 10000000000): " INITIAL_SUPPLY
  : "${CONTRACT_NAME:?}"; : "${TOKEN_NAME:?}"; : "${TOKEN_SYMBOL:?}"; : "${INITIAL_SUPPLY:?}"
  deploy_one "$CONTRACT_NAME" "$TOKEN_NAME" "$TOKEN_SYMBOL" "$INITIAL_SUPPLY"
}

deploy_multiple_contracts() {
  echo "-----------------------------------"
  ensure_env
  read -r -p "How many contracts to deploy? " NUM
  if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ]; then
    show "Invalid number." error; exit 1
  fi
  read -r -p "Base supply per token (default 10000000000): " SUPPLY
  SUPPLY="${SUPPLY:-10000000000}"

  for ((i=1; i<=NUM; i++)); do
    # jika .env sudah di-wipe karena batas habis, stop loop
    if [ ! -f token_deployment/.env ]; then
      show ".env already wiped — stopping multi deploy." error
      break
    fi
    # reload sisa counter
    # shellcheck disable=SC1090
    source token_deployment/.env || true
    local left="${ENV_USES_LEFT:-1}"
    if ! [[ "$left" =~ ^[0-9]+$ ]] || [ "$left" -lt 1 ]; then
      show "No uses left — stopping." error
      break
    fi

    local NAME="Token_$(rand_alpha 10)"
    local SYM="$(rand_caps3)"
    deploy_one "RandomToken" "$NAME" "$SYM" "$SUPPLY"
    echo "-----------------------------------"
  done
}

menu() {
  echo -e "\n${YELLOW}┌──────────────────────────────────────────────┐${NORMAL}"
  echo -e   "${YELLOW}│                  Menu                        │${NORMAL}"
  echo -e   "${YELLOW}├──────────────────────────────────────────────┤${NORMAL}"
  echo -e   "${YELLOW}│ 1) Install dependencies                      │${NORMAL}"
  echo -e   "${YELLOW}│ 2) Input/Update .env                         │${NORMAL}"
  echo -e   "${YELLOW}│ 3) Deploy contract (random)                  │${NORMAL}"
  echo -e   "${YELLOW}│ 4) Deploy contract (manual)                  │${NORMAL}"
  echo -e   "${YELLOW}│ 5) Deploy multiple random tokens             │${NORMAL}"
  echo -e   "${YELLOW}│ 6) Exit                                      │${NORMAL}"
  echo -e   "${YELLOW}└──────────────────────────────────────────────┘${NORMAL}"
  read -r -p "Enter choice: " CH
  case "$CH" in
    1) install_dependencies;;
    2) input_required_details;;
    3) deploy_contract_random;;
    4) deploy_contract_manual;;
    5) deploy_multiple_contracts;;
    6) exit 0;;
    *) show "Invalid choice." error;;
  esac
}

# ---- main flow ----
install_dependencies || true
ensure_env           || true
# Auto-deploy sekali SEBELUM menu (random)
deploy_contract_random || true
# Lalu tampilkan menu terus-menerus
while true; do menu; done
