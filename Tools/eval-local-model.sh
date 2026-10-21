#!/bin/zsh
# Downloads MobileCLIP-S0 (once) and scores it on DevFixtures/shots.
# Usage: Tools/eval-local-model.sh [text_weight]
set -euo pipefail
root=${0:A:h:h}
cache=${XDG_CACHE_HOME:-$HOME/.cache}/shotsort-models
mkdir -p $cache
base=https://huggingface.co/apple/coreml-mobileclip/resolve/main
for m in mobileclip_s0_image mobileclip_s0_text; do
  if [[ ! -d $cache/$m.mlmodelc ]]; then
    for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
      mkdir -p $cache/$m.mlpackage/${f:h}
      curl -sfL -o $cache/$m.mlpackage/$f $base/$m.mlpackage/$f
    done
    xcrun coremlcompiler compile $cache/$m.mlpackage $cache >/dev/null
  fi
done
bin=$cache/clip-eval
swiftc -O -o $bin $root/Tools/ClipEval/main.swift $root/ScreenshotOrganizer/LocalModel/*.swift
$bin $cache $root/DevFixtures/shots $root/ScreenshotOrganizer/Resources ${1:-0.3}
