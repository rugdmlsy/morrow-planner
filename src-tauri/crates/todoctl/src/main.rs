use std::{env, path::PathBuf, process::ExitCode};
use todo_core::{default_data_file, TaskKind, Todo, TodoCompletionState, TodoPriority, TodoStore};

const HELP: &str = r#"todoctl — command-line control for Todo

Usage:
  todoctl [--data-file PATH] <command> [arguments]

Commands:
  list [all|active|completed|archived] [--json]
                                         List parent and child tasks with global IDs
  show <id> [--json]                    Show any parent or child task by ID
  add <title>                            Add a parent with one default child; print parent ID
  done <id>                              Complete a parent or child task
  undo <id>                              Restore a parent or child task
  archive <id>                           Archive a parent task
  unarchive <id>                         Restore an archived parent task
  edit <id> <title>                      Rename a parent or child task
  content <id> <text>                    Update Markdown content
  result <id> <text>                     Set the optional completion result
  clear-result <id>                      Clear the completion result
  priority <id> <low|medium|high>        Set task priority
  subtask-list <parent-id> [--json]      List children of a parent
  subtask-add <parent-id> <title>        Add a child task and print its global ID
  subtask-done <parent-id> <child-id>    Mark a child completed
  subtask-undo <parent-id> <child-id>    Restore a child
  subtask-edit <parent-id> <child-id> <title>
                                         Rename a child
  subtask-delete <parent-id> <child-id>  Delete a child; one child must remain
  delete <id>                            Delete a parent or child task
  complete-all                           Complete every unarchived parent and child
  restore-all                            Restore every unarchived parent and child
  archive-completed                      Archive completed parent tasks
  restore-archived                       Restore all archived parents
  clear-completed                        Delete completed unarchived parents
  clear-archived                         Delete all archived parents
  path                                   Print the data file path
  help                                   Show this help

Environment:
  TODO_DATA_FILE                         Override the default data file
"#;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("todoctl: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    let data_file = extract_data_file(&mut args)?;
    let command = args.first().map(String::as_str).unwrap_or("help");

    if matches!(command, "help" | "--help" | "-h") {
        print!("{HELP}");
        return Ok(());
    }
    if command == "path" {
        println!("{}", resolve_data_file(data_file)?.display());
        return Ok(());
    }

    let mut store =
        TodoStore::load(resolve_data_file(data_file)?).map_err(|error| error.to_string())?;

    match command {
        "list" => list(&store, &args[1..]),
        "show" | "get" => show(&store, &args),
        "add" => {
            let title = joined_argument(&args, 1, "add requires a title")?;
            let todo = store.add(title).map_err(|error| error.to_string())?;
            println!("{}", todo.id);
            Ok(())
        }
        "done" => update_completed(&mut store, &args, true),
        "undo" => update_completed(&mut store, &args, false),
        "archive" => update_archived(&mut store, &args, true),
        "unarchive" => update_archived(&mut store, &args, false),
        "edit" => {
            let id = id_argument(&args, 1)?;
            let title = joined_argument(&args, 2, "edit requires a title")?;
            store
                .update(id, Some(title), None, None, None, None)
                .map_err(|error| error.to_string())?;
            Ok(())
        }
        "content" | "note" => {
            let id = id_argument(&args, 1)?;
            let content = joined_argument(&args, 2, "content requires text")?;
            store
                .update(id, None, Some(content), None, None, None)
                .map_err(|error| error.to_string())?;
            Ok(())
        }
        "result" => {
            let id = id_argument(&args, 1)?;
            let result = joined_argument(&args, 2, "result requires text")?;
            store
                .update(id, None, None, Some(result), None, None)
                .map_err(|error| error.to_string())?;
            Ok(())
        }
        "clear-result" => {
            let id = id_argument(&args, 1)?;
            store
                .update(id, None, None, Some(String::new()), None, None)
                .map_err(|error| error.to_string())?;
            Ok(())
        }
        "priority" => {
            let id = id_argument(&args, 1)?;
            let priority = priority_argument(&args, 2)?;
            store
                .update(id, None, None, None, Some(priority), None)
                .map_err(|error| error.to_string())?;
            Ok(())
        }
        "subtask-list" => list_subtasks(&store, &args),
        "subtask-add" => {
            let parent_id = id_argument(&args, 1)?;
            let title = joined_argument(&args, 2, "subtask-add requires a title")?;
            let record = store
                .add_subtask(parent_id, title)
                .map_err(|error| error.to_string())?;
            println!("{}", record.task.id);
            Ok(())
        }
        "subtask-done" => update_child_completed(&mut store, &args, true),
        "subtask-undo" => update_child_completed(&mut store, &args, false),
        "subtask-edit" => {
            let parent_id = id_argument(&args, 1)?;
            let child_id = id_argument(&args, 2)?;
            ensure_child_of(&store, parent_id, child_id)?;
            let title = joined_argument(&args, 3, "subtask-edit requires a title")?;
            store
                .update(child_id, Some(title), None, None, None, None)
                .map_err(|error| error.to_string())?;
            Ok(())
        }
        "subtask-delete" => {
            let parent_id = id_argument(&args, 1)?;
            let child_id = id_argument(&args, 2)?;
            ensure_child_of(&store, parent_id, child_id)?;
            store
                .delete_task(child_id)
                .map_err(|error| error.to_string())?;
            Ok(())
        }
        "delete" | "rm" => {
            let id = id_argument(&args, 1)?;
            store.delete_task(id).map_err(|error| error.to_string())?;
            Ok(())
        }
        "complete-all" => {
            let changed = store
                .set_all_completed(true)
                .map_err(|error| error.to_string())?;
            println!("{changed}");
            Ok(())
        }
        "restore-all" => {
            let changed = store
                .set_all_completed(false)
                .map_err(|error| error.to_string())?;
            println!("{changed}");
            Ok(())
        }
        "archive-completed" => print_count(store.archive_completed()),
        "restore-archived" => print_count(store.restore_archived()),
        "clear-completed" => print_count(store.clear_completed()),
        "clear-archived" => print_count(store.clear_archived()),
        unknown => Err(format!("unknown command '{unknown}'\n\n{HELP}")),
    }
}

