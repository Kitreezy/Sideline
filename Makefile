# Проект генерируется из project.yml, поэтому .xcodeproj в гите нет.
# После клонирования: make bootstrap

PROJECT := TennisForm.xcodeproj
SCHEME := TennisForm

.PHONY: bootstrap generate open test build clean help

help:
	@echo "bootstrap — поставить локальный конфиг и сгенерировать проект"
	@echo "generate  — пересобрать .xcodeproj из project.yml"
	@echo "open      — открыть проект в Xcode"
	@echo "test      — прогнать тесты на симуляторе (SIMULATOR_UDID=... чтобы выбрать свой)"
	@echo "build     — собрать под устройство"
	@echo "clean     — снести сгенерированный проект и сборку"
	@echo
	@echo "Разбор видео с мака: ./Tools/analyze.sh <видео> [right|left]"

bootstrap:
	@./Scripts/bootstrap.sh

generate: $(PROJECT)

# Проект пересобирается сам, если project.yml новее — иначе легко забыть
# и потом долго смотреть на «отсутствующий» только что добавленный файл.
$(PROJECT): project.yml
	@xcodegen generate

open: generate
	@open $(PROJECT)

test: generate
	@./Scripts/test.sh -quiet

build: generate
	@xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS' -quiet

clean:
	@rm -rf $(PROJECT) build
	@echo "Снесено. Вернуть: make generate"
