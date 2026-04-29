PKG := Rducks
USE_UNSTABLE_C_API ?= 1
RDUCKS_EXTENSION_ABI_TYPE ?= C_STRUCT

.PHONY: rd catalog test install check build clean

rd:
	Rscript -e 'roxygen2::roxygenize(load_code = "source")'

catalog:
	Rscript tools/generate_function_catalog.R

test:
	Rscript -e 'tinytest::test_package("$(PKG)")'

install:
	USE_UNSTABLE_C_API=$(USE_UNSTABLE_C_API) \
	RDUCKS_EXTENSION_ABI_TYPE=$(RDUCKS_EXTENSION_ABI_TYPE) \
	R CMD INSTALL --preclean .

build:
	R CMD build .

check: build
	R CMD check $(PKG)_*.tar.gz

clean:
	./cleanup
	rm -rf $(PKG).Rcheck
	rm -f $(PKG)_*.tar.gz
