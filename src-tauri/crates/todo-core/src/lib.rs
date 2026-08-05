use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::{
    env, fmt,
    fs::{self, File, OpenOptions},
    io::{self, BufReader, BufWriter, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

pub const MAX_TITLE_LEN: usize = 240;
pub const MAX_CONTENT_LEN: usize = 25_000;
pub const MAX_COMPLETION_RESULT_LEN: usize = 10_000;
pub const APP_IDENTIFIER: &str = "com.xycdev.todo";

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TodoPriority {
    #[default]
    Low,
    Medium,
    High,
}

impl TodoPriority {
    pub const fn rank(self) -> u8 {
        match self {
            Self::Low => 0,
            Self::Medium => 1,
            Self::High => 2,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Todo {
    pub id: u64,
    pub title: String,
    #[serde(default)]
    pub content: String,
    #[serde(default)]
    pub completion_result: String,
    #[serde(default)]
    pub priority: TodoPriority,
    pub completed: bool,
    #[serde(default)]
    pub created_at_ms: i64,
}

#[derive(Debug)]
pub enum StoreError {
    Io(io::Error),
    Json(serde_json::Error),
    InvalidTitle,
    TitleTooLong,
    ContentTooLong,
    CompletionResultTooLong,
    EmptyTodo,
    NotFound(u64),
    DataDirectoryUnavailable,
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(f, "storage error: {error}"),
            Self::Json(error) => write!(f, "invalid todo data: {error}"),
            Self::InvalidTitle => write!(f, "task title cannot be empty"),
            Self::TitleTooLong => write!(f, "task title cannot exceed {MAX_TITLE_LEN} characters"),
            Self::ContentTooLong => {
                write!(f, "task content cannot exceed {MAX_CONTENT_LEN} characters")
            }
            Self::CompletionResultTooLong => write!(
                f,
                "completion result cannot exceed {MAX_COMPLETION_RESULT_LEN} characters"
            ),
            Self::EmptyTodo => write!(f, "task title and content cannot both be empty"),
            Self::NotFound(id) => write!(f, "task {id} was not found"),
            Self::DataDirectoryUnavailable => {
                write!(f, "application data directory is unavailable")
            }
        }
    }
}

impl std::error::Error for StoreError {}

impl From<io::Error> for StoreError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<serde_json::Error> for StoreError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

pub struct TodoStore {
    path: PathBuf,
    todos: Vec<Todo>,
    next_id: u64,
}

impl TodoStore {
    pub fn load(path: PathBuf) -> Result<Self, StoreError> {
        let mut todos = read_todos(&path)?;
        if todos.iter().any(|todo| todo.created_at_ms <= 0) {
            migrate_created_at(&path, &mut todos)?;
        }
        let next_id = next_id(&todos);
        Ok(Self {
            path,
            todos,
            next_id,
        })
    }

    pub fn load_default() -> Result<Self, StoreError> {
        Self::load(default_data_file()?)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn reload(&mut self) -> Result<(), StoreError> {
        self.todos = read_todos(&self.path)?;
        self.next_id = next_id(&self.todos);
        Ok(())
    }

    pub fn list(&self) -> &[Todo] {
        &self.todos
    }

    pub fn add(&mut self, title: String) -> Result<Todo, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload()?;
        let title = normalize_title(title)?;
        let todo = Todo {
            id: self.next_id,
            title,
            content: String::new(),
            completion_result: String::new(),
            priority: TodoPriority::Low,
            completed: false,
            created_at_ms: now_ms(),
        };
        self.next_id += 1;
        self.todos.push(todo.clone());
        self.persist()?;
        Ok(todo)
    }

    pub fn update(
        &mut self,
        id: u64,
        title: Option<String>,
        content: Option<String>,
        completion_result: Option<String>,
        priority: Option<TodoPriority>,
        completed: Option<bool>,
    ) -> Result<Todo, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload()?;
        let normalized_title = title.map(normalize_optional_title).transpose()?;
        let normalized_content = content.map(normalize_content).transpose()?;
        let normalized_completion_result = completion_result
            .map(normalize_completion_result)
            .transpose()?;
        let todo = self
            .todos
            .iter_mut()
            .find(|todo| todo.id == id)
            .ok_or(StoreError::NotFound(id))?;

        if let Some(title) = normalized_title {
            todo.title = title;
        }
        if let Some(content) = normalized_content {
            todo.content = content;
        }
        if let Some(completion_result) = normalized_completion_result {
            todo.completion_result = completion_result;
        }
        if let Some(priority) = priority {
            todo.priority = priority;
        }
        if let Some(completed) = completed {
            todo.completed = completed;
        }

        if todo.title.is_empty() && todo.content.is_empty() {
            return Err(StoreError::EmptyTodo);
        }

        let updated = todo.clone();
        self.persist()?;
        Ok(updated)
    }

    pub fn delete(&mut self, id: u64) -> Result<Todo, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload()?;
        let index = self
            .todos
            .iter()
            .position(|todo| todo.id == id)
            .ok_or(StoreError::NotFound(id))?;
        let removed = self.todos.remove(index);
        self.persist()?;
        Ok(removed)
    }

    pub fn clear_completed(&mut self) -> Result<usize, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload()?;
        let before = self.todos.len();
        self.todos.retain(|todo| !todo.completed);
        let removed = before - self.todos.len();
        if removed > 0 {
            self.persist()?;
        }
        Ok(removed)
    }

    pub fn set_all_completed(&mut self, completed: bool) -> Result<usize, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload()?;
        let mut changed = 0;
        for todo in &mut self.todos {
            if todo.completed != completed {
                todo.completed = completed;
                changed += 1;
            }
        }
        if changed > 0 {
            self.persist()?;
        }
        Ok(changed)
    }

    fn lock_exclusive(&self) -> Result<File, StoreError> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let lock_path = self.path.with_extension("lock");
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(lock_path)?;
        lock.lock_exclusive()?;
        Ok(lock)
    }

    fn persist(&self) -> Result<(), StoreError> {
        persist_todos(&self.path, &self.todos)
    }
}

