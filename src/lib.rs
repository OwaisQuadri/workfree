use std::{collections::HashSet, path::{Path, PathBuf}, process::Command};
use std::os::unix::fs::MetadataExt;

use thiserror::Error;
use std::io::ErrorKind;

pub struct Worktree {
    pub path: PathBuf,
    pub branch: Option<String>,
    is_main: bool,
}

pub struct WorktreeStorage{
    pub full: u64,
    pub private: u64,
}
impl WorktreeStorage {
    fn new(full: u64, private: u64) -> Self {
        Self { full, private }
    }
    pub fn storage_saved(&self) -> u64 { self.full - self.private }
}

impl Worktree {

    fn new(path: PathBuf, branch: Option<String>, is_main: bool) -> Self {
        Self { path, branch, is_main }
    }

    pub fn storage_used(&self) -> Result<WorktreeStorage, WorktreeErr> { 
        let mut wt_storage = WorktreeStorage::new(0, 0);
        let mut skip: HashSet<(u64, u64)> = HashSet::new();
        fn walk(dir: &Path, usage: &mut WorktreeStorage, skip: &mut HashSet<(u64, u64)>) -> Result<(), WorktreeErr> {
            for entry in std::fs::read_dir(dir).map_err(|e| WorktreeErr::StorageMeasurementError {path: dir.to_path_buf(), source: e})? {
                let entry = entry.map_err(|e| WorktreeErr::StorageMeasurementError {path: dir.to_path_buf(), source: e})?;
                let meta = entry.metadata().map_err(|e| WorktreeErr::StorageMeasurementError {path: entry.path(), source: e})?;

                if meta.is_dir() {
                    walk(&entry.path(), usage, skip)?;
                } else if meta.is_file() || meta.is_symlink() {
                    if meta.nlink() > 1 {
                        let id = (meta.dev(), meta.ino());
                        if !skip.insert(id) { continue }
                    }
                    usage.full += meta.blocks() * 512;
                } 
            }
            Ok(())
        }

        walk(&self.path, &mut wt_storage, &mut skip)?;

        Ok(wt_storage)
    }

    pub fn is_main(&self) -> bool { self.is_main }

    pub fn list(path: Option<&Path>) -> Result<Vec<Worktree>, WorktreeErr> {
        let mut cmd = Command::new("git");
        cmd.args(["worktree", "list", "--porcelain"]);
        if let Some(dir) = path {
            if !dir.is_dir() {
                return Result::Err(WorktreeErr::InvalidPath)
            }
            cmd.current_dir(dir);
        }
        let out = cmd.output().map_err(|e| match e.kind() {
            ErrorKind::NotFound => WorktreeErr::GitDoesNotExist,
            _ => WorktreeErr::GitError,
        })?;

        if out.status.success() {
            // parse
            let git_output = String::from_utf8(out.stdout).map_err(|_| WorktreeErr::DecodeError)?;
            let mut wts: Vec<Worktree> = Vec::new();

            for (i, block) in git_output.split("\n\n").enumerate() {

                let mut path = None;
                let mut branch = None;
                let is_main = i == 0;

                for line in block.lines() {
                    if let Some(_path) = line.strip_prefix("worktree ") {
                        path = Some(PathBuf::from(_path));
                    }
                    if let Some(_branch) = line.strip_prefix("branch refs/heads/") {
                        branch = Some(String::from(_branch)); 
                    }
                }
                let Some(path) = path else { continue };

                let wt = Worktree::new(path, branch, is_main);
                wts.push(wt);

            }
            Ok(wts)
        } else {
            Err(WorktreeErr::NotGitRepo)
        }
    }
}

#[derive(Error, Debug)]
pub enum WorktreeErr {

    #[error("git is not installed on this system.")]
    GitDoesNotExist,

    #[error("there was an error in git.")]
    GitError,

    #[error("wf was unable to decode git command output.")]
    DecodeError,

    #[error("The path is not from a git repository.")]
    NotGitRepo,

    #[error("the path is not a valid directory")]
    InvalidPath,

    #[error("could not measure {path}")]
    StorageMeasurementError {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

