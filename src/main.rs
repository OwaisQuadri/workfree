mod commands;

use commands::*;
use std::time::Instant;
use clap::Parser;

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
            if let Some(_path) = path {
                // resolve path -> repo
                print!("A bunch of worktrees in this current repo:\n\n  5.0 GB - worktrees/job-1\n  1.1 GB - worktrees/job-2")
            } else {
                // all repos
                print!("A bunch of worktrees in all repos:\n\n  5.0 GB - worktrees/job-1\n  1.1 GB - worktrees/job-2\n  0.8 GB - worktrees/job-3\n  1.9 GB - worktrees/job-4")
            }
        }

        Command::New { open: _ } => {

        }

        Command::Close { force: _ } => {

        }

        Command::Open { id: _ } => {

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
                ConfigSubcommand::Set { key: _, value: _ } => {

                }
                ConfigSubcommand::Get { key: _ } => {

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
