#!/usr/bin/env bash
set -e

echo "Reinstalling smallcode from local fork..."
npm install
npm install -g .
echo "Done. Run: smallcode --help"
