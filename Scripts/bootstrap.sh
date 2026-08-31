#!/bin/bash
# Поднимает проект после клонирования: проверяет инструменты, заводит локальный
# конфиг подписи и генерирует .xcodeproj.
#
#   ./Scripts/bootstrap.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Нет xcodegen. Поставить:"
    echo "    brew install xcodegen"
    exit 1
fi

if [ ! -f Configs/Local.xcconfig ]; then
    cp Configs/Local.xcconfig.example Configs/Local.xcconfig
    echo "Создал Configs/Local.xcconfig из примера."
    echo "Впиши туда DEVELOPMENT_TEAM, иначе на устройство приложение не встанет."
    echo
fi

xcodegen generate

echo
echo "Готово. Дальше:"
echo "    make open     — открыть проект"
echo "    make test     — прогнать тесты"
