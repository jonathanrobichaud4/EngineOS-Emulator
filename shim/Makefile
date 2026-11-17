# Builds libemushim.so for the SC LIVE 4 (32-bit ARM, hard float).
# Needs an arm-linux-gnueabihf cross compiler and the ALSA headers:
#   sudo apt install gcc-arm-linux-gnueabihf libasound2-dev
CC = arm-linux-gnueabihf-gcc
CFLAGS = -O2 -Wall -fPIC -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard

libemushim.so: emushim.c alsa_emu.c
	mkdir -p alsainc && ln -sfn /usr/include/alsa alsainc/alsa
	$(CC) $(CFLAGS) -shared -Ialsainc -o $@ emushim.c alsa_emu.c -ldl -lpthread
	rm -rf alsainc