fn print_count(result: Result<usize, todo_core::StoreError>) -> Result<(), String> {
    let count = result.map_err(|error| error.to_string())?;
    println!("{count}");
    Ok(())
}

fn extract_data_file(args: &mut Vec<String>) -> Result<Option<PathBuf>, String> {
    let Some(index) = args.iter().position(|arg| arg == "--data-file") else {
        return Ok(None);
    };
    if index + 1 >= args.len() {
        return Err("--data-file requires a path".to_owned());
    }
    let path = PathBuf::from(args.remove(index + 1));
    args.remove(index);
    Ok(Some(path))
}

fn resolve_data_file(path: Option<PathBuf>) -> Result<PathBuf, String> {
    path.map(Ok)
        .unwrap_or_else(|| default_data_file().map_err(|error| error.to_string()))
}

fn list(store: &TodoStore, args: &[String]) -> Result<(), String> {
    let mut filter = "all";
    let mut json = false;
    for arg in args {
        match arg.as_str() {
            "all" | "active" | "completed" | "archived" => filter = arg,
            "--json" => json = true,
            unknown => return Err(format!("unknown list option '{unknown}'")),
        }
    }

    let todos = filtered_todos(store, filter);
    if json {
        println!(
            "{}",
            serde_json::to_string(&todos).map_err(|error| error.to_string())?
        );
        return Ok(());
    }

    for todo in &todos {
        println!(
            "{}\t{}\t{}\tparent\t{}",
            todo.id,
            if todo.archived {
                "archived"
            } else {
                completion_state_name(todo.completion_state())
            },
            priority_name(todo.priority),
            display_task(&todo.task)
        );
        for task in &todo.subtasks {
            println!(
                "{}\t{}\t{}\tchild:{}\t{}",
                task.id,
                if task.completed { "done" } else { "todo" },
                priority_name(task.priority),
                todo.id,
                display_task(task)
            );
        }
    }
    Ok(())
}

fn filtered_todos(store: &TodoStore, filter: &str) -> Vec<Todo> {
    store
        .list()
        .iter()
        .filter_map(|todo| {
            let parent_matches = matches_parent_filter(todo, filter);
            let mut visible = todo.clone();
            visible
                .subtasks
                .retain(|task| matches_child_filter(todo, task.completed, filter));
            (parent_matches || !visible.subtasks.is_empty()).then_some(visible)
        })
        .collect()
}

fn matches_parent_filter(todo: &Todo, filter: &str) -> bool {
    match filter {
        "active" => !todo.archived && !todo.is_completed(),
        "completed" => !todo.archived && todo.is_completed(),
        "archived" => todo.archived,
        _ => true,
    }
}

fn matches_child_filter(todo: &Todo, completed: bool, filter: &str) -> bool {
    match filter {
        "active" => !todo.archived && !completed,
        "completed" => !todo.archived && completed,
        "archived" => todo.archived,
        _ => true,
    }
}

