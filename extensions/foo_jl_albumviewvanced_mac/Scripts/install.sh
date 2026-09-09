#!/bin/bash
set -e
PROJECT_NAME="foo_jl_albumviewvanced"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/../../../shared/scripts/lib.sh"
parse_install_args "$@"
do_install
