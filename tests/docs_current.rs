use std::fs;
use std::path::PathBuf;

#[test]
fn readme_documents_the_real_pipeline_without_scaffold_commands() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let readme = fs::read_to_string(root.join("README.md")).unwrap();

    assert!(readme.contains("doppelbanger master"));
    assert!(readme.contains("doppelbanger worker"));
    assert!(readme.contains("doppelbanger benchmark"));
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
