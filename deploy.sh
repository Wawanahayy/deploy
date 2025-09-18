#!/bin/bash
set -euo pipefail

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
cd "$SCRIPT_DIR"

install_dependencies() {
  if [ ! -d ".git" ]; then
    show "Initializing Git repository..." progress
    git init >/dev/null
  fi

  if ! command -v forge >/dev/null 2>&1; then
    show "Installing Foundry..." progress
    curl -L https://foundry.paradigm.xyz | bash
    export PATH="$HOME/.foundry/bin:$PATH"
    foundryup >/dev/null
  fi

  mkdir -p lib
  if [ ! -d "lib/openzeppelin-contracts" ]; then
    show "Installing OpenZeppelin Contracts..." progress
    git clone --depth 1 https://github.com/OpenZeppelin/openzeppelin-contracts.git lib/openzeppelin-contracts >/dev/null
  else
    show "OpenZeppelin Contracts already installed."
  fi

  mkdir -p src token_deployment

  # Token template (compile sekali, deploy berkali-kali)
  cat > src/TokenTemplate.sol <<'SOL'
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.20;
  import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

  contract TokenTemplate is ERC20 {
      constructor(string memory name_, string memory symbol_, uint256 initialSupply)
      ERC20(name_, symbol_) {
          _mint(msg.sender, initialSupply);
      }
  }
SOL

  # foundry.toml dengan remappings
  cat > foundry.toml <<'TOML'
  [profile.default]
  src = "src"
  out = "out"
  libs = ["lib"]
  optimizer = true
  optimizer_runs = 200

  remappings = ["@openzeppelin/=lib/openzeppelin-contracts/"]

  [rpc_endpoints]
  # akan diisi via ENV RPC_URL saat forge create
TOML

  show "Dependencies ready."
}

input_required_details() {
  echo "-----------------------------------"
  read -rp "Enter your Private Key: " PRIVATE_KEY
  read -rp "Enter the network RPC URL: " RPC_URL
  read -rp "Enter delay time (seconds) between tx: " DELAY_TIME

  # Seed nama/simbol default (boleh diubah per-deploy)
  RAND_NAME=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)
  RAND_SYM=$(tr -dc 'A-Z' </dev/urandom | head -c 3)

  cat > token_deployment/.env <<EOF
PRIVATE_KEY="$PRIVATE_KEY"
RPC_URL="$RPC_URL"
DELAY_TIME="${DELAY_TIME:-5}"
DEFAULT_TOKEN_NAME="Token_${RAND_NAME}"
DEFAULT_TOKEN_SYMBOL="${RAND_SYM}"
DEFAULT_INITIAL_SUPPLY_WEI="$((1000000 * 10**18))"
EOF

  show "Saved to token_deployment/.env"
}

# Sanitizer kecil biar gak nabrak keyword aneh
sanitize() {
  local s="$1"
  s="${s//[^A-Za-z0-9_]/_}"
  [[ "$s" =~ ^[0-9_] ]] && s="X${s}"
  if [[ "$s" =~ ^(this|super|contract|function|event|error|mapping|import|using|interface|type|public|external|internal|private|payable|view|pure|virtual|override|return|if|else|for|while|do|try|catch|assembly|unchecked|new|delete|true|false)$ ]]; then
    s="${s}_X"
  fi
  echo "$s"
}

deploy_once() {
  # args: NAME SYMBOL SUPPLY_WEI
  local NAME="$1" SYMBOL="$2" SUPPLY="$3"
  source token_deployment/.env

  NAME=$(sanitize "$NAME")
  SYMBOL=$(sanitize "$SYMBOL")

  show "Deploying \"$NAME\" ($SYMBOL)..." progress

  # compile sekali per session
  forge build >/dev/null

  # deploy (tidak pakai --broadcast)
  DEPLOY_OUTPUT=$(forge create src/TokenTemplate.sol:TokenTemplate \
      --rpc-url "$RPC_URL" \
      --private-key "$PRIVATE_KEY" \
      --constructor-args "$NAME" "$SYMBOL" "$SUPPLY" \
    )

  if [[ $? -ne 0 ]]; then
    show "Deployment failed." error
    echo "$DEPLOY_OUTPUT"
    exit 1
  fi

  CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oE 'Deployed to: (0x[0-9a-fA-F]{40})' | awk '{print $3}')
  show "Deployed at: $CONTRACT_ADDRESS"

  echo "${NAME},${SYMBOL},${SUPPLY},${CONTRACT_ADDRESS}" >> token_deployment/deployments.csv

  sleep "${DELAY_TIME:-5}"
}

deploy_multiple_contracts() {
  echo "-----------------------------------"
  read -rp "How many contracts do you want to deploy? " NUM
  if [[ -z "${NUM}" || "${NUM}" -lt 1 ]]; then
    show "Invalid number of contracts." error
    exit 1
  fi

  source token_deployment/.env

  # header csv
  if [ ! -f token_deployment/deployments.csv ]; then
    echo "name,symbol,initial_supply_wei,address" > token_deployment/deployments.csv
  fi

  for (( i=1; i<=NUM; i++ )); do
    RAND_NAME=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)
    RAND_SYM=$(tr -dc 'A-Z' </dev/urandom | head -c 3)

    NAME="Token_${RAND_NAME}"
    SYMBOL="${RAND_SYM}"
    SUPPLY="${DEFAULT_INITIAL_SUPPLY_WEI:-1000000000000000000000000}"  # 1,000,000 * 1e18

    show "Compiling contract $i..." progress
    deploy_once "$NAME" "$SYMBOL" "$SUPPLY"
    echo "-----------------------------------"
  done
}

deploy_contract_manual() {
  echo "-----------------------------------"
  source token_deployment/.env || { show "Run option (2) first to set .env" error; exit 1; }

  read -rp "Enter contract name (e.g., MyToken): " NAME
  read -rp "Enter the token symbol (e.g., MTK): " SYMBOL
  read -rp "Enter initial supply (human, e.g., 1000000): " HUMAN_SUPPLY

  # default 18 decimals
  SUPPLY_WEI=$(python3 - <<PY
import sys,decimal
decimal.getcontext().prec = 80
human = decimal.Decimal("${HUMAN_SUPPLY or '1000000'}")
wei = int(human * (10 ** 18))
print(wei)
PY
)

  deploy_once "$NAME" "$SYMBOL" "$SUPPLY_WEI"
}

menu() {
  curl -s https://raw.githubusercontent.com/Wawanahayy/JawaPride-all.sh/refs/heads/main/display.sh | bash || true
  sleep 1
  echo -e "\n${YELLOW}┌─────────────────────────────────────────────────────┐${NORMAL}"
  echo -e   "${YELLOW}│              Script Menu Options                    │${NORMAL}"
  echo -e   "${YELLOW}├─────────────────────────────────────────────────────┤${NORMAL}"
  echo -e   "${YELLOW}│ 1) Install dependencies                             │${NORMAL}"
  echo -e   "${YELLOW}│ 2) Input required details                           │${NORMAL}"
  echo -e   "${YELLOW}│ 3) Deploy contract (random)                         │${NORMAL}"
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
    *) show "Invalid choice." error ;;
  esac
}

while true; do menu; done
