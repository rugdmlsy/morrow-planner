use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    env, fmt,
    fs::{self, File, OpenOptions},
    io::{self, BufReader, BufWriter, Write},
    ops::{Deref, DerefMut},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

pub const MAX_TITLE_LEN: usize = 240;
pub const MAX_CONTENT_LEN: usize = 25_000;
pub const MAX_COMPLETION_RESULT_LEN: usize = 10_000;
pub const MAX_SUBTASKS: usize = 500;
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

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TodoCompletionState {
    Active,
    Partial,
    Completed,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TaskKind {
    Parent,
    Subtask,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Task {
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

pub type Subtask = Task;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Todo {
    #[serde(flatten)]
    pub task: Task,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub subtasks: Vec<Subtask>,
}

impl Deref for Todo {
    type Target = Task;

    fn deref(&self) -> &Self::Target {
        &self.task
    }
}

impl DerefMut for Todo {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.task
    }
}

impl Todo {
    pub fn completion_state(&self) -> TodoCompletionState {
        let completed = self.completed_subtask_count();
        if completed == 0 {
            TodoCompletionState::Active
        } else if completed == self.subtasks.len() {
            TodoCompletionState::Completed
        } else {
            TodoCompletionState::Partial
        }
    }

    pub fn is_completed(&self) -> bool {
        self.completion_state() == TodoCompletionState::Completed
    }

    pub fn completed_subtask_count(&self) -> usize {
        self.subtasks.iter().filter(|task| task.completed).count()
    }

    fn set_completed(&mut self, completed: bool) -> bool {
        let changed = self.task.completed != completed
            || self.subtasks.iter().any(|task| task.completed != completed);
        self.task.completed = completed;
        for task in &mut self.subtasks {
            task.completed = completed;
        }
        changed
    }

    fn sync_completed_from_subtasks(&mut self) {
        self.task.completed =
            !self.subtasks.is_empty() && self.subtasks.iter().all(|task| task.completed);
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskRecord {
    pub kind: TaskKind,
    pub parent_id: Option<u64>,
    #[serde(flatten)]
    pub task: Task,
}

#[derive(Debug)]
pub enum StoreError {
    Io(io::Error),
    Json(serde_json::Error),
    InvalidTitle,
    TitleTooLong,
    ContentTooLong,
    CompletionResultTooLong,
    TooManySubtasks,
    LastSubtask,
    EmptyTodo,
    NotFound(u64),
    NotParent(u64),
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
            Self::TooManySubtasks => {
                write!(f, "a task cannot contain more than {MAX_SUBTASKS} subtasks")
            }
            Self::LastSubtask => write!(f, "a parent task must keep at least one subtask"),
            Self::EmptyTodo => write!(f, "task title and content cannot both be empty"),
            Self::NotFound(id) => write!(f, "task {id} was not found"),
            Self::NotParent(id) => write!(f, "task {id} is not a parent task"),
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
        if needs_migration(&todos) {
            migrate_data(&path, &mut todos)?;
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
        let _lock = self.lock_exclusive()?;
        self.reload_locked()
    }

    pub fn list(&self) -> &[Todo] {
        &self.todos
    }

    pub fn task(&self, id: u64) -> Option<TaskRecord> {
        for todo in &self.todos {
            if todo.id == id {
                return Some(TaskRecord {
                    kind: TaskKind::Parent,
                    parent_id: None,
                    task: todo.task.clone(),
                });
            }
            if let Some(task) = todo.subtasks.iter().find(|task| task.id == id) {
                return Some(TaskRecord {
                    kind: TaskKind::Subtask,
                    parent_id: Some(todo.id),
                    task: task.clone(),
                });
            }
        }
        None
    }

    pub fn todo(&self, id: u64) -> Option<&Todo> {
        self.todos.iter().find(|todo| todo.id == id)
    }

    pub fn add(&mut self, title: String) -> Result<Todo, StoreError> {
        let child_title = title.clone();
        self.add_with_initial_subtask(title, child_title)
    }

    pub fn add_with_initial_subtask(
        &mut self,
        title: String,
        initial_subtask_title: String,
    ) -> Result<Todo, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload_locked()?;
        let title = normalize_title(title)?;
        let initial_subtask_title = normalize_title(initial_subtask_title)?;
        let created_at_ms = now_ms();
        let parent_id = self.allocate_id();
        let child_id = self.allocate_id();
        let todo = Todo {
            task: Task {
                id: parent_id,
                title,
                content: String::new(),
                completion_result: String::new(),
                priority: TodoPriority::Low,
                completed: false,
                created_at_ms,
            },
            archived: false,
            subtasks: vec![Task {
                id: child_id,
                title: initial_subtask_title,
                content: String::new(),
                completion_result: String::new(),
                priority: TodoPriority::Low,
                completed: false,
                created_at_ms,
            }],
        };
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
    ) -> Result<TaskRecord, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload_locked()?;
        let title = title.map(normalize_optional_title).transpose()?;
        let content = content.map(normalize_content).transpose()?;
        let completion_result = completion_result
            .map(normalize_completion_result)
            .transpose()?;

        for todo in &mut self.todos {
            if todo.id == id {
                apply_task_update(&mut todo.task, title, content, completion_result, priority)?;
                if let Some(completed) = completed {
                    todo.set_completed(completed);
                }
                let record = TaskRecord {
                    kind: TaskKind::Parent,
                    parent_id: None,
                    task: todo.task.clone(),
                };
                self.persist()?;
                return Ok(record);
            }

            let parent_id = todo.id;
            if let Some(task) = todo.subtasks.iter_mut().find(|task| task.id == id) {
                apply_task_update(task, title, content, completion_result, priority)?;
                if let Some(completed) = completed {
                    task.completed = completed;
                }
                let record = TaskRecord {
                    kind: TaskKind::Subtask,
                    parent_id: Some(parent_id),
                    task: task.clone(),
                };
                todo.sync_completed_from_subtasks();
                self.persist()?;
                return Ok(record);
            }
        }
        Err(StoreError::NotFound(id))
    }

    pub fn add_subtask(&mut self, parent_id: u64, title: String) -> Result<TaskRecord, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload_locked()?;
        let title = normalize_title(title)?;
        let id = self.allocate_id();
        let todo = self
            .todos
            .iter_mut()
            .find(|todo| todo.id == parent_id)
            .ok_or(StoreError::NotParent(parent_id))?;
        if todo.subtasks.len() >= MAX_SUBTASKS {
            return Err(StoreError::TooManySubtasks);
        }
        let task = Task {
            id,
            title,
            content: String::new(),
            completion_result: String::new(),
            priority: TodoPriority::Low,
            completed: false,
            created_at_ms: now_ms(),
        };
        todo.subtasks.push(task.clone());
        todo.sync_completed_from_subtasks();
        self.persist()?;
        Ok(TaskRecord {
            kind: TaskKind::Subtask,
            parent_id: Some(parent_id),
            task,
        })
    }

    pub fn delete_task(&mut self, id: u64) -> Result<TaskRecord, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload_locked()?;
        if let Some(index) = self.todos.iter().position(|todo| todo.id == id) {
            let todo = self.todos.remove(index);
            let record = TaskRecord {
                kind: TaskKind::Parent,
                parent_id: None,
                task: todo.task,
            };
            self.persist()?;
            return Ok(record);
        }

        for todo in &mut self.todos {
            if let Some(index) = todo.subtasks.iter().position(|task| task.id == id) {
                if todo.subtasks.len() == 1 {
                    return Err(StoreError::LastSubtask);
                }
                let task = todo.subtasks.remove(index);
                let parent_id = todo.id;
                todo.sync_completed_from_subtasks();
                self.persist()?;
                return Ok(TaskRecord {
                    kind: TaskKind::Subtask,
                    parent_id: Some(parent_id),
                    task,
                });
            }
        }
        Err(StoreError::NotFound(id))
    }

    pub fn delete(&mut self, id: u64) -> Result<Todo, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload_locked()?;
        let index = self
            .todos
            .iter()
            .position(|todo| todo.id == id)
            .ok_or(StoreError::NotParent(id))?;
        let removed = self.todos.remove(index);
        self.persist()?;
        Ok(removed)
    }

    pub fn clear_completed(&mut self) -> Result<usize, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload_locked()?;
        let before = self.todos.len();
        self.todos
            .retain(|todo| !todo.is_completed() || todo.archived);
        let removed = before - self.todos.len();
        if removed > 0 {
            self.persist()?;
        }
        Ok(removed)
    }

    pub fn clear_archived(&mut self) -> Result<usize, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload_locked()?;
        let before = self.todos.len();
        self.todos.retain(|todo| !todo.archived);
        let removed = before - self.todos.len();
        if removed > 0 {
            self.persist()?;
        }
        Ok(removed)
    }

    pub fn set_archived_for_ids(
        &mut self,
        ids: &[u64],
        archived: bool,
    ) -> Result<usize, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload_locked()?;
        let mut changed = 0;
        for todo in &mut self.todos {
            if ids.contains(&todo.id) && todo.archived != archived {
                todo.archived = archived;
                changed += 1;
            }
        }
        if changed > 0 {
            self.persist()?;
        }
        Ok(changed)
    }

    pub fn archive_completed(&mut self) -> Result<usize, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload_locked()?;
        let mut changed = 0;
        for todo in &mut self.todos {
            if todo.is_completed() && !todo.archived {
                todo.archived = true;
                changed += 1;
            }
        }
        if changed > 0 {
            self.persist()?;
        }
        Ok(changed)
    }

    pub fn restore_archived(&mut self) -> Result<usize, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload_locked()?;
        let mut changed = 0;
        for todo in &mut self.todos {
            if todo.archived {
                todo.archived = false;
                changed += 1;
            }
        }
        if changed > 0 {
            self.persist()?;
        }
        Ok(changed)
    }

    pub fn set_all_completed(&mut self, completed: bool) -> Result<usize, StoreError> {
        let _lock = self.lock_exclusive()?;
        self.reload_locked()?;
        let mut changed = 0;
        for todo in &mut self.todos {
            if !todo.archived && todo.set_completed(completed) {
                changed += 1;
            }
        }
        if changed > 0 {
            self.persist()?;
        }
        Ok(changed)
    }

    fn reload_locked(&mut self) -> Result<(), StoreError> {
        self.todos = read_todos(&self.path)?;
        if needs_migration(&self.todos) {
            migrate_todos(&self.path, &mut self.todos)?;
        }
        self.next_id = next_id(&self.todos);
        Ok(())
    }

    fn allocate_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
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

