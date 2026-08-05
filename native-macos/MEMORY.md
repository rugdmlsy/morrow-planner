# Native macOS memory measurements

Measurement date: 2026-08-04

Machine:

- Apple M5 Pro
- 24 GB RAM
- macOS 26.3.2
- Release build, ad-hoc signed
- Sampled after 7 seconds with `/usr/bin/footprint`

`phys_footprint` is the primary metric because RSS includes clean shared framework pages and mapped files that can be reclaimed or shared with other processes.

## Actual application data

The real data file contained 2 tasks, 661 bytes on disk, and 240 total content characters.

| State | Physical footprint | RSS | Idle CPU |
|---|---:|---:|---:|
| Sidebar only | 25 MB | approximately 96,000–98,000 KB | 0.0% |
| Editing selected task | 28–29 MB | approximately 106,000–111,000 KB | approximately 0% |
| Markdown preview | 28–30 MB | approximately 108,000–112,000 KB | approximately 0% |

## Stress data

The stress file contained 101 tasks. The selected task contained approximately 20 KB of Markdown with headings, links, code, task lists, quotations, tables, and Chinese text.

| State | Physical footprint | RSS | Idle CPU |
|---|---:|---:|---:|
| Sidebar only | 26 MB | 99,264 KB | 0.0% |
| Editing 20 KB task | 30 MB | 108,704 KB | 0.0% |
| Previewing 20 KB task | 33 MB | 110,080 KB | 0.0% |

The 100 additional task summaries add roughly 1 MB. Loading the current full document adds roughly 3–4 MB, primarily because AppKit activates the text system and creates another backing surface. Rendering the 20 KB preview adds another 2–3 MB. Individual samples vary by roughly 1–2 MB because the WindowServer and AppKit choose backing-surface sizes dynamically.

## Actual-data footprint composition

Values are rounded from `footprint` categories.

| Category | List | Edit | Preview | Meaning |
|---|---:|---:|---:|---|
| `MALLOC_SMALL` | about 12 MB | about 13 MB | about 13 MB | AppKit/Foundation object graph, table and text objects, strings, dictionaries, fonts, temporary Rust/JSON allocations, and allocator slack |
| `IOSurface` | about 5.2 MB | about 6.8 MB | about 8.2 MB | Window and scrollable text backing surfaces shared with the compositor |
| `__DATA_DIRTY` | 1.7 MB | 1.8 MB | 1.8 MB | Writable global state in AppKit, Foundation, Objective-C runtime, Rust, and linked system libraries |
| `MALLOC metadata` | 1.2 MB | 1.2 MB | 1.2 MB | Allocator bookkeeping for heap regions |
| `__DATA` | 1.0 MB | 1.1 MB | 1.1 MB | Process and framework writable data sections |
| `CoreAnimation` | 1.0 MB | 0.9 MB | 0.9 MB | Layer tree and window composition state |
| Page tables | 0.6 MB | 0.6 MB | 0.6 MB | Kernel mappings required for the process address space |
| `CoreUI image data` | 0.5 MB | 0.5 MB | 0.5 MB | Native window and control appearance assets |
| Other dirty categories | about 1.3 MB | about 1.1 MB | about 1.7 MB | Stacks, VM allocations, authentication sections, CoreGraphics, IOKit, and small runtime categories |

Clean mapped code and data were about 21–29 MB, but they are not part of the physical footprint total. They are mostly system frameworks and can be shared or reclaimed. The final executable itself is about 0.89 MB, and its clean `__TEXT` mapping is about 1.0–1.1 MB.

Heap inspection showed that the largest named allocations are CoreFoundation dictionaries and strings, Objective-C class metadata and method caches, AppKit view-layout state, CoreText font caches, and CoreGraphics display lists. The Rust task summaries and Markdown runs are small relative to the fixed AppKit/window cost.

## Design choices selected from measurements

- Tauri/WebView was removed completely.
- Slint was rejected after prototypes measured substantially more memory on this machine.
- Swift AppKit was replaced with Objective-C AppKit because the Swift runtime and modern AppKit control implementation added persistent allocations.
- TextKit 2 was rejected for this workload: a 20 KB preview temporarily measured approximately 137 MB due mainly to graphics backing allocations.
- TextKit 1 measured 30–33 MB for the same editing and preview workload and is used in the final app.
- Standard modern buttons and segmented controls were replaced with small custom AppKit controls because macOS 26 implements parts of their appearance through a SwiftUI-backed DesignLibrary stack.
- The sidebar stores summaries only. Only the selected task retains full content.
- Markdown is parsed only when Preview is opened. Returning to Edit releases the preview text view and attributed string.

## Reproduce

Build and measure the real data file:

```bash
./native-macos/build.sh
./native-macos/measure-memory.sh
```

Measure a separate data file:

```bash
./native-macos/measure-memory.sh /tmp/todos.json
```
