#!/bin/bash

curl -s https://raw.githubusercontent.com/Wawanahayy/JawaPride-all.sh/refs/heads/main/display.sh | bash
sleep 3

BOLD=$(tput bold)
NORMAL=$(tput sgr0)
PINK='\033[1;35m'
YELLOW='\033[1;33m'

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit

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

input_required_details() {
    echo -e "-----------------------------------"
    if [ -f "$SCRIPT_DIR/token_deployment/.env" ]; then
        rm "$SCRIPT_DIR/token_deployment/.env"
    fi

    # Nama dan simbol token akan acak
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

deploy_contract() {
    echo -e "-----------------------------------"
    source "$SCRIPT_DIR/token_deployment/.env"

    local contract_number=$1

    mkdir -p "$SCRIPT_DIR/src"

    cat <<EOL > "$SCRIPT_DIR/src/RandomToken.sol"
    // SPDX-License-Identifier: MIT
    pragma solidity ^0.8.20;

    import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

    contract RandomToken is ERC20 {
        constructor() ERC20("${RANDOM_NAME}", "${RANDOM_SYMBOL}") {
            _mint(msg.sender, 100000000 * (10 ** decimals()));
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
    DEPLOY_OUTPUT=$(forge create "$SCRIPT_DIR/src/RandomToken.sol:RandomToken" \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        --broadcast)  # Added --broadcast to actually deploy the contract

    if [[ $? -ne 0 ]]; then
        show "Deployment of contract $contract_number failed." "error"
        exit 1
    fi

    CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oP 'Deployed to: \K(0x[a-fA-F0-9]{40})')
    show "Contract $contract_number deployed successfully at address: $CONTRACT_ADDRESS"
}

deploy_contract_manual() {
    echo -e "-----------------------------------"
    
    # Gunakan .env yang sudah ada, tanpa perlu meminta input lagi
    if [ -f "$SCRIPT_DIR/token_deployment/.env" ]; then
        source "$SCRIPT_DIR/token_deployment/.env"
    else
        echo "Environment file (.env) not found. Please input the details first."
        exit 1
    fi
    
    read -p "Enter contract name (e.g., RandomToken): " CONTRACT_NAME
    read -p "Enter the token name: " TOKEN_NAME
    read -p "Enter the token symbol: " TOKEN_SYMBOL
    read -p "Enter the initial supply (e.g., 100000): " INITIAL_SUPPLY

    mkdir -p "$SCRIPT_DIR/src"

    cat <<EOL > "$SCRIPT_DIR/src/$CONTRACT_NAME.sol"
    // SPDX-License-Identifier: MIT
    pragma solidity ^0.8.20;

    import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

    contract $CONTRACT_NAME is ERC20 {
        constructor() ERC20("$TOKEN_NAME", "$TOKEN_SYMBOL") {
            _mint(msg.sender, $INITIAL_SUPPLY * (10 ** decimals()));
        }
    }
EOL

    show "Compiling $CONTRACT_NAME contract..." "progress"
    forge build

    if [[ $? -ne 0 ]]; then
        show "$CONTRACT_NAME contract compilation failed." "error"
        exit 1
    fi

    show "Deploying $CONTRACT_NAME contract..." "progress"
    DEPLOY_OUTPUT=$(forge create "$SCRIPT_DIR/src/$CONTRACT_NAME.sol:$CONTRACT_NAME" \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        --broadcast)

    if [[ $? -ne 0 ]]; then
        show "Deployment of $CONTRACT_NAME contract failed." "error"
        exit 1
    fi

    CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oP 'Deployed to: \K(0x[a-fA-F0-9]{40})')
    show "$CONTRACT_NAME contract deployed successfully at address: $CONTRACT_ADDRESS"
}

deploy_multiple_contracts() {
    echo -e "-----------------------------------"
    read -p "How many contracts do you want to deploy? " NUM_CONTRACTS
    if [[ $NUM_CONTRACTS -lt 1 ]]; then
        show "Invalid number of contracts." "error"
        exit 1
    fi

    for (( i=1; i<=NUM_CONTRACTS; i++ ))
    do
        # Nama dan simbol token dibuat acak setiap kali
        RANDOM_NAME=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 10)
        TOKEN_NAME="Token_$RANDOM_NAME"

        RANDOM_SYMBOL=$(head /dev/urandom | tr -dc A-Z | head -c 3)
        TOKEN_SYMBOL="$RANDOM_SYMBOL"

        # Perbarui file .env untuk menyimpan nama & simbol token yang diacak
        echo "TOKEN_NAME=\"$TOKEN_NAME\"" > "$SCRIPT_DIR/token_deployment/.env"
        echo "TOKEN_SYMBOL=\"$TOKEN_SYMBOL\"" >> "$SCRIPT_DIR/token_deployment/.env"

        source "$SCRIPT_DIR/token_deployment/.env"

        deploy_contract "$i"
        echo -e "-----------------------------------"
    done
}

menu() {
    echo -e "\n${YELLOW}┌─────────────────────────────────────────────────────┐${NORMAL}"
    echo -e "${YELLOW}│              Script Menu Options                    │${NORMAL}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────┤${NORMAL}"
    echo -e "${YELLOW}│              1) Install dependencies                │${NORMAL}"
    echo -e "${YELLOW}│              2) Input required details              │${NORMAL}"
    echo -e "${YELLOW}│              3) Deploy contract(s)                  │${NORMAL}"
    echo -e "${YELLOW}│              4) Deploy contract (manual)            │${NORMAL}"
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
            deploy_multiple_contracts
            ;;
        4)
            deploy_contract_manual
            ;;
        5)
            exit 0
            ;;
        *)
            show "Invalid choice." "error"
            ;;
    esac
}

while true; do
    menu
done
