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
    /// What a handoff carried over from the previous conversation.
    Handoff,
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
    /// The session agent it is for (its slug), or empty.
    pub agent: String,
    pub worker: String,
    pub title: String,
    pub state: String,
    pub reviewer: String,
    pub elapsed: Option<u64>,
    pub waiting_until: String,
    pub latest_step: String,
    pub next: String,
    pub run_id: String,
    pub terminal: String,
}

/// A lesson approved in the session's repository (`docs/chat-channel.md`).
#[derive(Debug, Clone, PartialEq)]
pub struct Lesson {
    pub code: String,
    pub text: String,
    pub proposed_by: String,
    pub approved_by: String,
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
    /// The conversation `last_sequence` counts in; a handoff starts another.
    pub conversation_id: Option<String>,
    /// Remove the old note only after it appears in the successor's block.
    pub handoff_note_start: Option<usize>,
    pub coordinator: Option<String>,
    pub entries: Vec<Entry>,
    pub last_sequence: u64,
    pub engine: String,
    pub pending: u64,
    pub hold: Option<String>,
    pub turns: Option<(u64, u64)>,
    /// Visible conversation text used and its limit, in bytes.
    pub context: Option<(u64, u64)>,
    pub dispatches: Vec<Dispatch>,
    pub capacity: Vec<String>,
    pub connection: Connection,
    pub notice: Option<String>,
    pub editor: Editor,
    pub agents_focus: bool,
    pub selected: Option<String>,
    pub detail: Option<Detail>,
    pub confirm: Option<Dispatch>,
    /// A held dispatch the person is asked to start.
    pub start: Option<Dispatch>,
    /// The session's team, as `/team` prints it: its name and one line per agent.
    pub team: Option<(String, Vec<String>)>,
    pub help: bool,
    /// Lessons approved since this screen opened, shown one at a time; the
    /// ones approved before it opened are on the Lessons page.
    pub lessons: std::collections::VecDeque<Lesson>,
    pub lessons_seen: std::collections::HashSet<String>,
    pub lessons_loaded: bool,
    /// A lesson the person is asked to confirm retiring.
    pub retire: Option<Lesson>,
    /// The web UI's address, from the service.
    pub web_url: Option<String>,
    /// A page to open in the default browser, taken by the input loop.
    pub open: Option<String>,
    /// The highlighted entry of the `/` menu.
    pub slash_selected: usize,
    /// The conversation's first shown row while scrolled back; None follows
    /// the latest.
    pub scroll_top: Option<usize>,
    /// The conversation as last drawn: its last possible first row, and its
    /// height.
    pub conversation_view: ConversationView,
    pub dirty: bool,
    pub quit: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct ConversationView {
    pub last_top: usize,
    pub height: usize,
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

    /// Scrolls the conversation back (negative) or forward by `pages`; at
    /// the end it follows the latest again.
    pub fn scroll_conversation(&mut self, pages: isize) {
        let view = self.conversation_view;
        let page = view.height.saturating_sub(1).max(1);
        let top = self.scroll_top.unwrap_or(view.last_top);
        let top = if pages < 0 {
            top.saturating_sub(page * pages.unsigned_abs())
        } else {
            top.saturating_add(page * pages as usize)
        };
        self.scroll_top = (top < view.last_top).then_some(top);
    }

    /// The join reply named the session's current conversation. Another than
    /// the one shown means it was handed off while away: the service sends
    /// the new one from its first event.
    pub fn joined(&mut self, conversation_id: &str) {
        let id = clean_line(conversation_id);
        if self
            .conversation_id
            .as_ref()
            .is_some_and(|known| *known != id)
        {
            self.last_sequence = 0;
            self.push(
                Kind::Notice,
                "This session continued in a fresh conversation (a handoff) while you were away."
                    .into(),
            );
            self.dirty = true;
        }
        self.conversation_id = Some(id);
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
            "conversation.handoff.requested" => {
                self.handoff_note_start = (payload["note"] == true).then_some(self.entries.len());
                self.push(
                    Kind::Notice,
                    if payload["note"] == true {
                        "Handing off: the coordinator is writing its note for a fresh conversation."
                    } else {
                        "Handing off: the fresh conversation gets Shoestring's facts only."
                    }
                    .into(),
                )
            }
            "conversation.handed_off" => {
                // The successor's events follow, numbered from its first.
                self.last_sequence = 0;
                self.conversation_id = Some(clean_line(text("successor_id")));
                self.push(
                    Kind::Notice,
                    "Handed off: this session continues in a fresh conversation, with the same grant and agents."
                        .into(),
                )
            }
            "conversation.handoff.received" => {
                if let Some(start) = self.handoff_note_start.take()
                    && payload["note"].is_string()
                {
                    let mut index = 0;
                    self.entries.retain(|entry| {
                        let keep = index < start || entry.kind != Kind::Coordinator;
                        index += 1;
                        keep
                    });
                }
                let note = match payload["note"].as_str() {
                    Some(note) => format!("The previous coordinator's note:\n{}", clean(note)),
                    None => format!(
                        "The previous coordinator wrote no note ({}).",
                        clean_line(text("note_status"))
                    ),
                };
                self.push(
                    Kind::Handoff,
                    format!(
                        "Carried over from the previous conversation (the coordinator reads this with your next message):\n{}\n\n{note}",
                        clean(text("facts"))
                    ),
                )
            }
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
        self.context = engine["context"]["used"]
            .as_u64()
            .zip(engine["context"]["limit"].as_u64())
            .filter(|(_, limit)| *limit > 0);

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
                agent: clean_line(d["agent"].as_str().unwrap_or_default()),
                worker: clean_line(d["worker"].as_str().unwrap_or("?")),
                title: clean_line(d["title"].as_str().unwrap_or_default()),
                state: clean_line(d["state"].as_str().unwrap_or("?")),
                reviewer: clean_line(d["reviewer"].as_str().unwrap_or("none")),
                elapsed: d["elapsed_seconds"].as_u64(),
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
        self.team = team(&state["grant"]["team"]);
        self.web_url = state["web_url"].as_str().map(clean_line);
        self.apply_lessons(&state["lessons"]);
        self.capacity = state["capacity"]["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(capacity)
            .collect();

        self.dirty = true;
    }

    /// New approved lessons queue a popup each; those present when the
    /// screen first loads are only marked seen.
    fn apply_lessons(&mut self, lessons: &Value) {
        for lesson in lessons.as_array().into_iter().flatten() {
            let text = |key: &str| lesson[key].as_str().unwrap_or_default();
            let code = clean_line(text("code"));
            if code.is_empty() || !self.lessons_seen.insert(code.clone()) {
                continue;
            }
            if self.lessons_loaded {
                self.lessons.push_back(Lesson {
                    code,
                    text: clean(text("text")),
                    proposed_by: clean_line(text("proposed_by")),
                    approved_by: clean_line(text("approved_by")),
                });
            }
        }
        self.lessons_loaded = true;
    }

    /// Asks the browser to open the web UI at `path`, or says why it cannot.
    pub fn open_web(&mut self, path: &str) {
        match &self.web_url {
            Some(url) => self.open = Some(format!("{}{path}", url.trim_end_matches('/'))),
            None => self.note("The web UI's address is not known yet"),
        }
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

    /// Asks to confirm cancelling dispatch `id`, or says why there is
    /// nothing to cancel.
    pub fn ask_cancel(&mut self, id: Option<&String>) {
        let Some(dispatch) = self.dispatches.iter().find(|d| Some(&d.id) == id).cloned() else {
            return;
        };
        if cancellable(&dispatch.state) {
            self.confirm = Some(dispatch);
        } else {
            self.note(format!(
                "{} is already {}; nothing to cancel",
                short(&dispatch.id),
                dispatch.state
            ));
        }
    }

    /// Asks to start held dispatch `id`, or says why there is nothing to start.
    pub fn ask_start(&mut self, id: Option<&String>) {
        let Some(dispatch) = self.dispatches.iter().find(|d| Some(&d.id) == id).cloned() else {
            return;
        };
        if dispatch.state == "held" {
            self.start = Some(dispatch);
        } else {
            self.note(format!(
                "{} is {}; only a held dispatch waits for you to start it",
                short(&dispatch.id),
                dispatch.state
            ));
        }
    }

    /// What `/team` prints into the conversation: the session's agents.
    pub fn team_entry(&mut self) {
        match self.team.clone() {
            Some((name, lines)) => {
                self.push(Kind::Notice, format!("team {name}:"));
                for line in lines {
                    self.push(Kind::Notice, format!("  {line}"));
                }
            }
            None => self.push(
                Kind::Notice,
                "this session started without a team; its dispatches name a worker".into(),
            ),
        }
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
        let context = match self.context_percent() {
            Some(percent) => format!("context {percent}% used"),
            None => "context unknown".into(),
        };
        let line = format!(
            "status: coordinator {}, {}; {} waiting; {}; {context}; {} dispatches",
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

impl Model {
    /// How much of the conversation's text limit is used, rounded down.
    pub fn context_percent(&self) -> Option<u64> {
        self.context.map(|(used, limit)| used * 100 / limit)
    }
}

/// Whether a dispatch in `state` can still be cancelled: anything not yet
/// finished. A finished one is never offered for cancelling.
pub fn cancellable(state: &str) -> bool {
    !matches!(
        state,
        "completed" | "failed" | "failed_to_start" | "cancelled"
    )
}

/// What a person calls the job a dispatch of `purpose` does.
pub fn job(purpose: &str) -> &'static str {
    match purpose {
        "explore" => "Explorer",
        "implement" => "Implementer",
        "review" => "Reviewer",
        _ => "Dispatch",
    }
}

/// The session's team from the grant's `team`, cleaned: its name and a line
/// per agent with its model and limit.
fn team(value: &Value) -> Option<(String, Vec<String>)> {
    let name = clean_line(value["team"].as_str()?);
    let lines = value["agents"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|agent| {
            let kind = agent["kind"].as_str().unwrap_or("?");
            let limit = match (kind, agent["max_minutes"].as_u64()) {
                ("coordinator", _) => "limit: the grant's turns".to_string(),
                (_, Some(minutes)) => format!("at most {minutes} min a dispatch"),
                (_, None) => "no limit of its own".to_string(),
            };
            clean_line(&format!(
                "{} {} · {}:{} · {limit}",
                match kind {
                    "coordinator" => "Coordinator",
                    "explorer" => "Explorer",
                    "implementer" => "Implementer",
                    "reviewer" => "Reviewer",
                    _ => "Agent",
                },
                agent["slug"].as_str().unwrap_or("?"),
                agent["provider"].as_str().unwrap_or("?"),
                agent["model"].as_str().unwrap_or("?"),
            ))
        })
        .collect();
    Some((name, lines))
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
        "context_limit_reached" => {
            "this conversation has reached its text limit; /handoff continues it in a fresh one"
                .to_string()
        }
        "input_too_large" => "the pending input exceeds the turn limit".to_string(),
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
    fn a_handoff_shows_what_carries_over_and_counts_the_successor_from_its_first_event() {
        let mut model = Model::new("s1");
        model.joined("old");
        model.apply_events(&json!({"events": [
            event(1, "conversation.opened", json!({"provider": "claude", "model": "opus"})),
            event(6, "conversation.message.coordinator", json!({"text": "Earlier answer stays."})),
            event(7, "conversation.handoff.requested", json!({"note": true})),
            event(8, "conversation.message.coordinator", json!({"text": "Keep ids at 8 digits."})),
            event(9, "conversation.message.coordinator", json!({"text": "Keep checks hermetic."})),
            event(10, "conversation.handed_off", json!({"successor_id": "new"})),
        ]}));
        assert_eq!(model.last_sequence, 0);
        assert_eq!(model.conversation_id.as_deref(), Some("new"));
        model.apply_events(&json!({"events": [
            event(1, "conversation.opened", json!({"provider": "claude", "model": "opus"})),
            event(2, "conversation.handoff.received", json!({
                "facts": "Facts from Shoestring's records\u{1b}[2J: 3 of 4 dispatch attempts left",
                "note": "Keep ids at 8 digits.\n\nKeep checks hermetic.", "note_status": "written"})),
        ]}));
        assert_eq!(model.last_sequence, 2);
        let carried = model.entries.last().unwrap();
        assert_eq!(carried.kind, Kind::Handoff);
        assert!(carried.text.contains("3 of 4 dispatch attempts left"));
        assert!(carried.text.contains("note:\nKeep ids at 8 digits."));
        assert!(!carried.text.contains('\u{1b}'));
        assert_eq!(
            model
                .entries
                .iter()
                .filter(|entry| entry.kind == Kind::Coordinator)
                .count(),
            1
        );
        assert!(
            model
                .entries
                .iter()
                .any(|entry| entry.text == "Earlier answer stays.")
        );
        assert_eq!(
            model
                .entries
                .iter()
                .filter(|entry| entry.text.contains("Keep ids at 8 digits."))
                .count(),
            1
        );

        model.apply_events(&json!({"events": [event(3, "conversation.handoff.received",
            json!({"facts": "f", "note_status": "skipped:turns_exhausted"}))]}));
        assert!(
            model
                .entries
                .last()
                .unwrap()
                .text
                .contains("wrote no note (skipped:turns_exhausted)")
        );
    }

    #[test]
    fn rejoining_after_a_handoff_elsewhere_starts_the_new_conversation_from_its_first_event() {
        let mut model = Model::new("s1");
        model.joined("old");
        model.last_sequence = 40;
        model.joined("old");
        assert_eq!(model.last_sequence, 40);
        model.joined("new");
        assert_eq!(model.last_sequence, 0);
        assert!(model.entries.last().unwrap().text.contains("handoff"));
    }

    #[test]
    fn context_use_comes_from_the_engine_state() {
        let mut model = Model::new("s1");
        model.apply_state(
            &json!({"engine": {"state": "idle", "context": {"used": 950, "limit": 1000}}}),
        );
        assert_eq!(model.context_percent(), Some(95));
        model
            .apply_state(&json!({"engine": {"state": "idle", "context": {"used": 1, "limit": 0}}}));
        assert_eq!(model.context_percent(), None);
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
