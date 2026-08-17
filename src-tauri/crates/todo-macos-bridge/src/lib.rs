use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    ffi::{CStr, CString},
    fs,
    os::raw::c_char,
    panic::{catch_unwind, AssertUnwindSafe},
    path::{Path, PathBuf},
};
use todo_core::{
    default_data_file, Task, TaskKind, TaskRecord, Todo, TodoCompletionState, TodoPriority,
    TodoStore,
};

#[derive(Debug, Deserialize)]
#[serde(tag = "command", rename_all = "camelCase")]
enum Request {
    List,
    Get {
        id: u64,
    },
    Add {
        title: String,
        #[serde(rename = "initialSubtaskTitle")]
        initial_subtask_title: Option<String>,
    },
    Update {
        id: u64,
        title: Option<String>,
        content: Option<String>,
        #[serde(rename = "completionResult")]
        completion_result: Option<String>,
        priority: Option<TodoPriority>,
        completed: Option<bool>,
    },
    Delete {
        id: u64,
    },
    AddSubtask {
        id: u64,
        title: String,
    },
    UpdateSubtask {
        id: u64,
        #[serde(rename = "subtaskId")]
        subtask_id: u64,
        title: Option<String>,
        content: Option<String>,
        #[serde(rename = "completionResult")]
        completion_result: Option<String>,
        priority: Option<TodoPriority>,
        completed: Option<bool>,
    },
    DeleteSubtask {
        id: u64,
        #[serde(rename = "subtaskId")]
        subtask_id: u64,
    },
    ReorderParents {
        ids: Vec<u64>,
    },
    ReorderSubtasks {
        id: u64,
        ids: Vec<u64>,
    },
    SetArchived {
        ids: Vec<u64>,
        archived: bool,
    },
    ArchiveCompleted,
    RestoreArchived,
    ClearCompleted,
    ClearArchived,
    SetAllCompleted {
        completed: bool,
    },
    ListFolders,
    CreateFolder {
        name: String,
    },
    RenameFolder {
        name: String,
        #[serde(rename = "newName")]
        new_name: String,
    },
    DeleteFolder {
        name: String,
    },
    FolderDataPath {
        name: String,
    },
    DataPath,
    RenderMarkdown {
        markdown: String,
    },
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct TaskSummary {
    kind: TaskKind,
    parent_id: Option<u64>,
    id: u64,
    selection_id: u64,
    child_index: Option<usize>,
    collapsed_single_child: bool,
    title: String,
    subtitle: String,
    completed: bool,
    completion_state: TodoCompletionState,
    priority: TodoPriority,
    archived: bool,
    created_at_ms: i64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct TodoSummary {
    #[serde(flatten)]
    task: TaskSummary,
    subtask_count: usize,
    completed_subtask_count: usize,
    subtasks: Vec<TaskSummary>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct TaskDetail {
    kind: TaskKind,
    parent_id: Option<u64>,
    #[serde(flatten)]
    task: Task,
    completion_state: TodoCompletionState,
    archived: bool,
    title_only: bool,
    effective_title: String,
    title_inherited: bool,
    subtask_count: usize,
    subtasks: Vec<TaskSummary>,
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
    let raw: Value = serde_json::from_str(request).map_err(|error| error.to_string())?;
    let data_file = raw
        .get("dataFile")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from);
    let request: Request = serde_json::from_value(raw).map_err(|error| error.to_string())?;

    match request {
        Request::List => {
            let store = load_store(data_file.as_deref())?;
            summaries(&store)
        }
        Request::Get { id } => {
            let store = load_store(data_file.as_deref())?;
            let detail =
                task_detail(&store, id).ok_or_else(|| format!("task {id} was not found"))?;
            serde_json::to_value(detail).map_err(|error| error.to_string())
        }
        Request::Add {
            title,
            initial_subtask_title,
        } => {
            let mut store = load_store(data_file.as_deref())?;
            let todo = match initial_subtask_title {
                Some(child_title) => store.add_with_initial_subtask(title, child_title),
                None => store.add(title),
            }
            .map_err(|error| error.to_string())?;
            serde_json::to_value(todo_summary(&todo)).map_err(|error| error.to_string())
        }
        Request::Update {
            id,
            title,
            content,
            completion_result,
            priority,
            completed,
        } => {
            let mut store = load_store(data_file.as_deref())?;
            store
                .update(id, title, content, completion_result, priority, completed)
                .map_err(|error| error.to_string())?;
            let detail =
                task_detail(&store, id).ok_or_else(|| format!("task {id} was not found"))?;
            serde_json::to_value(detail).map_err(|error| error.to_string())
        }
        Request::Delete { id } => {
            let mut store = load_store(data_file.as_deref())?;
            store.delete_task(id).map_err(|error| error.to_string())?;
            summaries(&store)
        }
        Request::AddSubtask { id, title } => {
            let mut store = load_store(data_file.as_deref())?;
            let record = store
                .add_subtask(id, title)
                .map_err(|error| error.to_string())?;
            let archived = store.todo(id).is_some_and(|todo| todo.archived);
            serde_json::to_value(task_detail_from_record(record, archived))
                .map_err(|error| error.to_string())
        }
        Request::UpdateSubtask {
            id,
            subtask_id,
            title,
            content,
            completion_result,
            priority,
            completed,
        } => {
            let mut store = load_store(data_file.as_deref())?;
            let existing = store
                .task(subtask_id)
                .ok_or_else(|| format!("task {subtask_id} was not found"))?;
            if existing.parent_id != Some(id) {
                return Err(format!("task {subtask_id} is not a child of task {id}"));
            }
            let record = store
                .update(
                    subtask_id,
                    title,
                    content,
                    completion_result,
                    priority,
                    completed,
                )
                .map_err(|error| error.to_string())?;
            let archived = store.todo(id).is_some_and(|todo| todo.archived);
            serde_json::to_value(task_detail_from_record(record, archived))
                .map_err(|error| error.to_string())
        }
        Request::DeleteSubtask { id, subtask_id } => {
            let mut store = load_store(data_file.as_deref())?;
            let record = store
                .task(subtask_id)
                .ok_or_else(|| format!("task {subtask_id} was not found"))?;
            if record.parent_id != Some(id) {
                return Err(format!("task {subtask_id} is not a child of task {id}"));
            }
            store
                .delete_task(subtask_id)
                .map_err(|error| error.to_string())?;
            Ok(Value::Bool(true))
        }
        Request::ReorderParents { ids } => {
            let mut store = load_store(data_file.as_deref())?;
            store
                .reorder_parents(&ids)
                .map_err(|error| error.to_string())?;
            Ok(Value::Bool(true))
        }
        Request::ReorderSubtasks { id, ids } => {
            let mut store = load_store(data_file.as_deref())?;
            store
                .reorder_subtasks(id, &ids)
                .map_err(|error| error.to_string())?;
            Ok(Value::Bool(true))
        }
        Request::SetArchived { ids, archived } => {
            let mut store = load_store(data_file.as_deref())?;
            let count = store
                .set_archived_for_ids(&ids, archived)
                .map_err(|error| error.to_string())?;
            Ok(json!(count))
        }
        Request::ArchiveCompleted => {
            let mut store = load_store(data_file.as_deref())?;
            let count = store
                .archive_completed()
                .map_err(|error| error.to_string())?;
            Ok(json!(count))
        }
        Request::RestoreArchived => {
            let mut store = load_store(data_file.as_deref())?;
            let count = store
                .restore_archived()
                .map_err(|error| error.to_string())?;
            Ok(json!(count))
        }
        Request::ClearCompleted => {
            let mut store = load_store(data_file.as_deref())?;
            let count = store.clear_completed().map_err(|error| error.to_string())?;
            Ok(json!(count))
        }
        Request::ClearArchived => {
            let mut store = load_store(data_file.as_deref())?;
            let count = store.clear_archived().map_err(|error| error.to_string())?;
            Ok(json!(count))
        }
        Request::SetAllCompleted { completed } => {
            let mut store = load_store(data_file.as_deref())?;
            store
                .set_all_completed(completed)
                .map_err(|error| error.to_string())?;
            summaries(&store)
        }
        Request::ListFolders => {
            serde_json::to_value(list_folders()?).map_err(|error| error.to_string())
        }
        Request::CreateFolder { name } => {
            fs::create_dir_all(folders_directory()?).map_err(|error| error.to_string())?;
            let directory = folder_directory(&name)?;
            match fs::create_dir(&directory) {
                Ok(()) => Ok(Value::String(directory.display().to_string())),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    Err(format!("folder '{name}' already exists"))
                }
                Err(error) => Err(error.to_string()),
            }
        }
        Request::RenameFolder { name, new_name } => {
            let source = folder_directory(&name)?;
            let destination = folder_directory(&new_name)?;
            if !source.is_dir() {
                return Err(format!("folder '{name}' was not found"));
            }
            if destination.exists() {
                return Err(format!("folder '{new_name}' already exists"));
            }
            fs::rename(source, &destination).map_err(|error| error.to_string())?;
            Ok(Value::String(destination.display().to_string()))
        }
        Request::DeleteFolder { name } => {
            let directory = folder_directory(&name)?;
            if !directory.is_dir() {
                return Err(format!("folder '{name}' was not found"));
            }
            fs::remove_dir_all(directory).map_err(|error| error.to_string())?;
            Ok(Value::Bool(true))
        }
        Request::FolderDataPath { name } => Ok(Value::String(
            folder_data_path(&name)?.display().to_string(),
        )),
        Request::DataPath => {
            let store = load_store(data_file.as_deref())?;
            Ok(Value::String(store.path().display().to_string()))
        }
        Request::RenderMarkdown { markdown } => {
            serde_json::to_value(render_markdown(&markdown)).map_err(|error| error.to_string())
        }
    }
}

fn load_store(path: Option<&Path>) -> Result<TodoStore, String> {
    match path {
        Some(path) => TodoStore::load(path.to_path_buf()),
        None => TodoStore::load_default(),
    }
    .map_err(|error| error.to_string())
}

fn data_directory() -> Result<PathBuf, String> {
    let data_file = default_data_file().map_err(|error| error.to_string())?;
    data_file
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| "todo data file has no parent directory".to_owned())
}

