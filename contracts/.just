#
# `$ just sui`
#

# By default just list all available commands
[private]
default:
    @just -l sui

# Fails if sui is not a binary
[private]
_check_sui:
    #!/bin/bash
    if ! command -v sui 2>&1 >/dev/null
    then
        echo "sui binary not found"
        echo "You can download the binary from https://github.com/MystenLabs/sui/releases"
        exit 1
    fi

# Builds all things Sui
build: _check_sui
    sui move build -p steamm

# Tests all things Sui
test: _check_sui
    sui move test -p steamm_scripts --gas-limit 5000000000000
    sui move test -p steamm --gas-limit 5000000000000
