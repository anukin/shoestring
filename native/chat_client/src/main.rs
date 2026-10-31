//! `shoestring-chat --url URL --session ID --token-file PATH`
//!
//! Started by `shoestring chat`, which creates or reattaches the
//! conversation and writes the token file first. Leaving (`/exit`, Ctrl+C or
//! a lost terminal) leaves the conversation and every agent running.

use std::io::{self, Read};
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crossterm::event::{
    DisableBracketedPaste, EnableBracketedPaste, Event, EventStream, KeyCode, KeyEvent,
    KeyEventKind, KeyModifiers,
};
use crossterm::terminal::{self, EnterAlternateScreen, LeaveAlternateScreen};
use futures_util::StreamExt;
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use tokio::sync::mpsc;

use shoestring_chat::connection::{self, Config, Outgoing, Shared, lock};
use shoestring_chat::editor::Command;
use shoestring_chat::model::{Connection, Detail, Model};
use shoestring_chat::ui;

const FRAME: Duration = Duration::from_millis(33);

fn main() -> ExitCode {
    let config = match config(std::env::args().skip(1).collect()) {
        Ok(config) => config,
        Err(message) => {
            eprintln!("{message}");
            return ExitCode::from(2);
        }
    };
    let session = config.session.clone();

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("Could not start: {error}");
            return ExitCode::FAILURE;
        }
    };

    match runtime.block_on(run(config)) {
        Ok(()) => {
            println!(
                "Left session {session}; the conversation and its agents keep running. \
                 Back to it: shoestring chat --session {session}"
            );
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("shoestring-chat: {error}");
            ExitCode::FAILURE
        }
    }
}

fn config(args: Vec<String>) -> Result<Config, String> {
    let usage = "usage: shoestring-chat --url URL --session ID --token-file PATH";
    let mut url = None;
    let mut session = None;
    let mut token_file = None;
    let mut args = args.into_iter();

    while let Some(flag) = args.next() {
        let value = args.next().ok_or(usage)?;
        match flag.as_str() {
            "--url" => url = Some(value),
            "--session" => session = Some(value),
            "--token-file" => token_file = Some(value),
            _ => return Err(usage.into()),
        }
    }

    let (Some(url), Some(session), Some(token_file)) = (url, session, token_file) else {
        return Err(usage.into());
    };
    let token = std::fs::read_to_string(&token_file)
        .map_err(|error| format!("Could not read the token file {token_file}: {error}"))?
        .trim()
        .to_string();

    Ok(Config {
        url,
        session,
        token,
    })
}

async fn run(config: Config) -> io::Result<()> {
    let model: Shared = Arc::new(Mutex::new(Model::new(&config.session)));
    let (outbox, inbox) = mpsc::unbounded_channel();

    terminal::enable_raw_mode()?;
    crossterm::execute!(io::stdout(), EnterAlternateScreen, EnableBracketedPaste)?;
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        restore();
        default_hook(info);
    }));

    let drawing = draw_thread(model.clone());
    let socket = tokio::spawn(connection::run(config, model.clone(), inbox));

    let result = input(&model, &outbox).await;

    drop(outbox);
    lock(&model).quit = true;
    let drawn = drawing.join();
    socket.abort();
    restore();

    result?;
    match drawn {
        Ok(drawn) => drawn,
        Err(_) => Err(io::Error::other("drawing stopped")),
    }
}

fn restore() {
    let _ = crossterm::execute!(io::stdout(), DisableBracketedPaste, LeaveAlternateScreen);
    let _ = terminal::disable_raw_mode();
}

// Drawing has its own thread and draws a copy of the model, so a terminal
// that stops accepting output blocks only this thread: input and the socket
// keep going, and frames are dropped until it drains.
fn draw_thread(model: Shared) -> thread::JoinHandle<io::Result<()>> {
    thread::spawn(move || {
        let mut terminal = Terminal::new(CrosstermBackend::new(io::stdout()))?;
        loop {
            let view = {
                let mut model = lock(&model);
                if model.quit {
                    return Ok(());
                }
                if model.dirty {
                    model.dirty = false;
                    Some(model.clone())
                } else {
                    None
                }
            };
            if let Some(view) = view {
                let mut drawn = Default::default();
                terminal.draw(|frame| drawn = ui::draw(frame, &view))?;
                // Scrolling needs the conversation as drawn; that is no
                // change to draw again.
                lock(&model).conversation_view = drawn;
            }
            thread::sleep(FRAME);
        }
    })
}

