#!/bin/zsh
# Downloads the Core ML version of Underdog Bark 3.0 Pro (~1.1 GB) into ./model.
set -e
cd "$(dirname "$0")"
if command -v uvx >/dev/null; then
    HF=(uvx --from huggingface_hub==2.2.0 hf)
else
    python3 -m venv .venv-download
    .venv-download/bin/pip install -q huggingface_hub==2.2.0
    HF=(.venv-download/bin/hf)
fi
$HF download ConwayResearch/Underdog-Bark-3.0-Pro --revision main --local-dir model \
    --include 'coreml/*' --include 'NOTICE'
echo "Model downloaded to $(pwd)/model"
