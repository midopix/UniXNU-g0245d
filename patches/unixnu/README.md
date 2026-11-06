# unixnu-src patches

Applied to the `unixnu-src` checkout (upstream `a6314f2`) before building.
These change the UniXNU payload application itself, so they live outside the
uefi overlay repo.

- `0002-portrait-menu-shows-all-entries.patch` — v102
  * `Ui.c`: portrait layout shrinks the UI scale until `VisibleRows >= EntryCount`.
    Navigation wraps over EntryCount while drawing stops at VisibleRows, so on
    this panel Tools (index 3) could be Selected — and even booted by the
    rotate cycle — with no highlight ever shown.
  * `Config.c`: builtin `timeout = 10` → `60` (keypad still unverified; 10 s
    was too short to reach Tools even with the rotate cycle).
