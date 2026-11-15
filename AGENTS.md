# AGENTS.md — local law for agents working in elwidget

This file adds repo-local rules on top of the Owner's GLOBAL AGENTS.md
(the copy in agent-team-ci).  Where the two disagree, the GLOBAL file
wins.

## Identity law (same as global)

- Commit author: `MODEL <MODEL@PROVIDER>` (e.g.
  `GLM 5.3 <glm-5.3@z.ai>`).  Never a harness/container identity.
- Both trailers on every commit:
  `Co-authored-by: Z.ai agent <agent@chat.z.ai>` and
  `Co-authored-by: Khalid Rafi <khaalidrafi@gmail.com>`.
- Never commit directly to `main`.  Work lands on `ai/main`; use
  `ai/<topic>--<member-contraction>` branches for long work.

## Repo rules

- Pure Elisp only: no external Emacs packages — json.el and org are
  built-in.  elwidget must keep working on Linux, TTY and
  Android/Termux unchanged (Owner priority order).
- The Android contract is FILE-BASED (specs/bindings/state/events
  under `elwidget-dir`); never introduce a dependency on the app
  process being alive for Elisp-side correctness.
- `make compile` (warnings are errors) and `make test` (offline ERT)
  must stay green on machines with nothing installed.
- The node set mirrors Android RemoteViews constraints; new nodes
  need a matching layout in emacshell's app module FIRST (or a
  documented degradation).
- Keep it simple and light: this runs on a low-spec phone
  (Redmi 8A-class).  No polling tighter than the defaults without an
  Owner order.
