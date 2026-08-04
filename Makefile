# h/t to @jimhester and @yihui for this parse block:
# https://github.com/yihui/knitr/blob/dc5ead7bcfc0ebd2789fe99c527c7d91afb3de4a/Makefile#L1-L4
# Note the portability change as suggested in the manual:
# https://cran.r-project.org/doc/manuals/r-release/R-exts.html#Writing-portable-packages
PKGNAME := $(shell sed -n 's/Package: *\([^ ]*\)/\1/p' DESCRIPTION)
PKGVERS := $(shell sed -n 's/Version: *\([^ ]*\)/\1/p' DESCRIPTION)
USE_UNSTABLE_C_API ?= 1
RDUCKS_EXTENSION_ABI_TYPE ?= C_STRUCT_UNSTABLE

.PHONY: rd rdm catalog test install check build clean
.PHONY: fuzz fuzz-asan fuzz-ubsan fuzz-clean
.PHONY: prop prop-quick prop-asan prop-ubsan prop-sanitize prop-coverage prop-clean

FUZZ_CC ?= clang
FUZZ_RUNS ?= 100000
FUZZ_MAX_LEN ?= 4096
FUZZ_BUILD_DIR ?= .fuzz
FUZZ_CORPUS := test/fuzz/corpus
FUZZ_DRIVER := test/fuzz/quack_fuzz.c
FUZZ_CORE := src/quack_core.c
FUZZ_HEADERS := src/quack_core.h
FUZZ_LIBSTDCXX_DIR := $(shell dirname "$$(cc -print-file-name=libstdc++.so)")
FUZZ_COMMON_FLAGS := -std=c99 -g -O1 -Wall -Wextra -Werror -fno-omit-frame-pointer -Isrc
FUZZ_ASAN_BIN := $(FUZZ_BUILD_DIR)/quack_fuzz_asan
FUZZ_UBSAN_BIN := $(FUZZ_BUILD_DIR)/quack_fuzz_ubsan

