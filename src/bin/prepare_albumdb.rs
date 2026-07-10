use std::env;
use std::fs::{self, File};
use std::io::{BufReader, Read};
use std::path::{Path, PathBuf};
use std::process;

use serde::Serialize;
use sha2::{Digest, Sha256};

const SOURCE_DOI: &str = "10.5281/zenodo.19683001";

#[derive(Serialize)]
struct CorpusManifest {
    schema_version: u32,
    source_doi: &'static str,
    pairs: Vec<PreparedPair>,
}

#[derive(Serialize)]
struct PreparedPair {
    id: String,
    title: String,
    stem_count: usize,
    reference_path: String,
    target_path: String,
    reference_sha256: String,
    target_sha256: String,
}

fn main() {
    if let Err(error) = run(env::args().skip(1).collect()) {
        eprintln!("error: {error}");
        process::exit(1);
    }
}

fn run(args: Vec<String>) -> Result<(), String> {
    let root = parse_root(&args)?;
    let stems_root = root.join("stems_mixed");
    let masters_root = root.join("masters_stereo");
    let pairs_root = root.join("pairs");
    require_directory(&stems_root)?;
    require_directory(&masters_root)?;
    fs::create_dir_all(&pairs_root)
        .map_err(|error| format!("failed to create {}: {error}", pairs_root.display()))?;

    let mut song_dirs = directories(&stems_root)?;
    song_dirs.sort();
    if song_dirs.is_empty() {
        return Err(format!(
            "no song directories found in {}",
            stems_root.display()
        ));
    }

    let mut pairs = Vec::with_capacity(song_dirs.len());
    for song_dir in song_dirs {
        let directory_name = file_name(&song_dir)?;
        let (id, title) = parse_song_directory(directory_name)?;
        let master = find_master(&masters_root, id)?;
        let mut stems = wav_files(&song_dir)?;
        stems.sort();
        if stems.is_empty() {
            return Err(format!("no WAV stems found in {}", song_dir.display()));
        }

        let pair_dir = pairs_root.join(id);
        fs::create_dir_all(&pair_dir)
            .map_err(|error| format!("failed to create {}: {error}", pair_dir.display()))?;
        let reference = pair_dir.join("reference.wav");
        let target = pair_dir.join("target.wav");
        fs::copy(&master, &reference).map_err(|error| {
            format!(
                "failed to copy master {} to {}: {error}",
                master.display(),
                reference.display()
            )
        })?;
        sum_stems(&stems, &target)?;
        validate_pair_alignment(&reference, &target)?;

        pairs.push(PreparedPair {
            id: id.to_string(),
            title: title.to_string(),
            stem_count: stems.len(),
            reference_path: relative_path(&root, &reference)?,
            target_path: relative_path(&root, &target)?,
            reference_sha256: sha256(&reference)?,
            target_sha256: sha256(&target)?,
        });
        println!("prepared {id} {title} from {} stems", stems.len());
    }

    let manifest = CorpusManifest {
        schema_version: 1,
        source_doi: SOURCE_DOI,
        pairs,
    };
    let json = serde_json::to_string_pretty(&manifest)
        .map_err(|error| format!("failed to encode corpus manifest: {error}"))?;
    let path = pairs_root.join("manifest.json");
    fs::write(&path, format!("{json}\n"))
        .map_err(|error| format!("failed to write {}: {error}", path.display()))?;
    println!("wrote {}", path.display());
    Ok(())
}

fn validate_pair_alignment(reference: &Path, target: &Path) -> Result<(), String> {
    let reference_reader = hound::WavReader::open(reference)
        .map_err(|error| format!("failed to inspect {}: {error}", reference.display()))?;
    let target_reader = hound::WavReader::open(target)
        .map_err(|error| format!("failed to inspect {}: {error}", target.display()))?;
    let reference_spec = reference_reader.spec();
    let target_spec = target_reader.spec();
    if reference_spec.channels != target_spec.channels
        || reference_spec.sample_rate != target_spec.sample_rate
        || reference_reader.duration() != target_reader.duration()
    {
        return Err(format!(
            "prepared pair is not aligned: reference={}, target={}",
            reference.display(),
            target.display()
        ));
    }
    Ok(())
}

