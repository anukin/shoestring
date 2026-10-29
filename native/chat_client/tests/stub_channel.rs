//! The client's connection against a stub Phoenix channel on loopback: no
//! service, provider or network.

// tungstenite's handshake callback returns its large `ErrorResponse`.
#![allow(clippy::result_large_err)]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};

use shoestring_chat::connection::{self, Config, Outgoing, Shared, lock};
use shoestring_chat::model::{Connection, Model};
use shoestring_chat::protocol::Frame;

type Socket = WebSocketStream<TcpStream>;

const TOPIC: &str = "conversation:s1";

async fn accept(listener: &TcpListener) -> (Socket, String) {
    let (stream, _) = listener.accept().await.unwrap();
    let (uri_tx, mut uri_rx) = mpsc::unbounded_channel();
    let socket = tokio_tungstenite::accept_hdr_async(
        stream,
        move |request: &Request, response: Response| {
            uri_tx.send(request.uri().to_string()).unwrap();
            Ok(response)
        },
    )
    .await
    .unwrap();
    (socket, uri_rx.recv().await.unwrap())
}

/// The next frame on the conversation's topic, skipping heartbeats.
async fn next(socket: &mut Socket) -> Frame {
    loop {
        let message = tokio::time::timeout(Duration::from_secs(5), socket.next())
            .await
            .expect("a frame within 5 s")
            .expect("an open socket")
            .unwrap();
        if let Message::Text(text) = message {
            let frame = Frame::decode(&text).unwrap();
            if frame.topic == TOPIC {
                return frame;
            }
        }
    }
}

async fn push(socket: &mut Socket, event: &str, payload: Value) {
    let frame = Frame {
        join_ref: Some("1".into()),
        reference: None,
        topic: TOPIC.into(),
        event: event.into(),
        payload,
    };
    socket.send(Message::text(frame.encode())).await.unwrap();
}

async fn reply(socket: &mut Socket, to: &Frame, status: &str, response: Value) {
    let frame = Frame {
        join_ref: to.join_ref.clone(),
        reference: to.reference.clone(),
        topic: TOPIC.into(),
        event: "phx_reply".into(),
        payload: json!({"status": status, "response": response}),
    };
    socket.send(Message::text(frame.encode())).await.unwrap();
}

fn said(sequence: u64, text: &str) -> Value {
    json!({"sequence": sequence, "type": "conversation.message.coordinator", "payload": {"text": text}})
}

async fn until(model: &Shared, check: impl Fn(&Model) -> bool) {
    for _ in 0..500 {
        if check(&lock(model)) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("condition not reached: {:?}", lock(model).entries);
}

fn start(
    port: u16,
) -> (
    Shared,
    mpsc::UnboundedSender<Outgoing>,
    tokio::task::JoinHandle<()>,
) {
    let model: Shared = Arc::new(Mutex::new(Model::new("s1")));
    let (outbox, inbox) = mpsc::unbounded_channel();
    let config = Config {
        url: format!("ws://127.0.0.1:{port}/chat/socket"),
        session: "s1".into(),
        token: "tok+en".into(),
    };
    let task = tokio::spawn(connection::run(config, model.clone(), inbox));
    (model, outbox, task)
}

#[tokio::test]
async fn joins_after_the_last_sequence_and_shows_nothing_twice_across_a_reconnect() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (model, _outbox, task) = start(listener.local_addr().unwrap().port());

    let (mut first, uri) = accept(&listener).await;
    assert!(
        uri.contains("session=s1") && uri.contains("token=tok%2Ben") && uri.contains("vsn=2.0.0")
    );
    let join = next(&mut first).await;
    assert_eq!(join.event, "phx_join");
    assert_eq!(join.payload["after"], 0);
    reply(&mut first, &join, "ok", json!({})).await;
    push(
        &mut first,
        "events",
        json!({"events": [said(1, "one"), said(2, "two")]}),
    )
    .await;
    until(&model, |m| {
        m.entries.len() == 2 && m.connection == Connection::Live
    })
    .await;
    drop(first);

    let (mut second, _) = accept(&listener).await;
    let join = next(&mut second).await;
    assert_eq!(join.payload["after"], 2);
    reply(&mut second, &join, "ok", json!({})).await;
    push(
        &mut second,
        "events",
        json!({"events": [said(2, "two"), said(3, "three")]}),
    )
    .await;
    until(&model, |m| m.last_sequence == 3).await;

    let texts: Vec<String> = lock(&model)
        .entries
        .iter()
        .map(|e| e.text.clone())
        .collect();
    assert_eq!(texts, vec!["one", "two", "three"]);
    task.abort();
}

