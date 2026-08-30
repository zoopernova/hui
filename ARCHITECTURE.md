# HUI Architecture

A GUI framework in Zig. Strictly layered: **imports only ever point down**. Nothing
upstream of a module imports it — verified from the source import graph. Two swap
points (render **backend**, OS **embedder**) sit behind seams so the core never knows
which is in use.

## Layered module map

```
 ┌─ L7  ENTRY ─────────────────────────────────────────────────────────────────┐
 │  main.zig            demos (counter, settings); wires embedder+backend+tree   │
 │  root.zig            the `HUI` module — re-exports every public submodule      │
 └───────────────────────────────────────────────────────────────────────────────┘
        │ uses
 ┌─ L6  FRONTENDS ──────────────────────────────────────────────────────────────┐
 │  immediate.zig  Imm      rebuild tree each frame; widgets return values        │
 │  retained.zig   Tree     persistent tree; callbacks + registered widgets       │
 └───────────────────────────────────────────────────────────────────────────────┘
        │                                   │
 ┌─ L5  WIDGETS ─────────────┐      ┌─ L4  PAINT BRIDGE ────────────────────────┐
 │  widgets.zig              │      │  paint.zig   emit(Node tree) → DrawList     │
 │   Checkbox Slider         │      └─────────────────────────────────────────────┘
 │   TextField Scroll        │                     │
 └────────────┬──────────────┘                     │
        │                                            │
 ┌─ L3  CORE ────────────────────────────┐   ┌─ RENDER SEAM ────────────────────┐
 │  layout.zig   measure/arrange, Node    │   │  draw_list.zig  Command, DrawList │
 │               flex + grid + absolute   │   │   (the backend-agnostic verbs)    │
 │  focus.zig    keyboard focus + Tab      │   └──────────────┬────────────────────┘
 └───────┬───────────────┬────────────────┘                  │ consumed by
         │               │                                    │
 ┌─ L2  SEAMS ───────────┴────────────────────────────────────┴──────────────────┐
 │  text.zig      Measurer/Metrics (text-measure seam)                            │
 │  input.zig     pointer+keyboard state, key scancodes                           │
 │  clipboard.zig Clipboard get/set seam                                          │
 └───────────────────────────────┬────────────────────────────────────────────────┘
        │                          │
 ┌─ L1  PRIMITIVES ────────────────┴───────────────────────────────────────────────┐
 │  geometry.zig   Point · Rect · Size(f32) · Color     (leaf, no deps)            │
 └───────────────────────────────────────────────────────────────────────────────┘

 ┌─ SWAP POINT A — RENDER BACKEND (consumes DrawList, implements text seam) ───────┐
 │  backend/impeller.zig  Renderer   GPU: Vulkan via Google Impeller               │
 │    ├ backend/impeller_text.zig    Typography (Impeller impl of text.Measurer)   │
 │    ├ backend/vk_wsi.zig           native-Wayland swapchain-extent shim          │
 │    └ impeller.zig                 Impeller C ABI bindings (@cImport)            │
 │  backend/raster.zig    Raster     CPU: RGBA8 buffer, coverage-AA, no GPU        │
 │    ├ backend/raster_text.zig      Font (stb impl of text.Measurer)             │
 │    ├ backend/stb.zig              stb_truetype decls (@cImport)                │
 │    └ vendor/stb_truetype.h + stb_impl.c   (impl compiled as C)                 │
 └───────────────────────────────────────────────────────────────────────────────┘

 ┌─ SWAP POINT B — EMBEDDER (owns the OS window + input + surface plumbing) ───────┐
 │  embedder.zig        contract (duck-typed) + `Default` per-target selection     │
 │  embedder/sdl3.zig   Sdl3   SDL3 window, event→Event mapping, Vulkan surface,   │
 │                             pixel-density scaling, SDL clipboard                │
 └───────────────────────────────────────────────────────────────────────────────┘
```

## The per-frame pipeline (data flow)

