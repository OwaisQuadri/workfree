use std::time::Instant;
use clap::{Parser, Subcommand};

#[cfg(target_os = "linux")]
fn peak_rss_kb() -> u64 {
    let mut u: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut u) };
    u.ru_maxrss as u64  // KB
}

#[cfg(target_os = "macos")]
fn peak_rss_kb() -> u64 {
    let mut u: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut u) };
    u.ru_maxrss as u64 / 1024 // B -> KB
}

#[derive(Parser)]
#[command(version = "0.0.1")]
#[command(name = "Workfree")]
#[command(about = "Automatic worktree storage optimizations.", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Command
}

#[derive(Subcommand)]
enum Command {
    /// How much storage is actively being saved by CoW and how much has been reclaimed over all
    /// time.
    Status,
    /// List the worktrees and their size(s)
    List {
        /// specify a path to a working directory to resolve all worktrees in the repository
        #[arg(short, long)]
        path: Option<String>
    },
    /// Create a new copy-on-write worktree
    New {
        /// Open the new worktree
        #[arg(short, long)]
        open: Option<bool>
    },
    /// Create an automated checkpoint in git, remove the worktree, and return to the main checkout
    Close {
        /// no checkpoint in git
        #[arg(short, long)]
        force: Option<bool>
    },
    /// cd into an existing worktree checkout
    Open {
        /// The ID of the target worktree
        id: String
    },
    /// Schedule cleanup based on an idle time-limit (default 24h, default on)
    Watch {
        #[command(subcommand)]
        command: WatchSubcommand
    },
    /// Get or set user-configurable properties
    Config {
        #[command(subcommand)]
        command: ConfigSubcommand
    },
}

#[derive(Subcommand)]
enum ConfigSubcommand {
    /// write config value based on a key
    Set {
        /// write at this key
        key: String,
        /// write this value (omit to use default value)
        value: Option<String>
    },
    /// read config value(s)
    Get {
        /// read value for key
        key: Option<String>
    },
    /// Open the file that controls the configuration for the current repository
    Open
}

#[derive(Subcommand)]
enum WatchSubcommand {
    /// start watching this repository or worktree
    On,
    /// stop watching this repository or worktree
    Off,
    /// To check if the current repository is being watched
    Status
}

fn main() {
    // command
    let cli = Cli::parse();
    // time measurement start
    let now = Instant::now();

    match &cli.command {

        Command::Status => {
            println!("just like git status!")
        }

        Command::List { path } => {
            if let Some(path) = path {
                // resolve path -> repo
                print!("A bunch of worktrees in this current repo:\n\n  5.0 GB - worktrees/job-1\n  1.1 GB - worktrees/job-2")
            } else {
                // all repos
                print!("A bunch of worktrees in all repos:\n\n  5.0 GB - worktrees/job-1\n  1.1 GB - worktrees/job-2\n  0.8 GB - worktrees/job-3\n  1.9 GB - worktrees/job-4")
            }
        }

        Command::New { open } => {

        }

        Command::Close { force } => {

        }

        Command::Open { id } => {

        }

        Command::Watch { command } => {
            match command {
                WatchSubcommand::On => {

                }
                WatchSubcommand::Off => {

                }
                WatchSubcommand::Status => {

                }
            }

        }

        Command::Config { command } => {
            match command {
                ConfigSubcommand::Set { key, value } => {

                }
                ConfigSubcommand::Get { key } => {

                }
                ConfigSubcommand::Open => {

                }
            }

        }
    }

    // time measurement end
    let elapsed_seconds: f64 = (now.elapsed().as_nanos() as f64) / 1_000_000_000.0;

    // ram measurement
    let ram_in_mb = (peak_rss_kb() as f32) / 1_000.0;

    // debug output
    println!("\n--------------------------------------");
    println!("this command took {} seconds", elapsed_seconds);
    println!("this command used {} MB of memory", ram_in_mb);
}
