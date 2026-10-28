//! Model and Elf text is untrusted. Before it reaches the terminal, escape
//! sequences are removed, other control characters and bidirectional
//! overrides become U+FFFD, tabs become spaces and carriage returns are
//! dropped, so nothing can move the cursor, recolour the screen or draw a
//! forged prompt. The readable text stays.

const REPLACEMENT: char = '\u{FFFD}';

pub fn clean(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();

    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => skip_escape(&mut chars),
            '\u{9b}' => skip_csi(&mut chars),
            '\u{90}' | '\u{98}' | '\u{9d}' | '\u{9e}' | '\u{9f}' => skip_string(&mut chars),
            '\n' => out.push('\n'),
            '\t' => out.push_str("    "),
            '\r' => {}
            c if c.is_control() || bidi(c) => out.push(REPLACEMENT),
            c => out.push(c),
        }
    }

    out
}

/// One line of untrusted text: `clean`, with line breaks as spaces.
pub fn clean_line(text: &str) -> String {
    clean(text).replace('\n', " ")
}

type Chars<'a> = std::iter::Peekable<std::str::Chars<'a>>;

fn skip_escape(chars: &mut Chars) {
    match chars.peek() {
        Some('[') => {
            chars.next();
            skip_csi(chars);
        }
        Some(']' | 'P' | 'X' | '^' | '_') => {
            chars.next();
            skip_string(chars);
        }
        Some(_) => {
            chars.next();
        }
        None => {}
    }
}

// Parameters and intermediates, then one final byte.
fn skip_csi(chars: &mut Chars) {
    for c in chars.by_ref() {
        if !('\u{20}'..='\u{3f}').contains(&c) {
            break;
        }
    }
}

// An OSC, DCS or similar string, ended by BEL or ST.
fn skip_string(chars: &mut Chars) {
    while let Some(c) = chars.next() {
        match c {
            '\u{07}' | '\u{9c}' => break,
            '\u{1b}' if chars.peek() == Some(&'\\') => {
                chars.next();
                break;
            }
            _ => {}
        }
    }
}

fn bidi(c: char) -> bool {
    matches!(c, '\u{061C}' | '\u{200E}' | '\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escape_sequences_are_removed_and_the_text_stays() {
        assert_eq!(clean("\u{1b}[31mred\u{1b}[0m text"), "red text");
        assert_eq!(clean("\u{1b}]0;title\u{07}after"), "after");
        assert_eq!(
            clean("\u{1b}]8;;http://x\u{1b}\\link\u{1b}]8;;\u{1b}\\"),
            "link"
        );
        assert_eq!(clean("\u{9b}2Jcleared"), "cleared");
        assert_eq!(clean("a\u{1b}cb"), "ab");
    }

    #[test]
    fn other_controls_and_overrides_are_visible_replacements() {
        assert_eq!(clean("bell\u{07}"), "bell\u{FFFD}");
        assert_eq!(clean("over\rwrite"), "overwrite");
        assert_eq!(clean("\u{202E}evil"), "\u{FFFD}evil");
        assert_eq!(clean("tab\there"), "tab    here");
        assert_eq!(clean("two\nlines"), "two\nlines");
        assert_eq!(clean_line("two\nlines"), "two lines");
    }

    #[test]
    fn plain_and_wide_text_is_unchanged() {
        let text = "Splitter ignores quotes (lib/import.ex:41) ✓ 日本語";
        assert_eq!(clean(text), text);
    }

    #[test]
    fn an_unterminated_sequence_swallows_only_itself() {
        assert_eq!(clean("ok\u{1b}["), "ok");
        assert_eq!(clean("ok\u{1b}"), "ok");
        assert_eq!(clean("ok\u{1b}]never ends"), "ok");
    }
}