fn folders_directory() -> Result<PathBuf, String> {
    Ok(data_directory()?.join("folders"))
}

fn legacy_weekly_reports_directory() -> Result<PathBuf, String> {
    Ok(data_directory()?.join("weekly-reports"))
}

fn validate_folder_name(name: &str) -> Result<&str, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("folder name cannot be empty".to_owned());
    }
    if name.len() > 80 {
        return Err("folder name cannot exceed 80 bytes".to_owned());
    }
    if name == "."
        || name == ".."
        || name.contains('/')
        || name.contains('\\')
        || name.chars().any(char::is_control)
    {
        return Err("folder name contains unsupported characters".to_owned());
    }
    Ok(name)
}

fn folder_directory(name: &str) -> Result<PathBuf, String> {
    Ok(folders_directory()?.join(validate_folder_name(name)?))
}

fn folder_data_path(name: &str) -> Result<PathBuf, String> {
    Ok(folder_directory(name)?.join("todos.json"))
}

fn list_folders() -> Result<Vec<String>, String> {
    migrate_legacy_weekly_reports()?;
    let directory = folders_directory()?;
    if !directory.exists() {
        return Ok(Vec::new());
    }
    let mut names = fs::read_dir(directory)
        .map_err(|error| error.to_string())?
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| validate_folder_name(name).is_ok())
        .collect::<Vec<_>>();
    names.sort_by(|left, right| right.cmp(left));
    Ok(names)
}

