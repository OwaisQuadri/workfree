mod commands;

use commands::*;
use std::{error::Error, path::Path, time::Instant};
use clap::Parser;
use workfree_rust::{ Worktree };

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
    // scratch
    //

    //
    // command
    let cli = Cli::parse();
    // time measurement start
    let now = Instant::now();

    match &cli.command {

        Command::Status => {
            println!("just like git status!")
        }

        Command::List { path } => {
            match Worktree::list(path.as_deref().map(Path::new)) {
                Ok(wts) => {
                    println!("{}", wts.len());
                    for wt in wts {
                        let main_tag = if wt.is_main() { "(MAIN)" } else { "" };
                        let branch_display = wt.branch.as_deref().unwrap_or("(DETACHED)");

                        let full_storage = match wt.storage_used() {
                            Ok(storage) => format!("{} bytes", storage.full),
                            Err(e) => {
                                if let Some(source) = e.source() {
                                    format!("size unknown: {}", source)
                                } else {
                                    "size unknown".to_string()
                                }
                            }
                        };
                        println!(
                            "branch {} at `{}` {} - {}",
                            branch_display,
                            wt.path.display(),
                            main_tag,
                            full_storage
                        );
                    }
                },
                Err(e) => eprintln!("{e}")
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
