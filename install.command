#!/bin/sh
set -eu
cd "$(dirname "$0")"
/usr/bin/env python3 scripts/install.py
