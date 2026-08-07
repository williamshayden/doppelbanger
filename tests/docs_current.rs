use std::fs;
use std::path::PathBuf;

#[test]
fn readme_documents_the_plugin_product_and_temporary_harness() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let readme = fs::read_to_string(root.join("README.md")).unwrap();

    assert!(readme.contains("VST3 plugin"));
    assert!(readme.contains("no public CLI"));
    assert!(readme.contains("temporary developer and evidence harness"));
    assert!(readme.contains("mastered.report.json"));
    assert!(readme.contains("mastered.plan.json"));
    assert!(!readme.contains("does **not** master audio yet"));
    assert!(!readme.contains("cargo run -- prepare"));
    assert!(!readme.contains("`punch`"));
}

#[test]
fn audition_guide_preserves_the_manual_acceptance_gate() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let guide = fs::read_to_string(root.join("docs/AUDITION.md")).unwrap();

    assert!(guide.contains("01, 04, and 10"));
    assert!(guide.contains("Warp off"));
    assert!(guide.contains("two of three"));
    assert!(guide.contains("severe artifact"));
}

#[test]
fn product_contract_is_plugin_first_and_realtime_safe() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let prd = fs::read_to_string(root.join("docs/PRD.md")).unwrap();
    let architecture = fs::read_to_string(root.join("docs/PLUGIN_ARCHITECTURE.md")).unwrap();

    assert!(prd.contains("VST3"));
    assert!(prd.contains("sole user-facing MVP surface"));
    assert!(architecture.contains("audio callback"));
    assert!(architecture.contains("No heap allocation"));
    assert!(architecture.contains("PostgREST"));
    assert!(architecture.contains("iPlug2"));
    assert!(architecture.contains("Ableton Live"));
}

#[test]
fn react_editor_contract_is_local_thin_and_off_callback() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let architecture = fs::read_to_string(root.join("docs/PLUGIN_ARCHITECTURE.md")).unwrap();
    let decisions = fs::read_to_string(root.join("docs/DECISIONS.md")).unwrap();
    let editor = architecture
        .split_once("## Editor Architecture")
        .and_then(|(_, remainder)| remainder.split_once("## Runtime Topology"))
        .map(|(section, _)| section)
        .expect("editor architecture must remain a dedicated canonical section");

    assert!(editor.contains("`UI NONE`"));
    assert!(editor.contains("`UI WEBVIEW`"));
    assert!(editor.contains("React and TypeScript"));
    assert!(editor.contains("loads no remote page"));
    assert!(editor.contains("| React view |"));
    assert!(editor.contains("audio buffers, service credentials, filesystem paths"));
    assert!(editor.contains("`audition.set_mode`"));
    assert!(editor.contains("must not affect active audio"));
    assert!(architecture.contains("no web technology or JSON enters the audio callback"));
    assert!(architecture.contains("db_processor_set_parameters_v1"));
    assert!(architecture.contains("db_parameter_snapshot_v1"));
    assert!(architecture.contains("precomputed target"));
    assert!(architecture.contains("raw queue count in `0..=5`"));
    assert!(architecture.contains("Raw traversal, storage, and effective work"));
    assert!(architecture.contains("floors the applied output gain toward negative infinity"));
    assert!(architecture.contains("zero-frame parameter flush"));
    assert!(architecture.contains("begins the transition on the next positive-length block"));
    assert!(decisions.contains("## PD-031: The first product editor uses React"));
    assert!(decisions.contains("PLUGIN_ARCHITECTURE.md#editor-architecture"));
}

#[test]
fn contributor_workflow_defines_validation_and_evidence_contracts() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let contributing = fs::read_to_string(root.join("CONTRIBUTING.md")).unwrap();
    let validation = fs::read_to_string(root.join("docs/VALIDATION.md")).unwrap();
    let agent_workflow = fs::read_to_string(root.join("docs/AGENT_WORKFLOW.md")).unwrap();

    assert!(contributing.contains("Tests first"));
    assert!(contributing.contains("400 changed lines"));
    assert!(validation.contains("Tier 0"));
    assert!(validation.contains("AlbumDB"));
    assert!(validation.contains("VST3 Validator"));
    assert!(validation.contains("Ableton Live"));
    assert!(validation.contains("git commit"));
    assert!(agent_workflow.contains("specification and code-quality reviews"));
    assert!(agent_workflow.contains("Hooks are advisory"));
}

