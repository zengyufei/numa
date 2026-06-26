use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use arc_swap::ArcSwap;

const QTYPE_A: u16 = 1;
const QTYPE_AAAA: u16 = 28;
const CLASS_IN: u16 = 1;

#[derive(Clone)]
struct Options {
    domains_path: String,
    bind: SocketAddr,
    ttl: u32,
}

#[derive(Clone, Debug)]
struct DomainEntry {
    ip: Ipv4Addr,
}

struct Query {
    id: u16,
    rd: bool,
    domain: String,
    qtype: u16,
    question_end: usize,
}

enum QueryResult {
    A(Ipv4Addr),
    Empty,
    NxDomain,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let options = parse_args()?;
    let initial_entries = load_domains(&options.domains_path)?;
    let domain_count = initial_entries.len();
    let entries = Arc::new(ArcSwap::from_pointee(initial_entries));

    println!(
        "numa-dev listening on {}, domains {}, ttl {}",
        options.bind, domain_count, options.ttl
    );

    spawn_domain_reloader(options.domains_path.clone(), Arc::clone(&entries));

    let udp_socket = UdpSocket::bind(options.bind)?;
    let tcp_listener = TcpListener::bind(options.bind)?;

    let tcp_entries = Arc::clone(&entries);
    let tcp_ttl = options.ttl;
    thread::spawn(move || {
        for stream in tcp_listener.incoming() {
            match stream {
                Ok(stream) => {
                    let entries = Arc::clone(&tcp_entries);
                    thread::spawn(move || handle_tcp(stream, entries, tcp_ttl));
                }
                Err(e) => eprintln!("tcp accept error: {}", e),
            }
        }
    });

    let mut buf = [0u8; 1500];
    loop {
        let (len, peer) = udp_socket.recv_from(&mut buf)?;
        let start = Instant::now();
        let current_entries = entries.load();
        let response = handle_dns_message(
            &buf[..len],
            peer,
            current_entries.as_ref(),
            options.ttl,
            start,
        );
        if let Some(response) = response {
            if let Err(e) = udp_socket.send_to(&response, peer) {
                eprintln!("{} | udp send error: {}", peer, e);
            }
        }
    }
}

fn parse_args() -> Result<Options, Box<dyn std::error::Error>> {
    let mut domains_path = "dev-domains.txt".to_string();
    let mut bind: SocketAddr = "127.0.0.2:53".parse()?;
    let mut ttl = 60u32;

    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--domains" => {
                domains_path = args.next().ok_or("--domains requires a path")?;
            }
            "--bind" => {
                bind = args.next().ok_or("--bind requires an address")?.parse()?;
            }
            "--ttl" => {
                ttl = args.next().ok_or("--ttl requires seconds")?.parse()?;
            }
            "--help" | "-h" => {
                print_usage();
                std::process::exit(0);
            }
            unknown => {
                return Err(format!("unknown argument: {}", unknown).into());
            }
        }
    }

    Ok(Options {
        domains_path,
        bind,
        ttl,
    })
}

fn print_usage() {
    println!("Usage: numa-dev.exe [--domains dev-domains.txt] [--bind 127.0.0.2:53] [--ttl 60]");
}

fn load_domains(path: &str) -> Result<HashMap<String, DomainEntry>, Box<dyn std::error::Error>> {
    let contents = fs::read_to_string(path)?;
    let mut entries = HashMap::new();

    for (line_no, raw_line) in contents.lines().enumerate() {
        let line = raw_line.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }

        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 2 {
            return Err(format!(
                "{}:{} must be '<ip> <domain> [domain...]'",
                path,
                line_no + 1
            )
            .into());
        }

        let ip: Ipv4Addr = parts[0].parse().map_err(|e| {
            format!(
                "{}:{} invalid IPv4 '{}': {}",
                path,
                line_no + 1,
                parts[0],
                e
            )
        })?;

        for domain in &parts[1..] {
            let domain = normalize_domain(domain);
            if domain.is_empty() || domain.starts_with("*.") {
                return Err(format!(
                    "{}:{} numa-dev supports exact IPv4 domains only: {}",
                    path,
                    line_no + 1,
                    domain
                )
                .into());
            }
            entries.insert(domain, DomainEntry { ip });
        }
    }

    if entries.is_empty() {
        return Err(format!("no domains found in {}", path).into());
    }

    Ok(entries)
}

fn normalize_domain(domain: &str) -> String {
    domain.trim().trim_end_matches('.').to_ascii_lowercase()
}

