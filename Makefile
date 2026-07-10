# Builds the native macOS window shim (c_src/ap_mac_window.m → priv/ap_mac_window.so).
# Invoked by elixir_make, which is added to `compilers` ONLY on macOS desktop
# (see mix.exs) — so on Linux/cloud/CI this Makefile is never run. It also guards
# itself on uname, so a manual `make` off-Darwin is a harmless no-op.

PRIV = priv
NIF  = $(PRIV)/ap_mac_window.so
SRC  = c_src/ap_mac_window.m

# elixir_make exports ERTS_INCLUDE_DIR; fall back to computing it for a bare `make`.
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~ts", [filename:join([code:root_dir(), lists:concat(["erts-", erlang:system_info(version)]), "include"])])' -s init stop)

UNAME := $(shell uname)

ifeq ($(UNAME),Darwin)
all: $(NIF)

$(NIF): $(SRC)
	@mkdir -p $(PRIV)
	clang -O2 -fobjc-arc -dynamiclib -undefined dynamic_lookup \
	  -I"$(ERTS_INCLUDE_DIR)" -framework Cocoa -framework WebKit -framework AVFoundation \
	  $(SRC) -o $(NIF)
else
all:
	@true
endif

clean:
	rm -f $(NIF)

.PHONY: all clean
