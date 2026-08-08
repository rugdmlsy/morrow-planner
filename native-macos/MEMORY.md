# Native macOS memory measurements

Measurement date: 2026-08-04

Machine:

- Apple M5 Pro
- 24 GB RAM
- macOS 26.3.2
- Release build, ad-hoc signed
- Sampled after 7 seconds with `/usr/bin/footprint`

`phys_footprint` is the main metric used here. RSS also includes clean shared framework pages and mapped files, so it is less useful for estimating the app's private memory cost.

## Actual application data

The real data file contained 2 tasks, occupied 661 bytes on disk, and had 240 content characters in total.

| State | Physical footprint | RSS | Idle CPU |
|---|---:|---:|---:|
| Sidebar only | 25 MB | approximately 96,000 to 98,000 KB | 0.0% |
| Editing selected task | 28 to 29 MB | approximately 106,000 to 111,000 KB | approximately 0% |
| Markdown preview | 28 to 30 MB | approximately 108,000 to 112,000 KB | approximately 0% |

## Stress data

The stress file contained 101 tasks. The selected task had about 20 KB of Markdown with headings, links, code, task lists, quotations, tables, and Chinese text.

| State | Physical footprint | RSS | Idle CPU |
|---|---:|---:|---:|
| Sidebar only | 26 MB | 99,264 KB | 0.0% |
| Editing 20 KB task | 30 MB | 108,704 KB | 0.0% |
| Previewing 20 KB task | 33 MB | 110,080 KB | 0.0% |

Adding 100 task summaries costs about 1 MB. Loading the selected full document adds about 3 to 4 MB, mostly because AppKit activates the text system and creates another backing surface. Rendering the 20 KB preview adds another 2 to 3 MB. Samples can differ by about 1 to 2 MB because AppKit and WindowServer choose backing-surface sizes dynamically.

## Actual-data footprint composition

The values below are rounded from `footprint` categories.

| Category | List | Edit | Preview | Meaning |
|---|---:|---:|---:|---|
| `MALLOC_SMALL` | about 12 MB | about 13 MB | about 13 MB | AppKit and Foundation objects, table and text objects, strings, dictionaries, fonts, temporary Rust/JSON allocations, and allocator slack |
| `IOSurface` | about 5.2 MB | about 6.8 MB | about 8.2 MB | Window and scrollable text backing surfaces shared with the compositor |
| `__DATA_DIRTY` | 1.7 MB | 1.8 MB | 1.8 MB | Writable global state in AppKit, Foundation, Objective-C runtime, Rust, and linked system libraries |
| `MALLOC metadata` | 1.2 MB | 1.2 MB | 1.2 MB | Allocator bookkeeping for heap regions |
| `__DATA` | 1.0 MB | 1.1 MB | 1.1 MB | Writable process and framework data sections |
| `CoreAnimation` | 1.0 MB | 0.9 MB | 0.9 MB | Layer tree and window composition state |
| Page tables | 0.6 MB | 0.6 MB | 0.6 MB | Kernel mappings for the process address space |
| `CoreUI image data` | 0.5 MB | 0.5 MB | 0.5 MB | Native window and control appearance assets |
| Other dirty categories | about 1.3 MB | about 1.1 MB | about 1.7 MB | Stacks, VM allocations, authentication sections, CoreGraphics, IOKit, and small runtime categories |

Clean mapped code and data accounted for about 21 to 29 MB, but they are not included in the physical footprint total. Most of those mappings are system frameworks that can be shared or reclaimed. The executable itself is about 0.89 MB, with a clean `__TEXT` mapping of about 1.0 to 1.1 MB.

Heap inspection showed that the largest named allocations came from CoreFoundation dictionaries and strings, Objective-C class metadata and method caches, AppKit view layout state, CoreText font caches, and CoreGraphics display lists. Rust task summaries and Markdown runs were small compared with the fixed AppKit and window cost.

## Design choices based on the measurements

- The app does not use Tauri or WebView.
- Slint prototypes used substantially more memory on this machine, so the app does not use Slint.
- Objective-C AppKit replaced Swift AppKit after the Swift runtime and modern AppKit controls showed persistent allocation overhead.
- TextKit 2 was not used for this workload. A 20 KB preview temporarily measured about 137 MB, mostly from graphics backing allocations.
- TextKit 1 measured 30 to 33 MB for the same edit and preview workload and is used by the app.
- Small custom AppKit controls replaced standard modern buttons and segmented controls because macOS 26 implements parts of their appearance through a SwiftUI-backed DesignLibrary stack.
- The sidebar keeps summaries only. Full content is retained only for the selected task.
- Markdown is parsed when Preview opens. Returning to Edit releases the preview text view and attributed string.

## Reproduce

Build and measure the real data file:

```bash
./native-macos/build.sh
./native-macos/measure-memory.sh
```

Measure another data file:

```bash
./native-macos/measure-memory.sh /tmp/todos.json
```
