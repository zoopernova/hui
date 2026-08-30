# HUI Roadmap

A GUI framework in Zig. Status: Phases 0–4 complete — native-Wayland Impeller/Vulkan render + a headless software-raster backend over the same draw-list seam; measure/arrange layout (flex + grid); both frontends (immediate + retained); widgets (button, checkbox, slider, single-line text field, scroll); focus/clipboard. A settings panel runs live (Impeller) and headless (raster) off the same draw list.
This doc is a **plan**, not a spec — phases ship in order, later phases stay vague until the one before lands.

## Guiding rules

- **Vertical slices, not horizontal layers.** Get one pixel on screen end-to-end before building a widget system.
- **Defer every decision you can.** Each phase names the *minimum* to move on. Don't build phase N+1's abstraction in phase N.
- **The module boundary is already set:** logic lives in `src/root.zig` (the `HUI` module), the demo/CLI in `src/main.zig`. New subsystems are `src/<name>.zig`, re-exported from `root.zig`.

## Open decisions (resolve at the phase that forces them)

These define the framework. Don't decide them all now — each is due at a specific phase.

| # | Decision | Chosen | Notes / still open |
|---|----------|--------|--------------------|
| D1 | **Rendering backend** | ✅ **Abstracted: Impeller + software raster** | Draw-list seam, **`comptime` backend selection** (zero runtime cost). Impeller = standalone single-header C API (`impeller/toolkit/interop`), consume prebuilts, ⚠️ pin version (API unstable). Software raster = CPU fallback. See Backend abstraction below. |
| D2 | **UI paradigm** | ✅ **Both — immediate + retained, per-project switchable** | Two frontends over one shared render core. See Architecture below. |
| D3 | **Layout model** | ✅ **Measure/Arrange, own box model** | Two-pass (constraints down, sizes up — attribute-grammar shape). Built: `fixed`/`grow`/`fit` per axis, row/column, main-axis `justify` (start/center/end/space-between/around/evenly) + cross-axis `cross` (start/center/end/stretch), **grid** (`fixed`/`fr`/`auto` tracks, explicit placement + spanning, sequential auto-flow, row/col gaps), and absolute (out-of-flow). Own model, not the CSS spec — the one boundary is grid auto-track sizing of spanning children (even split, not spec min/max-content distribution). **Retained invalidation:** rung-2 (dirty-flag + subtree skip + cache keyed on constraints, Flutter relayout-boundary / Taffy style) is the build target; **self-adjusting computation (auto DDG + change-propagation) is the documented north star**, adopted only if hand-maintained invalidation proves too coarse/buggy at scale. Immediate frontend re-lays-out the full (ephemeral) tree each frame — SAC is a retained-only optimization. |
| D4 | **Target platforms** | 🚧 **First target: Linux / Wayland**; rest open | Wayland needs EGL (GLES) or `VK_KHR_wayland_surface` (Vulkan) — no built-in GL. Other platforms follow as per-target embedders. |
| D5 | **Text/font stack** | ✅ **Impeller's own typography API** | `ImpellerTypographyContext` + `ParagraphBuilder` + `DrawParagraph`. No new deps. Standalone SDK has no fontconfig, so we register one TTF (`src/text.zig`, hardcoded Noto Sans). Ties text to the Impeller backend — raster backend (Phase 4) needs its own path. |

## Architecture (from D2: dual-mode)

One renderer, two frontends. Mode is a per-project choice, not a runtime toggle inside one app.

```
                 ┌─ immediate frontend ─┐              ┌─ Impeller backend ─┐
your app ──pick──┤                      ├──▶ draw list ─┤  (comptime-picked) ├──▶ surface ◀── embedder
                 └─ retained frontend ──┘   (the seam)  └─ software raster ──┘   (window + gfx ctx)
```

- **Shared, mode-agnostic:** render primitives, text, the draw-list type. Built once (Phases 0–2).
- **Immediate frontend:** app calls `hui.button(...)` each frame; frontend emits draw list + returns interaction results inline.
- **Retained frontend:** app builds/updates a widget tree once; frontend diffs and re-emits the draw list on change.
- **The frontend contract:** both frontends produce the *same* draw-list type. Keep that type the single seam — no mode-specific concepts leak below it.

### Backend abstraction (D1)

The **draw list is also the backend seam**. A backend is anything that consumes a draw list and presents it.

