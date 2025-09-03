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

# Sets git versioning for the package
bump-mvr version *FLAGS: _check_sui
    sui client ptb \
      --move-call 0xc88768f8b26581a8ee1bf71e6a6ec0f93d4cc6460ebb66a31b94d64de8105c98::git::new '"https://github.com/suilend/steamm-public.git"' '"contracts/steamm"' "\"$(git rev-parse HEAD)\"" \
      --assign git_obj \
      --move-call 0xc88768f8b26581a8ee1bf71e6a6ec0f93d4cc6460ebb66a31b94d64de8105c98::package_info::set_git_versioning @0xd49b8790a7e6f5c89527f06d4ed075c8f49823021e3a35577f6076ded14ee460 {{version}} git_obj \
      --gas-budget 10000000 \
      {{FLAGS}}


