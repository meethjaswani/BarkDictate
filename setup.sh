#!/bin/zsh
# One-step setup: checks your Mac, downloads the model, builds and installs BarkDictate.
set -e
cd "$(dirname "$0")"

[[ "$(uname -m)" == "arm64" ]] || { echo "BarkDictate needs an Apple Silicon Mac (M1 or newer)."; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 15 )) || { echo "BarkDictate needs macOS 15 or newer (you have $(sw_vers -productVersion))."; exit 1; }
if ! command -v swift >/dev/null; then
    echo "Installing Apple's Command Line Tools. Re-run ./setup.sh when that finishes."
    xcode-select --install
    exit 1
fi

if [[ -d model/coreml/Encoder.mlpackage ]]; then
    echo "Model already downloaded."
else
    ./download-model.sh
fi
./build.sh
