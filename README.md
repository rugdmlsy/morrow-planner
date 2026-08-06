# Todo

A local-first macOS Todo application with a native desktop interface and a native command-line interface.

- `Todo`: Objective-C AppKit interface using `NSTableView` and `NSTextView`.
- `todoctl`: non-interactive Rust CLI suitable for scripts and automation.
- `todo-core`: shared Rust validation, locking, migration, and atomic JSON persistence.
- `todo-macos-bridge`: small static Rust library exposed to AppKit through a C ABI.

The desktop application contains no WebView, JavaScript runtime, HTML renderer, SwiftUI frontend, or Tauri runtime.

## Task hierarchy

The sidebar shows parent projects and their indented child tasks in one list. Parent and child tasks both have global numeric IDs and are selectable, filterable, sortable, and controllable from `todoctl`. Each new parent is created with one child task by default. The `+` button on a parent row adds another child and opens it immediately.

A selected parent or child uses the same full detail workspace. Both support:

- an editable Markdown document;
- Edit, Split, and Preview modes;
- a multiline Markdown completion result;
- Low, Medium, or High priority;
- independent creation time and stable ID;
- completion and restoration controls.

A child can be completed independently. A parent is active when none of its children are complete, partially completed when only some are complete, and completed only when every child is complete. Completing or restoring a parent applies the same state to all of its children. At least one child is retained under every parent.

The first non-empty Markdown line supplies the title shown in the sidebar. Parent rows show child progress, such as `2/5`. Partial parents use an orange mixed-state checkbox; completed tasks use a green checkbox. Archive operations remain group-scoped: archiving a parent hides the parent and all of its children together.

The completion-result section is collapsible. Empty results start collapsed, non-empty results start expanded, and the task/result ratio can be changed by dragging the divider. Split mode places the editor on the left and a live Markdown preview on the right. Markdown is parsed by `pulldown-cmark`; Rust returns structured style runs and AppKit renders them without an HTML or JavaScript runtime.

The sidebar combines status filtering, creation-time filtering, and sorting in one Filter / Sort menu. It supports active, completed, or all tasks; all time, the last 24 hours, the last 7 days, or a custom inclusive date range; and original, newest-first, or priority-first order. Parent-child grouping is retained while matching children remain individually visible. Tasks changed by another process can be reloaded with the refresh button or Command-R without restarting the app.

Data is stored at:

```text
~/Library/Application Support/com.xycdev.todo/todos.json
```

Set `TODO_DATA_FILE` to use another file. Legacy parent-only records are migrated to contain one first-class child without discarding the original parent data. Missing child fields receive safe defaults, missing creation times use the best available parent or file timestamp, and duplicate legacy child IDs are reassigned so IDs are globally unique.

## Build the macOS app

```bash
./native-macos/build.sh
```

The signed local bundle is written to:

```text
native-macos/build/Todo.app
```

Run it with:

```bash
open native-macos/build/Todo.app
```

The build requires the macOS command-line developer tools, Rust, `clang`, and `codesign`.

## Command-line usage

Build the CLI:

```bash
cargo build --release --manifest-path src-tauri/Cargo.toml -p todoctl
```

The binary is written to `src-tauri/target/release/todoctl`.

Create a parent and inspect its default child:

```bash
PARENT_ID=$(todoctl add "Ship the release")
todoctl show "$PARENT_ID"
todoctl subtask-list "$PARENT_ID"
```

Add and edit a child. Once its global ID is known, the same generic commands used for parents work directly on it:

```bash
CHILD_ID=$(todoctl subtask-add "$PARENT_ID" "Run the full test suite")

todoctl content "$CHILD_ID" "# Run the full test suite\n\nVerify unit and integration tests."
todoctl result "$CHILD_ID" "All tests passed"
todoctl priority "$CHILD_ID" high
todoctl done "$CHILD_ID"
todoctl show "$CHILD_ID" --json
todoctl undo "$CHILD_ID"
todoctl delete "$CHILD_ID"
```

Other commands:

```bash
todoctl list
todoctl list active
todoctl list completed
todoctl edit <id> "New title"
todoctl clear-result <id>
todoctl done <parent-id>       # completes every child
todoctl undo <parent-id>       # restores every child
todoctl archive <parent-id>
todoctl unarchive <parent-id>
todoctl list archived
todoctl complete-all
todoctl restore-all
todoctl archive-completed
todoctl restore-archived
todoctl clear-completed
todoctl clear-archived
todoctl path
```

Compatibility commands remain available for scripts that specify both IDs:

```bash
todoctl subtask-done <parent-id> <child-id>
todoctl subtask-undo <parent-id> <child-id>
todoctl subtask-edit <parent-id> <child-id> "New title"
todoctl subtask-delete <parent-id> <child-id>
```

For isolated tests:

```bash
todoctl --data-file /tmp/todo-test.json add "Test project"
```

## Verification

```bash
cargo fmt --manifest-path src-tauri/Cargo.toml --all --check
cargo test --manifest-path src-tauri/Cargo.toml --workspace
cargo clippy --manifest-path src-tauri/Cargo.toml --workspace --all-targets -- -D warnings
./native-macos/build.sh
codesign --verify --deep --strict native-macos/build/Todo.app
```

## Headless UI diagnostics

Set `TODO_BENCHMARK_HEADLESS=1` to keep the benchmark window transparent and non-activating. This allows layout and data-flow checks without changing the current frontmost application or keyboard focus.

```bash
TODO_DATA_FILE=/tmp/todos.json \
TODO_BENCHMARK_HEADLESS=1 \
TODO_BENCHMARK_MODE=edit \
TODO_BENCHMARK_TASK_ID=42 \
TODO_LAYOUT_DIAGNOSTICS=1 \
native-macos/build/Todo.app/Contents/MacOS/Todo
```

`TODO_BENCHMARK_TASK_ID` accepts a parent or child global ID. `TODO_BENCHMARK_SELECT_FIRST_CHILD=1` selects the first visible child when an exact ID is not supplied. Edit, Split, Preview, filtering, sorting, refresh, completion-result expansion, and priority diagnostics use the same isolated startup path.
