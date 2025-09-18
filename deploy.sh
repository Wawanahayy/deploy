#!/bin/bash
# Safer shell (jangan -u supaya var kosong ga bikin exit)
set -eo pipefail

# (non-fatal) Banner
curl -s https://raw.githubusercontent.com/Wawanahayy/JawaPride-all.sh/refs/heads/main/display.sh | bash || true
sleep 1

BOLD=$(tput bold); NORMAL=$(tput sgr0)
PINK='\033[1;35m'; YELLOW='\033[1;33m'

show() {
  case "${2:-ok}" in
    error)    echo -e "${PINK}${BOLD}❌ $1${NORMAL}";;
    progress) echo -e "${PINK}${BOLD}⏳ $1${NORMAL}";;
    *)        echo -e "${PINK}${BOLD}✅ $1${NORMAL}";;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# ---- helpers ----
sanitize() {
  local s="$1"
  s="${s//[^A-Za-z0-9_]/_}"
  [[ "$s" =~ ^[0-9_] ]] && s="X${s}"
  if [[ "$s" =~ ^(this|super|contract|function|event|error|mapping|import|using|interface|type|public|external|internal|private|payable|view|pure|virtual|override|return|if|else|for|while|do|try|catch|assembly|unchecked|new|delete|true|false)$ ]]; then
    s="${s}_X"
  fi
  echo "$s"
}

ensure_env() {
  if [ ! -f "$SCRIPT_DIR/token_deployment/.env" ]; then
    show "Config belum ada. Jalankan menu (2) dulu untuk isi detail." "error"
    return 1
  fi
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/token_deployment/.env"
  # wajib ada:
  if [ -z "${PRIVATE_KEY:-}" ] || [ -z "${RPC_URL:-}" ]; then
    show "PRIVATE_KEY / RPC_URL kosong di .env" "error"
    return 1
  fi
  return 0
}

install_dependencies() {
  if [ ! -d ".git" ]; then
    show "Initializing Git repository..." "progress"
    git init >/dev/null
  fi

  if ! command -v forge >/dev/null 2>&1; then
    show "Foundry is not installed. Installing now..." "progress"
    # installer kamu
    source <(wget -O - https://raw.githubusercontent.com/Wawanahayy/deploy/refs/heads/main/plex.sh)
    export PATH="$HOME/.foundry/bin:$PATH"
    command -v forge >/dev/null || { show "forge belum di PATH; buka shell baru atau export PATH." "error"; }
  fi

  if [ ! -d "$SCRIPT_DIR/lib/openzeppelin-contracts" ]; then
    show "Installing OpenZeppelin Contracts..." "progress"
    git clone --depth 1 https://github.com/OpenZeppelin/openzeppelin-contracts.git "$SCRIPT_DIR/lib/openzeppelin-contracts"
  else
    show "OpenZeppelin Contracts already installed."
  fi

  mkdir -p "$SCRIPT_DIR/src" "$SCRIPT_DIR/token_deployment"

  # Kontrak template (constructor args) — compile sekali, deploy berkali-kali
  cat > "$SCRIPT_DIR/src/TokenTemplate.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TokenTemplate is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply)
        ERC20(name_, symbol_)
    {
        _mint(msg.sender, initialSupply);
    }
}
SOL

  # foundry.toml + remappings agar import OZ jalan
  cat > "$SCRIPT_DIR/foundry.toml" <<'TOML'
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
optimizer = true
optimizer_runs = 200
remappings = ["@openzeppelin/=lib/openzeppelin-contracts/"]

[rpc_endpoints]
# akan diisi via --rpc-url saat forge create
TOML

  show "Dependencies ready."
}

input_required_details() {
  echo -e "-----------------------------------"

  # Acak default nama/simbol (hanya default, bukan wajib)
  RAND_NAME=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)
  RAND_SYM=$(tr -dc 'A-Z' </dev/urandom | head -c 3)

  read -rp "Enter your Private Key: " PRIVATE_KEY
  read -rp "Enter the network RPC URL: " RPC_URL
  read -rp "Enter the delay time in seconds between transactions: " DELAY_TIME

  mkdir -p "$SCRIPT_DIR/token_deployment"
  cat > "$SCRIPT_DIR/token_deployment/.env" <<EOL
PRIVATE_KEY="$PRIVATE_KEY"
RPC_URL="$RPC_URL"
DELAY_TIME="${DELAY_TIME:-5}"
DEFAULT_TOKEN_NAME="Token_${RAND_NAME}"
DEFAULT_TOKEN_SYMBOL="${RAND_SYM}"
DEFAULT_INITIAL_SUPPLY_WEI="$((1000000 * 10**18))"
EOL

  show "Updated files with your given data"
}