fn migrate_legacy_weekly_reports() -> Result<(), String> {
    let source_root = legacy_weekly_reports_directory()?;
    if !source_root.is_dir() {
        return Ok(());
    }
    let destination_root = folders_directory()?;
    fs::create_dir_all(&destination_root).map_err(|error| error.to_string())?;
    for entry in fs::read_dir(source_root).map_err(|error| error.to_string())? {
        let entry = entry.map_err(|error| error.to_string())?;
        if !entry
            .file_type()
            .map_err(|error| error.to_string())?
            .is_dir()
        {
            continue;
        }
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if validate_folder_name(&name).is_err() {
            continue;
        }
        let destination = destination_root.join(&name);
        if destination.exists() {
            continue;
        }
        fs::create_dir(&destination).map_err(|error| error.to_string())?;
        let merged = merge_legacy_weekly_todos(&entry.path())?;
        if !merged.is_empty() {
            let data = serde_json::to_vec(&merged).map_err(|error| error.to_string())?;
            fs::write(destination.join("todos.json"), data).map_err(|error| error.to_string())?;
        }
    }
    Ok(())
}

fn merge_legacy_weekly_todos(directory: &Path) -> Result<Vec<Todo>, String> {
    let mut merged = read_optional_todos(&directory.join("done.json"))?;
    let mut next_id = merged
        .iter()
        .flat_map(|todo| {
            std::iter::once(todo.task.id).chain(todo.subtasks.iter().map(|task| task.id))
        })
        .max()
        .unwrap_or(0)
        .saturating_add(1);
    for mut todo in read_optional_todos(&directory.join("plan.json"))? {
        todo.task.id = next_id;
        next_id = next_id.saturating_add(1);
        for task in &mut todo.subtasks {
            task.id = next_id;
            next_id = next_id.saturating_add(1);
        }
        merged.push(todo);
    }
    Ok(merged)
}

