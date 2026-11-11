# Experimental SNES console launcher

This directory contains the in-progress console entry, gameplay owner, and
save-recovery implementation, together with portable host tests. It is shared
so contributors can inspect and continue the work. It is not installed by the
app, and normal compatibility-game sync is not implemented yet. In particular,
the target `--game` entry currently refuses gameplay; the host runner is only
a fixture. Do not install or run these files on a console as a finished feature.

The temporary SNES trials demonstrated gameplay, RESET, power-off, and a
RAM-only save/reload on one console. They did not establish persistent saves
across power loss, safe interrupted recovery, suspend points, or ordinary app
sync. The experimental runtime also refuses another launch when a prior
session workspace remains, until completion and recovery can be distinguished.

On macOS with Xcode command-line tools, run these tests from this directory:

```sh
sh check-console-entry-integration.sh
sh check-stock-gameplay.sh
sh check-stock-gameplay-transition.sh
sh check-stock-gameplay-image-order.sh
```

These use generated fixture data and host stubs; they do not connect to a
console or establish target-device behavior. The source references shared
components in the parent directory and the repository's vendored Mbed TLS.
The optional `check-real-entry-frontend.py` exercises the app-generated menu,
session owner and a separately built Mac frontend and core with a generated
test cartridge. Set `HC_HOST_FRONTEND` to the host RetroArch executable,
`HC_HOST_CORE` to the host Snes9x 2010 library, and `HC_LIBRETRO_INCLUDE` to
the matching source tree's libretro include directory. For example, after
setting those variables, run:

```sh
python3 check-real-entry-frontend.py --runtime-lock-manager-gameplay
python3 check-real-entry-frontend.py --manager-prepare-crash
python3 check-real-entry-frontend.py --manager-save-crash-before
python3 check-real-entry-frontend.py --manager-save-crash-after
```

These modes use generated cartridge and save data in disposable temporary
folders. They do not use a game library or contact a console. They require a
working Swift test build as well as the host frontend and core. Host results
do not prove that the console executable or persistent power-loss recovery
works on a real device.
