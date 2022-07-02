use anyhow::Result;
use clap::Parser;

mod init;

trait App {
    fn run(self) -> Result<()>;
}

#[derive(Parser)]
#[clap(version, about, long_about = None)]
enum Args {
    Init(init::Args),
}

impl App for Args {
    fn run(self) -> Result<()> {
        match self {
            Self::Init(args) => args.run(),
        }
    }
}

fn main() -> Result<()> {
    Args::from_args().run()
}
