# Upstream forks review

Reviewed on November 1, 2026. The [upstream Swift Hakchi2 repository](https://github.com/mattackerman808/swift-hakchi2) has four public forks, including this project. Commit counts are relative to upstream main at the time of review and will change.

- [coloboxp/swift-hakchi2](https://github.com/coloboxp/swift-hakchi2): 27 commits ahead. Its [recovery service](https://github.com/coloboxp/swift-hakchi2/blob/main/SwiftHakchi/Services/RecoveryService.swift) includes Mega Drive partition handling and NAND/eMMC backup paths. Its [port status](https://github.com/coloboxp/swift-hakchi2/blob/main/docs/PORT_STATUS.md) reports SNES hardware work; it does not establish Genesis hardware validation.
- [jefferysgoffnatur/swift-hakchi2](https://github.com/jefferysgoffnatur/swift-hakchi2): six commits ahead. The author's [upstream pull request](https://github.com/mattackerman808/swift-hakchi2/pull/1) describes fixes for SNES transfer stalls, menu parsing and SFROM conversion, along with the author's testing. Its stated hardware results do not by themselves validate this project or every console.
- [andrewyoo/swift-hakchi2](https://github.com/andrewyoo/swift-hakchi2): no commits ahead of upstream main at review time.

These projects provide useful implementation references, especially for Genesis backup. Their code has not been imported by this review. Check behavior, provenance and applicable licenses before reuse; a repository's visibility or a fork count alone is not evidence of a project-wide license.

## Broader all-in-one opportunities

The Coloboxp [port status](https://github.com/coloboxp/swift-hakchi2/blob/main/docs/PORT_STATUS.md) lists additional reference points: per-game emulator/core selection, other game-system formats, multi-file CD imports, incremental synchronization and console import, save-state import/export, screenshots, module repositories, controller options and folder trees. Its [system catalog](https://github.com/coloboxp/swift-hakchi2/blob/main/SwiftHakchi/Models/SystemCatalog.swift), [menu tree](https://github.com/coloboxp/swift-hakchi2/blob/main/SwiftHakchi/Models/MenuTree.swift), and [console tools](https://github.com/coloboxp/swift-hakchi2/blob/main/SwiftHakchi/Services/ConsoleToolsService.swift) show specific design choices to compare. Its stated hardware coverage is narrower than its feature list; in particular, the review found no Genesis hardware-test claim.

Our app already has staged NES/SNES menu and sync work and a legacy Clovershell connection path. Compare behavior before replacing those paths; Coloboxp describes Clovershell as outside its current transport support. The [Hakchi2 CE project](https://github.com/TeamShinkansen/Hakchi2-CE) remains an upstream reference for console tooling. Optional emulators or modules should be presented as additional components with their own compatibility, recovery and licensing requirements, rather than as automatic support for every game.
