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