fn spawn_domain_reloader(path: String, entries: Arc<ArcSwap<HashMap<String, DomainEntry>>>) {
    thread::spawn(move || {
        let mut last_error: Option<String> = None;

        loop {
            thread::sleep(Duration::from_secs(3));

            match load_domains(&path) {
                Ok(new_entries) => {
                    let count = new_entries.len();
                    entries.store(Arc::new(new_entries));
                    if last_error.take().is_some() {
                        eprintln!("domains reloaded from {}: {} entries", path, count);
                    }
                }
                Err(e) => {
                    let error = e.to_string();
                    if last_error.as_deref() != Some(error.as_str()) {
                        eprintln!("domain reload failed; keeping previous entries: {}", error);
                        last_error = Some(error);
                    }
                }
            }
        }
    });
}

fn handle_tcp(
    mut stream: TcpStream,
    entries: Arc<ArcSwap<HashMap<String, DomainEntry>>>,
    ttl: u32,
) {
    let peer = stream.peer_addr().ok();
    loop {
        let mut len_buf = [0u8; 2];
        if stream.read_exact(&mut len_buf).is_err() {
            return;
        }
        let len = u16::from_be_bytes(len_buf) as usize;
        let mut msg = vec![0u8; len];
        if stream.read_exact(&mut msg).is_err() {
            return;
        }

        let start = Instant::now();
        let peer_addr = peer.unwrap_or_else(|| "0.0.0.0:0".parse().unwrap());
        let current_entries = entries.load();
        if let Some(response) =
            handle_dns_message(&msg, peer_addr, current_entries.as_ref(), ttl, start)
        {
            let len = (response.len() as u16).to_be_bytes();
            if stream.write_all(&len).is_err() || stream.write_all(&response).is_err() {
                return;
            }
        }
    }
}

fn handle_dns_message(
    msg: &[u8],
    peer: SocketAddr,
    entries: &HashMap<String, DomainEntry>,
    ttl: u32,
    start: Instant,
) -> Option<Vec<u8>> {
    let query = match parse_query(msg) {
        Ok(query) => query,
        Err(e) => {
            eprintln!("{} | parse error: {}", peer, e);
            return None;
        }
    };

    let result = match entries.get(&query.domain) {
        Some(entry) if query.qtype == QTYPE_A => QueryResult::A(entry.ip),
        Some(_) => QueryResult::Empty,
        None => QueryResult::NxDomain,
    };

    let response = build_response(msg, &query, &result, ttl)
        .unwrap_or_else(|| build_servfail(msg, query.id, query.rd).unwrap_or_default());

    let elapsed = start.elapsed().as_millis();
    println!(
        "{} | {} {} | {} | {}ms",
        peer,
        qtype_name(query.qtype),
        query.domain,
        result_name(&result),
        elapsed
    );

    Some(response)
}

fn parse_query(msg: &[u8]) -> Result<Query, String> {
    if msg.len() < 12 {
        return Err("packet too short".to_string());
    }
    let id = u16::from_be_bytes([msg[0], msg[1]]);
    let flags = u16::from_be_bytes([msg[2], msg[3]]);
    let qdcount = u16::from_be_bytes([msg[4], msg[5]]);
    if qdcount == 0 {
        return Err("packet has no question".to_string());
    }

    let mut offset = 12usize;
    let domain = read_name(msg, &mut offset)?;
    if offset + 4 > msg.len() {
        return Err("question truncated".to_string());
    }
    let qtype = u16::from_be_bytes([msg[offset], msg[offset + 1]]);
    offset += 4;

    Ok(Query {
        id,
        rd: flags & 0x0100 != 0,
        domain: normalize_domain(&domain),
        qtype,
        question_end: offset,
    })
}

fn read_name(msg: &[u8], offset: &mut usize) -> Result<String, String> {
    let mut labels = Vec::new();
    let mut pos = *offset;
    let mut jumped = false;
    let mut jumps = 0usize;

    loop {
        if pos >= msg.len() {
            return Err("name out of bounds".to_string());
        }
        let len = msg[pos];
        if len & 0xC0 == 0xC0 {
            if pos + 1 >= msg.len() {
                return Err("compression pointer truncated".to_string());
            }
            let pointer = (((len as usize) & 0x3F) << 8) | msg[pos + 1] as usize;
            if !jumped {
                *offset = pos + 2;
            }
            pos = pointer;
            jumped = true;
            jumps += 1;
            if jumps > 8 {
                return Err("too many compression jumps".to_string());
            }
            continue;
        }
        if len == 0 {
            if !jumped {
                *offset = pos + 1;
            }
            break;
        }
        if len & 0xC0 != 0 {
            return Err("invalid label length".to_string());
        }
        let start = pos + 1;
        let end = start + len as usize;
        if end > msg.len() {
            return Err("label out of bounds".to_string());
        }
        let label =
            std::str::from_utf8(&msg[start..end]).map_err(|_| "label is not utf-8".to_string())?;
        labels.push(label.to_string());
        pos = end;
    }

    Ok(labels.join("."))
}

