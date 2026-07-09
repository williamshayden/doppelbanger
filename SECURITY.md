# Security Policy

## Supported Versions

doppelbanger is pre-release software. Security fixes are made on the latest `main` branch only until versioned releases begin.

## Reporting A Vulnerability

Use GitHub's private vulnerability reporting flow under the repository Security tab. Do not open a public issue, discussion, or pull request with exploit details, credentials, private audio, local service tokens, or sensitive filesystem paths.

Include:

- affected commit or version;
- operating system, architecture, DAW, and plugin format when relevant;
- exact reproduction steps and sanitized logs;
- expected impact and whether unreleased audio, local files, API state, or code execution is exposed;
- the smallest safe fixture or proof that demonstrates the issue.

You should receive an initial acknowledgement within seven days. Public disclosure and credit are coordinated after a fix or mitigation is available.

## Scope

High-priority areas include plugin/host memory safety, the Rust/C ABI boundary, local PostgREST exposure, filesystem path access, installer privileges, update/signing behavior, and accidental disclosure of user audio or credentials.

Ordinary crashes, audio artifacts, and performance regressions without a security impact belong in the public bug template.
