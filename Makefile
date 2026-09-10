.PHONY: build test app

build:
	swift build -c release

test:
	swift test

# Assemble and codesign Pfeifer.app from the release build.
# Pass OPEN=1 to launch it after building: `make app OPEN=1`.
app: build
	bash scripts/make-app.sh $(if $(OPEN),--open)
