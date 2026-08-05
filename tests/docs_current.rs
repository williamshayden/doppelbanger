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
