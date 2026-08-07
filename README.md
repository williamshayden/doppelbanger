# doppelbanger

## Windows x64 VST3 foundation

doppelbanger currently has a native, headless Windows x64 VST3 foundation. The
VST3 plugin uses the shared Rust DSP core, exposes the Task 4 state and automation
surface, advertises Goblin City Records as its vendor/distributor, and is built
and checked entirely from native Windows tooling. Its exact unsigned bundle is:

```text
build\windows-msvc-x64-release\artefacts\Release\VST3\Doppelbanger.vst3
```

This is a developer foundation, not a finished customer release. It has no
custom editor or installer yet. macOS is not a V1 promise. Once packaging
exists, end users will not need WSL or developer toolchains.

## Native Windows development

Use an x64 Visual Studio developer PowerShell from the repository root. Do not
run the dispatcher from WSL; it deliberately fails closed when its process
ancestry includes WSL. Developers install Visual Studio Build Tools, Rust,
CMake, and Ninja through their normal Windows installers.

```powershell
.\scripts\dev.ps1 -Task doctor
.\scripts\dev.ps1 -Task format
.\scripts\dev.ps1 -Task test
.\scripts\dev.ps1 -Task configure
.\scripts\dev.ps1 -Task build
.\scripts\dev.ps1 -Task validate
```

`configure` uses the committed `windows-msvc-x64-release` preset and configures
the pinned Steinberg SDK validator separately in
`build\windows-vst3-validator`. `build` builds the product, native tests, and
only the validator target, then runs the CTest preset. `validate` invokes the
Steinberg validator directly against the exact Release bundle with a bounded
timeout.

Validation evidence is ignored under:

```text
var\validation\native-foundation\
```

It includes separate validator stdout and stderr files plus a JSON result with
the exact validator and bundle paths, timestamps, timeout, exit code, and
outcome. The automation never installs or copies the plug-in to a system VST3
directory.

## Current scope

The native foundation covers the VST3 bundle, Rust/C/C++ contracts, CTest, and
the official Steinberg validator. It does not yet claim an Ableton smoke test,
pluginval, a UI, a limiter, long realtime stress evidence, an installer, or a
complete analysis workflow. The separate authorized Ableton milestone is still
required before Task 5 is complete.

## Separate analysis-development context

The repository also contains local-first analysis, plan generation, offline
rendering, and benchmark work. Postgres and PostgREST belong only to that
separate analysis-development context; neither is a Doppelbanger VST3 runtime
dependency. The plug-in restores its effective processing state from the DAW
project without requiring a service, database, filesystem access, or an
allocation in the audio callback.

There is no public CLI. The current source binary remains a temporary developer and evidence harness for analysis-development work; it can produce
`mastered.report.json` and `mastered.plan.json`, but those files are not
installed product interfaces or VST3 runtime requirements.

For that analysis-development workflow only, start Postgres/PostgREST and the
native worker in separate terminals:

```bash
docker compose up -d --wait
cargo run --bin doppelbanger -- worker
```

Submit an offline render from another terminal:

```bash
cargo run --bin doppelbanger -- master \
  --reference /absolute/path/reference.wav \
  --target /absolute/path/premaster.wav \
  --output /absolute/path/mastered.wav
```

Prepare AlbumDB and run the fast three-pair benchmark with:

```bash
./scripts/fetch_albumdb.sh
cargo run --release --bin doppelbanger -- benchmark \
  --corpus var/albumdb/pairs \
  --output var/validation/albumdb-fast.json
```

Add `--full` for all ten AlbumDB pairs. Ordinary analysis-development checks
remain:

```bash
cargo fmt --all -- --check
cargo test
cargo clippy --all-targets -- -D warnings
docker compose config
```

The shared processor currently provides bounded low/mid/high EQ and output
gain. A fixed-latency true-peak safety limiter, custom editor, capture queue,
and packaged distribution are later milestones, not capabilities of this
foundation.

## Validation and licensing

The current validation boundary and later release gates are documented in
[docs/VALIDATION.md](docs/VALIDATION.md). Product and engineering context is in
[docs/PRD.md](docs/PRD.md), [docs/ENGINEERING_SPEC.md](docs/ENGINEERING_SPEC.md),
and [docs/PLUGIN_ARCHITECTURE.md](docs/PLUGIN_ARCHITECTURE.md).

MIT. AlbumDB is separately licensed CC BY 4.0 and is never redistributed from
this repository. Plug-in framework and SDK dependencies retain their required
notices.
