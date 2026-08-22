# Git & PR workflow for coding tasks

This applies whenever you make code changes in a cloned repo — on top of
that repo's own `CLAUDE.md`/`AGENTS.md`, if it has one. Pods running these
agents can be killed and rescheduled at any time, so the workflow below
exists to make every task resumable by a fresh agent from the PR alone, and
to prove push/`gh` access work *before* you invest time in the task.

It does not change how you write chat replies — that's the separate
`STE100 + ADHD` output style.

## 1. Before writing any code

1. Fetch first: `git fetch origin`. If you're not already on a
   task-specific branch, create one from a fresh `origin/<default-branch>`
   — e.g. `git checkout -b <branch> origin/main` — not from whatever a
   local checkout happens to have, which can be stale. Name the branch
   `<type>/<short-description>`, using a Conventional Commits type — e.g.
   `feat/add-retry-logic`, `fix/null-pointer-in-parser`. Branching from a
   stale base is a common cause of avoidable merge conflicts later.
2. Push it immediately, even with no commits yet:
   `git push -u origin <branch>`. This confirms push access works before
   you rely on it later.
3. Open a **Draft PR** with `cc-rc-pr-update` (see below). This confirms
   `gh` access works, and gives a fresh agent something to find if this
   session is lost.
4. If a branch/PR already exists for this task — you're resuming a lost
   session — reuse it. Never open a duplicate.

## 2. `cc-rc-pr-update`: creating and updating the PR

Don't hand-craft `gh pr create`/`gh pr edit` calls or PR markdown yourself.
Use the baked-in `cc-rc-pr-update` command instead — it builds the PR body
consistently and picks create-vs-edit for you.

Write three plain-markdown files (e.g. under `/tmp`), then run it:

```sh
cc-rc-pr-update \
  --title "feat(scope): short conventional-commit-style title" \
  --summary-file /tmp/pr-summary.md \
  --plan-file /tmp/pr-plan.md \
  --ledger-file /tmp/pr-ledger.md
```

- `--title`: the PR title. Conventional Commits format, same as commits.
- `--summary-file`: 1-3 sentences on what this task is and why.
- `--plan-file`: a verbatim copy of the plan you intend to follow (from
  plan mode, or a short step list you write yourself if there was no
  separate planning step).
- `--ledger-file`: the progress ledger (see below). Leave it empty, or use
  a one-line placeholder, for the very first call.

Any of the three flags accepts `-` to read that section from stdin instead
of a file. Re-running the command regenerates the whole PR body from the
three inputs every time — always pass all three, even when only the ledger
changed, so the sections never drift out of the template.

The Plan and Progress ledger sections both render **collapsed** (`<details>`,
not `<details open>`) — the summary above them should be enough to read at a
glance; expand either only when you actually need the detail.

First call with no PR open yet for this branch creates a **Draft PR**.
Later calls edit that same PR in place.

**Writing the section files:** GitHub renders a single `\n` inside a PR/
issue body as a literal line break, not as a space like most Markdown
renderers — so a hard-wrapped paragraph (each sentence or clause on its own
line, as you might write in a text editor) shows up as choppy, broken
lines instead of flowing prose. Write each paragraph in `--summary-file`/
`--plan-file`/`--ledger-file` as a single unwrapped line, and separate
paragraphs only with a blank line. Markdown lists/headings are unaffected —
keep those on their own lines as normal, since that line-per-item structure
is what you want rendered anyway.

## 3. While working

- Commit using **Conventional Commits**: `type(scope): description`.
- For multi-phase or complex tasks, commit and push at natural break
  points — end of a plan phase, a logically complete unit of work, or
  right before something risky/long-running. Trivial single-step tasks can
  just commit once at the end.
- After every such push, call `cc-rc-pr-update` again with a refreshed
  `--ledger-file`, keeping `--title`/`--summary-file`/`--plan-file` the
  same.
- Write the ledger for **another agent**, not a human — assume the reader
  has no memory of this conversation. State: what's done, what's verified
  (tests run, builds passed), what's left, and any decisions or blockers.
  Be concrete enough that a fresh agent could pick the PR up cold and
  continue without re-deriving anything.

## 4. When the plan is complete

1. Verify the work — run tests/build as the repo's own conventions
   require.
2. Do one final `cc-rc-pr-update` call with a ledger summarizing the
   completed state.
3. Mark the PR ready: `cc-rc-pr-update --ready` (reuses the branch's
   existing PR; add `--title`/`--summary-file`/`--plan-file`/
   `--ledger-file` too if you want a final body refresh at the same time).
