#!/bin/bash
#
# clean.sh - Clean foo_jl_libvanced build artifacts
#

set -e

PROJECT_NAME="foo_jl_libvanced"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/../../../shared/scripts/lib.sh"

do_clean
