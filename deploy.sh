#!/usr/bin/env bash
set -euo pipefail

# ================= Banner =================
curl -fsSL https://raw.githubusercontent.com/Wawanahayy/JawaPride-all.sh/refs/heads/main/display.sh | bash || true
sleep 1

BOLD=$(tput bold || true)
NORMAL=$(tput sgr0 || true)
PINK='\033[1;35m'
YELLOW='\033[1;33m'

show() {
  case "${2:-ok}" in
    error)    echo -e "${PINK}${BOLD}❌ $1${NORMAL}";;
    progress) echo -e "${PINK}${BOLD}⏳ $1${NORMAL}";;
    *)        echo -e "${PINK}${BOLD}✅ $1${NORMAL}";;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ================ Helpers =================
ensure_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    show "Installing $1 ..." progress
    case "$1" in
      wget) sudo apt-get update -y && sudo apt-get install -y wget ;;
      curl) sudo apt-get update -y && sudo apt-get install -y curl ;;
      git)  sudo apt-get update -y && sudo apt-get install -y git  ;;
      forge)
        # pakai installer Foundry dari repo kamu
        source <(wget -O - https://raw.githubusercontent.com/Wawanahayy/deploy/refs/heads/main/plex.sh)
        ;;
      *) show "Please install $1 manually." error; exit 1 ;;
    esac
  fi
}

ensure_basics() {
  ensure_tool git
  ensure_tool curl
  ensure_tool wget
  ensure_tool forge

  if [ ! -d ".git" ]; then
    show "Initializing Git repository..." progress
    git init -q
  fi

  # .gitignore minimum
  if [ ! -f .gitignore ]; then
cat > .gitignore <<'GIT'
.env
.env.*
!.env.example
node_modules/
**/node_modules/
out/
cache/
broadcast/
lib/
foundry-cache/
*.log
.vercel/
GIT
  fi

  # forge project skeleton (kalau belum ada)
  mkdir -p src lib token_deployment

  # OpenZeppelin Contracts
  if [ ! -d "lib/openzeppelin-contracts" ]; then
    show "Installing OpenZeppelin Contracts..." progress
    git clone --depth 1 https://github.com/OpenZeppelin/openzeppelin-contracts.git lib/openzeppelin-contracts
  else
    show "OpenZeppelin Contracts already installed."
  fi

  # foundry.toml
cat > foundry.toml <<'TOML'
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.26"
optimizer = true
optimizer_runs = 200

# Remappings wajib untuk import OZ
remappings = [
  "@openzeppelin/=lib/openzeppelin-contracts/"
]

[fmt]
line_length = 100

[rpc_endpoints]
# akan diisi dinamis via --rpc-url, key ini tetap boleh ada
default = "http://localhost:8545"
TOML
}

# ================ Input ====================
input_required_details() {
  echo "-----------------------------------"
  local ENV="$SCRIPT_DIR/token_deployment/.env"
  rm -f "$ENV"

  # Random default (boleh terpakai utk deploy 1x)
  local RAND_NAME;  RAND_NAME=$(head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 10)
  local RAND_SYM;   RAND_SYM=$(head -c 32 /dev/urandom | tr -dc 'A-Z'       | head -c 3)
  local TOKEN_NAME="Token_${RAND_NAME}"
  local TOKEN_SYMBOL="${RAND_SYM}"

  # Input aman
  read -r -p "RPC URL        : " RPC_URL
  read -r -s -p "Private Key    : " PRIVATE_KEY; echo
  read -r -p "Delay antar tx (detik): " DELAY_TIME

  umask 077
  cat > "$ENV" <<EOL
RPC_URL="$RPC_URL"
PRIVATE_KEY="$PRIVATE_KEY"
TOKEN_NAME="$TOKEN_NAME"
TOKEN_SYMBOL="$TOKEN_SYMBOL"
DELAY_TIME="${DELAY_TIME:-2}"
EOL
  show "Updated .env with your data"
}

# ============== Build & Deploy =============
write_contract() {
  # Arg: NAME SYMBOL INITIAL_SUPPLY
  local NAME="$1"
  local SYMBOL="$2"
  local SUPPLY="$3" # in whole tokens

cat > "$SCRIPT_DIR/src/RandomToken.sol" <<EOL
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RandomToken is ERC20 {
    constructor() ERC20("$NAME", "$SYMBOL") {
        _mint(msg.sender, $SUPPLY * (10 ** decimals()));
    }
}
EOL
}

compile_contract() {
  show "Compiling contract..." progress
  forge build
}

