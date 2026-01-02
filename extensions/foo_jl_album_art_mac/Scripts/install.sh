#!/bin/bash
#
# install.sh - Install foo_jl_album_art to foobar2000
#
# Usage:
#   ./Scripts/install.sh [OPTIONS]
#
# Options:
#   --config CONFIG  Use specified build configuration (Debug/Release, default: Release)
#   --help           Show this help message

set -e

# Component configuration
PROJECT_NAME="foo_jl_album_art"

# Load shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/../../../shared/scripts/lib.sh"

show_help() {
    head -12 "$0" | tail -8
    exit 0
}

# Parse arguments
if ! parse_install_args "$@"; then
    show_help
fi

# Run install
do_install
