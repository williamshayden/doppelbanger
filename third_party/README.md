# Pinned plugin dependencies

This directory contains unmodified Git submodules used by the native VST3
build. Their complete, recursive provenance is fixed in
[`../tools/plugin-dependencies.lock.json`](../tools/plugin-dependencies.lock.json).

Initialize an existing checkout with:

```powershell
& 'C:\Program Files\Git\cmd\git.exe' submodule update --init --recursive
```

Do not edit either submodule. Phase 2B may assemble build-tree copies, but it
must never alter these source checkouts.
