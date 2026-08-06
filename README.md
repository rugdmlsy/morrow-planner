# Todo

A local-first macOS Todo application with a native desktop interface and a native command-line interface.

- `Todo`: Objective-C AppKit interface using `NSTableView` and `NSTextView`.
- `todoctl`: non-interactive Rust CLI suitable for scripts and automation.
- `todo-core`: shared Rust validation, locking, migration, and atomic JSON persistence.
- `todo-macos-bridge`: small static Rust library exposed to AppKit through a C ABI.

The desktop application contains no WebView, JavaScript runtime, HTML renderer, SwiftUI frontend, or Tauri runtime.

## Task hierarchy

Every project contains at least one child task.

When a project has exactly one child, the sidebar shows one compact project row instead of a redundant parent-and-child pair. The row keeps the parent ID, such as `#12`, but its title, subtitle, priority, completion state, Markdown document, and completion result come from the unique child. Selecting the row opens that child in the full editor. The row’s `+` button adds a second child and expands the project.

When a project has multiple children, the sidebar shows a parent row followed by indented child rows:

```text
#12   Release project
  ##1 Build package
  ##2 Run tests
  ##3 Publish artifacts
```

Child labels are local to their parent. They are displayed as `##1`, `##2`, and `##3`, rather than exposing unrelated global child numbers. Their shell selectors are `12##1`, `12##2`, and `12##3`. These local indexes remain stable under filtering and sorting; internal global IDs remain in the JSON data for persistence and backward compatibility.

A multi-child parent is a grouping record, not another document. It has only an optional title. When the title is empty, the first child’s displayed title is used automatically. Selecting the parent opens a title-only editor; Markdown modes, completion result, and priority editing are hidden. Parent priority is derived from the highest child priority, and parent completion is derived from child completion.

A child can be completed independently. A parent is active when none of its children are complete, partially completed when only some are complete, and completed only when every child is complete. Completing or restoring a parent applies the same state to all children. At least one child is retained under every parent.

Each child supports:

- an editable Markdown document;
- Edit, Split, and Preview modes;
- a multiline Markdown completion result;
- Low, Medium, or High priority;
- an immutable creation time;
- independent completion and restoration.

The completion-result section is collapsible. Empty results start collapsed, non-empty results start expanded, and the document/result ratio can be changed by dragging the divider. Markdown is parsed by `pulldown-cmark`; Rust returns structured style runs and AppKit renders them without an HTML or JavaScript runtime.

The sidebar combines status filtering, creation-time filtering, and sorting in one Filter / Sort menu. Parent context is retained when a matching child is shown. Local child indexes remain stable under filtering and sorting, so a child labeled `##2` does not become `##1` merely because its sibling is filtered out or reordered.

Archive operations remain project-scoped. Archiving a parent hides all of its children. Deleting a compact one-child row from the native app removes the whole project rather than attempting to delete its required final child. Tasks changed by another process can be loaded with the refresh button or Command-R without restarting the app.

## Data and migration

Data is stored at:

```text
~/Library/Application Support/com.xycdev.todo/todos.json
```

Set `TODO_DATA_FILE` to use another file.

Legacy records are migrated automatically:

- parent-only records receive one child containing the original document;
- legacy parent content and completion results are moved into the first child;
- legacy parent priority is transferred to the first child when it is higher;
- redundant single-child parent titles and generated placeholders are cleared;
- missing child fields receive safe defaults;
- duplicate child IDs are reassigned so internal IDs remain globally unique.

Migration uses the same exclusive file lock as normal writes.

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

Create a compact one-child project:

```bash
PARENT_ID=$(todoctl add "Write the first draft")
todoctl list
```

The list contains one row such as:

```text
#1  todo  low  task  Write the first draft
```

While the project has one child, its visible parent ID aliases that child for document-level commands:

```bash
todoctl content "$PARENT_ID" "# Write the first draft\n\nDraft the introduction."
todoctl result "$PARENT_ID" "Draft reviewed"
todoctl priority "$PARENT_ID" high
todoctl edit "$PARENT_ID" "Write the revised draft"
```

Add another child. `subtask-add` prints a parent-local selector:

```bash
SECOND=$(todoctl subtask-add "$PARENT_ID" "Run the review")
# SECOND is 1##2

todoctl content "$PARENT_ID##1" "# Draft\n\nPrepare the document."
todoctl content "$SECOND" "# Review\n\nCheck the final document."
todoctl done "$SECOND"
```

Once a project has multiple children, its parent ID addresses only the optional group title:

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

Other commands:

```bash
todoctl list [all|active|completed|archived]
todoctl subtask-list <parent-id>
todoctl done <parent-id>       # completes every child
todoctl undo <parent-id>       # restores every child
todoctl archive <parent-id>
todoctl unarchive <parent-id>
todoctl delete <parent-id>     # deletes the whole project
todoctl complete-all
todoctl restore-all
todoctl archive-completed
todoctl restore-archived
todoctl clear-completed
todoctl clear-archived
todoctl path
```

Numeric internal child IDs remain accepted for compatibility, but normal text output and new scripts should use `P##N` selectors.

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

`TODO_BENCHMARK_TASK_ID` uses the internal numeric ID because it is a development-only diagnostic interface. User-facing CLI operations should use a parent ID or `P##N` child selector.
