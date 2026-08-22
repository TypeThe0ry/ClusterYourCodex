use anyhow::Result;
use clap::Parser;

#[derive(Debug, Parser)]
#[command(
    name = "cyc-worker",
    version,
    about = "Probe a computer for ClusterYourCodex scheduling"
)]
struct Args {
    /// Pretty-print the probe JSON.
    #[arg(long)]
    pretty: bool,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let report = cyc_worker::probe();
    if args.pretty {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("{}", serde_json::to_string(&report)?);
    }
    Ok(())
}
