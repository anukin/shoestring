//! What the screen shows, folded from the channel's `events` and `state`
//! pushes (`docs/chat-channel.md`). Every string from the service is
//! cleaned here, once, before anything can draw it.

use serde_json::Value;

use crate::editor::Editor;
use crate::text::{clean, clean_line};

#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    You,
    Coordinator,
    Tool,
    Inbox,
    Notice,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub kind: Kind,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Dispatch {
    pub id: String,
    pub purpose: String,
    pub worker: String,
    pub title: String,
    pub state: String,
    pub reviewer: String,
    pub elapsed: u64,
    pub waiting_until: String,
    pub latest_step: String,
    pub next: String,
    pub run_id: String,
    pub terminal: String,
}

#[derive(Debug, Clone, Default)]
pub struct Detail {
    pub id: String,
    pub lines: Vec<String>,
    pub steps: Vec<String>,
    pub last_sequence: u64,
    pub terminal: Option<String>,
    pub scroll: usize,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub enum Connection {
    #[default]
    Connecting,
    Live,
    Reconnecting(String),
    Refused(String),
}

#[derive(Debug, Clone, Default)]
pub struct Model {
    pub session: String,
    pub coordinator: Option<String>,
    pub entries: Vec<Entry>,
    pub last_sequence: u64,
    pub engine: String,
    pub pending: u64,
    pub hold: Option<String>,
    pub turns: Option<(u64, u64)>,
    pub dispatches: Vec<Dispatch>,
    pub capacity: Vec<String>,
    pub connection: Connection,
    pub notice: Option<String>,
    pub editor: Editor,
    pub agents_focus: bool,
    pub selected: Option<String>,
    pub detail: Option<Detail>,
    pub confirm: Option<Dispatch>,
    pub help: bool,
    pub dirty: bool,
    pub quit: bool,
}

impl Model {
    pub fn new(session: &str) -> Model {
        Model {
            session: clean_line(session),
            engine: "unknown".into(),
            dirty: true,
            ..Model::default()
        }
    }

    /// An `events` push. A sequence already seen is dropped, so a resumed
    /// or repeated delivery shows nothing twice.
    pub fn apply_events(&mut self, payload: &Value) {
        for event in payload["events"].as_array().into_iter().flatten() {
            let Some(sequence) = event["sequence"].as_u64() else {
                continue;
            };
            if sequence <= self.last_sequence {
                continue;
            }
            self.last_sequence = sequence;
            self.apply_event(
                event["type"].as_str().unwrap_or_default(),
                &event["payload"],
            );
        }
        self.dirty = true;
    }

    fn apply_event(&mut self, kind: &str, payload: &Value) {
        let text = |key: &str| payload[key].as_str().unwrap_or_default();

        match kind {
            "conversation.opened" => {
                self.coordinator = Some(clean_line(&format!(
                    "{}:{}",
                    text("provider"),
                    text("model")
                )))
            }
            "conversation.message.human" => self.push(Kind::You, clean(text("text"))),
            "conversation.message.coordinator" => self.push(Kind::Coordinator, clean(text("text"))),
            "conversation.tool.called" => {
                let tool = text("tool");
                let tool = tool.rsplit("__").next().unwrap_or(tool);
                self.push(Kind::Tool, format!("↳ {}", clean_line(tool)))
            }
            "conversation.tool.returned" if payload["is_error"] == true => {
                self.push(Kind::Tool, "↳ the tool refused or failed".into())
            }
            "conversation.turn.ended" => {
                if let Some(line) = turn_ended(text("status"), text("reason")) {
                    self.push(Kind::Notice, line)
                }
            }
            "conversation.turn.held" => self.push(
                Kind::Notice,
                held(text("reason"), payload["defer_until"].as_str()),
            ),
            "conversation.inbox.recorded" => self.push(
                Kind::Inbox,
                clean_line(&format!(
                    "◆ {} {} \"{}\" on {} is now {}",
                    short(text("dispatch_id")),
                    text("purpose"),
                    text("title"),
                    text("worker"),
                    text("state")
                )),
            ),
            _ => {}
        }
    }

