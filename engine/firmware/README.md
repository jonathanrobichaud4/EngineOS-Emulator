# From QEngine
These files come unchanged from [QEngine](https://github.com/Peyton-C/QEngine) (commit 9c2dfd6, MIT, see LICENSE), which runs inMusic's firmware in QEMU.

| File | Use here |
| --- | --- |
| `extract_updater.py` | Takes the update image out of a Windows updater `.exe`, a Mac updater zip or a zipped image, so `setup` accepts those too |
| `extract_az0x_rootfs.py` | Extracts the rootfs from the update image and checks its embedded digest |
| `extract_az01_rootfs.py` | The same for the older "AZ01" container (Prime 4 firmware); taken from a later QEngine commit |

Other ideas taken from QEngine are written into the emulator itself and say so where they are: OpenGL through virgl (`gl_ready` in `engine/lib/host.sh`, `tools/build_mesa_virgl.sh`), the telemetry host list (`block_telemetry`) and starting Engine with `-skipFirmwareUpdate`.
