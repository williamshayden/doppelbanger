use std::fs;
use std::path::PathBuf;

use serde_json::Value;

#[test]
fn albumdb_manifest_pins_source_license_archives_and_suites() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let manifest: Value =
        serde_json::from_slice(&fs::read(root.join("corpus/albumdb/manifest.json")).unwrap())
            .unwrap();

    assert_eq!(manifest["record_id"], 19_683_001);
    assert_eq!(manifest["doi"], "10.5281/zenodo.19683001");
    assert_eq!(manifest["license"], "CC-BY-4.0");
    assert_eq!(manifest["archives"].as_array().unwrap().len(), 2);
    assert_eq!(manifest["songs"].as_array().unwrap().len(), 10);
    assert_eq!(
        manifest["fast_suite"],
        serde_json::json!(["01", "04", "10"])
    );

    let ignore = fs::read_to_string(root.join(".gitignore")).unwrap();
    assert!(ignore.lines().any(|line| line == "var/"));
    let fetch = fs::read_to_string(root.join("scripts/fetch_albumdb.sh")).unwrap();
    assert!(fetch.contains("md5"));
    assert!(fetch.contains(".part"));
    assert!(fetch.contains("prepare_albumdb"));

    let compose = fs::read_to_string(root.join("docker-compose.yml")).unwrap();
    assert!(compose.contains("postgrest/postgrest:v14.14"));
}
