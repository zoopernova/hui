# HUI

A GUI framework in Zig — Google Impeller (Vulkan) rendering on native Wayland, a
draw-list backend seam, and both immediate and retained frontends over a shared
measure/arrange layout engine. See `ROADMAP.md` for the phase plan and the D1–D5
architectural decisions.

## Agent skills

### Issue tracker

Local markdown — issues and specs live as files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root (neither created yet — made lazily by `/domain-modeling`). `ROADMAP.md` holds the current decisions of record. See `docs/agents/domain.md`.
