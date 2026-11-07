# SNES save-profile switch research

These are developer-only fixtures for the unfinished replacement-console save
transfer. They do not install a helper, connect a console or authorize a write.
Backup History offers an experimental, separately confirmed transfer flow;
these fixtures themselves do not authorize or perform a hardware write.

The pinned SNES BusyBox does not implement `mv -T`. `profile_switch.c` instead
uses a fixed-path Linux `renameat` operation, checks the stage and destination
directory identities, refuses a nonempty destination, and synchronizes both
parent directories. It does not establish exclusive ownership against other
root processes; the surrounding workflow must provide that separately.

The developer helper also accepts an unused `suspendpoint1` through
`suspendpoint4` inside a verified existing game profile. It checks the profile
identity as well as the empty slot reservation and never replaces the enclosing
profile. A reviewed publication request and durable intent can now be prepared
for this mode. A stripped, path-free helper is bundled for read-only
preparation. A separately prepared delivery request checks the temporary runtime
filesystem and never overwrites a different helper. A native session can dispatch
that request and the recorded publication request with separate single-use
approval permits after separate user confirmations. Neither path has been tested
on a physical console.

Build into a new empty developer output directory with Zig 0.17.0:

```sh
sh tools/snes-save-publication/build_profile_switch.sh OUTPUT_DIRECTORY /path/to/zig
```

The build record binds the output and source hashes and explicitly marks the
helper as not hardware tested and not authorized for console writes. The
verified stripped helper is also included as an app resource.

`test_busybox_arm.py` checks the pinned BusyBox's actual command behavior in an
isolated, diskless, networkless ARM guest. `test_profile_switch_arm.py` runs the
built helper there, including changed identities, nonempty destinations and
symbolic links. `test_generated_publication_arm.py` runs an actual generated
command with synthetic saves. `test_helper_delivery_arm.py` exercises the helper
delivery, and `test_helper_then_publication_arm.py` runs both generated commands
in sequence. The optional test fixture exports create those synthetic inputs.
Each script accepts explicit `--kernel`, `--busybox`, `--qemu` and `--output`
arguments; run it with `--help` for its helper and fixture arguments. They
require the pinned generic Debian ARM kernel and BusyBox hashes checked in the
scripts.

The guest uses Linux 6.1 and RAM-backed storage, not the SNES's Linux 3.4
kernel or ext4 storage. The generated-command test substitutes console
identity, mount and game-process checks. Passing it does not prove power-loss
durability, rule out concurrent target changes, authorize a console write or
show that the saved game loads on a replacement console.
