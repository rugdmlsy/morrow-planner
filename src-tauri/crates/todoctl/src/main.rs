use std::{env, path::PathBuf, process::ExitCode};
use todo_core::{default_data_file, TodoPriority, TodoStore};

const HELP: &str = r#"todoctl — command-line control for Todo

Usage:
  todoctl [--data-file PATH] <command> [arguments]

Commands:
  list [all|active|completed] [--json]  List tasks and their IDs
  show <id> [--json]                    Show one task by ID
  add <title>                            Add a task and print its ID
  done <id>                              Mark a task completed
  undo <id>                              Restore a task
  edit <id> <title>                      Rename a task
  content <id> <text>                    Update task content
  result <id> <text>                     Set the optional completion result
  clear-result <id>                       Clear the completion result
  priority <id> <low|medium|high>         Set task priority
  delete <id>                            Delete a task
  complete-all                           Complete every task
  restore-all                            Restore every task
  clear-completed                        Delete completed tasks
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
        "delete" | "rm" => {
            let id = id_argument(&args, 1)?;
            store.delete(id).map_err(|error| error.to_string())?;
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
        "clear-completed" => {
            let removed = store.clear_completed().map_err(|error| error.to_string())?;
            println!("{removed}");
            Ok(())
        }
        unknown => Err(format!("unknown command '{unknown}'\n\n{HELP}")),
    }
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
            "all" | "active" | "completed" => filter = arg,
            "--json" => json = true,
            unknown => return Err(format!("unknown list option '{unknown}'")),
        }
    }

    let todos = store
        .list()
        .iter()
        .filter(|todo| match filter {
            "active" => !todo.completed,
            "completed" => todo.completed,
            _ => true,
        })
        .collect::<Vec<_>>();

    if json {
        println!(
            "{}",
            serde_json::to_string(&todos).map_err(|error| error.to_string())?
        );
    } else {
        for todo in todos {
            println!(
                "{}\t{}\t{}\t{}",
                todo.id,
                if todo.completed { "done" } else { "todo" },
                priority_name(todo.priority),
                display_title(todo)
            );
        }
    }
    Ok(())
}

fn show(store: &TodoStore, args: &[String]) -> Result<(), String> {
    let id = id_argument(args, 1)?;
    let mut json = false;
    for arg in &args[2..] {
        match arg.as_str() {
            "--json" => json = true,
            unknown => return Err(format!("unknown show option '{unknown}'")),
        }
    }

    let todo = store
        .list()
        .iter()
        .find(|todo| todo.id == id)
        .ok_or_else(|| format!("task {id} was not found"))?;

    if json {
        println!(
            "{}",
            serde_json::to_string(todo).map_err(|error| error.to_string())?
        );
        return Ok(());
    }

    println!("ID: {}", todo.id);
    println!("Status: {}", if todo.completed { "done" } else { "todo" });
    println!("Priority: {}", priority_name(todo.priority));
    println!("CreatedAtMs: {}", todo.created_at_ms);
    println!("Title: {}", display_title(todo));
    println!(
        "Content:
{}",
        todo.content
    );
    println!(
        "CompletionResult:
{}",
        todo.completion_result
    );
    Ok(())
}

fn display_title(todo: &todo_core::Todo) -> String {
    let title = todo.title.trim();
    if !title.is_empty() {
        return title.to_owned();
    }

    let content = todo
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

fn update_completed(store: &mut TodoStore, args: &[String], completed: bool) -> Result<(), String> {
    let id = id_argument(args, 1)?;
    store
        .update(id, None, None, None, None, Some(completed))
        .map_err(|error| error.to_string())?;
    Ok(())
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
