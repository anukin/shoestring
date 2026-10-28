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
use shoestring_chat::model::Model;
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
                terminal.draw(|frame| ui::draw(frame, &view))?;
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

    match key.code {
        KeyCode::Char('c') if control => return true,
        KeyCode::Char('j') if control => model.editor.newline(),
        KeyCode::Char('u') if control => model.editor.clear(),
        KeyCode::Enter if alt || key.modifiers.contains(KeyModifiers::SHIFT) => {
            model.editor.newline()
        }
        KeyCode::Enter => match model.editor.submit() {
            Command::Say(text) => match message_id() {
                Ok(message_id) => {
                    let _ = outbox.send(Outgoing::Say { message_id, text });
                    model.notice = None;
                }
                Err(error) => model.note(format!("Not sent: no message id ({error})")),
            },
            Command::Help => model.help = true,
            Command::Status => model.status_entry(),
            Command::Cancel => {
                let _ = outbox.send(Outgoing::CancelTurn);
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
