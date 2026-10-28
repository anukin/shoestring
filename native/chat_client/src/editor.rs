//! The input line: multiline text with a cursor, and the slash commands.

use crate::text;

#[derive(Debug, Clone, Default)]
pub struct Editor {
    text: String,
    /// A byte index on a character boundary.
    cursor: usize,
}

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