fn show(store: &TodoStore, args: &[String]) -> Result<(), String> {
    let id = id_argument(args, 1)?;
    let json = match args.get(2).map(String::as_str) {
        None => false,
        Some("--json") => true,
        Some(option) => return Err(format!("unknown show option '{option}'")),
    };
    let record = store
        .task(id)
        .ok_or_else(|| format!("task {id} was not found"))?;
    let parent = store.todo(id);

    if json {
        if let Some(todo) = parent {
            println!(
                "{}",
                serde_json::to_string(todo).map_err(|error| error.to_string())?
            );
        } else {
            println!(
                "{}",
                serde_json::to_string(&record).map_err(|error| error.to_string())?
            );
        }
        return Ok(());
    }

    println!("ID: {}", record.task.id);
    println!(
        "Kind: {}",
        match record.kind {
            TaskKind::Parent => "parent",
            TaskKind::Subtask => "child",
        }
    );
    if let Some(parent_id) = record.parent_id {
        println!("ParentID: {parent_id}");
    }
    println!(
        "Status: {}",
        parent
            .map(|todo| completion_state_name(todo.completion_state()))
            .unwrap_or(if record.task.completed {
                "done"
            } else {
                "todo"
            })
    );
    if let Some(todo) = parent {
        println!("Archived: {}", if todo.archived { "yes" } else { "no" });
    }
    println!("Priority: {}", priority_name(record.task.priority));
    println!("CreatedAtMs: {}", record.task.created_at_ms);
    println!("Title: {}", display_task(&record.task));
    println!("Content:\n{}", record.task.content);
    println!("CompletionResult:\n{}", record.task.completion_result);
    if let Some(todo) = parent {
        println!(
            "Progress: {}/{} ({})",
            todo.completed_subtask_count(),
            todo.subtasks.len(),
            completion_state_name(todo.completion_state())
        );
        for task in &todo.subtasks {
            println!(
                "  {}\t{}\t{}\t{}",
                task.id,
                if task.completed { "done" } else { "todo" },
                priority_name(task.priority),
                display_task(task)
            );
        }
    }
    Ok(())
}

fn list_subtasks(store: &TodoStore, args: &[String]) -> Result<(), String> {
    let parent_id = id_argument(args, 1)?;
    let json = match args.get(2).map(String::as_str) {
        None => false,
        Some("--json") => true,
        Some(option) => return Err(format!("unknown subtask-list option '{option}'")),
    };
    let todo = store
        .todo(parent_id)
        .ok_or_else(|| format!("parent task {parent_id} was not found"))?;
    if json {
        println!(
            "{}",
            serde_json::to_string(&todo.subtasks).map_err(|error| error.to_string())?
        );
    } else {
        for task in &todo.subtasks {
            println!(
                "{}\t{}\t{}\t{}",
                task.id,
                if task.completed { "done" } else { "todo" },
                priority_name(task.priority),
                display_task(task)
            );
        }
    }
    Ok(())
}

fn update_completed(store: &mut TodoStore, args: &[String], completed: bool) -> Result<(), String> {
    let id = id_argument(args, 1)?;
    store
        .update(id, None, None, None, None, Some(completed))
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn update_child_completed(
    store: &mut TodoStore,
    args: &[String],
    completed: bool,
) -> Result<(), String> {
    let parent_id = id_argument(args, 1)?;
    let child_id = id_argument(args, 2)?;
    ensure_child_of(store, parent_id, child_id)?;
    store
        .update(child_id, None, None, None, None, Some(completed))
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn ensure_child_of(store: &TodoStore, parent_id: u64, child_id: u64) -> Result<(), String> {
    let record = store
        .task(child_id)
        .ok_or_else(|| format!("task {child_id} was not found"))?;
    if record.parent_id == Some(parent_id) {
        Ok(())
    } else {
        Err(format!(
            "task {child_id} is not a child of task {parent_id}"
        ))
    }
}

fn update_archived(store: &mut TodoStore, args: &[String], archived: bool) -> Result<(), String> {
    let id = id_argument(args, 1)?;
    if store.todo(id).is_none() {
        return Err(format!("task {id} is not a parent task"));
    }
    store
        .set_archived_for_ids(&[id], archived)
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn display_task(task: &todo_core::Task) -> String {
    let title = task.title.trim();
    if !title.is_empty() {
        return title.to_owned();
    }
    let content = task
        .content
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if content.is_empty() {
        return "Untitled".to_owned();
    }
    let characters = content.chars().collect::<Vec<_>>();
    if characters.len() > 48 {
        format!("{}…", characters[..48].iter().collect::<String>())
    } else {
        content
    }
}

fn completion_state_name(state: TodoCompletionState) -> &'static str {
    match state {
        TodoCompletionState::Active => "todo",
        TodoCompletionState::Partial => "partial",
        TodoCompletionState::Completed => "done",
    }
}

fn priority_name(priority: TodoPriority) -> &'static str {
    match priority {
        TodoPriority::Low => "low",
        TodoPriority::Medium => "medium",
        TodoPriority::High => "high",
    }
}

fn priority_argument(args: &[String], index: usize) -> Result<TodoPriority, String> {
    match args.get(index).map(String::as_str) {
        Some("low") => Ok(TodoPriority::Low),
        Some("medium") => Ok(TodoPriority::Medium),
        Some("high") => Ok(TodoPriority::High),
        Some(value) => Err(format!(
            "invalid priority '{value}'; use low, medium, or high"
        )),
        None => Err("priority requires low, medium, or high".to_owned()),
    }
}

fn id_argument(args: &[String], index: usize) -> Result<u64, String> {
    args.get(index)
        .ok_or_else(|| "task id is required".to_owned())?
        .parse::<u64>()
        .map_err(|_| "task id must be a positive integer".to_owned())
}

fn joined_argument(args: &[String], start: usize, error: &str) -> Result<String, String> {
    if start >= args.len() {
        return Err(error.to_owned());
    }
    Ok(args[start..].join(" "))
}
