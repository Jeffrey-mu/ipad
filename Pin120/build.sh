#!/bin/bash
set -e
cd "$(dirname "$0")"
export THEOS="${THEOS:-$HOME/theos}"
export PATH="$HOME/bin/shim:$PATH"
make package FINALPACKAGE=1 "$@"