PROP_CC ?= cc
PROP_TRIALS ?= 1000
PROP_QUICK_TRIALS ?= 200
PROP_SEED ?= 0x726475636b735051
PROP_BUILD_DIR ?= .property
PROP_BIN := $(PROP_BUILD_DIR)/rducks_prop
PROP_ASAN_BIN := $(PROP_BUILD_DIR)/rducks_prop_asan
PROP_UBSAN_BIN := $(PROP_BUILD_DIR)/rducks_prop_ubsan
PROP_COV_DIR := $(PROP_BUILD_DIR)/coverage
PROP_COV_OBJ := $(PROP_COV_DIR)/quack_core.o
PROP_COV_BIN := $(PROP_COV_DIR)/rducks_prop
PROP_DRIVER := test/property/rducks_prop.c
PROP_THEFT_SRCS := $(wildcard test/vendor/theft/src/*.c)
PROP_SRCS := $(PROP_DRIVER) $(FUZZ_CORE) $(PROP_THEFT_SRCS)
PROP_HEADERS := $(FUZZ_HEADERS) $(wildcard test/vendor/theft/inc/*.h) $(wildcard test/vendor/theft/src/*.h)
PROP_COMMON_FLAGS := -std=c99 -g -O1 -Wall -Wextra -Wno-unused-function \
	-D_DEFAULT_SOURCE -DTHEFT_USE_FLOATING_POINT=0 \
	-Isrc -Itest/vendor/theft/inc -Itest/vendor/theft/src

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

$(FUZZ_ASAN_BIN): $(FUZZ_DRIVER) $(FUZZ_CORE) $(FUZZ_HEADERS) Makefile
	mkdir -p $(FUZZ_BUILD_DIR)
	$(FUZZ_CC) $(FUZZ_COMMON_FLAGS) -fsanitize=fuzzer,address \
		$(FUZZ_DRIVER) $(FUZZ_CORE) -L$(FUZZ_LIBSTDCXX_DIR) \
		-fsanitize=fuzzer,address -o $@

$(FUZZ_UBSAN_BIN): $(FUZZ_DRIVER) $(FUZZ_CORE) $(FUZZ_HEADERS) Makefile
	mkdir -p $(FUZZ_BUILD_DIR)
	$(FUZZ_CC) $(FUZZ_COMMON_FLAGS) -fsanitize=fuzzer,undefined \
		$(FUZZ_DRIVER) $(FUZZ_CORE) -L$(FUZZ_LIBSTDCXX_DIR) \
		-fsanitize=fuzzer,undefined -o $@

fuzz-asan: $(FUZZ_ASAN_BIN)
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT HUP INT TERM; \
	cp $(FUZZ_CORPUS)/* "$$tmp"/; mkdir "$$tmp/artifacts"; \
	ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
	$(FUZZ_ASAN_BIN) "$$tmp" -dict=test/fuzz/quack.dict \
		-artifact_prefix="$$tmp/artifacts/" -max_len=$(FUZZ_MAX_LEN) \
		-timeout=5 -rss_limit_mb=1024 -runs=$(FUZZ_RUNS)

fuzz-ubsan: $(FUZZ_UBSAN_BIN)
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT HUP INT TERM; \
	cp $(FUZZ_CORPUS)/* "$$tmp"/; mkdir "$$tmp/artifacts"; \
	UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1 \
	$(FUZZ_UBSAN_BIN) "$$tmp" -dict=test/fuzz/quack.dict \
		-artifact_prefix="$$tmp/artifacts/" -max_len=$(FUZZ_MAX_LEN) \
		-timeout=5 -rss_limit_mb=1024 -runs=$(FUZZ_RUNS)

fuzz: fuzz-asan fuzz-ubsan

fuzz-clean:
	rm -rf $(FUZZ_BUILD_DIR)

$(PROP_BIN): $(PROP_SRCS) $(PROP_HEADERS) Makefile
	mkdir -p $(PROP_BUILD_DIR)
	$(PROP_CC) $(PROP_COMMON_FLAGS) $(PROP_CFLAGS_EXTRA) $(PROP_SRCS) \
		$(PROP_LDFLAGS_EXTRA) -o $@

$(PROP_ASAN_BIN): $(PROP_SRCS) $(PROP_HEADERS) Makefile
	mkdir -p $(PROP_BUILD_DIR)
	$(PROP_CC) $(PROP_COMMON_FLAGS) -fsanitize=address -fno-omit-frame-pointer \
		$(PROP_SRCS) -fsanitize=address -o $@

$(PROP_UBSAN_BIN): $(PROP_SRCS) $(PROP_HEADERS) Makefile
	mkdir -p $(PROP_BUILD_DIR)
	$(PROP_CC) $(PROP_COMMON_FLAGS) -fsanitize=undefined -fno-omit-frame-pointer \
		$(PROP_SRCS) -fsanitize=undefined -o $@

prop: $(PROP_BIN)
	RDUCKS_PROP_TRIALS=$(PROP_TRIALS) RDUCKS_PROP_SEED=$(PROP_SEED) $(PROP_BIN)

prop-quick: $(PROP_BIN)
	RDUCKS_PROP_TRIALS=$(PROP_QUICK_TRIALS) RDUCKS_PROP_SEED=$(PROP_SEED) $(PROP_BIN)

prop-asan: $(PROP_ASAN_BIN)
	ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
		RDUCKS_PROP_TRIALS=$(PROP_TRIALS) RDUCKS_PROP_SEED=$(PROP_SEED) \
		$(PROP_ASAN_BIN)

prop-ubsan: $(PROP_UBSAN_BIN)
	UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1:print_stacktrace=1 \
		RDUCKS_PROP_TRIALS=$(PROP_TRIALS) RDUCKS_PROP_SEED=$(PROP_SEED) \
		$(PROP_UBSAN_BIN)

prop-sanitize: prop-asan prop-ubsan

$(PROP_COV_OBJ): $(FUZZ_CORE) $(FUZZ_HEADERS) Makefile
	mkdir -p $(PROP_COV_DIR)
	$(PROP_CC) -std=c99 -g -O0 --coverage -Wall -Wextra -Werror -Isrc \
		-c $(FUZZ_CORE) -o $@

$(PROP_COV_BIN): $(PROP_DRIVER) $(PROP_COV_OBJ) $(PROP_THEFT_SRCS) $(PROP_HEADERS) Makefile
	$(PROP_CC) $(PROP_COMMON_FLAGS) $(PROP_DRIVER) $(PROP_THEFT_SRCS) \
		$(PROP_COV_OBJ) --coverage -o $@

prop-coverage: $(PROP_COV_BIN)
	rm -f $(PROP_COV_DIR)/*.gcda quack_core.c.gcov
	RDUCKS_PROP_TRIALS=$(PROP_TRIALS) RDUCKS_PROP_SEED=$(PROP_SEED) $(PROP_COV_BIN)
	gcov -b -c -o $(PROP_COV_DIR) $(FUZZ_CORE)
	mv quack_core.c.gcov $(PROP_COV_DIR)/

prop-clean:
	rm -rf $(PROP_BUILD_DIR)

clean:
	./cleanup
	rm -rf $(FUZZ_BUILD_DIR) $(PROP_BUILD_DIR)
	rm -rf $(PKGNAME).Rcheck
	rm -f $(PKGNAME)_$(PKGVERS).tar.gz
