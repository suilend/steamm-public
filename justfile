#
# `$ just`
#
# Just is a command runner.
# You can download it from https://github.com/casey/just
# Alternatively, you can just read the file and run the commands manually.
#

# By default just list all available commands
[private]
default:
    @just -l

# Commands for Sui contracts
mod sui 'contracts/.just'
