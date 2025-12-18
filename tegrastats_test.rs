use std::process::{Command, Stdio};
use std::io::{BufRead, BufReader};

#[derive(Debug)]
struct Ram {
    used_mb: u32,
    total_mb: u32,
}

#[derive(Debug)]
struct Swap {
    used_mb: u32,
    total_mb: u32,
}

#[derive(Debug)]
struct CpuCore {
    load: u8,
    freq_mhz: u32,
}

#[derive(Debug)]
struct Engine {
    name: String,
    load: u8,
}

#[derive(Debug)]
struct Thermal {
    name: String,
    temp_c: f32,
}

#[derive(Debug, Default)]
struct Telemetry {
    ram: Option<Ram>,
    swap: Option<Swap>,
    cpu: Vec<CpuCore>,
    engines: Vec<Engine>,
    thermals: Vec<Thermal>,
}

#[derive(Clone, Copy)]
enum State {
    None,
    Ram,
    Swap,
    Cpu,
}

fn parse_line(line: &str) -> Telemetry {
    let mut tel = Telemetry::default();
    let mut state = State::None;

    for tok in line.split_whitespace() {
        if tok == "RAM" {
            state = State::Ram;
            continue;
        }
        if tok == "SWAP" {
            state = State::Swap;
            continue;
        }
        if tok == "CPU" {
            state = State::Cpu;
            continue;
        }

        // Engine: GR3D_FREQ 0%
        if tok.ends_with("_FREQ") {
            continue;
        }
        if tok.ends_with('%') && line.contains("_FREQ") {
            let name = line
                .split("_FREQ")
                .next()
                .unwrap()
                .split_whitespace()
                .last()
                .unwrap()
                .to_string();

            if let Ok(load) = tok.replace('%', "").parse() {
                tel.engines.push(Engine { name, load });
            }
            continue;
        }

        // Thermal: CPU@39C
        if let Some((name, val)) = tok.split_once('@') {
            if let Ok(temp) = val.replace('C', "").parse::<f32>() {
                tel.thermals.push(Thermal {
                    name: name.to_string(),
                    temp_c: temp,
                });
            }
            continue;
        }

        match state {
            State::Ram => {
                // 2035/31011MB
                if let Some((u, t)) = tok.split_once('/') {
                    if let (Ok(used), Ok(total)) =
                        (u.parse(), t.replace("MB", "").parse())
                    {
                        tel.ram = Some(Ram {
                            used_mb: used,
                            total_mb: total,
                        });
                    }
                }
                state = State::None;
            }
            State::Swap => {
                if let Some((u, t)) = tok.split_once('/') {
                    if let (Ok(used), Ok(total)) =
                        (u.parse(), t.replace("MB", "").parse())
                    {
                        tel.swap = Some(Swap {
                            used_mb: used,
                            total_mb: total,
                        });
                    }
                }
                state = State::None;
            }
            State::Cpu => {
                // [1%@1190,0%@1190,...]
                let clean = tok.trim_matches(&['[', ']'][..]);
                for core in clean.split(',') {
                    if let Some((l, f)) = core.split_once("%@") {
                        if let (Ok(load), Ok(freq)) = (l.parse(), f.parse()) {
                            tel.cpu.push(CpuCore {
                                load,
                                freq_mhz: freq,
                            });
                        }
                    }
                }
                state = State::None;
            }
            State::None => {}
        }
    }

    tel
}

fn main() {
    let mut child = Command::new("tegrastats")
        .arg("--interval")
        .arg("1000")
        .stdout(Stdio::piped())
        .spawn()
        .expect("tegrastats not found");

    let stdout = child.stdout.take().unwrap();
    let reader = BufReader::new(stdout);

    for line in reader.lines().flatten() {
        let tel = parse_line(&line);
        println!("{:#?}", tel);
    }
}