fn sum_stems(stems: &[PathBuf], output: &Path) -> Result<(), String> {
    let mut readers = stems
        .iter()
        .map(|path| {
            hound::WavReader::open(path)
                .map_err(|error| format!("failed to open stem {}: {error}", path.display()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    let expected = readers[0].spec();
    if expected.channels != 2
        || expected.sample_format != hound::SampleFormat::Int
        || expected.bits_per_sample != 16
    {
        return Err(format!(
            "AlbumDB stem {} must be stereo 16-bit PCM WAV",
            stems[0].display()
        ));
    }
    let duration = readers[0].duration();
    for (path, reader) in stems.iter().zip(&readers) {
        let spec = reader.spec();
        if spec != expected || reader.duration() != duration {
            return Err(format!(
                "stem {} does not match channels, rate, format, or duration of {}",
                path.display(),
                stems[0].display()
            ));
        }
    }

    let output_spec = hound::WavSpec {
        channels: 2,
        sample_rate: expected.sample_rate,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut writer = hound::WavWriter::create(output, output_spec)
        .map_err(|error| format!("failed to create target {}: {error}", output.display()))?;
    let interleaved_samples = duration as usize * expected.channels as usize;
    for sample_index in 0..interleaved_samples {
        let mut sum = 0.0_f32;
        for (path, reader) in stems.iter().zip(&mut readers) {
            let sample = reader
                .samples::<i16>()
                .next()
                .ok_or_else(|| {
                    format!(
                        "stem {} ended before interleaved sample {sample_index}",
                        path.display()
                    )
                })?
                .map_err(|error| format!("failed to read stem {}: {error}", path.display()))?;
            sum += sample as f32 / 32_768.0;
        }
        writer
            .write_sample(sum)
            .map_err(|error| format!("failed to write target {}: {error}", output.display()))?;
    }
    writer
        .finalize()
        .map_err(|error| format!("failed to finalize target {}: {error}", output.display()))
}

fn parse_root(args: &[String]) -> Result<PathBuf, String> {
    match args {
        [flag, root] if flag == "--root" => Ok(PathBuf::from(root)),
        _ => Err("usage: prepare_albumdb --root <extracted-albumdb-root>".to_string()),
    }
}

fn require_directory(path: &Path) -> Result<(), String> {
    if path.is_dir() {
        Ok(())
    } else {
        Err(format!(
            "required directory does not exist: {}",
            path.display()
        ))
    }
}

fn directories(root: &Path) -> Result<Vec<PathBuf>, String> {
    fs::read_dir(root)
        .map_err(|error| format!("failed to read {}: {error}", root.display()))?
        .filter_map(|entry| match entry {
            Ok(entry) if entry.path().is_dir() => Some(Ok(entry.path())),
            Ok(_) => None,
            Err(error) => Some(Err(format!("failed to read {}: {error}", root.display()))),
        })
        .collect()
}

fn wav_files(root: &Path) -> Result<Vec<PathBuf>, String> {
    fs::read_dir(root)
        .map_err(|error| format!("failed to read {}: {error}", root.display()))?
        .filter_map(|entry| match entry {
            Ok(entry)
                if entry.path().is_file()
                    && entry
                        .path()
                        .extension()
                        .is_some_and(|extension| extension.eq_ignore_ascii_case("wav")) =>
            {
                Some(Ok(entry.path()))
            }
            Ok(_) => None,
            Err(error) => Some(Err(format!("failed to read {}: {error}", root.display()))),
        })
        .collect()
}

fn find_master(root: &Path, id: &str) -> Result<PathBuf, String> {
    let prefix = format!("{id} - ");
    let matches: Vec<PathBuf> = wav_files(root)?
        .into_iter()
        .filter(|path| file_name(path).is_ok_and(|name| name.starts_with(&prefix)))
        .collect();
    match matches.as_slice() {
        [path] => Ok(path.clone()),
        [] => Err(format!(
            "no stereo master beginning with {prefix:?} in {}",
            root.display()
        )),
        _ => Err(format!(
            "multiple stereo masters beginning with {prefix:?} in {}",
            root.display()
        )),
    }
}

fn parse_song_directory(name: &str) -> Result<(&str, &str), String> {
    let (id, title) = name
        .split_once(' ')
        .ok_or_else(|| format!("song directory must start with a two-digit ID: {name}"))?;
    if id.len() == 2 && id.bytes().all(|byte| byte.is_ascii_digit()) && !title.is_empty() {
        Ok((id, title))
    } else {
        Err(format!(
            "song directory must start with a two-digit ID: {name}"
        ))
    }
}

fn file_name(path: &Path) -> Result<&str, String> {
    path.file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("path does not have a UTF-8 file name: {}", path.display()))
}

fn relative_path(root: &Path, path: &Path) -> Result<String, String> {
    path.strip_prefix(root)
        .map(|path| path.to_string_lossy().into_owned())
        .map_err(|error| format!("failed to make {} relative: {error}", path.display()))
}

fn sha256(path: &Path) -> Result<String, String> {
    let mut file = BufReader::new(
        File::open(path).map_err(|error| format!("failed to hash {}: {error}", path.display()))?,
    );
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| format!("failed to hash {}: {error}", path.display()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}