async fn input(model: &Shared, outbox: &mpsc::UnboundedSender<Outgoing>) -> io::Result<()> {
    let mut events = EventStream::new();

    while let Some(event) = events.next().await {
        let mut model = lock(model);
        model.dirty = true;

        match event? {
            Event::Key(key) if key.kind != KeyEventKind::Release => {
                if model.help {
                    model.help = false;
                    continue;
                }
                if key_pressed(&mut model, key, outbox) {
                    return Ok(());
                }
            }
            Event::Paste(text) => model.editor.paste(&text),
            _ => {}
        }
    }

    Ok(())
}

/// Applies one key; true when the person is leaving.
fn key_pressed(model: &mut Model, key: KeyEvent, outbox: &mpsc::UnboundedSender<Outgoing>) -> bool {
    let control = key.modifiers.contains(KeyModifiers::CONTROL);
    let alt = key.modifiers.contains(KeyModifiers::ALT);

    if control && key.code == KeyCode::Char('c') {
        return true;
    }
    if let Some(dispatch) = model.confirm.take() {
        if key.code == KeyCode::Char('y') {
            if model.connection == Connection::Live {
                let _ = outbox.send(Outgoing::CancelDispatch {
                    id: dispatch.id,
                    reason: "Cancelled by the person from the chat screen".into(),
                });
                model.note("Cancellation requested");
            } else {
                model.note("Disconnected; cancellation was not sent");
            }
        }
        return false;
    }
    if let Some(detail) = &mut model.detail {
        match key.code {
            KeyCode::Esc => {
                model.detail = None;
                let _ = outbox.send(Outgoing::Unwatch);
            }
            KeyCode::Up => detail.scroll = detail.scroll.saturating_sub(1),
            KeyCode::Down => detail.scroll = detail.scroll.saturating_add(1),
            KeyCode::Char('c') => {
                model.confirm = model.dispatches.iter().find(|d| d.id == detail.id).cloned();
            }
            _ => {}
        }
        return false;
    }
    // The `/` menu, while the input is one word starting with `/`: arrows
    // choose, Tab completes, Enter runs the highlighted command.
    let matches = model.editor.slash_matches();
    if !model.agents_focus && !matches.is_empty() {
        let selected = model.slash_selected.min(matches.len() - 1);
        match key.code {
            KeyCode::Up => {
                model.slash_selected = (selected + matches.len() - 1) % matches.len();
                return false;
            }
            KeyCode::Down => {
                model.slash_selected = (selected + 1) % matches.len();
                return false;
            }
            KeyCode::Tab => {
                model.editor.set(matches[selected].0);
                return false;
            }
            KeyCode::Enter if !alt && !key.modifiers.contains(KeyModifiers::SHIFT) => {
                model.editor.set(matches[selected].0)
            }
            _ => {}
        }
    }
    if key.code == KeyCode::Tab {
        model.agents_focus = !model.agents_focus;
        if model.selected.is_none() {
            model.select(0);
        }
        return false;
    }
    if model.agents_focus {
        match key.code {
            KeyCode::Up => model.select(-1),
            KeyCode::Down => model.select(1),
            KeyCode::Esc => model.agents_focus = false,
            KeyCode::Enter => {
                if let Some(id) = &model.selected {
                    model.detail = Some(Detail {
                        id: id.clone(),
                        ..Detail::default()
                    });
                    let _ = outbox.send(Outgoing::Watch { id: id.clone() });
                }
            }
            KeyCode::Char('c') => {
                model.confirm = model
                    .dispatches
                    .iter()
                    .find(|d| Some(&d.id) == model.selected.as_ref())
                    .cloned()
            }
            _ => {}
        }
        return false;
    }
    let before = model.editor.text().to_string();
    let leaving = edit(model, key, outbox);
    if model.editor.text() != before {
        model.slash_selected = 0;
    }
    leaving
}

