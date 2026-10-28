//! Phoenix channel frames, serializer 2.0.0:
//! `[join_ref, ref, topic, event, payload]`.

use serde_json::{Value, json};

#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    pub join_ref: Option<String>,
    pub reference: Option<String>,
    pub topic: String,
    pub event: String,
    pub payload: Value,
}

impl Frame {
    pub fn encode(&self) -> String {
        json!([
            self.join_ref,
            self.reference,
            self.topic,
            self.event,
            self.payload
        ])
        .to_string()
    }

    pub fn decode(text: &str) -> Option<Frame> {
        let Value::Array(parts) = serde_json::from_str::<Value>(text).ok()? else {
            return None;
        };
        let [join_ref, reference, topic, event, payload] = <[Value; 5]>::try_from(parts).ok()?;

        Some(Frame {
            join_ref: join_ref.as_str().map(str::to_string),
            reference: reference.as_str().map(str::to_string),
            topic: topic.as_str()?.to_string(),
            event: event.as_str()?.to_string(),
            payload,
        })
    }
}

pub fn topic(session: &str) -> String {
    format!("conversation:{session}")
}

/// The websocket URL for `base` (`ws://localhost:PORT/chat/socket`).
pub fn socket_url(base: &str, session: &str, token: &str) -> String {
    format!(
        "{}/websocket?vsn=2.0.0&session={}&token={}",
        base.trim_end_matches('/'),
        encode(session),
        encode(token)
    )
}

fn encode(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            b => format!("%{b:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_round_trip() {
        let frame = Frame {
            join_ref: Some("1".into()),
            reference: Some("2".into()),
            topic: topic("s1"),
            event: "say".into(),
            payload: json!({"text": "hi"}),
        };
        assert_eq!(Frame::decode(&frame.encode()), Some(frame));
    }

    #[test]
    fn a_heartbeat_reply_has_no_join_ref() {
        let frame = Frame::decode(r#"[null,"3","phoenix","phx_reply",{"status":"ok"}]"#).unwrap();
        assert_eq!(frame.join_ref, None);
        assert_eq!(frame.topic, "phoenix");
    }

    #[test]
    fn malformed_frames_are_none() {
        assert_eq!(Frame::decode("not json"), None);
        assert_eq!(Frame::decode("[1,2,3]"), None);
        assert_eq!(Frame::decode(r#"[null,null,1,"x",{}]"#), None);
    }

    #[test]
    fn the_url_carries_session_and_token_encoded() {
        assert_eq!(
            socket_url("ws://localhost:4000/chat/socket/", "s-1", "a+b/c"),
            "ws://localhost:4000/chat/socket/websocket?vsn=2.0.0&session=s-1&token=a%2Bb%2Fc"
        );
    }
}