- **Seam level:** draw-list. One handoff per frame → dispatch cost is once/frame, negligible.
- **Selection:** **`comptime`** — backend chosen at build time (per-project, matching D2's per-project mode choice). Monomorphized and inlinable, so the abstraction has **zero runtime cost**; it vanishes at compile time.
- **Backends:** Impeller (GPU) · software raster (CPU fallback — headless/testing, no GPU needed).
- **Contract:** a backend implements `present(draw_list) → surface`. That's the whole interface. Don't add per-primitive backend calls — batch stays in the draw list.
- **Cost paid:** code/compile-time complexity only, not runtime. Keep the interface minimal so the second backend (raster) is cheap to satisfy.

### Embedder model (windowing) — Flutter-style

**HUI's core does not own the window.** Like Flutter's engine + embedder split: the core renders into a *surface handed to it*; an **embedder** owns the platform window, graphics context, input, and vsync.

- **The seam:** the consumer provides a surface (native handle / gfx context + size) and a present/vsync hook. HUI renders; the embedder owns the window. This keeps the *library* portable — the platform layer lives outside the core.
- **We ship a default embedder per target** — the best surface provider for each platform, not one lib everywhere (mirrors Flutter's per-platform embedders). Consumers can still bring their own.
- **Selection:** comptime by target — HUI picks the platform's default embedder at build time unless the consumer supplies one. E.g. (candidates, decided per D4): desktop → GLFW or SDL3 · mobile → SDL3 · web/wasm → sokol_app or emscripten. Each target maps to one `src/embedder/<lib>.zig`.
- **Why this stays cheap:** all defaults implement the *same* embedder contract, so adding a platform is a new adapter file, not a change to the core.
- **Contract (keep minimal):** `init/deinit`, `pollEvents() → []Event`, plus surface plumbing — `vkGetInstanceProcAddr()` and `createVulkanSurface(instance) → VkSurfaceKHR`, and `drawableSize()`. No widget/layout concepts here. **Per-frame acquire/present is NOT the embedder's** — with Impeller's Vulkan interop, Impeller owns the `VkInstance` and its swapchain owns acquire/present (the backend drives frames, 0.5). Revised from the initial 0.3 draft once the real Impeller Vulkan flow was read.
- **⚠️ Per-target artifact coupling (known, deferred):** the Impeller prebuilt is per-platform (`.../linux-x64/impeller_sdk.zip`), and `build.zig.zon` + `build.zig` currently pin/link **linux-x64 only**. Adding a target means a per-target prebuilt (its own SHA/hash) and target-conditional linking, wired alongside that target's embedder — not a core change. First multi-target work item when D4 expands past Linux.

### Module layers (post-Phase-3 decoupling)

Strictly layered — imports only ever point **down**, so no module upstream of another depends on it (verified: nothing imports `layout` except `paint` and the frontends; the render backend never imports `layout`).

```
geometry.zig            Point, Rect, Size(f32), Color            (leaf — no deps)
  ├─ draw_list.zig      Command, DrawList                        → geometry
  ├─ text.zig  (seam)   Measurer, Metrics                        → geometry
  ├─ input.zig          pointer + keyboard state                 → geometry
  └─ layout.zig         Style, Node, measure/arrange, contains   → geometry, text
        └─ paint.zig    emit(node) → DrawList                    → layout, draw_list
              └─ immediate.zig / retained.zig                    → layout, paint, draw_list, input, text
backend/impeller.zig    Renderer; implements the text seam       → impeller, draw_list, geometry, text, impeller_text, vk_wsi
backend/impeller_text.zig  Typography (Impeller impl of text seam) → impeller, geometry, text
embedder.zig            Config, Extent(pixels), Event            → (integer window extent, distinct from geometry.Size)
```

Principles enforced: **one home per concept** (primitives in `geometry`; the text-measure seam in `text`, its Impeller impl under `backend/`; rendering in `draw_list`+`paint`+`backend`; structure in `layout`), and **no backwards edges** (the render backend implements the `text.Measurer` seam instead of importing `layout`).

Phase-4 additions slot into the same layers without new backwards edges:
- `focus.zig`, `clipboard.zig` — neutral seams above `input`/`geometry`, consumed by widgets + frontends.
- `widgets.zig` — checkbox/slider/text-field/scroll; builds `layout.Node` subtrees, depends on `layout`+`input`+`focus`+`clipboard`+`text`. Frontends register + drive them.
- `backend/raster.zig` (+ `raster_text.zig`, `stb.zig`, vendored `stb_truetype.h`) — the second backend; consumes the same `draw_list`, implements the same `text` seam via stb glyphs. Peer to `backend/impeller.zig`, never imports `layout`.
- `clip`/`rounded_rect` live in `draw_list`+`paint` and both backends implement them.

## Phases

### Phase 0 — Foundations ✅ *(complete)*
Goal: the Linux/Wayland embedder opens a window; Impeller renders into its surface and clears to a color. **Achieved — `./zig-out/bin/HUI 30` renders + exits 0.**
Target: **Linux / Wayland**. Surface lib: **SDL3**. Graphics API: **Vulkan** (`VK_KHR_wayland_surface`, SDL3 creates the surface).

- [x] **0.1 Impeller prebuilt.** Pinned in `build.zig.zon` (`.impeller`): **Flutter stable 3.47.1**, engine SHA `5d531788691ec3404cac0cee66ead4007b177363`, `linux-x64`, url + hash locked. Impeller **v1.4.0**. (Pin is anchored to the immutable engine SHA + zip sha256, so it holds even after `stable` advances past 3.47.1.) SDK layout: `include/impeller.h` (C API), `impeller.hpp`, `lib/libimpeller.so`.
  - ⚠️ **Vulkan interop requires Impeller ≥ 1.4** — older prebuilts (e.g. v1.2.0) expose GLES only (`ImpellerContextCreateOpenGLESNew`, FBO-wrapped surface). v1.4 adds `ImpellerContextCreateVulkanNew` + `ImpellerVulkanSwapchain*`. Don't downgrade the SHA below a 1.4 build.
  - To bump: get the engine SHA from `bin/internal/engine.version` on a Flutter channel, re-run `zig fetch --save=impeller <url>`.
- [x] **0.2 Impeller FFI.** `src/impeller.zig`: `@cImport("impeller.h")` (translates clean — header is stdlib-only + clang nullability attrs). Raw C namespace as `impeller.c` + `Version.get()` helper. `build.zig` consumes the prebuilt's `include/`+`lib/` directly (zip has no build.zig), links `impeller`, libc on, rpath to `lib/`. Verified: `zig build test` runs a version test that calls `ImpellerGetVersion()` on the linked `.so` (translate-c + link + runtime load all proven).
- [x] **0.3 Embedder contract.** `src/embedder.zig`: shared value types (`Config`, `Event`) + `assertEmbedder(T)` comptime validator (Zig's duck-typed "interface"). Required decls: `init`/`deinit`/`acquireFrame`/`present`/`pollEvents`. `FrameTarget` left embedder-defined (backend binds to it in 0.5) — no speculative type before the first impl. Re-exported from `root.zig`; test proves a conforming struct validates. Per-target default *selection* deferred to 0.4 (needs the SDL3 impl).
- [x] **0.4 First embedder (Linux/Wayland).** `src/embedder/sdl3.zig` (`Sdl3`): SDL3 Vulkan-capable window, SDL→`Event` mapping, surface plumbing (`vkGetInstanceProcAddr`, `createVulkanSurface(instance)`, `drawableSize`). SDL3 headers translate clean via `@cImport` (its own Vulkan handle typedefs — no Vulkan headers needed). Linked as system lib in `build.zig`. `Default` comptime-selects it on Linux. Verified: `zig build test` (7/7) — both `assertEmbedder` tests pass; window smoke test deferred to 0.6. Contract revised here (dropped acquire/present — swapchain owns them).
- [x] **0.5 Bind Impeller to the surface** *(code-complete, compiles; runtime-verified in 0.6)*. `src/backend/impeller.zig` (`Renderer`): create Vulkan `ImpellerContext` fed the embedder's `vkGetInstanceProcAddr` → `GetVulkanInfo` → `embedder.createVulkanSurface(instance)` → `ImpellerVulkanSwapchainCreateNew`. `clear(color)` acquires a swapchain surface, `DrawPaint`s a full-surface fill, presents. `version_packed` in `impeller.zig` (component-rebuilt, macro doesn't translate). Embedder is duck-typed (`anytype`). ⚠️ only proven to *run* once 0.6 opens a window.
- [x] **0.6 Clear loop.** `main.zig`: `Sdl3.init` → `Renderer.init(&embedder)` → loop {`pollEvents`, `clear(deep blue)`} until `close_requested`. Frame-cap arg for non-interactive runs (`zig build run -- N`).
- **Done:** verified `./zig-out/bin/HUI 30` → renders 30 frames, presents, **exits 0**. Full chain runs: SDL3 Wayland window → Impeller Vulkan context → swapchain → clear → present.
- _Seam check passed:_ `embedder.zig`/`sdl3.zig` mention no Impeller; `impeller.zig`/`backend` mention no windowing lib.
- _Gotcha found & fixed:_ `std.log`/`std.debug.print` **panic** under `main(init: std.process.Init)` — the global IO's environ is empty (real one is on `init.io`), and scanning it null-unwraps. Fix: library code returns errors (no global logging); app output goes through `init.io`. See `[[hui-no-std-log]]`.
- _Note:_ Impeller prints a benign "validation layers not found" warning (layers not installed system-wide); non-fatal, renders without them.

### Phase 1 — Draw primitives + the draw-list/backend seam ✅ *(complete)*
Goal: draw rectangles, lines, and a filled quad — through the shared draw list, via the backend.
- [x] `src/draw_list.zig`: the mode-agnostic draw-list type + geometry/color vocabulary (`Color`/`Point`/`Rect`, `Command` union: `background`/`fill_rect`/`line`, `DrawList` with `reset`/push helpers). Tested.
- [x] `src/backend/impeller.zig`: `Renderer.render(*const DrawList)` replaces `clear()` — switches over commands, emits `DrawPaint`/`DrawRect`/`DrawLine` with fill/stroke paint state. Consumes the seam.
- [x] **Done & pixel-verified:** the scene (olive bg, orange rect, semi-transparent green rect, white + red diagonal lines) renders correctly — confirmed by screenshot. 6/6 tests.
- **Three real bugs found & fixed getting here:**
  1. **Geometry lifetime** — `&rect`/`&from`/`&to` passed to `DrawRect`/`DrawLine` were emit-locals; Impeller resolves the display list lazily at `CreateDisplayListNew`, so they dangled → shapes invisible. Fixed: per-frame pre-reserved geometry arrays in the backend (see `example_vk.c` — geometry must live to build time).
  2. **Native-Wayland swapchain sizing** — Impeller's interop hardcodes the swapchain to `ISize::MakeWH(1,1)` and `imageExtent = clamp(1, minImageExtent, maxImageExtent)`; on Wayland `currentExtent` is `0xFFFFFFFF` so it's never corrected (Impeller TODO 163070, no size API). **Fixed on native Wayland** with a WSI shim (`src/backend/vk_wsi.zig`): wrap `vkGetPhysicalDeviceSurfaceCapabilities[2]KHR` and pin `minImageExtent` to the live window size so `clamp(1,size,max)==size`. Runs on **native Wayland**, no XWayland. See `[[hui-wayland-swapchain]]`.
  3. `std.log` panic under `process.Init` (Phase 0) — see `[[hui-no-std-log]]`.
- _Deferred:_ a separate `src/backend.zig` comptime-selection contract — only one backend today, so a selection layer is speculative. Add with the raster backend (Phase 4), when there's a second to select between.
- _Note:_ the software-raster backend is a Phase 4 task — the seam is designed for it now, built later.

### Phase 2 — Text ✅ (complete)
Goal: draw a string at a position.
- [x] Decide **D5** (font stack) → **Impeller's own typography API** (no atlas to hand-roll; the engine shapes + rasterizes).
- [x] `src/text.zig`: `Typography` owns an `ImpellerTypographyContext`, registers one TTF (Noto Sans), builds a paragraph per string.
- [x] `draw_list.zig`: `text` command (borrowed `str`, size, color); backend emits `DrawParagraph`. Paragraph handles live in a per-frame array (same lazy-resolve lifetime rule as geometry — released after present).
- [x] `Renderer.init` now takes `io` (Zig 0.16 fs needs it) to load the font.
- **Done when:** "Hello, HUI" renders on screen. ✅ **Pixel-verified on native Wayland** (48px white text over the scene).

### Phase 3 — Dual-mode frontends + layout (the framework starts here) ✅ (complete)
Goal: a clickable button + label, working in **both** modes over the shared core.
- [x] Decide **D3** (layout) → **measure/arrange, own box model** (see D3 row). SAC documented as retained's invalidation north star, rung-2 as build target.
- [x] `src/input.zig`: mode-agnostic pointer (position + press/release edges) **and keyboard** (held/pressed by scancode + typed UTF-8); `layout.contains` for hit-testing. Pointer coords are pixel-space (embedder scales by window pixel density → correct on HiDPI).
- [x] `src/layout.zig`: measure/arrange over a `Node` tree — `fixed`/`grow`/`fit` per axis, row/column, **justify + cross-align**, **grid** (fixed/fr/auto tracks, placement + spanning + auto-flow), absolute out-of-flow. Text sizing via a backend-supplied `Measurer` (Impeller paragraph metrics). Heap-boxed children for stable pointers. Unit tests: grow distribution, justify/cross centering, grid placement+spanning.
- [x] `src/immediate.zig`: `Imm` — tree rebuilt each frame in a reset arena; buttons return click via *previous* frame's rect (standard IM chicken-and-egg fix); container stack (`beginBox`/`endBox`).
- [x] `src/retained.zig`: `Tree` — persistent nodes + click handlers keyed by opaque tag; `frame()` = layout → dispatch → emit. Full-tree relayout each frame (rung-2/SAC slot in behind `frame()` later).
- [x] `root.zig` exposes `input`, `layout`, `immediate`, `retained`.
- **Done when:** the *same* counter demo works built two ways — once immediate, once retained. ✅ Both build & run clean (`zig build run -- immediate|retained`); retained click→increment **unit-tested headless**; counter **pixel-verified on native Wayland** (label + [-]/[+] buttons).

### Phase 4 — More widgets + state + second backend ✅ (complete)
Goal: enough to build a real small app, and prove the backend seam holds. Design locked in a grill (8 decisions): state cells + shared focus; raster text via stb_truetype behind the text seam; `clip`+`rounded_rect` primitives; complete single-line text field.
- [x] **Widgets** (`src/widgets.zig`): checkbox, slider (thumb rides flex spacers), single-line **text field** (caret, selection, arrows/home/end, clipboard cut/copy/paste, click-to-place), and **scroll container** (clip + wheel + draggable scrollbar). Persistent subtrees mutated in place; frontend-agnostic `Widget.update`.
- [x] **State/event hardening**: shared `src/focus.zig` (click-to-focus + Tab/Shift-Tab cycle, tab-order unit-tested) routes key/text to the focused widget; retained `frame()` resolves widget state before layout (no visual lag). `src/clipboard.zig` seam (SDL impl). Scroll wheel + key scancodes added to input.
- [x] **Draw-list primitives**: `clip_push`/`clip_pop` + `rounded_rect` added to the seam; both backends implement them (Impeller: ClipRect/RoundedRect+Save/Restore; raster: rect-clip stack + SDF coverage).
- [x] `src/backend/raster.zig`: **software-raster backend** — same draw list → CPU RGBA8 buffer, coverage-AA shapes, **stb_truetype** glyphs (`src/backend/raster_text.zig`, vendored `src/vendor/stb_truetype.h`), PPM dump. No window, no GPU.
- **Done when:** a demo settings panel works, and the same demo renders headless via the raster backend. ✅ Settings panel (text field + checkbox + slider + scroll list) runs **live via Impeller** (native Wayland, pixel-verified) and renders **headless via raster** off the *same* draw list — headless render **spot-checked in `zig build test`** + PPM eyeballed. Proves the draw-list seam isn't Impeller-shaped.

### Phase 5 — Polish & reach
Goal: usable by someone other than you.
- [ ] Decide **D4** (platforms) — only if there's real demand.
- [ ] Theming, DPI/scaling, docs + examples, API stabilization.
- **Done when:** a second person builds something with it from the README alone.

## Explicitly NOT doing (until proven needed)

- Animation system, accessibility tree, custom shaders, plugin system.
- A *third* backend or vtable/runtime backend switching — comptime + two backends is the ceiling until a real need appears.
- Building the raster backend before Phase 4 — the seam is designed for it in Phase 1, implemented in Phase 4.
- Runtime mode switching *within one app* — mode is picked per project (D2), not toggled live.
- Multi-platform before desktop is solid (D4).

> This list is a suggestion, not a ruling — you decide what's in and out.