/// A key in the input line, with the editing keys of a shell: macOS
/// terminals send Ctrl+A / Ctrl+E for Cmd+Left / Cmd+Right, and Alt+B /
/// Alt+F for Option+Left / Option+Right.
fn edit(model: &mut Model, key: KeyEvent, outbox: &mpsc::UnboundedSender<Outgoing>) -> bool {
    let control = key.modifiers.contains(KeyModifiers::CONTROL);
    let alt = key.modifiers.contains(KeyModifiers::ALT);
    match key.code {
        KeyCode::Char('c') if control => return true,
        KeyCode::Char('j') if control => model.editor.newline(),
        KeyCode::Char('a') if control => model.editor.home(),
        KeyCode::Char('e') if control => model.editor.end(),
        KeyCode::Char('w') if control => model.editor.delete_word_back(),
        KeyCode::Char('k') if control => model.editor.kill_to_end(),
        KeyCode::Char('u') if control => model.editor.kill_to_start(),
        KeyCode::Char('d') if control => model.editor.delete_forward(),
        KeyCode::Char('b') if alt => model.editor.word_left(),
        KeyCode::Char('f') if alt => model.editor.word_right(),
        KeyCode::Left if alt || control => model.editor.word_left(),
        KeyCode::Right if alt || control => model.editor.word_right(),
        KeyCode::Backspace if alt || control => model.editor.delete_word_back(),
        KeyCode::Delete => model.editor.delete_forward(),
        KeyCode::Up => {
            model.editor.up();
        }
        KeyCode::Down => {
            model.editor.down();
        }
        KeyCode::Enter if alt || key.modifiers.contains(KeyModifiers::SHIFT) => {
            model.editor.newline()
        }
        KeyCode::PageUp => model.scroll_conversation(-1),
        KeyCode::PageDown => model.scroll_conversation(1),
        KeyCode::Enter => match model.editor.submit() {
            Command::Say(text) => match message_id() {
                Ok(message_id) => {
                    let _ = outbox.send(Outgoing::Say { message_id, text });
                    model.notice = None;
                    model.scroll_top = None;
                }
                Err(error) => model.note(format!("Not sent: no message id ({error})")),
            },
            Command::Help => model.help = true,
            Command::Status => model.status_entry(),
            Command::Cancel => {
                let _ = outbox.send(Outgoing::CancelTurn);
            }
            Command::Handoff { note } => {
                let _ = outbox.send(Outgoing::Handoff { note });
            }
            Command::Exit => return true,
            Command::Unknown(name) => {
                model.note(format!("Unknown command {name}; /help lists them"))
            }
            Command::Nothing => {}
        },
        KeyCode::Backspace => model.editor.backspace(),
        KeyCode::Left => model.editor.left(),
        KeyCode::Right => model.editor.right(),
        KeyCode::Home => model.editor.home(),
        KeyCode::End => model.editor.end(),
        KeyCode::Char(c) if !control && !alt => model.editor.insert(c),
        _ => {}
    }
    false
}