fn apply_task_update(
    task: &mut Task,
    title: Option<String>,
    content: Option<String>,
    completion_result: Option<String>,
    priority: Option<TodoPriority>,
) -> Result<(), StoreError> {
    if let Some(title) = title {
        task.title = title;
    }
    if let Some(content) = content {
        task.content = content;
    }
    if let Some(completion_result) = completion_result {
        task.completion_result = completion_result;
    }
    if let Some(priority) = priority {
        task.priority = priority;
    }
    if task.title.is_empty() && task.content.is_empty() {
        return Err(StoreError::EmptyTodo);
    }
    Ok(())
}

fn read_todos(path: &Path) -> Result<Vec<Todo>, StoreError> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let file = File::open(path)?;
    Ok(serde_json::from_reader(BufReader::new(file))?)
}

fn needs_migration(todos: &[Todo]) -> bool {
    if todos.is_empty() {
        return false;
    }
    let mut ids = HashSet::new();
    for todo in todos {
        if todo.id == 0
            || todo.created_at_ms <= 0
            || todo.subtasks.is_empty()
            || !ids.insert(todo.id)
        {
            return true;
        }
        for task in &todo.subtasks {
            if task.id == 0 || task.created_at_ms <= 0 || !ids.insert(task.id) {
                return true;
            }
        }
        if todo.completed != todo.subtasks.iter().all(|task| task.completed) {
            return true;
        }
    }
    false
}

