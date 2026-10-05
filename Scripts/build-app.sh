#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
xcodegen generate
xcodebuild \
  -project Murmur.xcodeproj \
  -scheme Murmur \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  "$@" build

print "Built: $PWD/build/DerivedData/Build/Products/Debug/Murmur.app"
