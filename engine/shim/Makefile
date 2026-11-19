# Builds libemushim.so, the library preloaded into Engine (32-bit ARM, hard float).
# Needs an arm-linux-gnueabihf cross compiler and the ALSA headers:
#   sudo apt install gcc-arm-linux-gnueabihf libasound2-dev
# models.h comes from models/*/model.json. libemushim.so stays in git (the deck loads it straight
# from a checkout); SOURCES.sha256 records which sources it was built from, and the tests fail
# when they've changed since (tests/run.sh).
CC = arm-linux-gnueabihf-gcc
CFLAGS = -O2 -Wall -fPIC -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard
MODELS = $(wildcard ../../models/*/model.json)
SRC = emushim.c alsa_emu.c models.h

libemushim.so: $(SRC)
	mkdir -p alsainc && ln -sfn /usr/include/alsa alsainc/alsa
	$(CC) $(CFLAGS) -shared -Ialsainc -o $@ emushim.c alsa_emu.c -ldl -lpthread
	rm -rf alsainc
	sha256sum $(SRC) > SOURCES.sha256

models.h: ../../models/models.py $(MODELS)
	python3 ../../models/models.py header > $@

.PHONY: check
check: models.h
	sha256sum -c --quiet SOURCES.sha256