fn read_optional_todos(path: &Path) -> Result<Vec<Todo>, String> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let bytes = fs::read(path).map_err(|error| error.to_string())?;
    serde_json::from_slice(&bytes).map_err(|error| error.to_string())
}

fn summaries(store: &TodoStore) -> Result<Value, String> {
    serde_json::to_value(store.list().iter().map(todo_summary).collect::<Vec<_>>())
        .map_err(|error| error.to_string())
}

fn task_detail(store: &TodoStore, id: u64) -> Option<TaskDetail> {
    if let Some(todo) = store.todo(id) {
        let mut task = todo.task.clone();
        task.completed = todo.is_completed();
        let effective_title = summary_text(&task).0;
        return Some(TaskDetail {
            kind: TaskKind::Parent,
            parent_id: None,
            task,
            completion_state: todo.completion_state(),
            archived: todo.archived,
            title_only: false,
            effective_title,
            title_inherited: false,
            subtask_count: todo.subtasks.len(),
            subtasks: todo
                .subtasks
                .iter()
                .enumerate()
                .map(|(index, task)| child_summary(task, todo.id, index + 1, todo.archived))
                .collect(),
        });
    }
    store.task(id).map(|record| {
        let archived = record
            .parent_id
            .and_then(|parent_id| store.todo(parent_id))
            .is_some_and(|todo| todo.archived);
        task_detail_from_record(record, archived)
    })
}

fn task_detail_from_record(record: TaskRecord, archived: bool) -> TaskDetail {
    let completion_state = if record.task.completed {
        TodoCompletionState::Completed
    } else {
        TodoCompletionState::Active
    };
    let effective_title = summary_text(&record.task).0;
    TaskDetail {
        kind: record.kind,
        parent_id: record.parent_id,
        task: record.task,
        completion_state,
        archived,
        title_only: false,
        effective_title,
        title_inherited: false,
        subtask_count: 0,
        subtasks: Vec::new(),
    }
}

fn todo_summary(todo: &Todo) -> TodoSummary {
    let subtasks = todo
        .subtasks
        .iter()
        .enumerate()
        .map(|(index, task)| child_summary(task, todo.id, index + 1, todo.archived))
        .collect::<Vec<_>>();
    let parent_text = summary_text(&todo.task);
    let task = TaskSummary {
        kind: TaskKind::Parent,
        parent_id: None,
        id: todo.id,
        selection_id: todo.id,
        child_index: None,
        collapsed_single_child: false,
        title: parent_text.0,
        subtitle: parent_text.1,
        completed: todo.is_completed(),
        completion_state: todo.completion_state(),
        priority: todo.derived_priority(),
        archived: todo.archived,
        created_at_ms: todo.created_at_ms,
    };
    TodoSummary {
        task,
        subtask_count: subtasks.len(),
        completed_subtask_count: todo.completed_subtask_count(),
        subtasks,
    }
}