/// A version-4 UUID: the service records a message once per id, so a
/// resend after a reconnect is safe.
fn message_id() -> io::Result<String> {
    let mut bytes = [0u8; 16];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn key(model: &mut Model, code: KeyCode, tx: &mpsc::UnboundedSender<Outgoing>) {
        key_pressed(model, KeyEvent::new(code, KeyModifiers::NONE), tx);
    }
    #[test]
    fn selection_watch_and_confirm_cancel_exactly_the_displayed_dispatch() {
        let mut model = Model::new("s1");
        model.connection = Connection::Live;
        model.apply_state(&json!({"dispatches": [
            {"dispatch_id": "one", "title": "first", "state": "running"},
            {"dispatch_id": "two", "title": "second", "state": "held"}]}));
        let (tx, mut rx) = mpsc::unbounded_channel();
        key(&mut model, KeyCode::Tab, &tx);
        key(&mut model, KeyCode::Down, &tx);
        key(&mut model, KeyCode::Enter, &tx);
        assert_eq!(rx.try_recv().unwrap(), Outgoing::Watch { id: "two".into() });
        key(&mut model, KeyCode::Char('c'), &tx);
        assert!(rx.try_recv().is_err());
        assert_eq!(model.confirm.as_ref().unwrap().title, "second");
        model.selected = Some("one".into());
        key(&mut model, KeyCode::Char('y'), &tx);
        assert_eq!(
            rx.try_recv().unwrap(),
            Outgoing::CancelDispatch {
                id: "two".into(),
                reason: "Cancelled by the person from the chat screen".into()
            }
        );
        key(&mut model, KeyCode::Esc, &tx);
        assert_eq!(rx.try_recv().unwrap(), Outgoing::Unwatch);
        assert!(model.detail.is_none());
        key(&mut model, KeyCode::Char('c'), &tx);
        key(&mut model, KeyCode::Char('n'), &tx);
        assert!(rx.try_recv().is_err());
        key(&mut model, KeyCode::Char('c'), &tx);
        model.connection = Connection::Connecting;
        key(&mut model, KeyCode::Char('y'), &tx);
        assert!(rx.try_recv().is_err());
    }

    fn with(model: &mut Model, code: KeyCode, modifiers: KeyModifiers) {
        let (tx, _rx) = mpsc::unbounded_channel();
        key_pressed(model, KeyEvent::new(code, modifiers), &tx);
    }

    fn at(model: &Model) -> &str {
        &model.editor.text()[model.editor.cursor()..]
    }

    #[test]
    fn the_cursor_keys_macos_terminals_send_move_and_delete_in_the_input() {
        let mut model = Model::new("s1");
        model.editor.set("fix the importer now");
        // Cmd+Left / Cmd+Right arrive as Ctrl+A / Ctrl+E.
        with(&mut model, KeyCode::Char('a'), KeyModifiers::CONTROL);
        assert_eq!(model.editor.cursor(), 0);
        with(&mut model, KeyCode::Char('e'), KeyModifiers::CONTROL);
        assert_eq!(at(&model), "");
        // Option+Left / Option+Right arrive as Alt+B / Alt+F.
        with(&mut model, KeyCode::Char('b'), KeyModifiers::ALT);
        assert_eq!(at(&model), "now");
        with(&mut model, KeyCode::Left, KeyModifiers::ALT);
        assert_eq!(at(&model), "importer now");
        with(&mut model, KeyCode::Char('f'), KeyModifiers::ALT);
        assert_eq!(at(&model), " now");
        with(&mut model, KeyCode::Char('w'), KeyModifiers::CONTROL);
        assert_eq!(model.editor.text(), "fix the  now");
        with(&mut model, KeyCode::Char('k'), KeyModifiers::CONTROL);
        assert_eq!(model.editor.text(), "fix the ");
        with(&mut model, KeyCode::Char('u'), KeyModifiers::CONTROL);
        assert_eq!(model.editor.text(), "");

        model.editor.set("one\ntwo");
        with(&mut model, KeyCode::Up, KeyModifiers::NONE);
        assert_eq!(at(&model), "\ntwo");
        with(&mut model, KeyCode::Down, KeyModifiers::NONE);
        assert_eq!(at(&model), "");
    }

    #[test]
    fn slash_opens_a_menu_that_chooses_completes_and_runs_a_command() {
        let mut model = Model::new("s1");
        let (tx, mut rx) = mpsc::unbounded_channel();
        key(&mut model, KeyCode::Char('/'), &tx);
        key(&mut model, KeyCode::Down, &tx);
        key(&mut model, KeyCode::Tab, &tx);
        assert_eq!(model.editor.text(), "/status");
        assert!(!model.agents_focus);

        model.editor.clear();
        key(&mut model, KeyCode::Char('/'), &tx);
        key(&mut model, KeyCode::Char('c'), &tx);
        key(&mut model, KeyCode::Enter, &tx);
        assert_eq!(rx.try_recv().unwrap(), Outgoing::CancelTurn);
        assert_eq!(model.editor.text(), "");

        // Without a menu Tab still focuses the agents, and a message with
        // a slash in it is sent as it is.
        key(&mut model, KeyCode::Tab, &tx);
        assert!(model.agents_focus);
        key(&mut model, KeyCode::Tab, &tx);
        model.editor.set("/etc/hosts is odd");
        key(&mut model, KeyCode::Enter, &tx);
        assert!(
            matches!(rx.try_recv().unwrap(), Outgoing::Say { text, .. } if text == "/etc/hosts is odd")
        );
    }

    #[test]
    fn page_keys_scroll_the_conversation_and_sending_returns_to_the_latest() {
        let mut model = Model::new("s1");
        model.conversation_view = shoestring_chat::model::ConversationView {
            last_top: 30,
            height: 11,
        };
        let (tx, mut rx) = mpsc::unbounded_channel();
        key(&mut model, KeyCode::PageUp, &tx);
        assert_eq!(model.scroll_top, Some(20));
        key(&mut model, KeyCode::PageUp, &tx);
        key(&mut model, KeyCode::PageDown, &tx);
        assert_eq!(model.scroll_top, Some(20));
        // Typing and sending leave the scrolled conversation for the latest.
        key(&mut model, KeyCode::Char('h'), &tx);
        assert_eq!(model.scroll_top, Some(20));
        key(&mut model, KeyCode::Enter, &tx);
        assert!(matches!(rx.try_recv().unwrap(), Outgoing::Say { text, .. } if text == "h"));
        assert_eq!(model.scroll_top, None);
    }
}
