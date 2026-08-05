use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    ffi::{CStr, CString},
    os::raw::c_char,
    panic::{catch_unwind, AssertUnwindSafe},
};
use todo_core::{Todo, TodoStore};

#[derive(Debug, Deserialize)]
#[serde(tag = "command", rename_all = "camelCase")]
enum Request {
    List,
    Get {
        id: u64,
    },
    Add {
        title: String,
    },
    Update {
        id: u64,
        title: Option<String>,
        content: Option<String>,
        #[serde(rename = "completionResult")]
        completion_result: Option<String>,
        completed: Option<bool>,
    },
    Delete {
        id: u64,
    },
    ClearCompleted,
    SetAllCompleted {
        completed: bool,
    },
    DataPath,
    RenderMarkdown {
        markdown: String,
    },
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct TodoSummary {
    id: u64,
    title: String,
    subtitle: String,
    completed: bool,
    created_at_ms: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
enum RunStyle {
    Body,
    Heading1,
    Heading2,
    Heading3,
    Heading4,
    Heading5,
    Heading6,
    Quote,
    Code,
    Table,
    Separator,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct MarkdownRun {
    text: String,
    style: RunStyle,
    bold: bool,
    italic: bool,
    strikethrough: bool,
    link: Option<String>,
}

#[derive(Clone, Debug)]
struct InlineState {
    style: RunStyle,
    bold_depth: usize,
    italic_depth: usize,
    strikethrough_depth: usize,
    link: Option<String>,
    quote_depth: usize,
}

impl Default for InlineState {
    fn default() -> Self {
        Self {
            style: RunStyle::Body,
            bold_depth: 0,
            italic_depth: 0,
            strikethrough_depth: 0,
            link: None,
            quote_depth: 0,
        }
    }
}

#[derive(Clone, Debug)]
struct ListState {
    next_number: Option<u64>,
}

#[no_mangle]
/// Executes one UTF-8 JSON request and returns a newly allocated UTF-8 JSON response.
///
/// # Safety
///
/// `request` must be a non-null pointer to a valid NUL-terminated C string for the
/// duration of this call. The returned pointer must be released exactly once with
/// [`todo_bridge_free`].
pub unsafe extern "C" fn todo_bridge_call(request: *const c_char) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| unsafe { handle_ffi_request(request) }))
        .unwrap_or_else(|_| error_envelope("unexpected Rust panic"));
    into_c_string(response)
}

#[no_mangle]
/// Releases a response allocated by [`todo_bridge_call`].
///
/// # Safety
///
/// `value` must be either null or a pointer returned by [`todo_bridge_call`] that
/// has not already been freed.
pub unsafe extern "C" fn todo_bridge_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

unsafe fn handle_ffi_request(request: *const c_char) -> String {
    if request.is_null() {
        return error_envelope("request pointer was null");
    }

    let request = match unsafe { CStr::from_ptr(request) }.to_str() {
        Ok(value) => value,
        Err(error) => return error_envelope(&format!("request was not UTF-8: {error}")),
    };

    match handle_request(request) {
        Ok(value) => serde_json::to_string(&json!({ "ok": true, "value": value }))
            .unwrap_or_else(|error| error_envelope(&format!("failed to encode response: {error}"))),
        Err(error) => error_envelope(&error),
    }
}

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| CString::new(error_envelope("response contained a null byte")).unwrap())
        .into_raw()
}

fn error_envelope(error: &str) -> String {
    serde_json::to_string(&json!({ "ok": false, "error": error }))
        .unwrap_or_else(|_| "{\"ok\":false,\"error\":\"encoding failure\"}".to_owned())
}

