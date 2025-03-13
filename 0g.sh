#!/bin/bash

curl -s https://raw.githubusercontent.com/Wawanahayy/JawaPride-all.sh/refs/heads/main/display.sh | bash
sleep 3

BOLD=$(tput bold)
NORMAL=$(tput sgr0)
PINK='\033[1;35m'
YELLOW='\033[1;33m'

show() {
    case $2 in
        "error") echo -e "${PINK}${BOLD}❌ $1${NORMAL}" ;;
        "progress") echo -e "${PINK}${BOLD}⏳ $1${NORMAL}" ;;
        *) echo -e "${PINK}${BOLD}✅ $1${NORMAL}" ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$SCRIPT_DIR" ]; then
    show "Failed to determine script directory." "error"
    exit 1
fi
mkdir -p "$SCRIPT_DIR/src"

install_dependencies() {
    CONTRACT_NAME="JawaPride"

    if [ ! -d ".git" ]; then
        show "Initializing Git repository..." "progress"
        git init
    fi

    if ! command -v forge &>/dev/null; then
        show "Foundry is not installed. Installing now..." "progress"
        curl -L https://foundry.paradigm.xyz | bash
        source ~/.bashrc
        foundryup
    fi

    if ! command -v forge &>/dev/null; then
        show "Forge installation failed. Please restart terminal or run 'source ~/.bashrc' manually." "error"
        exit 1
    fi

    if [ ! -d "$SCRIPT_DIR/lib/openzeppelin-contracts" ]; then
        show "Installing OpenZeppelin Contracts..." "progress"
        git clone https://github.com/OpenZeppelin/openzeppelin-contracts.git "$SCRIPT_DIR/lib/openzeppelin-contracts"
    else
        show "OpenZeppelin Contracts already installed."
    fi
}

input_required_details() {
    echo -e "-----------------------------------"
    [ -f "$SCRIPT_DIR/token_deployment/.env" ] && rm "$SCRIPT_DIR/token_deployment/.env"

    read -s -p "Enter your Private Key: " PRIVATE_KEY
    echo ""
    read -p "Enter the token name (e.g., JawaPride Token): " TOKEN_NAME
    read -p "Enter the token symbol (e.g., JPR): " TOKEN_SYMBOL
    read -p "Enter the network RPC URL: " RPC_URL

    mkdir -p "$SCRIPT_DIR/token_deployment"
    cat <<EOL > "$SCRIPT_DIR/token_deployment/.env"
PRIVATE_KEY="$PRIVATE_KEY"
TOKEN_NAME="$TOKEN_NAME"
TOKEN_SYMBOL="$TOKEN_SYMBOL"
RPC_URL="$RPC_URL"
EOL

    source "$SCRIPT_DIR/token_deployment/.env"
    cat <<EOL > "$SCRIPT_DIR/foundry.toml"
[profile.default]
solc_version = "0.8.19"
src = "src"
out = "out"
libs = ["lib"]

[rpc_endpoints]
rpc_url = "$RPC_URL"
EOL
    show "Updated files with your given data"
}

deploy_contract() {
    echo -e "-----------------------------------"
    source "$SCRIPT_DIR/token_deployment/.env"

    if ! command -v forge &>/dev/null; then
        show "Forge is not installed. Cannot proceed with deployment." "error"
        exit 1
    fi

    local contract_number=$1

    cat <<EOL > "$SCRIPT_DIR/src/JawaPride.sol"
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract JawaPride is ERC20 {
    constructor() ERC20("$TOKEN_NAME", "$TOKEN_SYMBOL") {
        _mint(msg.sender, 100000 * (10 ** decimals()));
    }
}
EOL

    show "Compiling contract $contract_number..." "progress"
    forge build
    if [[ $? -ne 0 ]]; then
        show "Contract $contract_number compilation failed." "error"
        exit 1
    fi

    show "Deploying ERC20 Token Contract $contract_number..." "progress"
    DEPLOY_OUTPUT=$(forge create "$SCRIPT_DIR/src/JawaPride.sol:JawaPride" \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY")

    if [[ $? -ne 0 ]]; then
        show "Deployment of contract $contract_number failed." "error"
        exit 1
    fi

    CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oP 'Deployed to: \K(0x[a-fA-F0-9]{40})')
    show "Contract $contract_number deployed successfully at address: $CONTRACT_ADDRESS"
    echo "Transaction Details:"
    echo "$DEPLOY_OUTPUT"
}

deploy_multiple_contracts() {
    echo -e "-----------------------------------"
    read -p "How many contracts do you want to deploy? " NUM_CONTRACTS
    [[ $NUM_CONTRACTS -lt 1 ]] && show "Invalid number of contracts." "error" && exit 1

    ORIGINAL_TOKEN_NAME=$TOKEN_NAME
    for (( i=1; i<=NUM_CONTRACTS; i++ ))
    do
        TOKEN_NAME=$([[ $i -gt 1 ]] && echo "$(head /dev/urandom | tr -dc A-Z | head -c 2)$ORIGINAL_TOKEN_NAME" || echo "$ORIGINAL_TOKEN_NAME")
        deploy_contract "$i"
        echo -e "-----------------------------------"
    done
}

while true; do
    menu
done
