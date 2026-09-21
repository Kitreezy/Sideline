#!/bin/bash
# Прогон тестов. Симулятор выбирается сам: имена устройств на разных машинах
# разные, а захардкоженное имя даёт невнятное «destination not found».
set -euo pipefail

cd "$(dirname "$0")/.."

UDID="${SIMULATOR_UDID:-$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    if "iOS" not in runtime:
        continue
    for device in devices[runtime]:
        if "iPhone" in device["name"]:
            print(device["udid"])
            sys.exit(0)
sys.exit(1)
' || true)}"

if [ -z "$UDID" ]; then
    echo "Нет ни одного доступного симулятора iPhone."
    echo "Поставить можно через Xcode → Settings → Components."
    exit 1
fi

echo "Симулятор: $(xcrun simctl list devices | grep "$UDID" | sed 's/^ *//')"
xcodebuild test -project TennisForm.xcodeproj -scheme TennisForm \
    -destination "id=$UDID" "$@"