fn handle_request(request: &str) -> Result<Value, String> {
    let request: Request = serde_json::from_str(request).map_err(|error| error.to_string())?;

    match request {
        Request::List => {
            let store = TodoStore::load_default().map_err(|error| error.to_string())?;
            serde_json::to_value(store.list().iter().map(todo_summary).collect::<Vec<_>>())
                .map_err(|error| error.to_string())
        }
        Request::Get { id } => {
            let store = TodoStore::load_default().map_err(|error| error.to_string())?;
            let todo = store
                .list()
                .iter()
                .find(|todo| todo.id == id)
                .cloned()
                .ok_or_else(|| format!("task {id} was not found"))?;
            serde_json::to_value(todo).map_err(|error| error.to_string())
        }
        Request::Add { title } => {
            let mut store = TodoStore::load_default().map_err(|error| error.to_string())?;
            let todo = store.add(title).map_err(|error| error.to_string())?;
            serde_json::to_value(todo_summary(&todo)).map_err(|error| error.to_string())
        }
        Request::Update {
            id,
            title,
            content,
            completion_result,
            completed,
        } => {
            let mut store = TodoStore::load_default().map_err(|error| error.to_string())?;
            let todo = store
                .update(id, title, content, completion_result, completed)
                .map_err(|error| error.to_string())?;
            serde_json::to_value(todo).map_err(|error| error.to_string())
        }
        Request::Delete { id } => {
            let mut store = TodoStore::load_default().map_err(|error| error.to_string())?;
            store.delete(id).map_err(|error| error.to_string())?;
            Ok(Value::Bool(true))
        }
        Request::ClearCompleted => {
            let mut store = TodoStore::load_default().map_err(|error| error.to_string())?;
            let count = store.clear_completed().map_err(|error| error.to_string())?;
            Ok(json!(count))
        }
        Request::SetAllCompleted { completed } => {
            let mut store = TodoStore::load_default().map_err(|error| error.to_string())?;
            store
                .set_all_completed(completed)
                .map_err(|error| error.to_string())?;
            serde_json::to_value(store.list().iter().map(todo_summary).collect::<Vec<_>>())
                .map_err(|error| error.to_string())
        }
        Request::DataPath => {
            let store = TodoStore::load_default().map_err(|error| error.to_string())?;
            Ok(Value::String(store.path().display().to_string()))
        }
        Request::RenderMarkdown { markdown } => {
            serde_json::to_value(render_markdown(&markdown)).map_err(|error| error.to_string())
        }
    }
}

fn todo_summary(todo: &Todo) -> TodoSummary {
    let document = document_text(todo);
    let mut lines = document
        .lines()
        .map(strip_markdown)
        .filter(|line| !line.is_empty() && !is_separator(line));

    let title = lines.next().unwrap_or_else(|| "新任务".to_owned());
    let subtitle = lines.collect::<Vec<_>>().join(" ");

    TodoSummary {
        id: todo.id,
        title: truncate(&title, 42),
        subtitle: if subtitle.is_empty() {
            "暂无更多内容".to_owned()
        } else {
            truncate(&subtitle, 76)
        },
        completed: todo.completed,
        created_at_ms: todo.created_at_ms,
    }
}

fn document_text(todo: &Todo) -> String {
    let title = todo.title.trim();
    let content = todo.content.trim();
    match (title.is_empty(), content.is_empty()) {
        (true, _) => content.to_owned(),
        (_, true) => title.to_owned(),
        (false, false) => format!("{title}\n\n{content}"),
    }
}