    fn push(&mut self, kind: Kind, text: String) {
        self.entries.push(Entry { kind, text });
    }

    /// A `state` push: the service's view of the engine, grant, dispatches
    /// and capacity.
    pub fn apply_state(&mut self, state: &Value) {
        let engine = &state["engine"];
        self.engine = clean_line(engine["state"].as_str().unwrap_or("unknown"));
        self.pending = engine["pending_messages"].as_u64().unwrap_or(0)
            + engine["pending_inbox"].as_u64().unwrap_or(0);
        self.hold = engine["hold"].as_str().map(clean_line);

        self.turns = state["grant"]["turns"]["used"]
            .as_u64()
            .zip(state["grant"]["turns"]["left"].as_u64());

        self.dispatches = state["dispatches"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|d| Dispatch {
                id: clean_line(d["dispatch_id"].as_str().unwrap_or("?")),
                purpose: clean_line(d["purpose"].as_str().unwrap_or("?")),
                worker: clean_line(d["worker"].as_str().unwrap_or("?")),
                title: clean_line(d["title"].as_str().unwrap_or_default()),
                state: clean_line(d["state"].as_str().unwrap_or("?")),
                reviewer: clean_line(d["reviewer"].as_str().unwrap_or("none")),
                elapsed: d["elapsed_seconds"].as_u64().unwrap_or(0),
                waiting_until: clean_line(d["waiting_until"].as_str().unwrap_or_default()),
                latest_step: clean_line(d["latest_step"].as_str().unwrap_or_default()),
                next: clean_line(d["next"].as_str().unwrap_or_default()),
                run_id: clean_line(d["run_id"].as_str().unwrap_or_default()),
                terminal: clean_line(d["terminal"].as_str().unwrap_or_default()),
            })
            .collect();

        if !self
            .dispatches
            .iter()
            .any(|d| Some(&d.id) == self.selected.as_ref())
        {
            self.selected = self.dispatches.first().map(|d| d.id.clone());
        }
        self.capacity = state["capacity"]["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(capacity)
            .collect();

        self.dirty = true;
    }

    pub fn select(&mut self, delta: isize) {
        if self.dispatches.is_empty() {
            self.selected = None;
            return;
        }
        let current = self
            .dispatches
            .iter()
            .position(|d| Some(&d.id) == self.selected.as_ref())
            .unwrap_or(0);
        let index = current
            .saturating_add_signed(delta)
            .min(self.dispatches.len() - 1);
        self.selected = Some(self.dispatches[index].id.clone());
    }

    pub fn apply_dispatch(&mut self, payload: &Value, reset: bool) {
        let Some(detail) = &mut self.detail else {
            return;
        };
        if payload["dispatch_id"].as_str() != Some(detail.id.as_str()) {
            return;
        }
        detail.lines = payload["lines"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(clean))
            .collect();
        detail.terminal = payload["terminal"].as_str().map(clean_line);
        if reset {
            detail.steps.clear();
            detail.last_sequence = 0;
        }
        let steps = &payload["steps"];
        // Call histories have no sequence: they are complete snapshots.
        if steps["last_sequence"].is_null() {
            detail.steps.clear();
        }
        if let Some(omitted) = steps["omitted"].as_u64().filter(|n| *n > 0) {
            detail
                .steps
                .push(format!("… {omitted} earlier entries omitted"));
        }
        for entry in steps["entries"].as_array().into_iter().flatten() {
            let sequence = entry["sequence"].as_u64();
            if sequence.is_none_or(|n| n > detail.last_sequence) {
                detail
                    .steps
                    .push(clean(entry["line"].as_str().unwrap_or_default()));
            }
            if let Some(n) = sequence {
                detail.last_sequence = detail.last_sequence.max(n);
            }
        }
        if let Some(n) = steps["last_sequence"].as_u64() {
            detail.last_sequence = detail.last_sequence.max(n);
        }
        let excess = detail.steps.len().saturating_sub(500);
        detail.steps.drain(..excess);
        self.dirty = true;
    }

    pub fn note(&mut self, text: impl Into<String>) {
        self.notice = Some(clean_line(&text.into()));
        self.dirty = true;
    }

    /// What `/status` prints into the conversation, from service state only.
    pub fn status_entry(&mut self) {
        let turns = match self.turns {
            Some((used, left)) => format!("{used} turns used, {left} left"),
            None => "no grant".into(),
        };
        let line = format!(
            "status: coordinator {}, {}; {} waiting; {}; {} dispatches",
            self.coordinator.as_deref().unwrap_or("?"),
            self.engine,
            self.pending,
            turns,
            self.dispatches.len()
        );
        self.push(Kind::Notice, line);
        self.dirty = true;
    }
}

pub fn short(id: &str) -> String {
    id.chars().take(8).collect()
}

fn turn_ended(status: &str, reason: &str) -> Option<String> {
    let reason = if reason.is_empty() {
        String::new()
    } else {
        format!(" ({})", clean_line(reason))
    };
    match status {
        "completed" => None,
        "interrupted" => Some("The turn was interrupted.".into()),
        "failed" => Some(format!("The turn failed{reason}.")),
        "uncertain" => Some(format!(
            "The turn's end was not seen{reason}; it may have reached the coordinator and is not sent again."
        )),
        "unsent" => Some(format!(
            "The turn was not sent{reason}; send the message again."
        )),
        other => Some(format!("The turn ended: {}{reason}.", clean_line(other))),
    }
}

fn held(reason: &str, until: Option<&str>) -> String {
    let why = match reason {
        "no_grant" => "the session has no grant (shoestring grant)".to_string(),
        "turns_exhausted" => {
            "the grant's turns are used up (shoestring grants extend --turns N)".to_string()
        }
        other => clean_line(other),
    };
    match until {
        Some(until) => format!("Waiting: {why}, until {}.", clean_line(until)),
        None => format!("Waiting: {why}."),
    }
}

fn capacity(provider: &Value) -> Option<String> {
    let name = clean_line(provider["provider"].as_str()?);
    let window = provider["windows"]
        .as_array()?
        .iter()
        .find(|w| w["kind"] == "five_hour")?;
    let used = window["used_percent"].as_f64()?;
    Some(format!("{name} 5h {used:.0}%"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn event(sequence: u64, kind: &str, payload: Value) -> Value {
        json!({"sequence": sequence, "type": kind, "payload": payload})
    }

    #[test]
    fn detail_filters_text_deduplicates_steps_and_ignores_stale_dispatches() {
        let mut model = Model::new("s1");
        model.detail = Some(Detail {
            id: "d1".into(),
            ..Detail::default()
        });
        let data = json!({"dispatch_id": "d1", "lines": ["checks: ok\u{1b}[2J"],
            "terminal": "/runs/r1/terminal\u{1b}[0m", "steps": {"last_sequence": 2,
            "entries": [{"sequence": 1, "line": "read\u{1b}[31m file"}, {"sequence": 2, "line": "checked"}]}});
        model.apply_dispatch(&data, true);
        model.apply_dispatch(&data, false);
        model.apply_dispatch(&json!({"dispatch_id": "d2", "lines": ["wrong"]}), true);
        let detail = model.detail.unwrap();
        assert_eq!(detail.lines, vec!["checks: ok"]);
        assert_eq!(detail.steps, vec!["read file", "checked"]);
        assert_eq!(detail.terminal.as_deref(), Some("/runs/r1/terminal"));
    }

    #[test]
    fn events_fold_once_in_order_and_repeats_are_dropped() {
        let mut model = Model::new("s1");
        let batch = json!({"events": [
            event(1, "conversation.opened", json!({"provider": "claude", "model": "opus"})),
            event(2, "conversation.message.human", json!({"text": "fix it"})),
            event(3, "conversation.tool.called", json!({"tool": "mcp__shoestring__dispatch"})),
            event(4, "conversation.message.coordinator", json!({"text": "Dispatched."})),
        ]});
        model.apply_events(&batch);
        model.apply_events(&batch);
        model.apply_events(&json!({"events": [
            event(4, "conversation.message.coordinator", json!({"text": "Dispatched."})),
            event(5, "conversation.turn.ended", json!({"status": "uncertain", "reason": "service_restarted"})),
        ]}));

        assert_eq!(model.coordinator.as_deref(), Some("claude:opus"));
        assert_eq!(model.last_sequence, 5);
        let texts: Vec<&str> = model.entries.iter().map(|e| e.text.as_str()).collect();
        assert_eq!(texts.len(), 4);
        assert_eq!(texts[0], "fix it");
        assert_eq!(texts[1], "↳ dispatch");
        assert_eq!(texts[2], "Dispatched.");
        assert!(texts[3].contains("not sent again"));
    }

    #[test]
    fn service_text_is_cleaned_before_it_is_kept() {
        let mut model = Model::new("s1");
        model.apply_events(&json!({"events": [event(
            1,
            "conversation.message.coordinator",
            json!({"text": "\u{1b}[2J\u{1b}[HApprove? [y/N] \u{1b}[31mok"})
        )]}));
        assert_eq!(model.entries[0].text, "Approve? [y/N] ok");
        assert_eq!(model.entries[0].kind, Kind::Coordinator);
    }

    #[test]
    fn state_sets_engine_grant_dispatches_and_capacity() {
        let mut model = Model::new("s1");
        model.apply_state(&json!({
            "engine": {"state": "idle", "pending_messages": 1, "pending_inbox": 1, "hold": "turns_exhausted"},
            "grant": {"turns": {"used": 20, "left": 0}},
            "dispatches": [{"dispatch_id": "d-41aaaaaa-1", "purpose": "explore", "worker": "codex:m",
                            "title": "Find\u{1b}[0m it", "state": "running", "reviewer": "claude\u{1b}[31m:opus",
                            "latest_step": "read\u{1b}[2J file", "waiting_until": "tomorrow\u{1b}[0m", "next": "wait\u{1b}[0m"}],
            "capacity": {"providers": [
                {"provider": "claude", "windows": [{"kind": "five_hour", "used_percent": 41.2}]},
                {"provider": "opencode"}
            ]}
        }));
        assert_eq!(model.engine, "idle");
        assert_eq!(model.pending, 2);
        assert_eq!(model.hold.as_deref(), Some("turns_exhausted"));
        assert_eq!(model.turns, Some((20, 0)));
        assert_eq!(model.dispatches[0].title, "Find it");
        assert_eq!(model.dispatches[0].reviewer, "claude:opus");
        assert_eq!(model.dispatches[0].latest_step, "read file");
        assert_eq!(model.dispatches[0].waiting_until, "tomorrow");
        assert_eq!(model.dispatches[0].next, "wait");
        assert_eq!(model.capacity, vec!["claude 5h 41%".to_string()]);
    }

    #[test]
    fn holds_and_inbox_entries_read_plainly() {
        let mut model = Model::new("s1");
        model.apply_events(&json!({"events": [
            event(1, "conversation.turn.held", json!({"reason": "turns_exhausted"})),
            event(2, "conversation.inbox.recorded", json!({
                "dispatch_id": "0123456789", "purpose": "implement", "title": "Fix", "worker": "codex:m", "state": "completed"
            })),
        ]}));
        assert!(model.entries[0].text.contains("grants extend --turns"));
        assert_eq!(
            model.entries[1].text,
            "◆ 01234567 implement \"Fix\" on codex:m is now completed"
        );
    }
}