#[test]
fn request_lifecycles_and_plugin_reports_are_consistent() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let engineering = fs::read_to_string(root.join("docs/ENGINEERING_SPEC.md")).unwrap();
    let validation = fs::read_to_string(root.join("docs/VALIDATION.md")).unwrap();
    let roadmap = fs::read_to_string(
        root.join("docs/superpowers/specs/2026-08-05-vst3-react-editor-design.md"),
    )
    .unwrap();

    assert!(engineering.contains("plan_only:          queued -> analyzing -> plan_ready"));
    assert!(engineering.contains("plan_ready -- explicit render claim --> rendering -> complete"));
    assert!(validation.contains("explicit idempotent claim with the same plan hash"));
    assert!(validation.contains("reports use the canonical active-plan hash"));
    assert!(roadmap.contains("`report.generate`"));
    assert!(roadmap.contains("`report.export`"));
    assert!(roadmap.contains("`active_plan_hash_v1`"));
    assert!(roadmap.contains("This validation artifact is not the user's DAW export path"));
    assert!(roadmap.contains("stale reports are never presented as current"));
}

#[test]
fn windows_distribution_is_native_and_container_free() {
    let architecture = include_str!("../docs/PLUGIN_ARCHITECTURE.md");
    let workstation = include_str!("../docs/WINDOWS_WORKSTATION.md");
    let decisions = include_str!("../docs/DECISIONS.md");
    let roadmap = include_str!("../docs/superpowers/plans/2026-08-05-windows-headless-vst3.md");
    let companion = markdown_section(
        architecture,
        "## Companion Runtime Packaging",
        "## Thread Ownership",
    );

    for required in [
        "does not require WSL",
        "does not require Docker",
        "does not require developer tooling",
        "native per-user companion",
        "network-disconnected clean Windows",
    ] {
        assert!(
            companion.contains(required),
            "missing companion distribution contract: {required}"
        );
    }
    for required in [
        "native Windows PowerShell",
        "Customers use the product installer",
        "Visual Studio Build Tools, Rust, CMake, and Ninja normally",
        "`doctor` is read-only",
        "`configure` creates the native build files with Ninja",
        "DBDEV_WINDOWS_REQUIRED",
        "DBDEV_WSL_FORBIDDEN",
        "DBDEV_TOOL_MISSING",
        "DBDEV_WRONG_RUST_HOST",
    ] {
        assert!(
            workstation.contains(required),
            "missing native dispatcher contract: {required}"
        );
    }
    let pd031 = decisions
        .find("## PD-031: The first product editor uses React in an iPlug2 WebView")
        .expect("PD-031 must remain present");
    let pd032_heading = "## PD-032: Public Windows distribution is native and container-free";
    let pd032 = decisions
        .find(pd032_heading)
        .expect("PD-032 must be present");
    assert!(pd032 > pd031, "PD-032 must follow PD-031");
    assert_eq!(decisions.matches(pd032_heading).count(), 1);

    let task5 = markdown_section(
        roadmap,
        "## Task 5: Freeze the Milestone 1 runtime contracts in canonical docs",
        "## Task 6: Normalize generated and submitted plans to safe centidecibels",
    );
    assert!(task5.contains("Record decision `PD-033`"));
    assert!(task5.contains("doc assertions for `PD-033`"));
    assert!(!task5.contains("PD-032"));
    let task6 = markdown_section(
        roadmap,
        "## Task 6: Normalize generated and submitted plans to safe centidecibels",
        "## Task 7: Add precomputed 10 ms smoothing and separate-input/output Rust processing",
    );
    assert!(task6.contains("recorded in PD-033"));
    assert!(!task6.contains("PD-032"));

    let task11 = markdown_section(
        roadmap,
        "## Task 11: Build the production UI-NONE VST3 over the Rust processor",
        "## Task 12: Integrate production state with VST3 lifecycle and fixture restore",
    );
    for required in [
        "reusable recursive dependency-closure gate",
        "every native executable and DLL",
        "normal imports",
        "delay-load imports",
        "AMD64 PE provenance",
        "reject toolchain runtime DLLs that should have been statically linked",
        "committed reviewed Windows system-DLL allowlist or contained within the bundle",
        "Reject bundle escape through DLL search",
        "Derive the allowlist from documented Windows platform requirements and reviewed code usage",
        "forbid auto-populating it from the first artifact's observed imports",
        "current bundle is expected to contain only the plugin module",
        "later native companion must reuse this gate",
    ] {
        assert!(
            task11.contains(required),
            "missing Task 11 dependency-closure contract: {required}"
        );
    }
    assert!(!task11.contains("reject static-runtime leakage"));

    let task14 = markdown_section(
        roadmap,
        "## Task 14: Gate the bundle with Steinberg Validator and pluginval 10",
        "## Task 15: Reproduce from a clean clone and complete Ableton's UI-NONE proof",
    );
    let task14_leakage =
        markdown_checklist_item(task14, "same recursive dependency-closure inventory");
    assert!(task14_leakage.contains("same recursive dependency-closure inventory"));
    for category in [
        "WebView", "Node", "Docker", "WSL", "database", "service", "compiler",
    ] {
        assert!(
            task14_leakage.contains(category),
            "Task 14 leakage clause must reject {category}"
        );
    }
    let wrapped_task14 = task14.replace(
        "same recursive dependency-closure inventory",
        "same recursive dependency-closure\n  inventory",
    );
    let wrapped_task14_leakage =
        markdown_checklist_item(&wrapped_task14, "leakage from UI-NONE artifacts");
    assert!(wrapped_task14_leakage.contains("same recursive dependency-closure inventory"));

    let task15 = markdown_section(
        roadmap,
        "## Task 15: Reproduce from a clean clone and complete Ableton's UI-NONE proof",
        "## Task 16: Run final gates and independent reviews",
    );
    let clean_target_gate =
        markdown_checklist_item(task15, "network-disconnected clean Windows 11 x64 VM");
    for required in [
        "network-disconnected clean Windows 11 x64 VM with no WSL, Docker, Rust, Visual Studio, CMake, Ninja, Node, Postgres, or PostgREST",
        "statically linked pinned Steinberg headless host",
        "own reviewed dependency closure",
        "safe DLL search",
        "separate host directory",
        "one-process Windows job",
        "record the OS image",
        "disabled WSL and Virtual Machine Platform features",
        "absence of WSL distributions and container, database, and developer files, services, processes, PATH entries, and installed programs",
        "host and bundle hashes",
        "disconnected-network state",
        "Exercise load, stereo processing, settled bypass, state restore, and unload",
        "continuous image-load and process tracing from before host launch through termination",
        "loaded-module snapshots before load and after initialization, processing, restore, and unload",
        "every runtime-loaded module's canonical path and hash at each phase",
        "process tree",
        "listeners",
        "filesystem changes",
        "statically reject dynamic-loader imports",
        "`LoadLibrary*` and `GetProcAddress` are forbidden",
        "each use is declared in a committed manifest",
        "call-level instrumentation",
        "requested DLL and symbol",
        "resolved canonical module path",
        "Reject any undeclared or uninstrumented dynamic-loader use",
        "unresolved or undeclared module",
        "writable, PATH, or network search location",
        "child process",
        "download",
        "prerequisite installation",
        "prerequisite installation, listener, or unexpected filesystem write",
    ] {
        assert!(
            clean_target_gate.contains(required),
            "missing clean-target tracing contract: {required}"
        );
    }
    let listener_removed_gate = clean_target_gate.replace(
        "prerequisite installation, listener, or unexpected filesystem write",
        "prerequisite installation or unexpected filesystem write",
    );
    assert!(listener_removed_gate.contains("listeners"));
    assert!(
        !listener_removed_gate
            .contains("prerequisite installation, listener, or unexpected filesystem write")
    );
    let wrapped_task15 = task15.replace(
        "statically linked pinned Steinberg headless host",
        "statically linked pinned\n  Steinberg headless host",
    );
    let wrapped_clean_target_gate = markdown_checklist_item(
        &wrapped_task15,
        "network-disconnected clean Windows 11 x64 VM",
    );
    assert!(wrapped_clean_target_gate.contains("statically linked pinned Steinberg headless host"));

    let task16 = markdown_section(
        roadmap,
        "## Task 16: Run final gates and independent reviews",
        "## Milestone 1 Completion Criteria",
    );
    for required in [
        "Rerun the UI-NONE VST3 normal-import, delay-load, runtime-loaded-module, and clean-target gates as final release evidence",
        "their contract is reusable by the later native-companion milestone",
        "do not require or execute companion packaging during the UI-NONE milestone",
    ] {
        assert!(
            task16.contains(required),
            "missing Task 16 final-release contract: {required}"
        );
    }
}

fn markdown_section<'a>(contents: &'a str, heading: &str, next_heading: &str) -> &'a str {
    let start = contents.find(heading).expect("markdown section must exist");
    let end = contents[start + heading.len()..]
        .find(next_heading)
        .map(|offset| start + heading.len() + offset)
        .expect("next markdown section must exist");
    &contents[start..end]
}

fn markdown_checklist_item(section: &str, match_text: &str) -> String {
    let mut starts = Vec::new();
    let mut offset = 0;
    for line in section.split_inclusive('\n') {
        if line.starts_with("- [ ] ") {
            starts.push(offset);
        }
        offset += line.len();
    }

    let mut matching = None;
    for (index, start) in starts.iter().copied().enumerate() {
        let end = starts.get(index + 1).copied().unwrap_or(section.len());
        let item = &section[start..end];
        if item.contains(match_text) {
            assert!(matching.is_none(), "checklist match must be unique");
            matching = Some(normalize_markdown_whitespace(item));
        }
    }
    matching.expect("matching markdown checklist item must exist")
}

fn normalize_markdown_whitespace(contents: &str) -> String {
    contents.split_whitespace().collect::<Vec<_>>().join(" ")
}