fn strip_markdown(value: &str) -> String {
    let mut value = value.trim().to_owned();

    while value.starts_with('#') {
        value.remove(0);
    }
    value = value.trim_start().to_owned();

    while value.starts_with('>') {
        value.remove(0);
        value = value.trim_start().to_owned();
    }

    for marker in ["- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "+ "] {
        if let Some(rest) = value.strip_prefix(marker) {
            value = rest.to_owned();
            break;
        }
    }

    let mut output = String::with_capacity(value.len());
    let mut skip_destination = false;
    let mut destination_depth = 0usize;
    for character in value.chars() {
        if skip_destination {
            match character {
                '(' => destination_depth += 1,
                ')' if destination_depth == 0 => skip_destination = false,
                ')' => destination_depth -= 1,
                _ => {}
            }
            continue;
        }

        match character {
            '`' | '*' | '_' | '~' => {}
            ']' => {}
            '(' if output.ends_with(']') => {
                output.pop();
                skip_destination = true;
            }
            '<' | '>' => {}
            '|' => output.push(' '),
            other => output.push(other),
        }
    }

    output.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn is_separator(value: &str) -> bool {
    value.len() >= 3
        && value
            .chars()
            .all(|character| matches!(character, '-' | '=' | ':'))
}

fn truncate(value: &str, limit: usize) -> String {
    let mut characters = value.chars();
    let prefix = characters.by_ref().take(limit).collect::<String>();
    if characters.next().is_some() {
        format!("{prefix}…")
    } else {
        prefix
    }
}

fn render_markdown(markdown: &str) -> Vec<MarkdownRun> {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_FOOTNOTES);
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TASKLISTS);

    let mut runs = Vec::new();
    let mut state = InlineState::default();
    let mut lists = Vec::<ListState>::new();
    let mut in_table_head = false;
    let mut suppressed_html_depth = 0usize;

    for event in Parser::new_ext(markdown, options) {
        match &event {
            Event::Html(html) | Event::InlineHtml(html) => {
                let (opens, closes) = dangerous_html_counts(html);
                suppressed_html_depth = suppressed_html_depth.saturating_add(opens);
                suppressed_html_depth = suppressed_html_depth.saturating_sub(closes);
                continue;
            }
            Event::Text(_) if suppressed_html_depth > 0 => continue,
            _ => {}
        }

        match event {
            Event::Start(tag) => match tag {
                Tag::Paragraph => {}
                Tag::Heading { level, .. } => state.style = heading_style(level),
                Tag::BlockQuote(_) => {
                    state.quote_depth += 1;
                    if state.style == RunStyle::Body {
                        state.style = RunStyle::Quote;
                    }
                    append_text(&mut runs, &state, "▎ ");
                }
                Tag::CodeBlock(kind) => {
                    state.style = RunStyle::Code;
                    if let CodeBlockKind::Fenced(language) = kind {
                        let language = language.trim();
                        if !language.is_empty() {
                            append_text(&mut runs, &state, &format!("{language}\n"));
                        }
                    }
                }
                Tag::List(start) => lists.push(ListState { next_number: start }),
                Tag::Item => {
                    let depth = lists.len().saturating_sub(1);
                    let indent = "    ".repeat(depth);
                    let marker = match lists.last_mut().and_then(|list| list.next_number.as_mut()) {
                        Some(number) => {
                            let marker = format!("{number}. ");
                            *number += 1;
                            marker
                        }
                        None => "• ".to_owned(),
                    };
                    append_text(&mut runs, &state, &format!("{indent}{marker}"));
                }
                Tag::Emphasis => state.italic_depth += 1,
                Tag::Strong => state.bold_depth += 1,
                Tag::Strikethrough => state.strikethrough_depth += 1,
                Tag::Link { dest_url, .. } => state.link = Some(dest_url.to_string()),
                Tag::Image { .. } => {}
                Tag::FootnoteDefinition(label) => {
                    append_text(&mut runs, &state, &format!("[{}] ", label));
                }
                Tag::Table(_) => state.style = RunStyle::Table,
                Tag::TableHead => {
                    state.style = RunStyle::Table;
                    in_table_head = true;
                }
                Tag::TableRow => state.style = RunStyle::Table,
                Tag::TableCell => state.style = RunStyle::Table,
                Tag::HtmlBlock => {}
                Tag::MetadataBlock(_) => {}
                _ => {}
            },
            Event::End(tag) => match tag {
                TagEnd::Paragraph => append_text(&mut runs, &state, "\n\n"),
                TagEnd::Heading(_) => {
                    append_text(&mut runs, &state, "\n\n");
                    state.style = if state.quote_depth > 0 {
                        RunStyle::Quote
                    } else {
                        RunStyle::Body
                    };
                }
                TagEnd::BlockQuote(_) => {
                    append_text(&mut runs, &state, "\n");
                    state.quote_depth = state.quote_depth.saturating_sub(1);
                    if state.quote_depth == 0 {
                        state.style = RunStyle::Body;
                    }
                }
                TagEnd::CodeBlock => {
                    append_text(&mut runs, &state, "\n\n");
                    state.style = if state.quote_depth > 0 {
                        RunStyle::Quote
                    } else {
                        RunStyle::Body
                    };
                }
                TagEnd::List(_) => {
                    lists.pop();
                    if lists.is_empty() {
                        append_text(&mut runs, &state, "\n");
                    }
                }
                TagEnd::Item => append_text(&mut runs, &state, "\n"),
                TagEnd::Emphasis => state.italic_depth = state.italic_depth.saturating_sub(1),
                TagEnd::Strong => state.bold_depth = state.bold_depth.saturating_sub(1),
                TagEnd::Strikethrough => {
                    state.strikethrough_depth = state.strikethrough_depth.saturating_sub(1)
                }
                TagEnd::Link => state.link = None,
                TagEnd::Image => {}
                TagEnd::FootnoteDefinition => append_text(&mut runs, &state, "\n"),
                TagEnd::Table => {
                    append_text(&mut runs, &state, "\n");
                    state.style = RunStyle::Body;
                }
                TagEnd::TableHead => {
                    append_text(&mut runs, &state, "\n");
                    in_table_head = false;
                }
                TagEnd::TableRow => append_text(&mut runs, &state, "\n"),
                TagEnd::TableCell => append_text(&mut runs, &state, "\t"),
                TagEnd::HtmlBlock => {}
                TagEnd::MetadataBlock(_) => {}
                _ => {}
            },
            Event::Text(text) => {
                let mut run_state = state.clone();
                if in_table_head {
                    run_state.bold_depth += 1;
                }
                append_text(&mut runs, &run_state, &text);
            }
            Event::Code(text) => {
                let mut run_state = state.clone();
                run_state.style = RunStyle::Code;
                append_text(&mut runs, &run_state, &text);
            }
            Event::InlineMath(text) | Event::DisplayMath(text) => {
                let mut run_state = state.clone();
                run_state.style = RunStyle::Code;
                append_text(&mut runs, &run_state, &text);
            }
            Event::Html(_) | Event::InlineHtml(_) => unreachable!("raw HTML is handled above"),
            Event::FootnoteReference(label) => {
                append_text(&mut runs, &state, &format!("[{}]", label));
            }
            Event::SoftBreak | Event::HardBreak => append_text(&mut runs, &state, "\n"),
            Event::Rule => {
                let mut separator_state = state.clone();
                separator_state.style = RunStyle::Separator;
                append_text(&mut runs, &separator_state, "────────────\n");
            }
            Event::TaskListMarker(checked) => {
                if let Some(last) = runs.last_mut() {
                    if last.text.ends_with("• ") {
                        last.text
                            .truncate(last.text.len().saturating_sub("• ".len()));
                    }
                }
                append_text(&mut runs, &state, if checked { "☑ " } else { "☐ " });
            }
        }
    }

    while runs.last().is_some_and(|run| run.text.ends_with('\n')) {
        let last = runs.last_mut().expect("checked above");
        last.text.pop();
        if last.text.is_empty() {
            runs.pop();
        } else {
            break;
        }
    }

    runs
}

