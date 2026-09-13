.PHONY: build test app cert clean

build:
	swift build -c release

test:
	swift test

# Assemble and codesign Pfeifer.app from the release build.
# Pass OPEN=1 to launch it after building: `make app OPEN=1`.
app: build
	bash scripts/make-app.sh $(if $(OPEN),--open)

# One-time: create and import the "Pfeifer Development" signing identity
# so Accessibility grants survive rebuilds (see scripts/make-app.sh).
cert:
	bash scripts/make-cert.sh

# Delete regenerables (SwiftPM .build dirs, .DS_Store). Flags: --dry-run,
# --app (also Pfeifer.app), --models (asks first), --global (SwiftPM cache).
clean:
	bash scripts/clean.sh
