# h/t to @jimhester and @yihui for this parse block:
# https://github.com/yihui/knitr/blob/dc5ead7bcfc0ebd2789fe99c527c7d91afb3de4a/Makefile#L1-L4
# Note the portability change as suggested in the manual:
# https://cran.r-project.org/doc/manuals/r-release/R-exts.html#Writing-portable-packages
PKGNAME := $(shell sed -n 's/Package: *\([^ ]*\)/\1/p' DESCRIPTION)
PKGVERS := $(shell sed -n 's/Version: *\([^ ]*\)/\1/p' DESCRIPTION)
USE_UNSTABLE_C_API ?= 1
RDUCKS_EXTENSION_ABI_TYPE ?= C_STRUCT_UNSTABLE

.PHONY: rd rdm catalog test install check build clean

rd:
	Rscript -e 'roxygen2::roxygenize(load_code = "source")'

catalog:
	Rscript tools/generate_function_catalog.R

test: build
	@tmpdir=$$(mktemp -d); \
	USE_UNSTABLE_C_API=$(USE_UNSTABLE_C_API) \
	RDUCKS_EXTENSION_ABI_TYPE=$(RDUCKS_EXTENSION_ABI_TYPE) \
	R_LIBS_USER="$$tmpdir" \
	R CMD INSTALL $(PKGNAME)_$(PKGVERS).tar.gz; \
	res=$$?; \
	if [ $$res -ne 0 ]; then rm -rf "$$tmpdir"; exit $$res; fi; \
	R_LIBS_USER="$$tmpdir" RDUCKS_DEV_SURFACES=true \
	Rscript -e 'tinytest::test_package("$(PKGNAME)", testdir = "inst/tinytest")'; \
	res=$$?; \
	rm -rf "$$tmpdir"; \
	exit $$res

install: build
	USE_UNSTABLE_C_API=$(USE_UNSTABLE_C_API) \
	RDUCKS_EXTENSION_ABI_TYPE=$(RDUCKS_EXTENSION_ABI_TYPE) \
	R CMD INSTALL $(PKGNAME)_$(PKGVERS).tar.gz

build: rd catalog
	R CMD build .

check: build
	RDUCKS_DEV_SURFACES=true R CMD check $(PKGNAME)_$(PKGVERS).tar.gz

rdm: install
	Rscript -e 'rmarkdown::render("README.Rmd", output_format = rmarkdown::github_document(), quiet = TRUE)'
	rm -f README.html

clean:
	./cleanup
	rm -rf $(PKGNAME).Rcheck
	rm -f $(PKGNAME)_$(PKGVERS).tar.gz
