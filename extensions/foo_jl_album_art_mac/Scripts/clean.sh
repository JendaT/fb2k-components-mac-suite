#!/bin/bash
#
# clean.sh - Clean build artifacts
#

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "Cleaning build directory..."
rm -rf build/

echo "Clean complete."