deploy_once() {
  # gunakan env dari .env + var override (TOKEN_NAME/TOKEN_SYMBOL/SUPPLY_WEI) bila diset
  ensure_env || return 1

  local NAME="${TOKEN_NAME:-$DEFAULT_TOKEN_NAME}"
  local SYMBOL="${TOKEN_SYMBOL:-$DEFAULT_TOKEN_SYMBOL}"
  local SUPPLY="${SUPPLY_WEI:-$DEFAULT_INITIAL_SUPPLY_WEI}"

  NAME=$(sanitize "$NAME")
  SYMBOL=$(sanitize "$SYMBOL")

  show "Compiling..." "progress"
  if ! forge build >/dev/null; then
    show "Compile gagal." "error"
    return 1
  fi

  show "Deploying ${NAME} (${SYMBOL})..." "progress"
  DEPLOY_OUTPUT=$(forge create "$SCRIPT_DIR/src/TokenTemplate.sol:TokenTemplate" \
      --rpc-url "$RPC_URL" \
      --private-key "$PRIVATE_KEY" \
      --constructor-args "$NAME" "$SYMBOL" "$SUPPLY" 2>&1) || {
        show "Deployment failed." "error"
        echo "$DEPLOY_OUTPUT"
        return 1
      }

  CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oE 'Deployed to: (0x[0-9a-fA-F]{40})' | awk '{print $3}')
  if [ -z "$CONTRACT_ADDRESS" ]; then
    show "Gagal parse alamat kontrak." "error"
    echo "$DEPLOY_OUTPUT"
    return 1
  fi

  mkdir -p "$SCRIPT_DIR/token_deployment"
  if [ ! -f "$SCRIPT_DIR/token_deployment/deployments.csv" ]; then
    echo "name,symbol,initial_supply_wei,address" > "$SCRIPT_DIR/token_deployment/deployments.csv"
  fi
  echo "${NAME},${SYMBOL},${SUPPLY},${CONTRACT_ADDRESS}" >> "$SCRIPT_DIR/token_deployment/deployments.csv"

  show "Deployed at: $CONTRACT_ADDRESS"
  sleep "${DELAY_TIME:-5}"
}

deploy_contract() {
  echo -e "-----------------------------------"
  # MODE RANDOM (gunakan TOKEN_NAME/TOKEN_SYMBOL dari env runtime kalau ada)
  deploy_once
}

deploy_contract_manual() {
  echo -e "-----------------------------------"
  ensure_env || exit 1

  read -rp "Enter contract name (e.g., MyToken): " NAME
  read -rp "Enter the token symbol (e.g., MTK): " SYMBOL
  read -rp "Enter the initial supply (human, e.g., 1000000): " HUMAN_SUPPLY

  # konversi ke wei (18 desimal)
  SUPPLY_WEI=$(python3 - <<PY
import sys,decimal
decimal.getcontext().prec = 80
h = decimal.Decimal("${HUMAN_SUPPLY or '1000000'}")
print(int(h * (10 ** 18)))
PY
)
  TOKEN_NAME="$NAME" TOKEN_SYMBOL="$SYMBOL" SUPPLY_WEI="$SUPPLY_WEI" deploy_once
}

deploy_multiple_contracts() {
  echo -e "-----------------------------------"
  ensure_env || exit 1

  read -rp "How many contracts do you want to deploy? " NUM_CONTRACTS
  if [[ -z "${NUM_CONTRACTS}" || "${NUM_CONTRACTS}" -lt 1 ]]; then
    show "Invalid number of contracts." "error"
    exit 1
  fi

  for (( i=1; i<=NUM_CONTRACTS; i++ )); do
    RAND_NAME=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)
    RAND_SYM=$(tr -dc 'A-Z' </dev/urandom | head -c 3)
    NAME="Token_${RAND_NAME}"
    SYMBOL="${RAND_SYM}"

    # ⛔ JANGAN overwrite .env — hanya override via env runtime
    TOKEN_NAME="$NAME" TOKEN_SYMBOL="$SYMBOL" deploy_once
    echo -e "-----------------------------------"
  done
}

menu() {
  echo -e "\n${YELLOW}┌─────────────────────────────────────────────────────┐${NORMAL}"
  echo -e   "${YELLOW}│              Script Menu Options                    │${NORMAL}"
  echo -e   "${YELLOW}├─────────────────────────────────────────────────────┤${NORMAL}"
  echo -e   "${YELLOW}│ 1) Install dependencies                             │${NORMAL}"
  echo -e   "${YELLOW}│ 2) Input required details                           │${NORMAL}"
  echo -e   "${YELLOW}│ 3) Deploy contract(random)                          │${NORMAL}"
  echo -e   "${YELLOW}│ 4) Deploy contract (manual)                         │${NORMAL}"
  echo -e   "${YELLOW}│ 5) Exit                                             │${NORMAL}"
  echo -e   "${YELLOW}└─────────────────────────────────────────────────────┘${NORMAL}"

  read -rp "Enter your choice: " CHOICE
  case "$CHOICE" in
    1) install_dependencies ;;
    2) input_required_details ;;
    3) deploy_multiple_contracts ;;
    4) deploy_contract_manual ;;
    5) exit 0 ;;
    *) show "Invalid choice." "error" ;;
  esac
}

# CRLF killer kalau file disunting di Windows
sed -i 's/\r$//' "$0" 2>/dev/null || true

while true; do
  menu
done
