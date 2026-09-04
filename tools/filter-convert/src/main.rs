//! ABP-syntax filter lists -> Apple WebKit content-blocker JSON.
//!
//! Several inputs may feed one output:
//!
//!     --input easylist.txt --input brave-unbreak.txt --output ads.json
//!
//! That is not a convenience. WebKit evaluates each compiled list on its own,
//! and `ignore-previous-rules` cancels actions only within the list holding it
//! — verified in RuleActivationTests. So a compatibility list shipped as its
//! own rule list does nothing at all; its exceptions have to be parsed into the
//! same FilterSet as the rules they undo.
//!
//! Rules that cannot be represented in WebKit are dropped, never widened:
//! broadening an unsupported rule is how a blocker starts eating legitimate
//! media requests.

use std::{env, fs};

use adblock::lists::{FilterSet, ParseOptions, RuleTypes};

struct Job {
    inputs: Vec<String>,
    output: String,
}

fn parse_args(args: &[String]) -> Result<Vec<Job>, String> {
    let mut jobs = Vec::new();
    let mut inputs: Vec<String> = Vec::new();
    let mut i = 0;

    while i < args.len() {
        match args[i].as_str() {
            "--input" => {
                let path = args.get(i + 1).ok_or("--input needs a path")?;
                inputs.push(path.clone());
                i += 2;
            }
            "--output" => {
                let path = args.get(i + 1).ok_or("--output needs a path")?;
                if inputs.is_empty() {
                    return Err(format!("--output {path} has no --input before it"));
                }
                jobs.push(Job { inputs: std::mem::take(&mut inputs), output: path.clone() });
                i += 2;
            }
            other => return Err(format!("unexpected argument: {other}")),
        }
    }

    if !inputs.is_empty() {
        return Err(format!("{:?} is not followed by --output", inputs));
    }
    if jobs.is_empty() {
        return Err("usage: --input <list.txt> [--input ...] --output <rules.json>".into());
    }
    Ok(jobs)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().skip(1).collect();
    let jobs = parse_args(&args)?;

    for job in jobs {
        // Must be true: content-blocking conversion needs each rule's original
        // text, which FilterSet only retains in debug mode. With it off, the
        // conversion fails with a bare `Err(())`.
        let mut set = FilterSet::new(/* debug */ true);

        // Order matters. Exceptions are parsed after the rules they cancel, so
        // list the blocking sources first and the unbreak list last.
        for input in &job.inputs {
            let text = fs::read_to_string(input)
                .map_err(|e| format!("{input}: {e}"))?;
            set.add_filter_list(
                text,
                ParseOptions { rule_types: RuleTypes::All, ..Default::default() },
            );
        }

        // Keep the underlying error: a generic message here hides which rule
        // shape the converter actually rejected.
        let (rules, used_rules) = set.into_content_blocking().map_err(|e| {
            format!("{}: content blocking conversion failed: {e:?}", job.output)
        })?;

        let json = serde_json::to_string(&rules)?;
        fs::write(&job.output, &json)?;
        eprintln!(
            "{} -> {}: {} rules emitted, {} source rules used",
            job.inputs.join(" + "),
            job.output,
            rules.len(),
            used_rules.len()
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::parse_args;

    fn args(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn groups_every_input_before_an_output() {
        let jobs = parse_args(&args(&[
            "--input", "a.txt", "--input", "b.txt", "--output", "one.json",
            "--input", "c.txt", "--output", "two.json",
        ]))
        .unwrap();

        assert_eq!(jobs.len(), 2);
        assert_eq!(jobs[0].inputs, vec!["a.txt", "b.txt"]);
        assert_eq!(jobs[0].output, "one.json");
        assert_eq!(jobs[1].inputs, vec!["c.txt"]);
    }

    #[test]
    fn rejects_inputs_with_no_output() {
        assert!(parse_args(&args(&["--input", "a.txt"])).is_err());
    }

    #[test]
    fn rejects_output_with_no_input() {
        assert!(parse_args(&args(&["--output", "one.json"])).is_err());
    }
}
