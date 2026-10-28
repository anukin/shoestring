//! Drawing a `Model`. Everything drawn was cleaned when the model took it
//! in; the only prompts drawn come from service state, never from model or
//! Elf text.

use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};
use unicode_width::UnicodeWidthChar;

use crate::model::{Connection, Kind, Model, short};

const MAX_AGENTS: usize = 6;
const MAX_INPUT: usize = 6;

pub const HELP: &str = "\
Enter        send the message (the coordinator gets it when it is idle)
Alt+Enter    new line (Ctrl+J too); paste keeps line breaks
/cancel      interrupt the coordinator's running turn
/status      the coordinator, grant and dispatches, from Shoestring
/help        this help (any key closes it)
/exit        leave; the conversation and every agent keep running
Ctrl+C       same as /exit";

pub fn draw(frame: &mut Frame, model: &Model) {
    let agents = model.dispatches.len().clamp(1, MAX_AGENTS) as u16 + 2;
    let input = model.editor.line_count().clamp(1, MAX_INPUT) as u16 + 2;
    let [header, conversation, agents_area, input_area, status] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(3),
        Constraint::Length(agents),
        Constraint::Length(input),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    frame.render_widget(Paragraph::new(header_line(model)), header);
    draw_conversation(frame, model, conversation);
    draw_agents(frame, model, agents_area);
    draw_input(frame, model, input_area);
    frame.render_widget(Paragraph::new(status_line(model)), status);

    if model.help {
        draw_help(frame);
    }
}

fn header_line(model: &Model) -> Line<'static> {
    let turns = match model.turns {
        Some((used, left)) => format!("turns {used} used · {left} left"),
        None => "no grant".into(),
    };
    Line::from(vec![
        Span::styled(" shoestring ", Style::new().add_modifier(Modifier::BOLD)),
        Span::raw(format!(
            "· {} · coordinator {} · {turns}",
            model.session,
            model.coordinator.as_deref().unwrap_or("?")
        )),
    ])
}

fn draw_conversation(frame: &mut Frame, model: &Model, area: Rect) {
    let block = Block::new().borders(Borders::ALL).title(" Conversation ");
    let inner = block.inner(area);
    let width = inner.width.max(1) as usize;

    let mut lines: Vec<Line> = Vec::new();
    for entry in &model.entries {
        let (prefix, style) = match entry.kind {
            Kind::You => ("You: ", Style::new().fg(Color::Cyan)),
            Kind::Coordinator => ("Coordinator: ", Style::new()),
            Kind::Tool => ("  ", Style::new().fg(Color::DarkGray)),
            Kind::Inbox => ("  ", Style::new().fg(Color::Yellow)),
            Kind::Notice => ("! ", Style::new().fg(Color::Magenta)),
        };
        for (i, row) in wrap(&format!("{prefix}{}", entry.text), width)
            .into_iter()
            .enumerate()
        {
            let style = if i == 0 && entry.kind == Kind::You {
                style.add_modifier(Modifier::BOLD)
            } else {
                style
            };
            lines.push(Line::styled(row, style));
        }
    }

    let skip = lines.len().saturating_sub(inner.height as usize);
    frame.render_widget(Paragraph::new(lines.split_off(skip)).block(block), area);
}

fn draw_agents(frame: &mut Frame, model: &Model, area: Rect) {
    let block = Block::new().borders(Borders::ALL).title(" Agents ");
    let lines: Vec<Line> = if model.dispatches.is_empty() {
        vec![Line::styled("none yet", Style::new().fg(Color::DarkGray))]
    } else {
        model
            .dispatches
            .iter()
            .rev()
            .take(MAX_AGENTS)
            .map(|d| {
                Line::from(format!(
                    "{} {} {:<9} {:<24} {:<10} {}",
                    glyph(&d.state),
                    short(&d.id),
                    d.purpose,
                    d.worker,
                    d.state,
                    d.title
                ))
            })
            .collect()
    };
    frame.render_widget(Paragraph::new(lines).block(block), area);
}

fn draw_input(frame: &mut Frame, model: &Model, area: Rect) {
    let block = Block::new().borders(Borders::ALL);
    let inner = block.inner(area);
    let text = model.editor.text();
    let rows: Vec<&str> = text.split('\n').collect();

    let before = &text[..model.editor.cursor()];
    let cursor_row = before.matches('\n').count();
    let cursor_col: usize = before
        .rsplit('\n')
        .next()
        .unwrap_or_default()
        .chars()
        .map(|c| c.width().unwrap_or(0))
        .sum();

    let top = (cursor_row + 1).saturating_sub(inner.height as usize);
    let lines: Vec<Line> = rows
        .iter()
        .enumerate()
        .skip(top)
        .map(|(i, row)| {
            let prompt = if i == 0 { "❯ " } else { "  " };
            Line::from(format!("{prompt}{row}"))
        })
        .collect();
    frame.render_widget(Paragraph::new(lines).block(block), area);

    let x = inner.x + (2 + cursor_col).min(inner.width.saturating_sub(1) as usize) as u16;
    let y = inner.y + (cursor_row - top) as u16;
    frame.set_cursor_position(Position::new(x, y));
}

