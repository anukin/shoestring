//! The channel connection (`docs/chat-channel.md`): connect, join with the
//! last sequence seen, fold pushes into the model, send what the person
//! asks, and reconnect after a loss. A message not yet acknowledged is sent
//! again after a reconnect with the same `message_id`, which the service
//! records once; a cancel is never sent again, since it would interrupt a
//! later turn.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};

use crate::model::{Connection, Model};
use crate::protocol::{self, Frame};

pub type Shared = Arc<Mutex<Model>>;

const HEARTBEAT: Duration = Duration::from_secs(30);
const FIRST_RETRY: Duration = Duration::from_millis(500);
const LAST_RETRY: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, PartialEq)]
pub enum Outgoing {
    Say { message_id: String, text: String },
    CancelTurn,
    Watch { id: String },
    Unwatch,
    CancelDispatch { id: String, reason: String },
}

#[derive(Debug, Clone)]
pub struct Config {
    /// `ws://localhost:PORT/chat/socket`
    pub url: String,
    pub session: String,
    pub token: String,
}

enum Ended {
    /// The service refused the token or the session: retrying cannot help.
    Refused(String),
    Lost {
        reason: String,
        joined: bool,
    },
    /// The client is leaving.
    Closed,
}

pub fn lock(model: &Shared) -> MutexGuard<'_, Model> {
    model
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub async fn run(config: Config, model: Shared, mut outbox: mpsc::UnboundedReceiver<Outgoing>) {
    let mut unsent: Vec<Outgoing> = Vec::new();
    let mut retry = FIRST_RETRY;

    loop {
        set(&model, Connection::Connecting);

        match session(&config, &model, &mut outbox, &mut unsent).await {
            Ended::Closed => return,
            Ended::Refused(reason) => {
                set(&model, Connection::Refused(reason));
                return;
            }
            Ended::Lost { reason, joined } => {
                set(&model, Connection::Reconnecting(reason));
                if joined {
                    retry = FIRST_RETRY;
                }
            }
        }

        tokio::time::sleep(retry).await;
        retry = (retry * 2).min(LAST_RETRY);
    }
}

fn set(model: &Shared, connection: Connection) {
    let mut model = lock(model);
    model.connection = match connection {
        Connection::Reconnecting(reason) => {
            Connection::Reconnecting(crate::text::clean_line(&reason))
        }
        Connection::Refused(reason) => Connection::Refused(crate::text::clean_line(&reason)),
        other => other,
    };
    model.dirty = true;
}

struct Refs(u64);

impl Refs {
    fn next(&mut self) -> String {
        self.0 += 1;
        self.0.to_string()
    }
}

async fn session(
    config: &Config,
    model: &Shared,
    outbox: &mut mpsc::UnboundedReceiver<Outgoing>,
    unsent: &mut Vec<Outgoing>,
) -> Ended {
    let url = protocol::socket_url(&config.url, &config.session, &config.token);
    let socket = match tokio_tungstenite::connect_async(url).await {
        Ok((socket, _response)) => socket,
        Err(WsError::Http(response)) if response.status() == 403 => {
            return Ended::Refused("the service did not accept this session's token".into());
        }
        Err(error) => {
            return Ended::Lost {
                reason: short_error(&error.to_string()),
                joined: false,
            };
        }
    };
    let (mut sink, mut stream) = socket.split();
    let topic = protocol::topic(&config.session);
    let mut refs = Refs(0);
    let join_ref = refs.next();
    let after = lock(model).last_sequence;

    let join = Frame {
        join_ref: Some(join_ref.clone()),
        reference: Some(join_ref.clone()),
        topic: topic.clone(),
        event: "phx_join".into(),
        payload: json!({ "after": after }),
    };
    if sink.send(Message::text(join.encode())).await.is_err() {
        return lost("the connection closed while joining", false);
    }

    loop {
        match stream.next().await {
            Some(Ok(Message::Text(text))) => match Frame::decode(&text) {
                Some(frame)
                    if frame.event == "phx_reply"
                        && frame.reference.as_deref() == Some(&join_ref) =>
                {
                    if frame.payload["status"] == "ok" {
                        break;
                    }
                    let reason = frame.payload["response"]["reason"]
                        .as_str()
                        .unwrap_or("refused");
                    return match reason {
                        "unauthorized" | "no_conversation" => {
                            Ended::Refused(format!("join refused: {reason}"))
                        }
                        other => lost(&format!("join refused: {other}"), false),
                    };
                }
                _ => {}
            },
            Some(Ok(_)) => {}
            _ => return lost("the connection closed while joining", false),
        }
    }

    set(model, Connection::Live);
    let mut pending: HashMap<String, Outgoing> = HashMap::new();

    for outgoing in unsent.clone() {
        if !send(
            &mut sink,
            &topic,
            &join_ref,
            &mut refs,
            &mut pending,
            outgoing,
        )
        .await
        {
            return lost("the connection closed", true);
        }
    }

    let watched = lock(model).detail.as_ref().map(|d| d.id.clone());
    if let Some(id) = watched
        && !send(
            &mut sink,
            &topic,
            &join_ref,
            &mut refs,
            &mut pending,
            Outgoing::Watch { id },
        )
        .await
    {
        return lost("the connection closed", true);
    }
    let mut heartbeat = tokio::time::interval(HEARTBEAT);
    heartbeat.tick().await;

    loop {
        tokio::select! {
            message = stream.next() => match message {
                Some(Ok(Message::Text(text))) => {
                    let Some(frame) = Frame::decode(&text) else { continue };
                    if frame.topic != topic {
                        continue;
                    }
                    match frame.event.as_str() {
                        "events" => lock(model).apply_events(&frame.payload),
                        "state" => lock(model).apply_state(&frame.payload),
                        "dispatch" => lock(model).apply_dispatch(&frame.payload, false),
                        "detached" => return lost("the screen fell behind; catching up", true),
                        "phx_reply" => reply(model, unsent, &mut pending, &frame),
                        "phx_error" | "phx_close" => return lost("the channel closed", true),
                        _ => {}
                    }
                }
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return lost("the connection closed", true),
                Some(Ok(_)) => {}
            },
            outgoing = outbox.recv() => match outgoing {
                None => {
                    let _ = sink.close().await;
                    return Ended::Closed;
                }
                Some(outgoing) => {
                    if matches!(outgoing, Outgoing::Say { .. }) {
                        unsent.push(outgoing.clone());
                    }
                    if !send(&mut sink, &topic, &join_ref, &mut refs, &mut pending, outgoing).await {
                        return lost("the connection closed", true);
                    }
                }
            },
            _ = heartbeat.tick() => {
                let beat = Frame {
                    join_ref: None,
                    reference: Some(refs.next()),
                    topic: "phoenix".into(),
                    event: "heartbeat".into(),
                    payload: json!({}),
                };
                if sink.send(Message::text(beat.encode())).await.is_err() {
                    return lost("the connection closed", true);
                }
            }
        }
    }
}

