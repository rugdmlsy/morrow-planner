# Todo

A local-first macOS Todo application with a native desktop interface and a native command-line interface.

- `Todo`: Objective-C AppKit interface using `NSTableView` and `NSTextView`.
- `todoctl`: non-interactive Rust CLI suitable for scripts and automation.
- `todo-core`: shared Rust validation, locking, and atomic JSON persistence.
- `todo-macos-bridge`: small static Rust library exposed to AppKit through a C ABI.

The desktop application contains no WebView, JavaScript runtime, HTML renderer, SwiftUI frontend, or Tauri runtime.

Each task is created through the New Task button and immediately opens as one editable Markdown document; there is no separate quick-add path. The first non-empty Markdown line supplies the title shown in the sidebar. Each task also has a multiline Markdown completion-result editor for recording delivered output, links, or verification notes independently from the task document. The completion-result section is collapsible: empty results start collapsed at the bottom of the detail view, while non-empty results start expanded; a per-task manual choice is retained for the current app session. When expanded, the task and result editors both use AppKit TextKit views, and their vertical proportions can be changed by dragging the divider between them. The detail workspace has three global modes: Edit maximizes the editable source, Split places the editor on the left and a live Markdown preview on the right, and Preview maximizes the rendered result. The selected mode applies to both the task document and completion result, carries across task selection, and is stored locally; Split is the default for a new installation. The interface can switch between Chinese and English, and the preference is stored locally. Every new task receives an immutable `createdAtMs` timestamp when it is first defined; editing or completing the task does not change that timestamp. The sidebar can combine completion-state filtering with creation-time categories for all tasks, the rolling last 24 hours, the rolling last 7 days, or a custom inclusive date range. It can also retain the stored order or sort matching tasks by immutable creation time with the newest tasks first; the selected order is stored locally. Full task content is loaded only for the selected task. Whenever a preview pane is visible, Markdown is parsed by `pulldown-cmark`, Rust returns structured style runs rather than HTML, and AppKit converts those runs into an attributed string for a read-only `NSTextView`. In Split mode, preview rendering is debounced and refreshed while the user types.

Data is stored at:

```text
~/Library/Application Support/com.xycdev.todo/todos.json
```

Set `TODO_DATA_FILE` to use another file. Legacy records without `createdAtMs` are migrated once using the existing JSON file's modification time as their best available approximate creation time.

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

```bash
todoctl add "Write the first task"
todoctl list
todoctl done 1
todoctl edit 1 "Ship the MVP"
todoctl content 1 "# Ship the MVP\n\nVerify the native package."
todoctl result 1 "Released v1.0 and verified the checksum"
todoctl clear-result 1
todoctl list completed --json
todoctl clear-completed
todoctl path
```

For isolated tests:

```bash
todoctl --data-file /tmp/todo-test.json add "Test task"
```

## Verification

```bash
cargo fmt --manifest-path src-tauri/Cargo.toml --all --check
cargo test --manifest-path src-tauri/Cargo.toml --workspace
cargo clippy --manifest-path src-tauri/Cargo.toml --workspace --all-targets -- -D warnings
./native-macos/build.sh
```

## Memory measurement and UI diagnostics

The app supports isolated benchmark startup modes used by the development scripts. Set `TODO_BENCHMARK_HEADLESS=1` to keep the benchmark window transparent and non-activating, so automated checks do not change the current frontmost application or keyboard focus:

```bash
TODO_DATA_FILE=/tmp/todos.json TODO_BENCHMARK_HEADLESS=1 TODO_BENCHMARK_MODE=list native-macos/build/Todo.app/Contents/MacOS/Todo
TODO_DATA_FILE=/tmp/todos.json TODO_BENCHMARK_HEADLESS=1 TODO_BENCHMARK_MODE=edit native-macos/build/Todo.app/Contents/MacOS/Todo
TODO_DATA_FILE=/tmp/todos.json TODO_BENCHMARK_HEADLESS=1 TODO_BENCHMARK_MODE=split native-macos/build/Todo.app/Contents/MacOS/Todo
TODO_DATA_FILE=/tmp/todos.json TODO_BENCHMARK_HEADLESS=1 TODO_BENCHMARK_MODE=preview native-macos/build/Todo.app/Contents/MacOS/Todo
```

`list` loads sidebar summaries only. `edit` loads the first full document in the editor, `split` also creates its live Markdown preview, and `preview` displays the rendered document at full width.