#[tokio::test]
async fn an_unanswered_message_is_sent_again_with_its_id_and_a_cancel_is_not() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (_model, outbox, task) = start(listener.local_addr().unwrap().port());

    let (mut first, _) = accept(&listener).await;
    let join = next(&mut first).await;
    reply(&mut first, &join, "ok", json!({})).await;

    outbox
        .send(Outgoing::Say {
            message_id: "m-1".into(),
            text: "hello".into(),
        })
        .unwrap();
    outbox.send(Outgoing::CancelTurn).unwrap();
    outbox
        .send(Outgoing::CancelDispatch {
            id: "d1".into(),
            reason: "person".into(),
        })
        .unwrap();
    let say = next(&mut first).await;
    assert_eq!(
        (say.event.as_str(), &say.payload["message_id"]),
        ("say", &json!("m-1"))
    );
    assert_eq!(next(&mut first).await.event, "cancel_turn");
    let cancel = next(&mut first).await;
    assert_eq!(cancel.event, "cancel_dispatch");
    assert_eq!(cancel.payload["dispatch_id"], "d1");
    drop(first);

    let (mut second, _) = accept(&listener).await;
    let join = next(&mut second).await;
    reply(&mut second, &join, "ok", json!({})).await;
    let again = next(&mut second).await;
    assert_eq!(again.event, "say");
    assert_eq!(again.payload, json!({"message_id": "m-1", "text": "hello"}));
    reply(&mut second, &again, "ok", json!({})).await;

    // Answered now: a third connection sends nothing.
    tokio::time::sleep(Duration::from_millis(100)).await;
    drop(second);
    let (mut third, _) = accept(&listener).await;
    let join = next(&mut third).await;
    reply(&mut third, &join, "ok", json!({})).await;
    let quiet = tokio::time::timeout(Duration::from_millis(300), third.next()).await;
    assert!(
        quiet.is_err(),
        "nothing is resent after its reply: {quiet:?}"
    );
    task.abort();
}

#[tokio::test]
async fn a_refused_reply_is_shown_and_not_retried() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (model, outbox, task) = start(listener.local_addr().unwrap().port());

    let (mut socket, _) = accept(&listener).await;
    let join = next(&mut socket).await;
    reply(&mut socket, &join, "ok", json!({})).await;
    outbox
        .send(Outgoing::Say {
            message_id: "m-2".into(),
            text: "x".repeat(10),
        })
        .unwrap();
    let say = next(&mut socket).await;
    reply(
        &mut socket,
        &say,
        "error",
        json!({"reason": "message_too_large"}),
    )
    .await;

    until(&model, |m| {
        m.notice.as_deref() == Some("Not sent: the message is over 32 KiB")
    })
    .await;
    task.abort();
}

#[tokio::test]
async fn a_refused_token_stops_reconnecting() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (model, _outbox, task) = start(listener.local_addr().unwrap().port());

    let (stream, _) = listener.accept().await.unwrap();
    let _ = tokio_tungstenite::accept_hdr_async(stream, |_: &Request, _: Response| {
        Err::<Response, ErrorResponse>(
            tokio_tungstenite::tungstenite::http::Response::builder()
                .status(403)
                .body(None)
                .unwrap(),
        )
    })
    .await;

    tokio::time::timeout(Duration::from_secs(5), task)
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(&lock(&model).connection, Connection::Refused(why) if why.contains("token")));
}

#[tokio::test]
async fn a_join_for_a_missing_conversation_is_refused_for_good() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (model, _outbox, task) = start(listener.local_addr().unwrap().port());

    let (mut socket, _) = accept(&listener).await;
    let join = next(&mut socket).await;
    reply(
        &mut socket,
        &join,
        "error",
        json!({"reason": "no_conversation"}),
    )
    .await;

    tokio::time::timeout(Duration::from_secs(5), task)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        lock(&model).connection,
        Connection::Refused("join refused: no_conversation".into())
    );
}

#[tokio::test]
async fn rewatch_open_detail_after_reconnect_and_receive_live_steps() {
    use shoestring_chat::model::Detail;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (model, outbox, task) = start(listener.local_addr().unwrap().port());
    let (mut first, _) = accept(&listener).await;
    let join = next(&mut first).await;
    reply(&mut first, &join, "ok", json!({})).await;
    until(&model, |m| m.connection == Connection::Live).await;
    lock(&model).detail = Some(Detail {
        id: "d1".into(),
        ..Detail::default()
    });
    outbox.send(Outgoing::Watch { id: "d1".into() }).unwrap();
    let watch = next(&mut first).await;
    assert_eq!(watch.event, "watch_dispatch");
    reply(
        &mut first,
        &watch,
        "ok",
        json!({"dispatch_id": "d1", "lines": ["state: running"],
        "steps": {"last_sequence": 1, "entries": [{"sequence": 1, "line": "started"}]}}),
    )
    .await;
    until(&model, |m| m.detail.as_ref().unwrap().steps.len() == 1).await;
    drop(first);
    let (mut second, _) = accept(&listener).await;
    let join = next(&mut second).await;
    reply(&mut second, &join, "ok", json!({})).await;
    let watch = next(&mut second).await;
    assert_eq!(watch.event, "watch_dispatch");
    assert_eq!(watch.payload["dispatch_id"], "d1");
    reply(
        &mut second,
        &watch,
        "ok",
        json!({"dispatch_id": "d1", "lines": ["state: running"],
        "steps": {"last_sequence": 1, "entries": [{"sequence": 1, "line": "started"}]}}),
    )
    .await;
    push(
        &mut second,
        "dispatch",
        json!({"dispatch_id": "d1", "lines": ["checks: passed"],
        "steps": {"last_sequence": 2, "entries": [{"sequence": 2, "line": "checked"}]}}),
    )
    .await;
    until(&model, |m| m.detail.as_ref().unwrap().steps.len() == 2).await;
    assert_eq!(
        lock(&model).detail.as_ref().unwrap().steps,
        vec!["started", "checked"]
    );
    task.abort();
}
