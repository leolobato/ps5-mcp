.DEFAULT_GOAL := all
PYTHON ?= python3
ENV := bash scripts/with-env.sh
CC_PS5 = "$$PS5_PAYLOAD_SDK/bin/prospero-clang"

.PHONY: FORCE all app install bootstrap remoteplay-deps remoteplay-setup payloads verify test lint check clean
all: payloads verify app

# The macOS hub app (capture card, padd link, local API): app/project.yml (XcodeGen) built with xcodebuild and
# signed ad hoc by default (app/Configuration/Base.xcconfig). Sign with a team through DEVELOPMENT_TEAM=/APP_BUNDLE_ID=
# here or app/Configuration/LocalSigning.xcconfig: a stable signature keeps the macOS permissions across builds.
# Info.plist records this checkout and uv for padd Start/Stop. The version is pyproject.toml's (one for the app and the
# MCP server), the build number is the commit count, and build/padd.elf goes into the app: Start and Update deploy that.
APP := build/PS5 MCP.app
APP_VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml)
APP_BUILD := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
APP_EXECUTABLE := build/PS5\ MCP.app/Contents/MacOS/PS5\ MCP
APP_ARCH ?= $(shell uname -m)
APP_SOURCES := $(wildcard app/*.swift app/*.c app/*.h)
APP_ICON_ASSETS := $(wildcard app/Assets.xcassets/*.json app/Assets.xcassets/AppIcon.appiconset/*)
# The PBS payload is a video source, built in by default. `make app PBS=0` builds without any PBS code or controls.
# local.mk (gitignored) holds this machine's defaults: `PBS ?= 0` there leaves it out unless PBS=1 is given.
-include local.mk
PBS ?= 1
PBS_CONDITION := $(if $(filter 1,$(PBS)),PS5MCP_PBS)
XCODE_OVERRIDES := $(if $(DEVELOPMENT_TEAM),DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM)) $(if $(APP_BUNDLE_ID),APP_BUNDLE_ID=$(APP_BUNDLE_ID))
remoteplay-deps:
	$(PYTHON) scripts/build-remoteplay.py --arch $(APP_ARCH)

remoteplay-setup: build/remoteplay-setup.elf build/remoteplay-admit.elf
build/remoteplay-setup.elf: $(wildcard payload/remoteplay-setup/* third-party/account-tools/src/np_templates/*.h) scripts/build-remoteplay-setup.py toolchain.lock.json | build
	$(PYTHON) scripts/build-remoteplay-setup.py
build/remoteplay-admit.elf: $(wildcard payload/remoteplay-setup/* third-party/account-tools/src/np_templates/*.h) scripts/build-remoteplay-setup.py toolchain.lock.json | build
	$(PYTHON) scripts/build-remoteplay-setup.py --admission

app: $(APP_EXECUTABLE)
# Changes only when PBS= does, so switching rebuilds the app.
build/pbs-flag: FORCE
	@mkdir -p build
	@[ "$$(cat $@ 2>/dev/null)" = "$(PBS)" ] || echo "$(PBS)" > $@
FORCE:

$(APP_EXECUTABLE): build/pbs-flag $(APP_SOURCES) $(APP_ICON_ASSETS) app/Info.plist app/project.yml $(wildcard app/Configuration/*.xcconfig) src/ps5mcp/assets/assign-dialog.png pyproject.toml $(if $(wildcard build/padd.elf),build/toolchain-report.json) Makefile remoteplay-deps build/remoteplay-setup.elf build/remoteplay-admit.elf | build
	rm -rf build/bundle && mkdir -p build/bundle/padd build/bundle/remoteplay
	if [ -f build/padd.elf ] && [ -f build/toolchain-report.json ]; then cp build/padd.elf build/toolchain-report.json build/bundle/padd/; fi
	cp build/remoteplay-setup.elf build/remoteplay-setup-report.json build/bundle/remoteplay/
	cp build/remoteplay-admit.elf build/remoteplay-admit-report.json build/bundle/remoteplay/
	$(PYTHON) scripts/bundle-notices.py
	cd app && xcodegen generate --quiet
	xcodebuild -quiet -project app/PS5.xcodeproj -scheme PS5 -destination "generic/platform=macOS" -configuration Release -derivedDataPath build/DerivedData \
		-allowProvisioningUpdates ARCHS=$(APP_ARCH) PS5MCP_REPO="$(CURDIR)" PS5MCP_UV="$$(command -v uv)" MARKETING_VERSION="$(APP_VERSION)" \
		CURRENT_PROJECT_VERSION="$(APP_BUILD)" SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(PBS_CONDITION)" $(XCODE_OVERRIDES) build
	rm -rf "$(APP)"
	ditto "build/DerivedData/Build/Products/Release/PS5 MCP.app" "$(APP)"

# Waits for its turn on the console, replaces and restarts /Applications/PS5 MCP.app, and removes the copies under build/.
install: app
	uv run python scripts/install-app.py

bootstrap:
	$(PYTHON) scripts/bootstrap.py
	uv sync

payloads: build/padd.elf build/remoteplay-setup.elf build/remoteplay-admit.elf

PADD_SOURCES := payload/padd.c payload/smp.c payload/protocol.h payload/smp.h payload/system.h

build/padd.elf: $(PADD_SOURCES) payload/system_ps5.c toolchain.lock.json scripts/with-env.sh Makefile | build
	$(ENV) bash -c 'exec $(CC_PS5) -std=c11 -Wall -Wextra -Werror -g -O1 -o "$$1" payload/padd.c payload/smp.c payload/system_ps5.c -lSceUserService -lSceSystemService -lSceAppInstUtil' -- $@

# The same daemon logic against a recording stub, for host tests (tests/test_padd_host.py).
build/padd-host: $(PADD_SOURCES) payload/system_host.c Makefile | build
	cc -std=c11 -Wall -Wextra -Werror -g -O1 -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE -o $@ payload/padd.c payload/smp.c payload/system_host.c

build:
	mkdir -p $@

# Records SHA-256 and format of every payload; the deploy runner refuses stale ELFs, so any rebuilt payload rewrites it
# (the app depends on it, not on padd.elf alone, so it never bundles a new ELF next to an old report).
verify: build/toolchain-report.json
build/toolchain-report.json: build/padd.elf build/remoteplay-setup.elf build/remoteplay-admit.elf payload/padd.c scripts/verify.py
	$(ENV) $(PYTHON) scripts/verify.py

test: build/padd-host app
	uv run pytest -q

lint:
	uv run ruff check src tests scripts

check: lint test all

# Nothing here contacts the console. Deploying is always explicit:
#   uv run ps5mcp padd start --host <console IP> --firmware 13.60

clean:
	rm -rf build

# Offline Linux tests: local padd stub and synthetic frames; no Xcode or console.
.PHONY: test-linux check-linux
test-linux: build/padd-host
	uv run pytest -q tests/test_linux.py tests/test_linux_video.py tests/test_linux_pbs.py tests/test_linux_controller.py tests/test_protocol.py tests/test_padd_host.py tests/test_assign.py tests/test_transfer.py tests/test_transfer_server.py

check-linux: lint test-linux
