use anyhow::Result;
use structopt::StructOpt;

mod build;
mod init;

pub trait App {
    fn run(self) -> Result<()>;
}

#[derive(StructOpt)]
enum Opt {
    Build(build::Opt),
    Init(init::Opt),
}

impl App for Opt {
    fn run(self) -> Result<()> {
        match self {
            Self::Build(opt) => opt.run(),
            Self::Init(opt) => opt.run(),
        }
    }
}

fn main() -> Result<()> {
    let opt = Opt::from_args();
    opt.run()
}
