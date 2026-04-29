PKG := Rducks

.PHONY: rd test install check build clean

rd:
	Rscript -e 'roxygen2::roxygenize(load_code = "source")'

test:
	Rscript -e 'tinytest::test_package("$(PKG)")'

install:
	R CMD INSTALL --preclean .

build:
	R CMD build .

check: build
	R CMD check $(PKG)_*.tar.gz

clean:
	rm -f src/*.o src/*.so src/*.dll src/*.dylib
	rm -rf $(PKG).Rcheck