fn migrate_data(path: &Path, todos: &mut Vec<Todo>) -> Result<(), StoreError> {
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
    migrate_todos(path, todos)
}

fn migrate_todos(path: &Path, todos: &mut [Todo]) -> Result<(), StoreError> {
    if !needs_migration(todos) {
        return Ok(());
    }

    let fallback = file_modified_ms(path).unwrap_or_else(now_ms);
    let mut next = todos
        .iter()
        .flat_map(|todo| std::iter::once(todo.id).chain(todo.subtasks.iter().map(|task| task.id)))
        .max()
        .unwrap_or(0)
        + 1;
    let mut used = HashSet::new();

    for todo in todos.iter_mut() {
        if todo.id == 0 || !used.insert(todo.id) {
            todo.id = next;
            next += 1;
            used.insert(todo.id);
        }
        if todo.created_at_ms <= 0 {
            todo.created_at_ms = fallback;
        }
        if todo.subtasks.is_empty() {
            let child_id = next;
            next += 1;
            used.insert(child_id);
            todo.subtasks.push(Task {
                id: child_id,
                title: if todo.title.is_empty() {
                    "New Task".to_owned()
                } else {
                    todo.title.clone()
                },
                content: todo.content.clone(),
                completion_result: todo.completion_result.clone(),
                priority: todo.priority,
                completed: todo.completed,
                created_at_ms: todo.created_at_ms,
            });
        }
        let parent_created_at_ms = todo.created_at_ms;
        for task in &mut todo.subtasks {
            if task.id == 0 || !used.insert(task.id) {
                task.id = next;
                next += 1;
                used.insert(task.id);
            }
            if task.created_at_ms <= 0 {
                task.created_at_ms = parent_created_at_ms;
            }
        }
        todo.sync_completed_from_subtasks();
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
    todos
        .iter()
        .flat_map(|todo| std::iter::once(todo.id).chain(todo.subtasks.iter().map(|task| task.id)))
        .max()
        .unwrap_or(0)
        + 1
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
    fn new_parent_has_one_first_class_subtask() {
        let path = test_path("default-subtask");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let todo = store
            .add_with_initial_subtask("Project".to_owned(), "First step".to_owned())
            .expect("todo should be added");
        assert_eq!(todo.subtasks.len(), 1);
        assert_ne!(todo.id, todo.subtasks[0].id);
        assert_eq!(todo.subtasks[0].title, "First step");
        assert_eq!(todo.completion_state(), TodoCompletionState::Active);
        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn subtask_supports_document_result_priority_and_completion() {
        let path = test_path("subtask-fields");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let todo = store
            .add("Project".to_owned())
            .expect("todo should be added");
        let child_id = todo.subtasks[0].id;
        let record = store
            .update(
                child_id,
                Some(String::new()),
                Some("# Child\n\nMarkdown".to_owned()),
                Some("Verified".to_owned()),
                Some(TodoPriority::High),
                Some(true),
            )
            .expect("subtask should update");
        assert_eq!(record.kind, TaskKind::Subtask);
        assert_eq!(record.parent_id, Some(todo.id));
        assert_eq!(record.task.content, "# Child\n\nMarkdown");
        assert_eq!(record.task.completion_result, "Verified");
        assert_eq!(record.task.priority, TodoPriority::High);
        assert!(record.task.completed);
        assert!(store
            .todo(todo.id)
            .expect("parent should exist")
            .is_completed());
        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn parent_completion_cascades_and_partial_is_derived() {
        let path = test_path("derived-state");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let todo = store
            .add("Project".to_owned())
            .expect("todo should be added");
        let first = todo.subtasks[0].id;
        let second = store
            .add_subtask(todo.id, "Second".to_owned())
            .expect("subtask should be added")
            .task
            .id;
        store
            .update(first, None, None, None, None, Some(true))
            .expect("first should complete");
        assert_eq!(
            store
                .todo(todo.id)
                .expect("parent should exist")
                .completion_state(),
            TodoCompletionState::Partial
        );
        store
            .update(todo.id, None, None, None, None, Some(true))
            .expect("parent should complete");
        assert!(store
            .todo(todo.id)
            .expect("parent should exist")
            .subtasks
            .iter()
            .all(|task| task.completed));
        store
            .update(second, None, None, None, None, Some(false))
            .expect("second should restore");
        assert_eq!(
            store
                .todo(todo.id)
                .expect("parent should exist")
                .completion_state(),
            TodoCompletionState::Partial
        );
        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn ids_are_global_across_parents_and_children() {
        let path = test_path("global-ids");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let first = store.add("First".to_owned()).expect("todo should be added");
        let second = store
            .add("Second".to_owned())
            .expect("todo should be added");
        let added = store
            .add_subtask(first.id, "Extra".to_owned())
            .expect("subtask should be added");
        let ids = [
            first.id,
            first.subtasks[0].id,
            second.id,
            second.subtasks[0].id,
            added.task.id,
        ];
        assert_eq!(ids.iter().copied().collect::<HashSet<_>>().len(), ids.len());
        for id in ids {
            assert!(store.task(id).is_some());
        }
        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn deleting_last_subtask_is_rejected() {
        let path = test_path("last-subtask");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let todo = store
            .add("Project".to_owned())
            .expect("todo should be added");
        assert!(matches!(
            store.delete_task(todo.subtasks[0].id),
            Err(StoreError::LastSubtask)
        ));
        let added = store
            .add_subtask(todo.id, "Second".to_owned())
            .expect("subtask should be added");
        store
            .delete_task(added.task.id)
            .expect("extra subtask should delete");
        assert_eq!(
            store
                .todo(todo.id)
                .expect("parent should exist")
                .subtasks
                .len(),
            1
        );
        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn bulk_completion_and_completed_queries_use_children() {
        let path = test_path("bulk");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let first = store.add("First".to_owned()).expect("todo should be added");
        let second = store
            .add("Second".to_owned())
            .expect("todo should be added");
        store
            .update(first.subtasks[0].id, None, None, None, None, Some(true))
            .expect("child should complete");
        assert_eq!(
            store.archive_completed().expect("completed should archive"),
            1
        );
        assert!(store.todo(first.id).expect("first should exist").archived);
        assert!(!store.todo(second.id).expect("second should exist").archived);
        assert_eq!(
            store.set_all_completed(true).expect("all should complete"),
            1
        );
        assert!(store
            .todo(second.id)
            .expect("second should exist")
            .is_completed());
        assert_eq!(
            store.set_all_completed(false).expect("all should restore"),
            1
        );
        assert!(!store
            .todo(second.id)
            .expect("second should exist")
            .is_completed());
        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn migrates_legacy_leaf_and_duplicate_child_ids() {
        let path = test_path("migration");
        fs::write(
            &path,
            r#"[
                {"id":1,"title":"Legacy leaf","content":"Body","completed":true},
                {"id":2,"title":"Existing group","content":"","completed":false,"subtasks":[
                    {"id":1,"title":"Old child","completed":false}
                ]}
            ]"#,
        )
        .expect("legacy data should be written");
        let store = TodoStore::load(path.clone()).expect("legacy data should migrate");
        assert_eq!(store.list()[0].subtasks.len(), 1);
        assert!(store.list()[0].subtasks[0].completed);
        assert!(store.list()[0].subtasks[0].created_at_ms > 0);
        let ids = store
            .list()
            .iter()
            .flat_map(|todo| {
                std::iter::once(todo.id).chain(todo.subtasks.iter().map(|task| task.id))
            })
            .collect::<HashSet<_>>();
        assert_eq!(ids.len(), 4);
        let persisted = fs::read_to_string(&path).expect("migrated data should be readable");
        assert!(persisted.contains("completionResult"));
        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn mutation_migrates_external_legacy_data_under_one_lock() {
        let path = test_path("external-legacy");
        let mut store = TodoStore::load(path.clone()).expect("empty store should load");
        fs::write(
            &path,
            r#"[{"id":1,"title":"Legacy","content":"Body","completed":false}]"#,
        )
        .expect("legacy data should be written externally");

        let added = store
            .add("New parent".to_owned())
            .expect("mutation should migrate");
        assert_eq!(store.list().len(), 2);
        assert_eq!(store.list()[0].subtasks.len(), 1);
        assert_ne!(store.list()[0].subtasks[0].id, added.id);
        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn task_fields_persist_without_changing_creation_time() {
        let path = test_path("task-fields");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let todo = store
            .add("Project".to_owned())
            .expect("todo should be added");
        let child_id = todo.subtasks[0].id;
        let created_at_ms = todo.subtasks[0].created_at_ms;

        store
            .update(
                child_id,
                Some(String::new()),
                Some("# Child document".to_owned()),
                Some("Verified result".to_owned()),
                Some(TodoPriority::Medium),
                None,
            )
            .expect("child fields should update");
        let reloaded = TodoStore::load(path.clone()).expect("store should reload");
        let child = &reloaded.list()[0].subtasks[0];
        assert!(child.title.is_empty());
        assert_eq!(child.content, "# Child document");
        assert_eq!(child.completion_result, "Verified result");
        assert_eq!(child.priority, TodoPriority::Medium);
        assert_eq!(child.created_at_ms, created_at_ms);
        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn archive_restore_and_clear_keep_parent_child_groups_atomic() {
        let path = test_path("archive");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let first = store.add("First".to_owned()).expect("todo should be added");
        let second = store
            .add("Second".to_owned())
            .expect("todo should be added");
        store
            .set_archived_for_ids(&[first.id], true)
            .expect("first parent should archive");
        assert!(store.todo(first.id).expect("first should exist").archived);
        assert_eq!(store.restore_archived().expect("archive should restore"), 1);
        assert!(!store.todo(first.id).expect("first should exist").archived);
        store
            .set_archived_for_ids(&[second.id], true)
            .expect("second parent should archive");
        assert_eq!(store.clear_archived().expect("archive should clear"), 1);
        assert!(store.todo(second.id).is_none());
        assert!(store.task(second.subtasks[0].id).is_none());
        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn clear_completed_uses_derived_parent_completion() {
        let path = test_path("clear-completed");
        let mut store = TodoStore::load(path.clone()).expect("store should load");
        let completed = store
            .add("Completed".to_owned())
            .expect("todo should be added");
        let active = store
            .add("Active".to_owned())
            .expect("todo should be added");
        store
            .update(completed.subtasks[0].id, None, None, None, None, Some(true))
            .expect("child should complete");
        assert_eq!(store.clear_completed().expect("completed should clear"), 1);
        assert!(store.todo(completed.id).is_none());
        assert!(store.todo(active.id).is_some());
        fs::remove_file(path).expect("test data should be removable");
    }

    #[test]
    fn rejects_empty_or_oversized_documents() {
        assert!(matches!(
            normalize_title("   ".to_owned()),
            Err(StoreError::InvalidTitle)
        ));
        assert!(matches!(
            normalize_title("x".repeat(MAX_TITLE_LEN + 1)),
            Err(StoreError::TitleTooLong)
        ));
        assert!(matches!(
            normalize_content("x".repeat(MAX_CONTENT_LEN + 1)),
            Err(StoreError::ContentTooLong)
        ));
    }
}
