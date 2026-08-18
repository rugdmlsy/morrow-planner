# Morrow Planner

Morrow Planner is a local macOS task app with a native desktop UI and a Rust command-line interface.

- `Morrow Planner` is an Objective-C AppKit app built with `NSTableView` and `NSTextView`.
- `todoctl` is a non-interactive Rust CLI for scripts and automation.
- `todo-core` handles validation, locking, migration, and atomic JSON persistence.
- `todo-macos-bridge` exposes the Rust core to AppKit through a small C ABI.

The desktop app does not use WebView, JavaScript, HTML rendering, SwiftUI, or the Tauri runtime.

## Data and migration

The default data file is:

```text
~/Library/Application Support/com.xycdev.todo/todos.json
```

Set `TODO_DATA_FILE` to use another file.

Legacy data is migrated on load. Existing standalone parent records remain standalone. Records created by the earlier compact one-child model are promoted back into the parent when the parent had no independent payload and merely mirrored its only child. Parent content, completion results, and priority are otherwise preserved independently. Missing child fields receive defaults, and duplicate child IDs are reassigned so internal IDs remain globally unique.

Migration uses the same exclusive file lock as normal writes.

## Folders

The native app can scope the task list to local folders. The root task list remains unchanged, while each folder stores an independent TodoStore at:

```text
~/Library/Application Support/com.xycdev.todo/folders/<folder-name>/todos.json
```

Use the folder menu in the sidebar to switch between the root task list and folders, create a folder, rename the current folder, or delete it. New folder names default to the current date (`YYYY-MM-DD`), which makes date-based weekly notes convenient without introducing a separate weekly-report mode. Tasks inside a folder retain the normal task model, including Markdown content, priority, completion state, child tasks, drag ordering, and completion results.

The first folder-based release used `weekly-reports/<date>/done.json` and `plan.json`. Those folders are migrated into the generic folder store on discovery; the two former sections are merged into one task list and task IDs are remapped when needed.

## Build the macOS app

```bash
./native-macos/build.sh
```

The signed local bundle is written to:

```text
native-macos/build/Morrow Planner.app
```

Run it with:

```bash
open "native-macos/build/Morrow Planner.app"
```

Building requires the macOS command-line developer tools, Rust, `clang`, and `codesign`.

## Command-line usage

Build the CLI:

```bash
cargo build --release --manifest-path src-tauri/Cargo.toml -p todoctl
```

The binary is written to `src-tauri/target/release/todoctl`.

Create a parent task:

```bash
PARENT_ID=$(todoctl add "Write the first draft")
todoctl list
```

The list contains one row such as:

```text
1  todo  default  parent  Write the first draft
```

The parent is a full task. Its title, Markdown body, completion result, and priority can all be edited directly:

```bash
todoctl content "$PARENT_ID" "# Write the first draft\n\nDraft the introduction."
todoctl result "$PARENT_ID" "Draft reviewed"
todoctl priority "$PARENT_ID" high
todoctl edit "$PARENT_ID" "Write the revised draft"
```

Priority has five levels: `lowest`, `low`, `default`, `high`, and `highest`. New parent and child tasks start at `default`; the legacy CLI value `medium` is still accepted as an alias for `default`.

Add child tasks explicitly. `subtask-add` prints a selector local to the parent:

```bash
FIRST=$(todoctl subtask-add "$PARENT_ID" "Prepare the document")
SECOND=$(todoctl subtask-add "$PARENT_ID" "Run the review")
# FIRST is 1##1 and SECOND is 1##2

todoctl content "$FIRST" "# Draft\n\nPrepare the document."
todoctl content "$SECOND" "# Review\n\nCheck the final document."
todoctl done "$SECOND"
```

Use `P##N` for a child while the plain parent ID always refers to the parent itself:

```bash
todoctl show "$PARENT_ID##1"
todoctl result "$PARENT_ID##1" "Artifact verified"
todoctl priority "$PARENT_ID##2" highest
todoctl undo "$PARENT_ID##2"
todoctl delete "$PARENT_ID##2"
```

Manual order can also be changed from the shell. Positions start at 1:

```bash
todoctl move 12 1       # move parent #12 to the top
todoctl move 12##3 1    # move the third child to the top of parent #12
```

Moving a child changes its local `##N` selector. `subtask-add` always appends the new child after the existing manual child order.

Other commands:

```bash
todoctl list [all|active|completed|archived]
todoctl subtask-list <parent-id>
todoctl done <parent-id>       # completes every child
todoctl undo <parent-id>       # restores every child
todoctl archive <parent-id>
todoctl unarchive <parent-id>
todoctl delete <parent-id>     # deletes the whole project
todoctl move <selector> <position>
todoctl complete-all
todoctl restore-all
todoctl archive-completed
todoctl restore-archived
todoctl clear-completed
todoctl clear-archived
todoctl path
```

Numeric internal child IDs are still accepted for compatibility. Normal text output and new scripts should use `P##N` selectors.

For isolated tests:

```bash
todoctl --data-file /tmp/todo-test.json add "Test task"
```

## Verification

```bash
cargo fmt --manifest-path src-tauri/Cargo.toml --all --check
cargo test --manifest-path src-tauri/Cargo.toml --workspace
cargo clippy --manifest-path src-tauri/Cargo.toml --workspace --all-targets -- -D warnings
cargo build --release --manifest-path src-tauri/Cargo.toml -p todoctl
./native-macos/build.sh
codesign --verify --deep --strict "native-macos/build/Morrow Planner.app"
```

## Headless UI diagnostics

Set `TODO_BENCHMARK_HEADLESS=1` to keep the benchmark window transparent and non-activating. This lets layout and data-flow tests run without changing the frontmost application or keyboard focus.

```bash
TODO_DATA_FILE=/tmp/todos.json \
TODO_BENCHMARK_HEADLESS=1 \
TODO_BENCHMARK_MODE=edit \
TODO_BENCHMARK_TASK_ID=42 \
TODO_LAYOUT_DIAGNOSTICS=1 \
"native-macos/build/Morrow Planner.app/Contents/MacOS/Morrow Planner"
```

`TODO_BENCHMARK_TASK_ID` uses the internal numeric ID because this interface is only for development diagnostics. User-facing CLI commands should use a parent ID or a `P##N` child selector.
