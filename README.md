# Todo

Todo is a local macOS task app with a native desktop UI and a Rust command-line interface.

- `Todo` is an Objective-C AppKit app built with `NSTableView` and `NSTextView`.
- `todoctl` is a non-interactive Rust CLI for scripts and automation.
- `todo-core` handles validation, locking, migration, and atomic JSON persistence.
- `todo-macos-bridge` exposes the Rust core to AppKit through a small C ABI.

The desktop app does not use WebView, JavaScript, HTML rendering, SwiftUI, or the Tauri runtime.

## Task hierarchy

Every project has at least one child task.

A project with one child appears as a single compact row. The row keeps the parent ID, such as `#12`, while the visible title, subtitle, priority, completion state, Markdown document, and completion result come from the child. Selecting the row opens that child in the full editor. Pressing `+` adds a second child and expands the project.

A project with multiple children shows one parent row followed by indented child rows:

```text
#12   Release project
  ##1 Build package
  ##2 Run tests
  ##3 Publish artifacts
```

Child numbers are local to the parent. The UI shows `##1`, `##2`, and `##3` instead of internal global child IDs. The matching shell selectors are `12##1`, `12##2`, and `12##3`. Filters and derived sorts do not change these numbers. Manual child reordering does, so moving the old `##3` to the top makes it `##1`. Internal global IDs stay in the JSON file for persistence and backward compatibility.

Projects with multiple children have a large disclosure button on the right. Collapsing a project hides its child rows but does not change task data, completion state, local selectors, or manual order. Expanding it restores the same hierarchy. The project row stays at the same viewport position during either action. Collapse state is saved between normal app launches. A one-child project remains compact and has no disclosure button. Adding a child to a collapsed project expands it and opens the new child.

Manual drag ordering is available in Original Order. Dragging a parent moves the whole project with all of its children. Dragging a child changes its position only within that parent; children cannot be dragged into another project. If filtering hides some rows, those hidden records keep their stored positions while the visible rows are reordered. The same applies to children hidden by a collapsed parent. New children are appended to the end of the parent's manual order. Dragging is disabled in Newest First and Priority First because those views derive their order from task data. Right-click a project or child row to delete that item directly from the sidebar. Deleting a compact one-child project row removes the whole project.

A parent with multiple children is only a grouping record. It has an optional title and no separate Markdown document, completion result, or editable priority. If the title is empty, the UI uses the first child's displayed title. Selecting the parent opens a title-only editor. Parent priority is the highest priority among its children, and parent completion is derived from child completion.

Children can be completed independently. A parent is active when none of its children are complete, partial when some are complete, and complete only when all are complete. Completing or restoring a parent applies the same state to every child. A parent always keeps at least one child.

Each child has a Markdown document, Edit, Split, and Preview modes, a multiline Markdown completion result, Low/Medium/High priority, an immutable creation time, and its own completion state.

The completion-result area can be collapsed. Empty results start collapsed and non-empty results start expanded. Drag the divider to change the document/result ratio. Markdown parsing is handled by `pulldown-cmark`; Rust returns structured style runs and AppKit renders them directly, without HTML or JavaScript.

The Filter / Sort menu combines status filtering, creation-time filtering, and sorting. Active is a parent-level filter: if any child is unfinished, the parent and all of its children stay visible, including children that are already complete. An explicitly collapsed parent still hides its child rows. Completed keeps its existing child-level behavior. Filtering and derived sorting do not change stored order or local `##N` selectors. Only manual reordering changes those selectors.

Archive operations work at the project level. Archiving a parent hides all of its children. Deleting a compact one-child row from the app removes the whole project instead of trying to delete its required last child. Changes made by another process can be loaded with the refresh button or Command-R without restarting the app.

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
native-macos/build/Todo.app
```

Run it with:

```bash
open native-macos/build/Todo.app
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
codesign --verify --deep --strict native-macos/build/Todo.app
```

## Headless UI diagnostics

Set `TODO_BENCHMARK_HEADLESS=1` to keep the benchmark window transparent and non-activating. This lets layout and data-flow tests run without changing the frontmost application or keyboard focus.

```bash
TODO_DATA_FILE=/tmp/todos.json \
TODO_BENCHMARK_HEADLESS=1 \
TODO_BENCHMARK_MODE=edit \
TODO_BENCHMARK_TASK_ID=42 \
TODO_LAYOUT_DIAGNOSTICS=1 \
native-macos/build/Todo.app/Contents/MacOS/Todo
```

`TODO_BENCHMARK_TASK_ID` uses the internal numeric ID because this interface is only for development diagnostics. User-facing CLI commands should use a parent ID or a `P##N` child selector.
