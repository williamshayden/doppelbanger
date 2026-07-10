use std::fs;
use std::path::PathBuf;

#[test]
fn schema_models_request_roles_plans_artifacts_and_atomic_claiming() {
    let schema = fs::read_to_string(schema_path()).unwrap();
    let tracks = table_body(&schema, "api.tracks");

    assert!(
        !tracks.contains("role text"),
        "roles belong to requests, not tracks"
    );
    assert!(schema.contains("parent_request_id uuid"));
    assert!(schema.contains("submitted_plan jsonb"));
    assert!(schema.contains("create table if not exists api.mastering_plans"));
    assert!(schema.contains("create table if not exists api.render_artifacts"));
    assert!(schema.contains("create or replace function api.submit_mastering_request"));
    assert!(schema.contains("create or replace function api.claim_mastering_request"));
    assert!(schema.contains("for update skip locked"));
    assert!(schema.contains("'queued', 'analyzing', 'ready', 'rendering', 'complete', 'failed'"));
}

#[test]
fn anonymous_api_role_has_only_the_required_local_state_permissions() {
    let schema = fs::read_to_string(schema_path()).unwrap();

    assert!(schema.contains("grant select on api.tracks to web_anon"));
    assert!(schema.contains("grant select, update on api.mastering_requests to web_anon"));
    assert!(schema.contains("grant insert, select on api.analysis_results to web_anon"));
    assert!(schema.contains("grant insert, select on api.mastering_plans to web_anon"));
    assert!(schema.contains("grant insert, select on api.render_artifacts to web_anon"));
    assert!(!schema.contains("delete on all tables"));
}

fn schema_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("db/init/001_schema.sql")
}

fn table_body<'a>(schema: &'a str, name: &str) -> &'a str {
    let start = schema
        .find(&format!("create table if not exists {name}"))
        .unwrap();
    let remainder = &schema[start..];
    let end = remainder.find(");").unwrap();
    &remainder[..end]
}
