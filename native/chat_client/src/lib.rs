//! The Shoestring chat client: a thin terminal view of one conversation the
//! service holds (`docs/chat-channel.md`). It keeps no domain state, so
//! losing it loses nothing.

pub mod connection;
pub mod editor;
pub mod model;
pub mod protocol;
pub mod text;
pub mod ui;
