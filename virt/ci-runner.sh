#!/bin/bash

set -eu
set -o pipefail

SCRIPT_ROOT="$(dirname "$0")"

if ! command -v mkosi && ! "$SCRIPT_ROOT/setup-mkosi.sh"; then
    echo >&2 "Failed to configure mkosi, can't continue"
    exit 1
fi
