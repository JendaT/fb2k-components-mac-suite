#!/bin/bash
#
# clean.sh - Clean foo_jl_plorg build artifacts
#
# Usage:
#   ./Scripts/clean.sh

set -e

# Component configuration
PROJECT_NAME="foo_jl_plorg"

# Load shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/../../../shared/scripts/lib.sh"

# Run clean
do_clean