pub fn default_data_file() -> Result<PathBuf, StoreError> {
    if let Some(path) = env::var_os("TODO_DATA_FILE") {
        return Ok(PathBuf::from(path));
    }

    #[cfg(target_os = "macos")]
    {
        return home_dir()
            .map(|home| {
                home.join("Library")
                    .join("Application Support")
                    .join(APP_IDENTIFIER)
                    .join("todos.json")
            })
            .ok_or(StoreError::DataDirectoryUnavailable);
    }

    #[cfg(target_os = "windows")]
    {
        return env::var_os("APPDATA")
            .map(PathBuf::from)
            .map(|dir| dir.join(APP_IDENTIFIER).join("todos.json"))
            .ok_or(StoreError::DataDirectoryUnavailable);
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        if let Some(data_home) = env::var_os("XDG_DATA_HOME") {
            return Ok(PathBuf::from(data_home)
                .join(APP_IDENTIFIER)
                .join("todos.json"));
        }
        return home_dir()
            .map(|home| {
                home.join(".local")
                    .join("share")
                    .join(APP_IDENTIFIER)
                    .join("todos.json")
            })
            .ok_or(StoreError::DataDirectoryUnavailable);
    }

    #[allow(unreachable_code)]
    Err(StoreError::DataDirectoryUnavailable)
}

fn read_todos(path: &Path) -> Result<Vec<Todo>, StoreError> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let file = File::open(path)?;
    Ok(serde_json::from_reader(BufReader::new(file))?)
}

