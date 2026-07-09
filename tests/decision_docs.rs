use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

const REQUIRED_FIELDS: [&str; 9] = [
    "Status",
    "Date",
    "Area",
    "Decision",
    "Rationale",
    "Source",
    "Consequences",
    "Revisit trigger",
    "GitHub",
];

#[test]
fn decision_ledger_is_complete_and_machine_checkable() {
    let ledger = fs::read_to_string("docs/DECISIONS.md").expect("docs/DECISIONS.md must exist");
    let records = parse_records(&ledger);
    let expected: BTreeSet<String> = (1..=25).map(|id| format!("PD-{id:03}")).collect();
    let actual: BTreeSet<String> = records.keys().cloned().collect();

    assert_eq!(
        actual, expected,
        "seeded product decisions changed unexpectedly"
    );

    for (id, fields) in &records {
        for required in REQUIRED_FIELDS {
            assert!(
                fields.get(required).is_some_and(|value| !value.is_empty()),
                "{id} is missing required field {required}"
            );
        }

        let status = fields["Status"].trim_matches('`');
        assert!(
            matches!(
                status,
                "proposed" | "accepted" | "deferred" | "rejected" | "superseded"
            ),
            "{id} has invalid status {status}"
        );

        if status == "deferred" {
            assert_ne!(
                fields["Revisit trigger"].to_ascii_lowercase(),
                "none",
                "{id} is deferred without a revisit trigger"
            );
        }

        if status == "superseded" {
            let replacement = fields
                .get("Superseded by")
                .expect("superseded decisions must name their replacement");
            assert!(
                records.contains_key(replacement),
                "{id} points to missing {replacement}"
            );
        }
    }
}

#[test]
fn github_templates_require_actionable_and_safe_public_reports() {
    for path in [
        ".github/ISSUE_TEMPLATE/bug.yml",
        ".github/ISSUE_TEMPLATE/proposal.yml",
        ".github/ISSUE_TEMPLATE/config.yml",
        ".github/pull_request_template.md",
    ] {
        assert!(Path::new(path).is_file(), "missing {path}");
    }

    let bug = fs::read_to_string(".github/ISSUE_TEMPLATE/bug.yml").unwrap();
    let proposal = fs::read_to_string(".github/ISSUE_TEMPLATE/proposal.yml").unwrap();
    let pull_request = fs::read_to_string(".github/pull_request_template.md").unwrap();

    for contents in [&bug, &proposal, &pull_request] {
        assert!(contents.contains("proprietary audio"));
        assert!(contents.contains("credentials"));
    }
    assert!(bug.contains("Steps to reproduce"));
    assert!(proposal.contains("Revisit trigger"));
    assert!(pull_request.contains("Contract and documentation impact"));
    assert!(pull_request.contains("Validation evidence"));
}

fn parse_records(contents: &str) -> BTreeMap<String, BTreeMap<String, String>> {
    let mut records = BTreeMap::new();
    let mut current_id: Option<String> = None;

    for line in contents.lines() {
        if let Some(heading) = line.strip_prefix("## PD-") {
            let id = heading
                .split_once(':')
                .map(|(number, _)| format!("PD-{number}"))
                .expect("decision headings must use '## PD-###: Title'");
            assert!(
                records.insert(id.clone(), BTreeMap::new()).is_none(),
                "duplicate {id}"
            );
            current_id = Some(id);
            continue;
        }

        let Some(id) = current_id.as_ref() else {
            continue;
        };
        let Some(field) = line.strip_prefix("- **") else {
            continue;
        };
        let Some((name, value)) = field.split_once(":** ") else {
            continue;
        };
        records
            .get_mut(id)
            .unwrap()
            .insert(name.to_string(), value.trim().to_string());
    }

    records
}
