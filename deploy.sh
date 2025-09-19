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

# .env handler
ensure_env() {
  mkdir -p token_deployment
  local ENV="token_deployment/.env"

  ask() {
    local prompt="$1" default="$2" secret="${3:-no}" val
    if [ "$secret" = "yes" ]; then
      read -r -s -p "$prompt" val
      # newline fix
      echo
      printf '\n\n'
    else
      read -r -p "$prompt" val
    fi
    val="$(printf "%s" "$val" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    echo "${val:-$default}"
  }

  if [ -f "$ENV" ]; then
    source "$ENV" || true
  fi

  local _PK="${PRIVATE_KEY:-}"
  local _RPC="${RPC_URL:-}"
  local _DELAY="${DELAY_TIME:-}"
  local _MAX="${ENV_MAX_USES:-}"
  local _LEFT="${ENV_USES_LEFT:-}"

  if [ -z "$_PK" ]; then
    _PK=$(ask "Enter your Private Key (0x… or 64-hex, hidden; or @/path/to/file): " "" yes)
    if [[ "$_PK" == @* ]]; then
      local fp="${_PK#@}"
      if [ -f "$fp" ]; then _PK="$(tr -d '\r\n' < "$fp")"; fi
    fi
  fi
  _PK="$(printf "%s" "$_PK" | tr -d ' \t\r\n')"
  if [[ "$_PK" =~ ^[0-9a-fA-F]{64}$ ]]; then _PK="0x$_PK"; fi

  if [ -z "$_RPC" ];   then _RPC=$(ask "Enter the RPC URL: " ""); fi
  if [ -z "$_DELAY" ]; then _DELAY=$(ask "Delay between deployments (seconds) [2]: " "2"); fi
  if [ -z "$_MAX" ];   then _MAX=$(ask "How many deployments before wiping .env? [1]: " "1"); fi

  if ! [[ "$_PK" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    show "Private key tidak valid. Contoh: 0x0123… (64 hex)" error
    exit 1
  fi
  if ! [[ "$_RPC" =~ ^https?:// ]]; then
    show "RPC URL tidak valid." error; exit 1
  fi
  if ! [[ "$_DELAY" =~ ^[0-9]+$ ]]; then
    show "DELAY_TIME harus angka." error; exit 1
  fi
  if ! [[ "$_MAX" =~ ^[0-9]+$ ]] || [ "$_MAX" -lt 1 ]; then
    show "ENV_MAX_USES harus angka >=1." error; exit 1
  fi

  if [ -z "$_LEFT" ]; then _LEFT="$_MAX"; fi

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
  if have jq; then jq -r ".${key} // empty"; else sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p" | head -n1; fi
}

_after_success_decrement_or_wipe() {
  local ENV="token_deployment/.env"
  local left="${ENV_USES_LEFT:-1}" max="${ENV_MAX_USES:-1}"
  [[ "$left" =~ ^[0-9]+$ ]] || left=1
  [[ "$max"  =~ ^[0-9]+$ ]] || max=1

  if [ "$left" -le 1 ]; then
    rm -f "$ENV"
    unset PRIVATE_KEY RPC_URL DELAY_TIME ENV_MAX_USES ENV_USES_LEFT
    show "ENV wiped after reaching max uses ($max)."
  else
    left=$(( left - 1 ))
    ENV_USES_LEFT="$left"; export ENV_USES_LEFT
    {
      echo "PRIVATE_KEY=\"$PRIVATE_KEY\""
      echo "RPC_URL=\"$RPC_URL\""
      echo "DELAY_TIME=\"$DELAY_TIME\""
      echo "ENV_MAX_USES=\"$ENV_MAX_USES\""
      echo "ENV_USES_LEFT=\"$left\""
    } > "$ENV"
    chmod 600 "$ENV" || true
    show "ENV uses left: $left"
  fi
}

deploy_one() {
  local CONTRACT_NAME="$1" TOKEN_NAME="$2" TOKEN_SYMBOL="$3" SUPPLY_TOKENS="$4"
  local SUPPLY_WEI="(${SUPPLY_TOKENS} * (10 ** decimals()))"

  reset_workspace
  mk_contract_file "$CONTRACT_NAME" "$TOKEN_NAME" "$TOKEN_SYMBOL" "$SUPPLY_WEI"
  forge_build

  show "Deploying $CONTRACT_NAME (${TOKEN_NAME}/${TOKEN_SYMBOL})…" progress
  : > .last_deploy.err
  set +e
  forge create "contracts/${CONTRACT_NAME}.sol:${CONTRACT_NAME}" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --json > .last_deploy.json 2> .last_deploy.err
  local rc=$?
  set -e

  if [ $rc -ne 0 ]; then cat .last_deploy.err; final_cleanup; show "Deployment failed." error; exit 1; fi

  local ADDR=$(cat .last_deploy.json | json_get deployedTo)
  if [[ ! "$ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    ADDR=$(sed -n 's/.*Deployed to:[[:space:]]*\(0x[0-9a-fA-F]\{40\}\).*/\1/p' .last_deploy.json | tail -n1)
  fi
  if [[ ! "$ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]]; then final_cleanup; show "Could not parse contract address." error; exit 1; fi

  echo "$(date -Iseconds) | $CONTRACT_NAME | $TOKEN_NAME/$TOKEN_SYMBOL | $ADDR" | tee -a deployed.txt >/dev/null
  show "$CONTRACT_NAME deployed at: $ADDR"

  final_cleanup
  _after_success_decrement_or_wipe
  sleep "${DELAY_TIME:-2}"
}

install_dependencies() { ensure_git; ensure_foundry; ensure_oz; write_foundry_toml; show "Dependencies ready."; }
input_required_details() { ensure_env; write_foundry_toml; show "Updated foundry & env."; }
deploy_contract_random() { ensure_env; deploy_one "RandomToken" "Token_$(rand_alpha 10)" "$(rand_caps3)" "10000000000"; }
deploy_contract_manual() { ensure_env; read -r -p "Contract name: " CONTRACT_NAME; read -r -p "Token name: " TOKEN_NAME; read -r -p "Token symbol: " TOKEN_SYMBOL; read -r -p "Initial supply: " INITIAL_SUPPLY; deploy_one "$CONTRACT_NAME" "$TOKEN_NAME" "$TOKEN_SYMBOL" "$INITIAL_SUPPLY"; }

menu() {
  echo -e "\n${YELLOW}┌──────────────────────────────────────────────┐${NORMAL}"
  echo -e   "${YELLOW}│                  Menu                        │${NORMAL}"
  echo -e   "${YELLOW}├──────────────────────────────────────────────┤${NORMAL}"
  echo -e   "${YELLOW}│ 1) Install dependencies                      │${NORMAL}"
  echo -e   "${YELLOW}│ 2) Input/Update .env                         │${NORMAL}"
  echo -e   "${YELLOW}│ 3) Deploy contract (random)                  │${NORMAL}"
  echo -e   "${YELLOW}│ 4) Deploy contract (manual)                  │${NORMAL}"
  echo -e   "${YELLOW}│ 5) Exit                                      │${NORMAL}"
  echo -e   "${YELLOW}└──────────────────────────────────────────────┘${NORMAL}"
  read -r -p "Enter choice: " CH
  case "$CH" in
    1) install_dependencies;;
    2) input_required_details;;
    3) deploy_contract_random;;
    4) deploy_contract_manual;;
    5) exit 0;;
    *) show "Invalid choice." error;;
  esac
}

install_dependencies || true
ensure_env           || true
deploy_contract_random || true
while true; do menu; done
