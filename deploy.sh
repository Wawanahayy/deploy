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

ensure_git() {
  if [ ! -d ".git" ]; then
    show "Initializing Git repository…" progress
    git init >/dev/null 2>&1 || true
  fi
}

# ==== RECOMMENDED: Foundry via official installer (no plex.sh) ====
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
  if [ ! -f "$ENV" ]; then
    echo "-----------------------------------"
    read -r -p "Enter your Private Key (0x…): " PRIVATE_KEY
    read -r -p "Enter the RPC URL: " RPC_URL
    read -r -p "Delay between deployments (seconds): " DELAY_TIME
    cat > "$ENV" <<EOF
PRIVATE_KEY="$PRIVATE_KEY"
RPC_URL="$RPC_URL"
DELAY_TIME="${DELAY_TIME:-2}"
EOF
    chmod 600 "$ENV" || true
    show "Saved credentials to $ENV"
  fi
  # shellcheck disable=SC1090
  source "$ENV"
  : "${PRIVATE_KEY:?Missing PRIVATE_KEY in .env}"
  : "${RPC_URL:?Missing RPC_URL in .env}"
  : "${DELAY_TIME:=2}"
}

mk_contract_file() {
  local CONTRACT_NAME="$1"   # e.g., RandomToken
  local TOKEN_NAME="$2"      # e.g., Token_ABC
  local TOKEN_SYMBOL="$3"    # e.g., ABC
  local SUPPLY_WEI="$4"      # e.g., 10000000000 * 10**18
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
  # usage: echo "$JSON" | json_get key.path.if.needed
  local key="$1"
  if have jq; then
    jq -r ".${key} // empty"
  elif have python3; then
    python3 - "$key" <<'PY'
import sys, json
k = sys.argv[1]
try:
    data = json.load(sys.stdin)
    def get(d, path):
        cur = d
        for p in path.split('.'):
            if isinstance(cur, dict):
                cur = cur.get(p, "")
            else:
                cur = ""
        return cur if cur is not None else ""
    v = get(data, k)
    print(v)
except Exception:
    print("")
PY
  else
    # super simple fallback (best effort)
    sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p" | head -n1
  fi
}

deploy_one() {
  local CONTRACT_NAME="$1"
  local TOKEN_NAME="$2"
  local TOKEN_SYMBOL="$3"
  local SUPPLY_TOKENS="$4"   # plain token units, multiplied by 10**decimals in Solidity
  local SUPPLY_WEI="(${SUPPLY_TOKENS} * (10 ** decimals()))"

  mk_contract_file "$CONTRACT_NAME" "$TOKEN_NAME" "$TOKEN_SYMBOL" "$SUPPLY_WEI"
  forge_build

  show "Deploying $CONTRACT_NAME (${TOKEN_NAME}/${TOKEN_SYMBOL})…" progress

  # Run in JSON mode; keep stdout JSON & stderr separate
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
    # Sometimes forge still writes partial JSON; show some context:
    [ -s .last_deploy.json ] && sed -n '1,120p' .last_deploy.json || true
    show "Deployment failed." error
    exit 1
  fi

  # Try standard keys
  local TX_HASH ADDR
  TX_HASH=$(cat .last_deploy.json | json_get transactionHash)
  ADDR=$(cat .last_deploy.json | json_get deployedTo)

  # Receipt fallback (node lag)
  if [[ ! "$ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] && [ -n "$TX_HASH" ] && have cast; then
    ADDR=$(cast receipt "$TX_HASH" contractAddress --rpc-url "$RPC_URL" 2>/dev/null || true)
    if [[ ! "$ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
      ADDR=$(cast receipt "$TX_HASH" --json --rpc-url "$RPC_URL" 2>/dev/null | json_get contractAddress)
    fi
  fi

  # Legacy text fallback
  if [[ ! "$ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    ADDR=$(sed -n 's/.*Deployed to:[[:space:]]*\(0x[0-9a-fA-F]\{40\}\).*/\1/p' .last_deploy.json | tail -n1)
  fi

  # Compute-address fallback (needs deployer + nonce in JSON)
  if [[ ! "$ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] && have cast; then
    local DEPLOYER NONCE
    DEPLOYER=$(cat .last_deploy.json | json_get deployer)
    NONCE=$(cat .last_deploy.json | json_get nonce)
    if [[ "$DEPLOYER" =~ ^0x[0-9a-fA-F]{40}$ ]] && [ -n "$NONCE" ]; then
      ADDR=$(cast compute-address "$DEPLOYER" --nonce "$NONCE" 2>/dev/null || true)
    fi
  fi

  if [[ ! "$ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    show "Could not parse contract address." error
    echo "Hints:"
    echo "  • TX hash (jika ada) di .last_deploy.json → cast receipt <txhash> contractAddress --rpc-url \"$RPC_URL\""
    echo "  • Atau compute: cast compute-address <deployer> --nonce <nonce>"
    exit 1
  fi

  echo "$(date -Iseconds) | $CONTRACT_NAME | $TOKEN_NAME/$TOKEN_SYMBOL | $ADDR" | tee -a deployed.txt >/dev/null
  show "$CONTRACT_NAME deployed at: $ADDR"

  echo "Waiting $DELAY_TIME seconds…"
  sleep "$DELAY_TIME"
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
  case "$CONTRACT_NAME" in
    this|super|_*) show "Nama kontrak '$CONTRACT_NAME' terlarang (reserved/bad)." error; exit 1;;
  esac
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
    show "Invalid number." error
    exit 1
  fi
  read -r -p "Base supply per token (default 10000000000): " SUPPLY
  SUPPLY="${SUPPLY:-10000000000}"

  for ((i=1; i<=NUM; i++)); do
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

# ---- main loop ----
install_dependencies || true
while true; do menu; done
