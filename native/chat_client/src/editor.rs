//! The input line: multiline text with a cursor, and the slash commands.

use crate::text;

#[derive(Debug, Clone, Default)]
pub struct Editor {
    text: String,
    /// A byte index on a character boundary.
    cursor: usize,
}

/// The slash commands, as the `/` menu lists them.
pub const COMMANDS: &[(&str, &str)] = &[
    ("/help", "the keys and commands"),
    (
        "/status",
        "the coordinator, grant and dispatches, from Shoestring",
    ),
    ("/cancel", "interrupt the coordinator's running turn"),
    (
        "/exit",
        "leave; the conversation and every agent keep running",
    ),
];

#[derive(Debug, PartialEq)]
pub enum Command {
    Say(String),
    Help,
    Status,
    Cancel,
    Exit,
    Unknown(String),
    Nothing,
}

impl Editor {
    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn cursor(&self) -> usize {
        self.cursor
    }

    pub fn insert(&mut self, c: char) {
        self.text.insert(self.cursor, c);
        self.cursor += c.len_utf8();
    }

    /// Pasted text keeps its line breaks; anything else a terminal would act
    /// on is cleaned first.
    pub fn paste(&mut self, pasted: &str) {
        let cleaned = text::clean(pasted);
        self.text.insert_str(self.cursor, &cleaned);
        self.cursor += cleaned.len();
    }

    pub fn newline(&mut self) {
        self.insert('\n');
    }

    pub fn backspace(&mut self) {
        if let Some(c) = self.text[..self.cursor].chars().next_back() {
            self.cursor -= c.len_utf8();
            self.text.remove(self.cursor);
        }
    }

    pub fn left(&mut self) {
        if let Some(c) = self.text[..self.cursor].chars().next_back() {
            self.cursor -= c.len_utf8();
        }
    }

    pub fn right(&mut self) {
        if let Some(c) = self.text[self.cursor..].chars().next() {
            self.cursor += c.len_utf8();
        }
    }

    pub fn home(&mut self) {
        self.cursor = self.text[..self.cursor].rfind('\n').map_or(0, |i| i + 1);
    }

    pub fn end(&mut self) {
        self.cursor += self.text[self.cursor..]
            .find('\n')
            .unwrap_or(self.text.len() - self.cursor);
    }

    /// To the start of the previous word (Option+Left, Ctrl+Left, Alt+B).
    pub fn word_left(&mut self) {
        let before = &self.text[..self.cursor];
        let trimmed = before.trim_end();
        self.cursor = trimmed.rfind(char::is_whitespace).map_or(0, |i| {
            i + trimmed[i..].chars().next().map_or(1, char::len_utf8)
        });
    }

    /// To the end of the next word (Option+Right, Ctrl+Right, Alt+F).
    pub fn word_right(&mut self) {
        let after = &self.text[self.cursor..];
        let skipped = after.len() - after.trim_start().len();
        let rest = &after[skipped..];
        self.cursor += skipped + rest.find(char::is_whitespace).unwrap_or(rest.len());
    }

    /// Deletes back to the start of the word (Ctrl+W, Option+Backspace).
    pub fn delete_word_back(&mut self) {
        let end = self.cursor;
        self.word_left();
        self.text.replace_range(self.cursor..end, "");
    }

    /// Deletes the character under the cursor (Delete, Ctrl+D).
    pub fn delete_forward(&mut self) {
        if self.cursor < self.text.len() {
            self.text.remove(self.cursor);
        }
    }

    /// Deletes to the end of the line (Ctrl+K).
    pub fn kill_to_end(&mut self) {
        let end = self.cursor
            + self.text[self.cursor..]
                .find('\n')
                .unwrap_or(self.text.len() - self.cursor);
        self.text.replace_range(self.cursor..end, "");
    }

    /// Deletes to the start of the line (Ctrl+U, Cmd+Backspace).
    pub fn kill_to_start(&mut self) {
        let end = self.cursor;
        self.home();
        self.text.replace_range(self.cursor..end, "");
    }

    /// To the line above, keeping the column where it can; false on the
    /// first line.
    pub fn up(&mut self) -> bool {
        let start = self.text[..self.cursor].rfind('\n').map_or(0, |i| i + 1);
        if start == 0 {
            return false;
        }
        let column = self.text[start..self.cursor].chars().count();
        let above = self.text[..start - 1].rfind('\n').map_or(0, |i| i + 1);
        self.cursor = column_in(&self.text, above, start - 1, column);
        true
    }

    /// To the line below, keeping the column where it can; false on the
    /// last line.
    pub fn down(&mut self) -> bool {
        let Some(newline) = self.text[self.cursor..].find('\n').map(|i| self.cursor + i) else {
            return false;
        };
        let start = self.text[..self.cursor].rfind('\n').map_or(0, |i| i + 1);
        let column = self.text[start..self.cursor].chars().count();
        let below = newline + 1;
        let end = self.text[below..]
            .find('\n')
            .map_or(self.text.len(), |i| below + i);
        self.cursor = column_in(&self.text, below, end, column);
        true
    }

    /// Replaces the whole text, with the cursor at its end.
    pub fn set(&mut self, text: &str) {
        self.text = text.to_string();
        self.cursor = self.text.len();
    }

