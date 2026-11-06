use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(version = "0.0.1")]
#[command(name = "Workfree")]
#[command(about = "Automatic worktree storage optimizations.", long_about = None)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command
}

#[derive(Subcommand)]
pub enum Command {
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
pub enum ConfigSubcommand {
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
pub enum WatchSubcommand {
    /// start watching this repository or worktree
    On,
    /// stop watching this repository or worktree
    Off,
    /// To check if the current repository is being watched
    Status
}