```
 OS event                                                            pixels
    │                                                                  ▲
    ▼                                                                  │
 embedder.pollEvents ──► []Event ──► input.feed / focus.beginFrame     │
                                          │                            │
                                          ▼                            │
                              FRONTEND builds/updates a                │
                              layout.Node tree from state              │
                                          │                            │
                                          ▼                            │
                     layout.layout(root, area, Measurer) ──────────────┤
                       measure↑ (asks backend to measure text)         │
                       arrange↓ (assigns every node.rect)              │
                                          │                            │
                                          ▼                            │
                          paint.emit(root) ──► draw_list.DrawList       │
                                          │        (Command list)      │
                                          ▼                            │
                    ┌─────────────────────┴─────────────────────┐      │
                    ▼                                            ▼      │
        backend/impeller.render                     backend/raster.render
        (Vulkan display list → present) ────────────► (CPU blend → buffer/PPM)
```

Same `DrawList`, either backend. The frontend, layout, and widgets never name a
backend; the backend never names layout or widgets.

## Module duties

| Module | Layer | Duty | Key public API | Imports |
|---|---|---|---|---|
| `geometry.zig` | L1 primitives | Value types shared by everyone; the common vocabulary that stops higher modules coupling through a borrowed type. | `Point` `Rect` `Size` `Color` | — |
| `draw_list.zig` | render seam | The backend-agnostic **command vocabulary** frontends produce and backends consume. | `Command` (`background`/`fill_rect`/`rounded_rect`/`line`/`text`/`clip_push`/`clip_pop`), `DrawList` | geometry |
| `text.zig` | L2 seam | **Text-measure seam** — lets layout measure glyph runs and the backend supply the measurement, without either importing the other. | `Measurer` `Metrics` `default_font_path` | geometry |
| `input.zig` | L2 seam | Per-frame pointer + keyboard snapshot with press/release edges, scroll deltas, typed text, key scancodes. | `Input` (`beginFrame`/`feed`/`keyDown`/`keyPressed`/`typed`/`shift`/`ctrl`), `key.*` | geometry |
| `clipboard.zig` | L2 seam | Neutral clipboard get/set interface so widgets cut/copy/paste without a platform dep. | `Clipboard` (`get`/`set`) | — |
| `focus.zig` | L3 core | Shared keyboard-focus state: which widget owns keys, click-to-focus, Tab/Shift-Tab cycling. | `Focus` (`beginFrame`/`visit`/`has`/`clear`) | input |
| `layout.zig` | L3 core | **Measure/arrange engine.** Owns the `Node` tree + `Style`. Flex (fixed/grow/fit, justify, cross-align), grid (fixed/fr/auto tracks, placement, spanning), absolute, clip flag. Pure — no draw-list, no backend. | `Node` `Style` `Len` `Justify` `Align` `Track` `Grid` `layout()` `contains()` | geometry, text |
| `paint.zig` | L4 bridge | Walk a laid-out `Node` tree and translate it into `DrawList` commands. Kept out of layout so layout stays pure. | `emit(node, *DrawList)` | layout, draw_list |
| `widgets.zig` | L5 widgets | Checkbox, slider, single-line text field (caret/selection/clipboard), scroll (clip+wheel+scrollbar). Persistent subtrees whose `update` mutates node fields in place from state+input. | `Widget` `Checkbox` `Slider` `TextField` `Scroll` `theme` | layout, geometry, input, focus, clipboard, text |
| `immediate.zig` | L6 frontend | Immediate mode: rebuild the tree each frame in a reset arena; widgets return interaction via previous-frame rects. | `Imm` (`begin`/`beginBox`/`endBox`/`label`/`button`/`end`) | layout, paint, draw_list, geometry, input |
| `retained.zig` | L6 frontend | Retained mode: persistent tree + click `Handler`s + registered `Widget`s; `frame()` resolves state before layout, dispatches, emits. | `Tree` (`button`/`checkbox`/`slider`/`textField`/`scroll`/`frame`), `Handler` | layout, paint, draw_list, geometry, input, focus, clipboard, widgets |
| `backend/impeller.zig` | swap A | **GPU backend.** Owns the Impeller Vulkan context/swapchain; consumes `DrawList`; provides a `Measurer`. Never imports layout. | `Renderer` (`init`/`render`/`resize`/`measurer`/`deinit`) | impeller, draw_list, geometry, text, impeller_text, vk_wsi |
| `backend/impeller_text.zig` | swap A | Impeller implementation of `text.Measurer` (paragraph build + metrics). | `Typography` | impeller, geometry, text |
| `backend/vk_wsi.zig` | swap A | Native-Wayland fix: proc-address shim pinning swapchain `minImageExtent` to the window size. | `Shim` `install` `procAddr` | — (vulkan cImport) |
| `impeller.zig` | swap A | Impeller C ABI bindings + version packing. | `c` `version_packed` | — (impeller.h cImport) |
| `backend/raster.zig` | swap A | **CPU backend.** Rasterizes the same `DrawList` into an RGBA8 buffer: coverage-AA rounded rects/lines, rect-clip stack, stb glyph blit; PPM dump; pixel readback. | `Raster` (`init`/`render`/`measurer`/`pixel`/`writePpm`) | geometry, draw_list, text, raster_text, stb |
| `backend/raster_text.zig` | swap A | stb_truetype implementation of `text.Measurer` + glyph access for the raster blitter. | `Font` | geometry, text, stb |
| `backend/stb.zig` | swap A | stb_truetype declarations (impl compiled as C — see `hui-stb-translate-c`). | `c` | — (cImport) |
| `embedder.zig` | swap B | Windowing **contract** (duck-typed) + comptime `Default` per target; `Extent` (integer window pixels) + input `Event` union. | `Config` `Extent` `Event` `Default` `assertEmbedder` | embedder/sdl3 |
| `embedder/sdl3.zig` | swap B | SDL3 adapter: window, `Event` mapping, Vulkan surface, HiDPI pointer scaling, SDL clipboard. | `Sdl3` (`init`/`pollEvents`/`vkGetInstanceProcAddr`/`createVulkanSurface`/`drawableSize`/`clipboard`) | embedder, clipboard |
| `root.zig` | entry | The `HUI` package module; re-exports every submodule. | (all above) | all |
| `main.zig` | entry | Demos: counter (both frontends) and the settings panel (live Impeller + headless raster). | `main` | HUI |