fn child_summary(task: &Task, parent_id: u64, child_index: usize, archived: bool) -> TaskSummary {
    let base = summary_text(task);
    let completion_state = if task.completed {
        TodoCompletionState::Completed
    } else {
        TodoCompletionState::Active
    };
    TaskSummary {
        kind: TaskKind::Subtask,
        parent_id: Some(parent_id),
        id: task.id,
        selection_id: task.id,
        child_index: Some(child_index),
        collapsed_single_child: false,
        title: base.0,
        subtitle: base.1,
        completed: task.completed,
        completion_state,
        priority: task.priority,
        archived,
        created_at_ms: task.created_at_ms,
    }
}

fn summary_text(task: &Task) -> (String, String) {
    let document = document_text(task);
    let mut lines = document
        .lines()
        .map(strip_markdown)
        .filter(|line| !line.is_empty() && !is_separator(line));
    let title = lines.next().unwrap_or_else(|| "New Task".to_owned());
    let subtitle = lines.collect::<Vec<_>>().join(" ");
    (
        truncate(&title, 42),
        if subtitle.is_empty() {
            String::new()
        } else {
            truncate(&subtitle, 76)
        },
    )
}

fn document_text(task: &Task) -> String {
    let title = task.title.trim();
    let content = task.content.trim();
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

    fn task() -> Task {
        Task {
            id: 2,
            title: "Child".to_owned(),
            content: "More detail".to_owned(),
            completion_result: "Verified".to_owned(),
            priority: TodoPriority::High,
            completed: false,
            created_at_ms: 123,
        }
    }

    #[test]
    fn child_summary_keeps_first_class_fields() {
        let summary = child_summary(&task(), 1, 1, false);
        assert_eq!(summary.kind, TaskKind::Subtask);
        assert_eq!(summary.parent_id, Some(1));
        assert_eq!(summary.child_index, Some(1));
        assert_eq!(summary.selection_id, 2);
        assert_eq!(summary.title, "Child");
        assert_eq!(summary.subtitle, "More detail");
        assert_eq!(summary.priority, TodoPriority::High);
        assert_eq!(summary.created_at_ms, 123);
    }

    #[test]
    fn one_child_parent_summary_remains_independent() {
        let todo = Todo {
            task: Task {
                id: 1,
                title: "Parent".to_owned(),
                content: "Parent detail".to_owned(),
                completion_result: String::new(),
                priority: TodoPriority::Low,
                completed: false,
                created_at_ms: 100,
            },
            archived: false,
            subtasks: vec![task()],
        };
        let summary = todo_summary(&todo);
        assert_eq!(summary.subtask_count, 1);
        assert_eq!(summary.subtasks[0].id, 2);
        assert!(!summary.task.collapsed_single_child);
        assert_eq!(summary.task.id, 1);
        assert_eq!(summary.task.selection_id, 1);
        assert_eq!(summary.task.title, "Parent");
        assert_eq!(summary.task.subtitle, "Parent detail");
        assert_eq!(summary.task.priority, TodoPriority::High);
    }

    #[test]
    fn multi_child_parent_uses_own_content_and_local_indexes() {
        let mut second = task();
        second.id = 3;
        second.title = "Second".to_owned();
        let todo = Todo {
            task: Task {
                id: 1,
                title: "Parent".to_owned(),
                content: "Parent body".to_owned(),
                completion_result: String::new(),
                priority: TodoPriority::Low,
                completed: false,
                created_at_ms: 100,
            },
            archived: false,
            subtasks: vec![task(), second],
        };
        let summary = todo_summary(&todo);
        assert!(!summary.task.collapsed_single_child);
        assert_eq!(summary.task.selection_id, 1);
        assert_eq!(summary.task.title, "Parent");
        assert_eq!(summary.task.subtitle, "Parent body");
        assert_eq!(summary.subtasks[0].child_index, Some(1));
        assert_eq!(summary.subtasks[1].child_index, Some(2));
    }

    #[test]
    fn parses_first_class_subtask_requests() {
        let update: Request = serde_json::from_str(
            r##"{"command":"updateSubtask","id":1,"subtaskId":2,"content":"# Markdown","completionResult":"Done","priority":"high","completed":true}"##,
        )
        .expect("request should parse");
        assert!(matches!(
            update,
            Request::UpdateSubtask {
                id: 1,
                subtask_id: 2,
                content: Some(_),
                completion_result: Some(_),
                priority: Some(TodoPriority::High),
                completed: Some(true),
                ..
            }
        ));
    }

    #[test]
    fn parses_two_level_reorder_requests() {
        let parents: Request =
            serde_json::from_str(r#"{"command":"reorderParents","ids":[3,1,2]}"#)
                .expect("parent reorder should parse");
        assert!(matches!(parents, Request::ReorderParents { ids } if ids == vec![3, 1, 2]));

        let children: Request =
            serde_json::from_str(r#"{"command":"reorderSubtasks","id":7,"ids":[10,8,9]}"#)
                .expect("child reorder should parse");
        assert!(matches!(
            children,
            Request::ReorderSubtasks { id: 7, ids } if ids == vec![10, 8, 9]
        ));
    }

    #[test]
    fn produces_structured_markdown_runs() {
        let runs = render_markdown("# Heading\n\n**bold** and [link](https://example.com)");
        assert!(runs.iter().any(|run| run.style == RunStyle::Heading1));
        assert!(runs.iter().any(|run| run.bold));
        assert!(runs
            .iter()
            .any(|run| run.link.as_deref() == Some("https://example.com")));
    }

    #[test]
    fn ignores_raw_html() {
        let runs = render_markdown("before <script>alert(1)</script> after");
        let text = runs.iter().map(|run| run.text.as_str()).collect::<String>();
        assert!(!text.contains("script"));
        assert!(!text.contains("alert"));
    }

    #[test]
    fn folder_names_reject_path_traversal() {
        assert!(validate_folder_name("2026-08-17").is_ok());
        assert!(validate_folder_name("Research Notes").is_ok());
        assert!(validate_folder_name("../escape").is_err());
        assert!(validate_folder_name("nested/report").is_err());
        assert!(validate_folder_name(" ").is_err());
    }

    #[test]
    fn folder_data_path_uses_one_todo_store() {
        let root = PathBuf::from("/tmp/morrow-folders");
        let path = root.join("2026-08-17").join("todos.json");
        assert_eq!(
            path.file_name().and_then(|value| value.to_str()),
            Some("todos.json")
        );
    }

    #[test]
    fn data_file_scope_reuses_todo_operations_without_touching_default_store() {
        let unique = format!("morrow-planner-folder-scope-{}", std::process::id());
        let path = std::env::temp_dir().join(unique).join("todos.json");
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("test directory");
        }
        let encoded_path = serde_json::to_string(&path.display().to_string()).unwrap();
        let add = format!(r#"{{"command":"add","title":"Folder unit","dataFile":{encoded_path}}}"#);
        handle_request(&add).expect("scoped add");
        let list = format!(r#"{{"command":"list","dataFile":{encoded_path}}}"#);
        let items = handle_request(&list).expect("scoped list");
        let items = items.as_array().expect("list response");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], "Folder unit");
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn legacy_done_and_plan_are_merged_with_unique_ids() {
        let unique = format!("morrow-planner-legacy-folder-{}", std::process::id());
        let directory = std::env::temp_dir().join(unique);
        fs::create_dir_all(&directory).unwrap();
        let make_todo = |title: &str| Todo {
            task: Task {
                id: 1,
                title: String::new(),
                content: String::new(),
                completion_result: String::new(),
                priority: TodoPriority::Low,
                completed: false,
                created_at_ms: 1,
            },
            archived: false,
            subtasks: vec![Task {
                id: 2,
                title: title.to_owned(),
                content: String::new(),
                completion_result: String::new(),
                priority: TodoPriority::Low,
                completed: false,
                created_at_ms: 1,
            }],
        };
        fs::write(
            directory.join("done.json"),
            serde_json::to_vec(&vec![make_todo("Done")]).unwrap(),
        )
        .unwrap();
        fs::write(
            directory.join("plan.json"),
            serde_json::to_vec(&vec![make_todo("Plan")]).unwrap(),
        )
        .unwrap();
        let merged = merge_legacy_weekly_todos(&directory).unwrap();
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0].subtasks[0].title, "Done");
        assert_eq!(merged[1].subtasks[0].title, "Plan");
        assert_ne!(merged[0].task.id, merged[1].task.id);
        assert_ne!(merged[0].subtasks[0].id, merged[1].subtasks[0].id);
        let _ = fs::remove_dir_all(directory);
    }
}
