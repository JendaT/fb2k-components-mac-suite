#!/bin/bash
set -e
PROJECT_NAME="foo_jl_playvanced"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/../../../shared/scripts/lib.sh"

if ! parse_install_args "$@"; then
    echo "Usage: ./Scripts/install.sh [--config Debug|Release]"
    exit 0
fi

do_install