fn build_response(msg: &[u8], query: &Query, result: &QueryResult, ttl: u32) -> Option<Vec<u8>> {
    let rcode = match result {
        QueryResult::NxDomain => 3u16,
        _ => 0u16,
    };
    let answers = matches!(result, QueryResult::A(_)) as u16;
    let mut out = Vec::with_capacity(64);
    write_header(&mut out, query.id, query.rd, rcode, 1, answers);
    out.extend_from_slice(msg.get(12..query.question_end)?);

    if let QueryResult::A(ip) = result {
        out.extend_from_slice(&[0xC0, 0x0C]);
        out.extend_from_slice(&QTYPE_A.to_be_bytes());
        out.extend_from_slice(&CLASS_IN.to_be_bytes());
        out.extend_from_slice(&ttl.to_be_bytes());
        out.extend_from_slice(&4u16.to_be_bytes());
        out.extend_from_slice(&ip.octets());
    }

    Some(out)
}

fn build_servfail(msg: &[u8], id: u16, rd: bool) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(32);
    write_header(&mut out, id, rd, 2, 1, 0);
    out.extend_from_slice(msg.get(12..)?);
    Some(out)
}

fn write_header(out: &mut Vec<u8>, id: u16, rd: bool, rcode: u16, questions: u16, answers: u16) {
    out.extend_from_slice(&id.to_be_bytes());
    let mut flags = 0x8000u16 | 0x0400u16;
    if rd {
        flags |= 0x0100;
    }
    flags |= rcode & 0x000F;
    out.extend_from_slice(&flags.to_be_bytes());
    out.extend_from_slice(&questions.to_be_bytes());
    out.extend_from_slice(&answers.to_be_bytes());
    out.extend_from_slice(&0u16.to_be_bytes());
    out.extend_from_slice(&0u16.to_be_bytes());
}

fn qtype_name(qtype: u16) -> String {
    match qtype {
        QTYPE_A => "A".to_string(),
        QTYPE_AAAA => "AAAA".to_string(),
        other => format!("TYPE{}", other),
    }
}

fn result_name(result: &QueryResult) -> &'static str {
    match result {
        QueryResult::A(_) => "LOCAL A",
        QueryResult::Empty => "NOERROR EMPTY",
        QueryResult::NxDomain => "NXDOMAIN",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn write_domains(contents: &str) -> PathBuf {
        let mut path = env::temp_dir();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        path.push(format!(
            "numa-dev-domains-{}-{}.txt",
            std::process::id(),
            unique
        ));
        fs::write(&path, contents).unwrap();
        path
    }

    #[test]
    fn load_domains_accepts_multiple_domains() {
        let path = write_domains(
            "\
# comment
192.168.0.103 api.example.test pay.example.test
10.0.0.2 admin.example.test.
",
        );

        let entries = load_domains(path.to_str().unwrap()).unwrap();

        assert_eq!(entries.len(), 3);
        assert_eq!(
            entries["api.example.test"].ip,
            Ipv4Addr::new(192, 168, 0, 103)
        );
        assert_eq!(
            entries["pay.example.test"].ip,
            Ipv4Addr::new(192, 168, 0, 103)
        );
        assert_eq!(entries["admin.example.test"].ip, Ipv4Addr::new(10, 0, 0, 2));

        let _ = fs::remove_file(path);
    }

    #[test]
    fn load_domains_rejects_empty_file() {
        let path = write_domains("\n# only comments\n");

        let err = load_domains(path.to_str().unwrap())
            .unwrap_err()
            .to_string();

        assert!(err.contains("no domains found"));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn load_domains_rejects_missing_domain() {
        let path = write_domains("192.168.0.103\n");

        let err = load_domains(path.to_str().unwrap())
            .unwrap_err()
            .to_string();

        assert!(err.contains("must be '<ip> <domain> [domain...]'"));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn load_domains_rejects_invalid_ipv4() {
        let path = write_domains("not-an-ip api.example.test\n");

        let err = load_domains(path.to_str().unwrap())
            .unwrap_err()
            .to_string();

        assert!(err.contains("invalid IPv4"));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn load_domains_rejects_wildcard_domain() {
        let path = write_domains("192.168.0.103 *.example.test\n");

        let err = load_domains(path.to_str().unwrap())
            .unwrap_err()
            .to_string();

        assert!(err.contains("exact IPv4 domains only"));
        let _ = fs::remove_file(path);
    }
}
