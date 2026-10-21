# Builds priv/egtm_worker.so -- invoked by rebar3 pre_hooks.
#
# YottaDB location: EGTM_DIST, or whatever pkg-config reports
# (the same lookup as priv/gtmenv).

EGTM_DIST ?= $(shell pkg-config --variable=prefix yottadb 2>/dev/null)
ifeq ($(EGTM_DIST),)
EGTM_DIST := /usr/local/lib/yottadb/current
endif

ERTS_INCLUDE := $(shell erl -noshell -eval \
  'io:format("~ts/erts-~ts/include", [code:root_dir(), erlang:system_info(version)]), halt().')

PRIV   := ../priv
TARGET := $(PRIV)/egtm_worker.so

CFLAGS  ?= -O2 -Wall
CFLAGS  += -fPIC -I$(ERTS_INCLUDE) -I$(EGTM_DIST)
LDFLAGS += -shared -L$(EGTM_DIST) -Wl,-rpath -Wl,$(EGTM_DIST)
LDLIBS  += -lgtmshr -lc

all: $(TARGET)

$(TARGET): egtm_worker.c
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ egtm_worker.c $(LDLIBS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
