#!/bin/bash
# Прогоняет видео через StrokeKit на маке и печатает разбор.
# Нужен, чтобы крутить пороги по живым видео, не гоняя симулятор.
#
#   ./Tools/analyze.sh ~/Desktop/тренировка.mov [right|left]
set -euo pipefail

cd "$(dirname "$0")/.."
BIN="$(mktemp -d)/analyze"

xcrun swiftc -O -swift-version 6 -parse-as-library \
  Sources/StrokeKit/*.swift Tools/Analyze/main.swift -o "$BIN"

"$BIN" "$@"
