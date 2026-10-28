# AI Edition: .deb and .rpm packages "heidisql-ai" from the GTK2 build, installable next to a
# stock HeidiSQL (DECISIONS.md, ADR-010). Needs nfpm (https://nfpm.goreleaser.com) and
# out/gtk2/heidisql (make build-gtk2). The version is AIEDITIONVERSION from source/const.inc.
NFPM ?= nfpm
AIVERSION = $(shell sed -n "s/^ *AIEDITIONVERSION = '\(.*\)';/\1/p" source/const.inc)

.PHONY: packages-ai
packages-ai:
	@echo "=== Creating heidisql-ai $(AIVERSION) packages"
	@test -n "$(AIVERSION)" || { echo "AIEDITIONVERSION not found in source/const.inc"; exit 1; }
	@test -x $(BINGTK) || { echo "$(BINGTK) missing, run make build-gtk2 first"; exit 1; }
	mkdir -p dist
	VERSION=$(AIVERSION) $(NFPM) package --config extra/packaging-ai/nfpm.yaml --packager deb --target dist/
	VERSION=$(AIVERSION) $(NFPM) package --config extra/packaging-ai/nfpm.yaml --packager rpm --target dist/
