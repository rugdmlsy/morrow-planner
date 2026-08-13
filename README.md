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

Legacy data is migrated on load. Parent-only records receive one child containing the original document. Existing parent content and completion results move into the first child, and a higher parent priority is transferred to that child. Redundant single-child parent titles and generated placeholders are cleared. Missing child fields receive defaults, and duplicate child IDs are reassigned so internal IDs remain globally unique.

Migration uses the same exclusive file lock as normal writes.

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

Create a compact one-child project:

```bash
PARENT_ID=$(todoctl add "Write the first draft")
todoctl list
```

The list contains one row such as:

```text
#1  todo  low  task  Write the first draft
```

While the project has one child, its parent ID aliases that child for document-level commands:

```bash
todoctl content "$PARENT_ID" "# Write the first draft\n\nDraft the introduction."
todoctl result "$PARENT_ID" "Draft reviewed"
todoctl priority "$PARENT_ID" high
todoctl edit "$PARENT_ID" "Write the revised draft"
```

Add another child. `subtask-add` prints a selector local to the parent:

```bash
SECOND=$(todoctl subtask-add "$PARENT_ID" "Run the review")
# SECOND is 1##2

todoctl content "$PARENT_ID##1" "# Draft\n\nPrepare the document."
todoctl content "$SECOND" "# Review\n\nCheck the final document."
todoctl done "$SECOND"
```

Once a project has multiple children, the parent ID addresses only its optional group title:

```bash
todoctl edit "$PARENT_ID" "Publication"
todoctl edit "$PARENT_ID" ""  # return to the first-child title fallback
```

Use `P##N` for child content, completion result, and priority:

```bash
todoctl show "$PARENT_ID##1"
todoctl result "$PARENT_ID##1" "Artifact verified"
todoctl priority "$PARENT_ID##2" medium
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
