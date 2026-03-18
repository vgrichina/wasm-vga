#!/bin/bash
# Compile all .wat files to .wasm using wat2wasm (from wabt)
set -e
cd "$(dirname "$0")/demos"
for f in *.wat; do
  name="${f%.wat}"
  echo "Compiling $f -> $name.wasm"
  wat2wasm "$f" -o "$name.wasm"
done
echo "Done. Serve with: python3 -m http.server 8080"