fn status_line(model: &Model) -> Line<'static> {
    let connection = match &model.connection {
        Connection::Connecting => "connecting".to_string(),
        Connection::Live => "connected".to_string(),
        Connection::Reconnecting(why) => format!("reconnecting ({why})"),
        Connection::Refused(why) => format!("refused: {why}"),
    };
    let coordinator = match (&model.hold, model.engine.as_str()) {
        (Some(hold), _) => format!("held: {hold}"),
        (None, "in_turn") => "working".to_string(),
        (None, state) => state.to_string(),
    };
    let waiting = if model.pending > 0 {
        format!(" · {} waiting", model.pending)
    } else {
        String::new()
    };
    let capacity = if model.capacity.is_empty() {
        String::new()
    } else {
        format!(" · {}", model.capacity.join(" · "))
    };
    let notice = model
        .notice
        .as_deref()
        .map(|n| format!(" · {n}"))
        .unwrap_or_default();

    Line::from(vec![
        Span::styled(
            format!(" {connection} · {coordinator}{waiting}{capacity}{notice}"),
            Style::new().fg(Color::Gray),
        ),
        Span::styled(" │ /help", Style::new().fg(Color::DarkGray)),
    ])
}

fn draw_help(frame: &mut Frame) {
    let area = frame.area();
    let width = 72.min(area.width);
    let height = (HELP.lines().count() as u16 + 2).min(area.height);
    let rect = Rect::new(
        area.x + (area.width - width) / 2,
        area.y + (area.height - height) / 2,
        width,
        height,
    );
    frame.render_widget(Clear, rect);
    frame.render_widget(
        Paragraph::new(HELP).block(Block::new().borders(Borders::ALL).title(" Help ")),
        rect,
    );
}

fn glyph(state: &str) -> &'static str {
    match state {
        "running" => "●",
        "queued" | "starting" => "◌",
        "completed" => "✓",
        "failed" | "failed_to_start" => "✗",
        "cancelled" => "⊘",
        "waiting" => "…",
        "held" => "‼",
        "needs_you" => "?",
        _ => "·",
    }
}

/// Splits `text` into rows of at most `width` display columns, at line
/// breaks and, where it can, at spaces.
pub fn wrap(text: &str, width: usize) -> Vec<String> {
    let mut rows = Vec::new();
    for line in text.split('\n') {
        let mut row = String::new();
        let mut used = 0;
        for word in line.split_inclusive(' ') {
            let w: usize = word.chars().map(|c| c.width().unwrap_or(0)).sum();
            // The trailing space may hang past the edge.
            let visible = w - (word.len() - word.trim_end_matches(' ').len());
            if used + visible > width && !row.is_empty() {
                rows.push(std::mem::take(&mut row).trim_end().to_string());
                used = 0;
            }
            if w > width {
                for c in word.chars() {
                    let cw = c.width().unwrap_or(0);
                    if used + cw > width {
                        rows.push(std::mem::take(&mut row));
                        used = 0;
                    }
                    row.push(c);
                    used += cw;
                }
            } else {
                row.push_str(word);
                used += w;
            }
        }
        rows.push(row.trim_end().to_string());
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::{Terminal, backend::TestBackend};
    use serde_json::json;

    fn screen(model: &Model, width: u16, height: u16) -> String {
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        terminal.draw(|frame| draw(frame, model)).unwrap();
        let buffer = terminal.backend().buffer();
        (0..height)
            .map(|y| {
                (0..width)
                    .map(|x| buffer[(x, y)].symbol().to_string())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn wrapping_respects_width_breaks_and_wide_characters() {
        assert_eq!(wrap("one two three", 7), vec!["one two", "three"]);
        assert_eq!(wrap("a\nb", 10), vec!["a", "b"]);
        assert_eq!(wrap("abcdefgh", 3), vec!["abc", "def", "gh"]);
        assert_eq!(wrap("日本語", 4), vec!["日本", "語"]);
    }

    #[test]
    fn the_screen_shows_conversation_agents_and_trusted_state() {
        let mut model = Model::new("s1");
        model.apply_events(&json!({"events": [
            {"sequence": 1, "type": "conversation.opened", "payload": {"provider": "claude", "model": "opus"}},
            {"sequence": 2, "type": "conversation.message.human", "payload": {"text": "Fix the importer"}},
            {"sequence": 3, "type": "conversation.message.coordinator", "payload": {"text": "\u{1b}[31mSending an EXPLORE"}}
        ]}));
        model.apply_state(&json!({
            "engine": {"state": "in_turn", "pending_messages": 0, "pending_inbox": 0, "hold": null},
            "grant": {"turns": {"used": 3, "left": 7}},
            "dispatches": [{"dispatch_id": "d41aaaaabbbb", "purpose": "explore", "worker": "codex:m", "title": "Find it", "state": "running"}],
            "capacity": {"providers": []}
        }));
        model.connection = Connection::Live;

        let text = screen(&model, 100, 20);
        assert!(text.contains("coordinator claude:opus · turns 3 used · 7 left"));
        assert!(text.contains("You: Fix the importer"));
        assert!(text.contains("Coordinator: Sending an EXPLORE"));
        assert!(text.contains("● d41aaaaa explore"));
        assert!(text.contains("connected · working"));
        assert!(!text.contains('\u{1b}'));
    }

    #[test]
    fn the_latest_lines_stay_in_view_and_help_draws_over_them() {
        let mut model = Model::new("s1");
        let events: Vec<_> = (1..=40)
            .map(|i| json!({"sequence": i, "type": "conversation.message.coordinator", "payload": {"text": format!("line {i}")}}))
            .collect();
        model.apply_events(&json!({ "events": events }));

        let text = screen(&model, 60, 16);
        assert!(text.contains("line 40"));
        assert!(!text.contains("line 1\u{20}"));

        model.help = true;
        assert!(
            screen(&model, 80, 24).contains("leave; the conversation and every agent keep running")
        );
    }
}
