use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::{self, Read};

pub const VERSION: u32 = 1;
pub const MAX_FRAME: usize = 65_536;
pub const MAX_QUEUE: usize = 262_144;
pub const MAX_INPUT: usize = 8192;

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Hello {
        version: u32,
    },
    Spawn {
        request_id: String,
        session_id: String,
        executable: String,
        argv: Vec<String>,
        cwd: String,
        env: BTreeMap<String, String>,
        rows: u16,
        cols: u16,
    },
    Input {
        session_id: String,
        data: String,
    },
    Resize {
        session_id: String,
        rows: u16,
        cols: u16,
    },
    Signal {
        session_id: String,
        signal: String,
    },
    Terminate {
        session_id: String,
        grace_ms: u64,
    },
    Ping {
        session_id: String,
    },
}

pub fn frame(value: &Value) -> io::Result<Vec<u8>> {
    let body = serde_json::to_vec(value)?;
    if body.is_empty() || body.len() > MAX_FRAME {
        return Err(io::Error::other("frame_size"));
    }
    let mut result = Vec::with_capacity(body.len() + 4);
    result.extend_from_slice(&(body.len() as u32).to_be_bytes());
    result.extend_from_slice(&body);
    Ok(result)
}

pub fn read_command(reader: &mut impl Read) -> io::Result<Command> {
    let mut header = [0u8; 4];
    reader.read_exact(&mut header)?;
    let size = u32::from_be_bytes(header) as usize;
    if size == 0 || size > MAX_FRAME {
        return Err(io::Error::other("frame_size"));
    }
    let mut body = vec![0u8; size];
    reader.read_exact(&mut body)?;
    serde_json::from_slice(&body).map_err(|_| io::Error::other("invalid_command"))
}

pub fn take_command(buffer: &mut Vec<u8>) -> io::Result<Option<Command>> {
    if buffer.len() < 4 {
        return Ok(None);
    }
    let size = u32::from_be_bytes(buffer[..4].try_into().unwrap()) as usize;
    if size == 0 || size > MAX_FRAME {
        return Err(io::Error::other("frame_size"));
    }
    if buffer.len() < size + 4 {
        return Ok(None);
    }
    let command = serde_json::from_slice(&buffer[4..size + 4])
        .map_err(|_| io::Error::other("invalid_command"))?;
    buffer.drain(..size + 4);
    Ok(Some(command))
}

pub fn dimensions(rows: u16, cols: u16) -> bool {
    (1..=500).contains(&rows) && (1..=500).contains(&cols)
}

pub fn identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn fragmented_and_adjacent_frames_do_not_desynchronize() {
        let bytes = frame(&json!({"op":"hello","version":1})).unwrap();
        let mut buffer = Vec::new();
        for b in &bytes[..bytes.len() - 1] {
            buffer.push(*b);
            assert!(take_command(&mut buffer).unwrap().is_none());
        }
        buffer.push(*bytes.last().unwrap());
        buffer.extend_from_slice(&bytes);
        assert!(matches!(
            take_command(&mut buffer).unwrap(),
            Some(Command::Hello { version: 1 })
        ));
        assert!(matches!(
            take_command(&mut buffer).unwrap(),
            Some(Command::Hello { version: 1 })
        ));
        assert!(buffer.is_empty());
    }
    #[test]
    fn reject_oversize_before_allocating_a_body() {
        assert!(take_command(&mut ((MAX_FRAME as u32) + 1).to_be_bytes().to_vec()).is_err());
        assert!(read_command(&mut &0u32.to_be_bytes()[..]).is_err());
    }
    #[test]
    fn arbitrary_bytes_round_trip_in_data_field() {
        use base64::{Engine, engine::general_purpose::STANDARD};
        let raw: Vec<u8> = (0..=255).collect();
        let bytes =
            frame(&json!({"op":"input","session_id":"fixture","data":STANDARD.encode(&raw)}))
                .unwrap();
        match read_command(&mut bytes.as_slice()).unwrap() {
            Command::Input { data, .. } => assert_eq!(STANDARD.decode(data).unwrap(), raw),
            _ => panic!("wrong_command"),
        }
    }
    #[test]
    fn commands_are_strict_and_dimensions_bounded() {
        assert!(
            serde_json::from_value::<Command>(json!({"op":"hello","version":1,"extra":true}))
                .is_err()
        );
        assert!(!dimensions(0, 80));
        assert!(!dimensions(24, 501));
        assert!(dimensions(24, 80));
        assert!(!identifier("../bad"));
    }
}