do_deploy() {
  # expects RPC_URL, PRIVATE_KEY in env
  local DEPLOY_OUTPUT
  DEPLOY_OUTPUT=$(forge create "src/RandomToken.sol:RandomToken" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast 2>&1 | tee /dev/stderr)

  # Ambil address
  local CONTRACT_ADDRESS
  CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oE 'Deployed to: 0x[a-fA-F0-9]{40}' | awk '{print $3}' || true)

  if [ -z "${CONTRACT_ADDRESS:-}" ]; then
    show "Deployment failed (no address found)." error
    exit 1
  fi

  show "Deployed at: $CONTRACT_ADDRESS"
}

deploy_random_once() {
  echo "-----------------------------------"
  # load env
  if [ ! -f "$SCRIPT_DIR/token_deployment/.env" ]; then
    show "Environment .env not found, run 'Input required details' first." error
    exit 1
  fi
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/token_deployment/.env"

  # generate random NAME/SYMBOL baru setiap deploy
  local RNAME RSYM
  RNAME=$(head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 10)
  RSYM=$(head -c 32 /dev/urandom | tr -dc 'A-Z'       | head -c 3)

  local NAME="Token_${RNAME}"
  local SYMBOL="${RSYM}"
  local SUPPLY=10000000000

  write_contract "$NAME" "$SYMBOL" "$SUPPLY"
  compile_contract
  do_deploy

  echo "Waiting ${DELAY_TIME}s before next action..."
  sleep "${DELAY_TIME}"
}

deploy_manual() {
  echo "-----------------------------------"
  if [ ! -f "$SCRIPT_DIR/token_deployment/.env" ]; then
    show "Environment .env not found, run 'Input required details' first." error
    exit 1
  fi
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/token_deployment/.env"

  read -r -p "Contract name (Class) [RandomToken]: " CONTRACT_CLASS
  CONTRACT_CLASS="${CONTRACT_CLASS:-RandomToken}"
  read -r -p "Token name        : " NAME
  read -r -p "Token symbol      : " SYMBOL
  read -r -p "Initial supply    : " SUPPLY

  # tulis ke file pakai class RandomToken (stabil)
  write_contract "$NAME" "$SYMBOL" "$SUPPLY"
  # bila ingin class custom, ganti nama file & 2 baris di bawah — tapi default aman:
  compile_contract
  do_deploy

  echo "Waiting ${DELAY_TIME}s before next action..."
  sleep "${DELAY_TIME}"
}

deploy_multiple() {
  echo "-----------------------------------"
  if [ ! -f "$SCRIPT_DIR/token_deployment/.env" ]; then
    show "Environment .env not found, run 'Input required details' first." error
    exit 1
  fi
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/token_deployment/.env"

  read -r -p "How many contracts to deploy? " NUM
  if ! [[ "$NUM" =~ ^[1-9][0-9]*$ ]]; then
    show "Invalid number." error
    exit 1
  fi

  for (( i=1; i<=NUM; i++ )); do
    local RNAME RSYM NAME SYMBOL SUPPLY
    RNAME=$(head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 10)
    RSYM=$(head -c 32 /dev/urandom | tr -dc 'A-Z'       | head -c 3)
    NAME="Token_${RNAME}"
    SYMBOL="${RSYM}"
    SUPPLY=10000000000

    show "[$i/$NUM] Preparing $NAME ($SYMBOL) ..." progress
    write_contract "$NAME" "$SYMBOL" "$SUPPLY"
    compile_contract
    do_deploy
    echo "Waiting ${DELAY_TIME}s..."
    sleep "${DELAY_TIME}"
    echo "-----------------------------------"
  done
}

# ================== Menu ===================
menu() {
  echo -e "\n${YELLOW}┌─────────────────────────────────────────────────────┐${NORMAL}"
  echo -e   "${YELLOW}│              Script Menu Options                    │${NORMAL}"
  echo -e   "${YELLOW}├─────────────────────────────────────────────────────┤${NORMAL}"
  echo -e   "${YELLOW}│ 1) Install dependencies                             │${NORMAL}"
  echo -e   "${YELLOW}│ 2) Input required details (.env)                     │${NORMAL}"
  echo -e   "${YELLOW}│ 3) Deploy contract (random, sekali)                 │${NORMAL}"
  echo -e   "${YELLOW}│ 4) Deploy contract (manual)                         │${NORMAL}"
  echo -e   "${YELLOW}│ 5) Deploy multiple (semua random)                   │${NORMAL}"
  echo -e   "${YELLOW}│ 6) Exit                                             │${NORMAL}"
  echo -e   "${YELLOW}└─────────────────────────────────────────────────────┘${NORMAL}"
  read -r -p "Enter your choice: " CHOICE

  case "${CHOICE}" in
    1) ensure_basics ;;
    2) input_required_details ;;
    3) deploy_random_once ;;
    4) deploy_manual ;;
    5) deploy_multiple ;;
    6) exit 0 ;;
    *) show "Invalid choice." error ;;
  esac
}

# ================ Run ======================
ensure_basics
while true; do menu; done
