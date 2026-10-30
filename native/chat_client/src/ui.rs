//! Drawing a `Model`. Everything drawn was cleaned when the model took it
//! in; the only prompts drawn come from service state, never from model or
//! Elf text.

use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};
use unicode_width::UnicodeWidthChar;

use crate::model::{Connection, ConversationView, Kind, Model, short};

const MAX_AGENTS: usize = 6;
const MAX_INPUT: usize = 6;

pub const HELP: &str = "\
Tab          focus agents; Up/Down select; Enter opens; c cancels (confirm)
Esc          close detail; Up/Down scroll detail
PgUp/PgDn    scroll the conversation back and forward
Enter        send the message (the coordinator gets it when it is idle)
Alt+Enter    new line (Ctrl+J too); paste keeps line breaks
Cmd/Ctrl+A,E line start/end; Option+←→ by word; ↑↓ between lines
Ctrl+W/K/U   delete word back / to line end / to line start
/            commands: ↑↓ choose, Tab completes, Enter runs
/cancel      interrupt the coordinator's running turn
/status      the coordinator, grant and dispatches, from Shoestring
/help        this help (any key closes it)
/exit        leave; the conversation and every agent keep running
Ctrl+C       same as /exit";

/// Draws `model`; returns the conversation as drawn, for scrolling it.
pub fn draw(frame: &mut Frame, model: &Model) -> ConversationView {
    let agents = (model.dispatches.len() * 3).clamp(1, MAX_AGENTS) as u16 + 2;
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
    let view = draw_conversation(frame, model, conversation);
    draw_agents(frame, model, agents_area);
    draw_input(frame, model, input_area);
    frame.render_widget(Paragraph::new(status_line(model)), status);

    if !model.agents_focus && model.detail.is_none() && model.confirm.is_none() && !model.help {
        draw_slash_menu(frame, model, input_area);
    }
    if model.help {
        draw_help(frame);
    }
    if let Some(detail) = &model.detail {
        let area = frame.area();
        let rect = Rect::new(
            area.x + 1,
            area.y + 1,
            area.width.saturating_sub(2),
            area.height.saturating_sub(2),
        );
        let width = rect.width.saturating_sub(2).max(1) as usize;
        let terminal = detail
            .terminal
            .as_ref()
            .map(|url| format!("Interactive terminal: {url}"))
            .unwrap_or_else(|| "Headless Elf: cannot be steered".into());
        let mut lines = vec![terminal];
        lines.extend(detail.lines.clone());
        lines.extend(detail.steps.clone());
        let rows: Vec<Line> = lines
            .iter()
            .flat_map(|l| wrap(l, width))
            .map(Line::from)
            .collect();
        let scroll = detail.scroll.min(
            rows.len()
                .saturating_sub(rect.height.saturating_sub(2) as usize),
        );
        frame.render_widget(Clear, rect);
        frame.render_widget(
            Paragraph::new(rows)
                .scroll((scroll.min(u16::MAX as usize) as u16, 0))
                .block(Block::bordered().title(format!(
                    " Elf {} · Esc close · ↑↓ scroll · c cancel ",
                    short(&detail.id)
                ))),
            rect,
        );
    }
    if let Some(dispatch) = &model.confirm {
        let area = frame.area();
        let rect = Rect::new(
            area.x,
            area.y + area.height.saturating_sub(7) / 2,
            area.width,
            7.min(area.height),
        );
        let text = format!(
            "Cancel {} {} on {}?\n{} · {}\ny confirms · any other key keeps it running",
            short(&dispatch.id),
            dispatch.purpose,
            dispatch.worker,
            dispatch.title,
            dispatch.state
        );
        frame.render_widget(Clear, rect);
        frame.render_widget(
            Paragraph::new(text)
                .wrap(ratatui::widgets::Wrap { trim: false })
                .block(Block::bordered().title(" Confirm cancellation · Shoestring ")),
            rect,
        );
    }
    view
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

fn draw_conversation(frame: &mut Frame, model: &Model, area: Rect) -> ConversationView {
    let inner = Block::new().borders(Borders::ALL).inner(area);
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

    let height = inner.height as usize;
    let last_top = lines.len().saturating_sub(height);
    let top = model.scroll_top.map_or(last_top, |top| top.min(last_top));
    let title = if top < last_top {
        format!(" Conversation · {} more below · PgDn ", last_top - top)
    } else {
        " Conversation · PgUp scroll back ".to_string()
    };
    let block = Block::new().borders(Borders::ALL).title(title);
    let shown: Vec<Line> = lines.into_iter().skip(top).take(height).collect();
    frame.render_widget(Paragraph::new(shown).block(block), area);
    ConversationView { last_top, height }
}

fn draw_agents(frame: &mut Frame, model: &Model, area: Rect) {
    let block = Block::new()
        .borders(Borders::ALL)
        .title(" Agents · Tab focus · ↑↓ select · Enter detail · c cancel ");
    let lines: Vec<Line> = if model.dispatches.is_empty() {
        vec![Line::styled("none yet", Style::new().fg(Color::DarkGray))]
    } else {
        let selected = model
            .dispatches
            .iter()
            .position(|d| Some(&d.id) == model.selected.as_ref())
            .unwrap_or(0);
        let start = selected.saturating_sub(MAX_AGENTS / 3 - 1);
        model
            .dispatches
            .iter()
            .skip(start)
            .take(MAX_AGENTS / 3)
            .flat_map(|d| {
                let style = if model.agents_focus && Some(&d.id) == model.selected.as_ref() {
                    Style::new().add_modifier(Modifier::REVERSED)
                } else {
                    Style::new()
                };
                [
                    format!(
                        "{} {} {:<9} {} · {}s {}",
                        glyph(&d.state),
                        short(&d.id),
                        d.purpose,
                        d.state,
                        d.elapsed,
                        d.waiting_until
                    ),
                    format!("  {} · reviewer {} · {}", d.worker, d.reviewer, d.title),
                    format!("  {} {}", d.latest_step, d.next),
                ]
                .into_iter()
                .map(move |line| Line::styled(line, style))
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
    let y = inner.y + cursor_row.saturating_sub(top) as u16;
    if !model.agents_focus && model.detail.is_none() && model.confirm.is_none() {
        frame.set_cursor_position(Position::new(x, y));
    }
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

/// The commands the input could be the start of, just above the input.
fn draw_slash_menu(frame: &mut Frame, model: &Model, input: Rect) {
    let matches = model.editor.slash_matches();
    if matches.is_empty() {
        return;
    }
    let selected = model.slash_selected.min(matches.len() - 1);
    let height = (matches.len() as u16 + 2).min(input.y);
    let width = 72.min(input.width);
    let rect = Rect::new(input.x, input.y - height, width, height);
    let lines: Vec<Line> = matches
        .iter()
        .enumerate()
        .map(|(i, (name, what))| {
            let style = if i == selected {
                Style::new().add_modifier(Modifier::REVERSED)
            } else {
                Style::new()
            };
            Line::styled(format!("{name:<9} {what}"), style)
        })
        .collect();
    frame.render_widget(Clear, rect);
    frame.render_widget(
        Paragraph::new(lines)
            .block(Block::bordered().title(" ↑↓ choose · Tab complete · Enter run ")),
        rect,
    );
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
        drawn(model, width, height).0
    }

    fn drawn(model: &Model, width: u16, height: u16) -> (String, ConversationView) {
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        let mut view = ConversationView::default();
        terminal.draw(|frame| view = draw(frame, model)).unwrap();
        let buffer = terminal.backend().buffer();
        let text = (0..height)
            .map(|y| {
                (0..width)
                    .map(|x| buffer[(x, y)].symbol().to_string())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n");
        (text, view)
    }

    #[test]
    fn tiny_terminal_does_not_underflow_input_cursor() {
        let model = Model::new("s1");
        let _ = screen(&model, 20, 1);
    }

    #[test]
    fn detail_and_confirmation_draw_from_state_at_narrow_widths() {
        let mut model = Model::new("s1");
        model.apply_state(&json!({"dispatches": [{"dispatch_id": "d1", "purpose": "explore", "worker": "codex:m", "title": "Find it", "state": "held"}]}));
        model.detail = Some(crate::model::Detail {
            id: "d1".into(),
            lines: vec!["checks: passed".into()],
            ..Default::default()
        });
        let text = screen(&model, 70, 20);
        assert!(text.contains("Headless Elf: cannot be steered"));
        assert!(text.contains("checks: passed"));
        model.confirm = Some(model.dispatches[0].clone());
        let text = screen(&model, 70, 20);
        assert!(text.contains("Cancel d1 explore on codex:m?"));
        assert!(text.contains("y confirms"));
        let _ = screen(&model, 20, 8);
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
    fn the_conversation_scrolls_back_holds_still_for_new_lines_and_returns_to_the_latest() {
        let said = |range: std::ops::RangeInclusive<u64>| {
            let events: Vec<_> = range
                .map(|i| json!({"sequence": i, "type": "conversation.message.coordinator", "payload": {"text": format!("line {i}")}}))
                .collect();
            json!({ "events": events })
        };
        let mut model = Model::new("s1");
        model.apply_events(&said(1..=40));
        let (text, view) = drawn(&model, 60, 16);
        assert!(text.contains("line 40"));
        assert!(text.contains("PgUp scroll back"));
        model.conversation_view = view;

        model.scroll_conversation(-1);
        let (text, view) = drawn(&model, 60, 16);
        assert!(!text.contains("line 40"));
        assert!(text.contains(&format!("line {}", 40 - view.height + 1)));
        assert!(text.contains(&format!("{} more below", view.height - 1)));
        model.conversation_view = view;

        // New lines arrive below; what is being read stays where it is.
        model.apply_events(&said(41..=45));
        let (later, view) = drawn(&model, 60, 16);
        let rows = |screen: &str| {
            screen
                .lines()
                .filter(|l| l.contains("line "))
                .map(String::from)
                .collect::<Vec<_>>()
        };
        assert_eq!(rows(&later), rows(&text));
        model.conversation_view = view;

        // As far back as it goes, then forward to the latest, which it follows again.
        for _ in 0..10 {
            model.scroll_conversation(-1);
        }
        assert_eq!(model.scroll_top, Some(0));
        assert!(screen(&model, 60, 16).contains("line 1\u{20}"));
        for _ in 0..10 {
            model.scroll_conversation(1);
        }
        assert_eq!(model.scroll_top, None);
        model.apply_events(&said(46..=46));
        assert!(screen(&model, 60, 16).contains("line 46"));
    }

    #[test]
    fn typing_a_slash_shows_the_matching_commands_above_the_input() {
        let mut model = Model::new("s1");
        model.editor.set("/");
        let text = screen(&model, 90, 24);
        for (name, _) in crate::editor::COMMANDS {
            assert!(text.contains(name), "{name} missing:\n{text}");
        }
        model.editor.set("/st");
        let text = screen(&model, 90, 24);
        assert!(text.contains("/status   the coordinator, grant and dispatches"));
        assert!(!text.contains("/exit"));
        model.editor.set("/st please");
        assert!(!screen(&model, 90, 24).contains("Tab complete"));
        let _ = screen(&model, 20, 6);
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
