# Contributing

This is an experimental macOS console-management project. Please read the status and build instructions in [README.md](README.md) and the publication notes in [THIRD_PARTY.md](THIRD_PARTY.md) before contributing.

Use synthetic game data and temporary workspaces in automated tests. Never commit game ROMs, console dumps, saves, personal backups, private keys, or device identifiers. A successful simulator or host test does not establish behavior on a physical console; describe any hardware model, software state, test scope and observed result without sharing private identifiers.

Run `swift build` and `swift test` for the changes you make. Console writes and firmware changes need clear review and recovery procedures. Keep unsupported hardware operations disabled until they are actually verified.