fn migrate_created_at(path: &Path, todos: &mut Vec<Todo>) -> Result<(), StoreError> {
    if !path.exists() || todos.is_empty() {
        return Ok(());
    }

    let lock_path = path.with_extension("lock");
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(lock_path)?;
    lock.lock_exclusive()?;

    *todos = read_todos(path)?;
    if !todos.iter().any(|todo| todo.created_at_ms <= 0) {
        return Ok(());
    }

    let fallback = file_modified_ms(path).unwrap_or_else(now_ms);
    for todo in todos.iter_mut() {
        if todo.created_at_ms <= 0 {
            todo.created_at_ms = fallback;
        }
    }
    persist_todos(path, todos)
}

fn persist_todos(path: &Path, todos: &[Todo]) -> Result<(), StoreError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let temporary_path = temporary_path(path);
    let file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&temporary_path)?;
    let mut writer = BufWriter::new(file);
    serde_json::to_writer(&mut writer, todos)?;
    writer.flush()?;
    writer.get_ref().sync_all()?;

    #[cfg(target_os = "windows")]
    if path.exists() {
        fs::remove_file(path)?;
    }

    fs::rename(temporary_path, path)?;
    Ok(())
}

fn now_ms() -> i64 {
    system_time_ms(SystemTime::now()).unwrap_or(1)
}

fn file_modified_ms(path: &Path) -> Option<i64> {
    fs::metadata(path)
        .ok()?
        .modified()
        .ok()
        .and_then(system_time_ms)
}

fn system_time_ms(time: SystemTime) -> Option<i64> {
    let millis = time.duration_since(UNIX_EPOCH).ok()?.as_millis();
    i64::try_from(millis).ok()
}

fn next_id(todos: &[Todo]) -> u64 {
    todos.iter().map(|todo| todo.id).max().unwrap_or(0) + 1
}

fn normalize_title(title: String) -> Result<String, StoreError> {
    let title = title.trim();
    if title.is_empty() {
        return Err(StoreError::InvalidTitle);
    }
    if title.chars().count() > MAX_TITLE_LEN {
        return Err(StoreError::TitleTooLong);
    }
    Ok(title.to_owned())
}

fn normalize_optional_title(title: String) -> Result<String, StoreError> {
    let title = title.trim();
    if title.chars().count() > MAX_TITLE_LEN {
        return Err(StoreError::TitleTooLong);
    }
    Ok(title.to_owned())
}

fn normalize_content(content: String) -> Result<String, StoreError> {
    let content = content.trim();
    if content.chars().count() > MAX_CONTENT_LEN {
        return Err(StoreError::ContentTooLong);
    }
    Ok(content.to_owned())
}

fn normalize_completion_result(result: String) -> Result<String, StoreError> {
    let result = result.trim();
    if result.chars().count() > MAX_COMPLETION_RESULT_LEN {
        return Err(StoreError::CompletionResultTooLong);
    }
    Ok(result.to_owned())
}

fn temporary_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("todos.json");
    path.with_file_name(format!(".{file_name}.tmp"))
}