async fn send<S>(
    sink: &mut S,
    topic: &str,
    join_ref: &str,
    refs: &mut Refs,
    pending: &mut HashMap<String, Outgoing>,
    outgoing: Outgoing,
) -> bool
where
    S: SinkExt<Message, Error = WsError> + Unpin,
{
    let (event, payload) = match &outgoing {
        Outgoing::Say { message_id, text } => {
            ("say", json!({"message_id": message_id, "text": text}))
        }
        Outgoing::CancelTurn => ("cancel_turn", json!({})),
        Outgoing::Watch { id } => ("watch_dispatch", json!({"dispatch_id": id})),
        Outgoing::Unwatch => ("unwatch_dispatch", json!({})),
        Outgoing::CancelDispatch { id, reason } => (
            "cancel_dispatch",
            json!({"dispatch_id": id, "reason": reason}),
        ),
    };
    let reference = refs.next();
    let frame = Frame {
        join_ref: Some(join_ref.to_string()),
        reference: Some(reference.clone()),
        topic: topic.to_string(),
        event: event.into(),
        payload,
    };
    pending.insert(reference, outgoing);
    // Whether it was written; a failed write means the connection is gone.
    sink.send(Message::text(frame.encode())).await.is_ok()
}

fn reply(
    model: &Shared,
    unsent: &mut Vec<Outgoing>,
    pending: &mut HashMap<String, Outgoing>,
    frame: &Frame,
) {
    let Some(outgoing) = frame.reference.as_ref().and_then(|r| pending.remove(r)) else {
        return;
    };
    // Answered either way: a refused message is not sent again.
    unsent.retain(|o| o != &outgoing);

    if frame.payload["status"] == "ok" && matches!(outgoing, Outgoing::Watch { .. }) {
        lock(model).apply_dispatch(&frame.payload["response"], true);
    }
    if frame.payload["status"] != "ok" {
        let reason = frame.payload["response"]["reason"]
            .as_str()
            .unwrap_or("refused");
        let what = match outgoing {
            Outgoing::Say { .. } => "Not sent",
            Outgoing::CancelTurn | Outgoing::CancelDispatch { .. } => "Nothing to cancel",
            Outgoing::Watch { .. } | Outgoing::Unwatch => "Dispatch unavailable",
        };
        lock(model).note(format!("{what}: {}", describe(reason)));
    }
}

fn describe(reason: &str) -> String {
    match reason {
        "message_too_large" => "the message is over 32 KiB".into(),
        "empty_message" => "the message is empty".into(),
        "no_turn" => "the coordinator is not in a turn".into(),
        other => other.to_string(),
    }
}

fn lost(reason: &str, joined: bool) -> Ended {
    Ended::Lost {
        reason: reason.to_string(),
        joined,
    }
}

fn short_error(error: &str) -> String {
    error.chars().take(80).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn connection_reasons_clean_service_text_and_keep_readable_words() {
        let model = Arc::new(Mutex::new(Model::new("s1")));
        set(
            &model,
            Connection::Reconnecting("refused\u{1b}[2J readable".into()),
        );
        assert_eq!(
            lock(&model).connection,
            Connection::Reconnecting("refused readable".into())
        );
        set(&model, Connection::Refused("bad\u{1b}[31m token".into()));
        assert_eq!(
            lock(&model).connection,
            Connection::Refused("bad token".into())
        );
    }
}
