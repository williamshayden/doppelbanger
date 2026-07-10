use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=DOPPELBANGER_GIT_COMMIT");
    println!("cargo:rerun-if-env-changed=DOPPELBANGER_GIT_DIRTY");
    emit_git_watch("HEAD");
    emit_git_watch("index");
    if let Some(reference) = git_output(&["symbolic-ref", "-q", "HEAD"]) {
        emit_git_watch(&reference);
    }

    let commit = env::var("DOPPELBANGER_GIT_COMMIT")
        .ok()
        .or_else(|| git_output(&["rev-parse", "--verify", "HEAD"]));
    let dirty = env::var("DOPPELBANGER_GIT_DIRTY").ok().or_else(|| {
        git_output(&["status", "--porcelain"]).map(|status| (!status.is_empty()).to_string())
    });
    let rustc = env::var("RUSTC")
        .ok()
        .and_then(|rustc| command_output(Command::new(rustc).arg("--version")));

    emit_env("DOPPELBANGER_BUILD_GIT_COMMIT", commit);
    emit_env("DOPPELBANGER_BUILD_GIT_DIRTY", dirty);
    emit_env("DOPPELBANGER_BUILD_RUSTC_VERSION", rustc);
}

fn emit_git_watch(path: &str) {
    if let Some(path) = git_output(&["rev-parse", "--git-path", path]) {
        let path = PathBuf::from(path);
        let path = if path.is_absolute() {
            path
        } else {
            PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join(path)
        };
        println!("cargo:rerun-if-changed={}", path.display());
    }
}

fn emit_env(name: &str, value: Option<String>) {
    if let Some(value) = value {
        println!("cargo:rustc-env={name}={value}");
    }
}

fn git_output(args: &[&str]) -> Option<String> {
    command_output(Command::new("git").args(args))
}

fn command_output(command: &mut Command) -> Option<String> {
    let output = command.output().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
}