fn home_dir() -> Option<PathBuf> {
    env::var_os("HOME").map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn test_path(name: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be after the Unix epoch")
            .as_nanos();
        env::temp_dir().join(format!("todo-core-{name}-{unique}.json"))
    }

    #[test]
    fn rejects_blank_and_oversized_titles() {
        assert!(matches!(
            normalize_title("   ".to_owned()),
            Err(StoreError::InvalidTitle)
        ));
        assert!(matches!(
            normalize_title("x".repeat(MAX_TITLE_LEN + 1)),
            Err(StoreError::TitleTooLong)
        ));
    }

    #[test]
    fn persists_mutations() {
        let path = test_path("mutations");
        let mut store = TodoStore::load(path.clone()).expect("store should load");

        let first = store
            .add("  Write tests  ".to_owned())
            .expect("todo should be added");
        let second = store
            .add("Ship MVP".to_owned())
            .expect("todo should be added");
        store
            .update(first.id, None, None, None, None, Some(true))
            .expect("todo should be updated");
        store.delete(second.id).expect("todo should be deleted");

        let reloaded = TodoStore::load(path.clone()).expect("store should reload");
        assert_eq!(
            reloaded.list(),
            &[Todo {
                id: first.id,
                title: "Write tests".to_owned(),
                content: String::new(),
                completion_result: String::new(),
                priority: TodoPriority::Low,
                completed: true,
                created_at_ms: first.created_at_ms,
            }]
        );

        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn clears_completed_tasks() {
        let path = test_path("clear");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let first = store.add("Keep".to_owned()).expect("todo should be added");
        let second = store
            .add("Remove".to_owned())
            .expect("todo should be added");
        store
            .update(second.id, None, None, None, None, Some(true))
            .expect("todo should be updated");

        assert_eq!(store.clear_completed().expect("clear should succeed"), 1);
        assert_eq!(store.list(), &[first]);

        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn supports_content_without_an_explicit_title() {
        let path = test_path("content");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let todo = store
            .add("Temporary title".to_owned())
            .expect("todo should be added");

        let updated = store
            .update(
                todo.id,
                Some(String::new()),
                Some("First line\nMore detail".to_owned()),
                None,
                None,
                None,
            )
            .expect("content-only todo should be valid");

        assert!(updated.title.is_empty());
        assert_eq!(updated.content, "First line\nMore detail");

        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn stores_and_clears_an_optional_completion_result() {
        let path = test_path("completion-result");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let todo = store
            .add("Ship release".to_owned())
            .expect("todo should be added");

        let updated = store
            .update(
                todo.id,
                None,
                None,
                Some("Released v1.0 and verified the package".to_owned()),
                None,
                Some(true),
            )
            .expect("completion result should update");
        assert_eq!(
            updated.completion_result,
            "Released v1.0 and verified the package"
        );

        let cleared = store
            .update(todo.id, None, None, Some("   ".to_owned()), None, None)
            .expect("completion result should clear");
        assert!(cleared.completion_result.is_empty());

        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn preserves_creation_time_across_updates_and_reloads() {
        let path = test_path("created-at");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let todo = store
            .add("Timestamped".to_owned())
            .expect("todo should be added");
        assert!(todo.created_at_ms > 0);

        let updated = store
            .update(
                todo.id,
                None,
                Some("Changed".to_owned()),
                None,
                None,
                Some(true),
            )
            .expect("todo should update");
        assert_eq!(updated.created_at_ms, todo.created_at_ms);

        let reloaded = TodoStore::load(path.clone()).expect("store should reload");
        assert_eq!(reloaded.list()[0].created_at_ms, todo.created_at_ms);
        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn defaults_and_updates_priority() {
        let path = test_path("priority");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let todo = store
            .add("Prioritized".to_owned())
            .expect("todo should be added");
        assert_eq!(todo.priority, TodoPriority::Low);

        let updated = store
            .update(todo.id, None, None, None, Some(TodoPriority::High), None)
            .expect("priority should update");
        assert_eq!(updated.priority, TodoPriority::High);

        let reloaded = TodoStore::load(path.clone()).expect("store should reload");
        assert_eq!(reloaded.list()[0].priority, TodoPriority::High);
        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn migrates_legacy_todos_with_a_persisted_creation_time() {
        let path = test_path("legacy-created-at");
        fs::write(
            &path,
            r#"[{"id":1,"title":"Legacy","content":"","completed":false}]"#,
        )
        .expect("legacy data should be written");

        let store = TodoStore::load(path.clone()).expect("legacy store should migrate");
        assert!(store.list()[0].created_at_ms > 0);
        assert!(store.list()[0].completion_result.is_empty());
        assert_eq!(store.list()[0].priority, TodoPriority::Low);

        let persisted = fs::read_to_string(&path).expect("migrated data should be readable");
        assert!(persisted.contains("createdAtMs"));
        fs::remove_file(path).expect("test data should be removable");
    }
}
