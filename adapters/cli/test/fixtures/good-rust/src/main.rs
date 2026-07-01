//! goodrust - a tiny example CLI (standard library only, no external crates).
use std::env;
use std::process;
use std::thread;
use std::time::Duration;

const VERSION: &str = "goodrust 0.1.0";
const HELP: &str = "goodrust - a tiny example CLI

Usage: goodrust [command] [options]

Commands:
  greet <name>   Print a greeting
  add <a> <b>    Print the sum of two integers
  quiet          Print nothing and exit 0
  sleep          Sleep briefly (for timeout testing)

Options:
  -h, --help     Show this help and exit
  --version      Print version and exit
";

fn run(args: &[String]) -> Result<(), String> {
    if args.is_empty() || args[0] == "-h" || args[0] == "--help" {
        print!("{HELP}");
        return Ok(());
    }
    match args[0].as_str() {
        "--version" => {
            println!("{VERSION}");
            Ok(())
        }
        "greet" => {
            let name = if args.len() > 1 { args[1].as_str() } else { "world" };
            println!("Hello, {name}!");
            Ok(())
        }
        "add" => {
            let a: i64 = args
                .get(1)
                .ok_or("add needs two integers")?
                .parse()
                .map_err(|_| "not an integer".to_string())?;
            let b: i64 = args
                .get(2)
                .ok_or("add needs two integers")?
                .parse()
                .map_err(|_| "not an integer".to_string())?;
            println!("{}", a + b);
            Ok(())
        }
        "quiet" => Ok(()),
        "sleep" => {
            thread::sleep(Duration::from_secs(5));
            println!("awake");
            Ok(())
        }
        other => Err(format!("unknown command: {other}")),
    }
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if let Err(err) = run(&args) {
        eprintln!("error: {err}");
        process::exit(1);
    }
}