## The seams (why the swaps are cheap)

- **Render seam — `draw_list.DrawList`.** Frontends emit `Command`s; backends consume them. Adding a backend = one file implementing `render(*const DrawList)`; the settings panel proved it by rendering identically on Impeller (GPU) and raster (CPU) with zero frontend changes.
- **Text-measure seam — `text.Measurer`.** Layout needs glyph widths for `fit`; the backend supplies them. Homed in `text.zig` (not layout) so the backend implements it *without importing layout* — the one edge that would otherwise point backwards.
- **Embedder contract — `embedder.zig`.** Comptime duck-typed (`assertEmbedder`); the core renders into a surface the embedder provides and never owns the window. New platform = one `embedder/<lib>.zig`.
- **Clipboard seam — `clipboard.Clipboard`.** Keeps the text-field platform-free.
- **Focus — `focus.Focus`.** One shared focus/Tab layer under both frontends.

## Known edges & notes

- `embedder.zig ↔ embedder/sdl3.zig` is a deliberate 2-way import (contract types ↔ `Default` selection) — Zig-legal via lazy analysis, not a layering violation.
- Two `Size`-like types on purpose: `geometry.Size` (f32 layout units) vs `embedder.Extent` (integer window pixels) vs `vk_wsi.Extent` (Vulkan) — distinct concepts, not duplication.
- Invalidation today is full-tree relayout each frame; the D3 north star (rung-2 dirty-flag cache → self-adjusting computation) slots in behind `frame()` without touching this graph.