    /// The slash commands the text could be the start of, while it is one
    /// word starting with `/`.
    pub fn slash_matches(&self) -> Vec<(&'static str, &'static str)> {
        let text = self.text.as_str();
        if !text.starts_with('/') || text.contains(char::is_whitespace) {
            return Vec::new();
        }
        COMMANDS
            .iter()
            .filter(|(name, _)| name.starts_with(text))
            .copied()
            .collect()
    }

    pub fn clear(&mut self) {
        self.text.clear();
        self.cursor = 0;
    }

    /// Enter: the command the text names, leaving the editor empty.
    pub fn submit(&mut self) -> Command {
        let text = std::mem::take(&mut self.text);
        self.cursor = 0;
        let trimmed = text.trim();

        match trimmed {
            "" => Command::Nothing,
            "/help" => Command::Help,
            "/status" => Command::Status,
            "/cancel" => Command::Cancel,
            "/exit" | "/quit" => Command::Exit,
            command if command.starts_with('/') && !command.contains(char::is_whitespace) => {
                Command::Unknown(command.to_string())
            }
            _ => Command::Say(trimmed.to_string()),
        }
    }

    pub fn line_count(&self) -> usize {
        self.text.split('\n').count()
    }
}

/// The byte index `column` characters into the line `start..end`, or its end.
fn column_in(text: &str, start: usize, end: usize, column: usize) -> usize {
    text[start..end]
        .char_indices()
        .nth(column)
        .map_or(end, |(i, _)| start + i)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn typed(text: &str) -> Editor {
        let mut editor = Editor::default();
        text.chars().for_each(|c| editor.insert(c));
        editor
    }

    #[test]
    fn typing_editing_and_multiline() {
        let mut editor = typed("héllo");
        editor.backspace();
        editor.left();
        editor.insert('X');
        assert_eq!(editor.text(), "hélXl");
        editor.end();
        editor.newline();
        editor.insert('2');
        assert_eq!(editor.text(), "hélXl\n2");
        assert_eq!(editor.line_count(), 2);
        editor.home();
        assert_eq!(editor.cursor(), "hélXl\n".len());
    }

    #[test]
    fn words_line_ends_and_lines_move_and_delete_as_in_a_shell() {
        let mut editor = typed("make  the héllo work");
        editor.word_left();
        assert_eq!(&editor.text()[editor.cursor()..], "work");
        editor.word_left();
        assert_eq!(&editor.text()[editor.cursor()..], "héllo work");
        editor.word_right();
        assert_eq!(&editor.text()[editor.cursor()..], " work");
        editor.delete_word_back();
        assert_eq!(editor.text(), "make  the  work");
        editor.kill_to_end();
        assert_eq!(editor.text(), "make  the ");
        editor.home();
        editor.delete_forward();
        assert_eq!(editor.text(), "ake  the ");
        editor.end();
        editor.kill_to_start();
        assert_eq!(editor.text(), "");

        let mut editor = typed("first line\nab\nthird");
        assert!(editor.up());
        assert_eq!(&editor.text()[editor.cursor()..], "\nthird");
        assert!(editor.up());
        // "ab" is shorter, so the column became 2.
        assert_eq!(&editor.text()[editor.cursor()..], "rst line\nab\nthird");
        assert!(!editor.up());
        assert!(editor.down());
        assert!(editor.down());
        assert!(!editor.down());
        assert_eq!(&editor.text()[editor.cursor()..], "ird");
    }

    #[test]
    fn slash_matches_list_the_commands_a_word_could_start() {
        assert_eq!(typed("/").slash_matches().len(), COMMANDS.len());
        assert_eq!(typed("/s").slash_matches(), vec![COMMANDS[1]]);
        assert_eq!(typed("/exit").slash_matches(), vec![COMMANDS[3]]);
        assert!(typed("/x").slash_matches().is_empty());
        assert!(typed("/help me").slash_matches().is_empty());
        assert!(typed("hi /").slash_matches().is_empty());
    }

    #[test]
    fn paste_keeps_lines_and_drops_escapes() {
        let mut editor = Editor::default();
        editor.paste("one\n\u{1b}[2Jtwo\r\n");
        assert_eq!(editor.text(), "one\ntwo\n");
    }

    #[test]
    fn submit_names_commands_and_says_the_rest() {
        assert_eq!(typed("  hello  ").submit(), Command::Say("hello".into()));
        assert_eq!(typed("/help").submit(), Command::Help);
        assert_eq!(typed("/exit").submit(), Command::Exit);
        assert_eq!(typed("/cancel").submit(), Command::Cancel);
        assert_eq!(typed("/status").submit(), Command::Status);
        assert_eq!(typed("/nope").submit(), Command::Unknown("/nope".into()));
        assert_eq!(
            typed("/etc/hosts is odd").submit(),
            Command::Say("/etc/hosts is odd".into())
        );
        assert_eq!(typed("   ").submit(), Command::Nothing);

        let mut editor = typed("sent");
        editor.submit();
        assert_eq!(editor.text(), "");
        assert_eq!(editor.cursor(), 0);
    }
}