fn dangerous_html_counts(html: &str) -> (usize, usize) {
    let html = html.to_ascii_lowercase();
    let mut opens = 0usize;
    let mut closes = 0usize;

    for tag in ["script", "style", "iframe", "object", "embed"] {
        opens += html.matches(&format!("<{tag}")).count();
        closes += html.matches(&format!("</{tag}")).count();
    }

    (opens, closes)
}

fn heading_style(level: HeadingLevel) -> RunStyle {
    match level {
        HeadingLevel::H1 => RunStyle::Heading1,
        HeadingLevel::H2 => RunStyle::Heading2,
        HeadingLevel::H3 => RunStyle::Heading3,
        HeadingLevel::H4 => RunStyle::Heading4,
        HeadingLevel::H5 => RunStyle::Heading5,
        HeadingLevel::H6 => RunStyle::Heading6,
    }
}

fn append_text(runs: &mut Vec<MarkdownRun>, state: &InlineState, text: &str) {
    if text.is_empty() {
        return;
    }

    let run = MarkdownRun {
        text: text.to_owned(),
        style: state.style,
        bold: state.bold_depth > 0,
        italic: state.italic_depth > 0,
        strikethrough: state.strikethrough_depth > 0,
        link: state.link.clone(),
    };

    if let Some(last) = runs.last_mut() {
        if last.style == run.style
            && last.bold == run.bold
            && last.italic == run.italic
            && last.strikethrough == run.strikethrough
            && last.link == run.link
        {
            last.text.push_str(&run.text);
            return;
        }
    }

    runs.push(run);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_summaries_without_retaining_full_content() {
        let summary = todo_summary(&Todo {
            id: 7,
            title: String::new(),
            content: "# Main title\n\nMore **detail** here".to_owned(),
            completion_result: "Verified output".to_owned(),
            completed: false,
            created_at_ms: 1_234,
        });

        assert_eq!(summary.title, "Main title");
        assert_eq!(summary.subtitle, "More detail here");
        assert_eq!(summary.created_at_ms, 1_234);
    }

    #[test]
    fn accepts_completion_result_in_update_requests() {
        let request: Request = serde_json::from_str(
            r#"{"command":"update","id":9,"completionResult":"Tests passed"}"#,
        )
        .expect("update request should parse");

        match request {
            Request::Update {
                id,
                completion_result,
                ..
            } => {
                assert_eq!(id, 9);
                assert_eq!(completion_result.as_deref(), Some("Tests passed"));
            }
            _ => panic!("expected update request"),
        }
    }

    #[test]
    fn produces_structured_markdown_runs() {
        let runs =
            render_markdown("# Heading\n\nA **bold** [link](https://example.com).\n\n- [x] Done");

        assert!(runs
            .iter()
            .any(|run| run.style == RunStyle::Heading1 && run.text.contains("Heading")));
        assert!(runs.iter().any(|run| run.bold && run.text == "bold"));
        assert!(runs
            .iter()
            .any(|run| run.link.as_deref() == Some("https://example.com")));
        assert!(runs.iter().any(|run| run.text.contains('☑')));
    }

    #[test]
    fn ignores_raw_html() {
        let runs = render_markdown("before <script>alert(1)</script> after");
        let text = runs.into_iter().map(|run| run.text).collect::<String>();

        assert!(!text.contains("script"));
        assert!(!text.contains("alert"));
        assert!(text.contains("before"));
        assert!(text.contains("after"));
    }
}
