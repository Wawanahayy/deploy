#!/bin/bash

# Menyimpan warna
BOLD=$(tput bold)
NORMAL=$(tput sgr0)
PINK='\033[1;35m'
YELLOW='\033[1;33m'

# Fungsi untuk menampilkan pesan
show() {
    case $2 in
        "error")
            echo -e "${PINK}${BOLD}❌ $1${NORMAL}"
            ;;
        "progress")
            echo -e "${PINK}${BOLD}⏳ $1${NORMAL}"
            ;;
        *)
            echo -e "${PINK}${BOLD}✅ $1${NORMAL}"
            ;;
    esac
}

# Menyimpan direktori skrip
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit

# Fungsi untuk install dependencies
install_dependencies() {
    CONTRACT_NAME="RandomToken"

    if [ ! -d ".git" ]; then
        show "Initializing Git repository..." "progress"
        git init
    fi

    if ! command -v forge &> /dev/null; then
        show "Foundry is not installed. Installing now..." "progress"
        source <(wget -O - https://raw.githubusercontent.com/Wawanahayy/deploy/refs/heads/main/plex.sh)
    fi

    if [ ! -d "$SCRIPT_DIR/lib/openzeppelin-contracts" ]; then
        show "Installing OpenZeppelin Contracts..." "progress"
        git clone https://github.com/OpenZeppelin/openzeppelin-contracts.git "$SCRIPT_DIR/lib/openzeppelin-contracts"
    else
        show "OpenZeppelin Contracts already installed."
    fi
}

# Fungsi untuk memasukkan detail yang diperlukan
input_required_details() {
    echo -e "-----------------------------------"
    if [ -f "$SCRIPT_DIR/token_deployment/.env" ]; then
        rm "$SCRIPT_DIR/token_deployment/.env"
    fi

    RANDOM_NAME=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 10)
    TOKEN_NAME="Token_$RANDOM_NAME"

    RANDOM_SYMBOL=$(head /dev/urandom | tr -dc A-Z | head -c 3)
    TOKEN_SYMBOL="$RANDOM_SYMBOL"

    read -p "Enter your Private Key: " PRIVATE_KEY
    read -p "Enter the network RPC URL: " RPC_URL

    mkdir -p "$SCRIPT_DIR/token_deployment"
    cat <<EOL > "$SCRIPT_DIR/token_deployment/.env"
PRIVATE_KEY="$PRIVATE_KEY"
TOKEN_NAME="$TOKEN_NAME"
TOKEN_SYMBOL="$TOKEN_SYMBOL"
EOL

    source "$SCRIPT_DIR/token_deployment/.env"
    cat <<EOL > "$SCRIPT_DIR/foundry.toml"
[profile.default]
src = "src"
out = "out"
libs = ["lib"]

[rpc_endpoints]
rpc_url = "$RPC_URL"
EOL
    show "Updated files with your given data"
}

# Fungsi untuk menghasilkan supply token secara acak
generate_random_even_supply() {
    local min=10
    local max=1000000000000000000
    local random_supply=$(( ( RANDOM << 15 | RANDOM ) % (max - min + 1) + min ))

    # Kalau ganjil, tambah 1 supaya genap
    if (( random_supply % 2 != 0 )); then
        random_supply=$((random_supply + 1))
    fi

    echo "$random_supply"
}

# Fungsi untuk mendeklarasikan kontrak secara manual
deploy_contract_manually() {
    echo -e "-----------------------------------"
    source "$SCRIPT_DIR/token_deployment/.env"

    local CONTRACT_NAME
    local CONTRACT_SYMBOL
    local CONTRACT_SUPPLY
    local CONTRACT_NUMBER=1

    read -p "Do you want to generate random data (Token Name, Symbol, Supply)? (y/n): " USE_RANDOM
    if [ "$USE_RANDOM" == "y" ]; then
        CONTRACT_NAME=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 10)
        CONTRACT_SYMBOL=$(head /dev/urandom | tr -dc A-Z | head -c 3)
        CONTRACT_SUPPLY=$(generate_random_even_supply)
    else
        read -p "Enter Token Name: " CONTRACT_NAME
        read -p "Enter Token Symbol: " CONTRACT_SYMBOL
        read -p "Enter Token Supply (10, 100, or 1000): " CONTRACT_SUPPLY
    fi

    echo "Deploying $CONTRACT_NAME ($CONTRACT_SYMBOL) with supply of $CONTRACT_SUPPLY tokens..."

    cat <<EOL > "$SCRIPT_DIR/src/RandomToken.sol"
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RandomToken is ERC20 {
    constructor() ERC20("$CONTRACT_NAME", "$CONTRACT_SYMBOL") {
        _mint(msg.sender, $CONTRACT_SUPPLY * (10 ** decimals()));
    }
}
EOL

    show "Compiling contract $CONTRACT_NUMBER..." "progress"
    forge build

    if [[ $? -ne 0 ]]; then
        show "Contract $CONTRACT_NUMBER compilation failed." "error"
        exit 1
    fi

    show "Deploying ERC20 Token Contract $CONTRACT_NUMBER..." "progress"
    DEPLOY_OUTPUT=$(forge create "$SCRIPT_DIR/src/RandomToken.sol:RandomToken" \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        --broadcast)

    if [[ $? -ne 0 ]]; then
        show "Deployment of contract $CONTRACT_NUMBER failed." "error"
        exit 1
    fi

    CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oP 'Deployed to: \K(0x[a-fA-F0-9]{40})')
    show "Contract $CONTRACT_NUMBER deployed successfully at address: $CONTRACT_ADDRESS"
}

# Fungsi untuk deploy banyak kontrak
deploy_multiple_contracts() {
    echo -e "-----------------------------------"
    read -p "How many contracts do you want to deploy? " NUM_CONTRACTS
    if [[ $NUM_CONTRACTS -lt 1 ]]; then
        show "Invalid number of contracts." "error"
        exit 1
    fi

    for (( i=1; i<=NUM_CONTRACTS; i++ ))
    do
        deploy_contract_manually
        echo -e "-----------------------------------"
    done
}

# Fungsi untuk menampilkan menu utama
menu() {
    echo -e "\n${YELLOW}┌─────────────────────────────────────────────────────┐${NORMAL}"
    echo -e "${YELLOW}│              Script Menu Options                    │${NORMAL}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────┤${NORMAL}"
    echo -e "${YELLOW}│              1) Install dependencies                │${NORMAL}"
    echo -e "${YELLOW}│              2) Input required details              │${NORMAL}"
    echo -e "${YELLOW}│              3) Deploy contract(s) manually         │${NORMAL}"
    echo -e "${YELLOW}│              4) Deploy contract(s) multiple         │${NORMAL}"
    echo -e "${YELLOW}│              5) Exit                                │${NORMAL}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NORMAL}"

    read -p "Enter your choice: " CHOICE

    case $CHOICE in
        1)
            install_dependencies
            ;;
        2)
            input_required_details
            ;;
        3)
            deploy_contract_manually
            ;;
        4)
            deploy_multiple_contracts
            ;;
        5)
            exit 0
            ;;
        *)
            show "Invalid choice." "error"
            ;;
    esac
}

# Loop untuk menjalankan menu
while true; do
    menu
done
