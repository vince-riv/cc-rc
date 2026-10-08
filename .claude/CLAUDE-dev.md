# Git & PR workflow for coding tasks

This applies whenever you make code changes in a cloned repo — on top of
that repo's own `CLAUDE.md`/`AGENTS.md`, if it has one. Pods running these
agents can be killed and rescheduled at any time, so the workflow below
exists to make every task resumable by a fresh agent from the PR alone, and
to prove push/`gh` access work *before* you invest time in the task.

It does not change how you write chat replies — that's the separate
`STE100 + ADHD` output style.

## Go versions

This image ships Go 1.25 and 1.26, managed by `update-alternatives`. Plain
`go` on `PATH` resolves to 1.26 (the default). To use 1.25 instead, call it
directly: `/usr/lib/go-1.25/bin/go`.

## Node versions

This image ships Node 22, 24, and 26 as prebuilt binaries under
`/usr/local/node-<major>/`, managed by `update-alternatives`. Plain `node`
on `PATH` resolves to 26 (the default). To use 22 or 24 instead, call them
directly — `/usr/local/node-22/bin/node` or `/usr/local/node-24/bin/node`
— or use `nvm use 22`/`nvm use 24`: `nvm` is installed too, and all three
versions are pre-registered with it (as symlinks to the same
`/usr/local/node-<major>/` install, not a separate download).

## 0. Hard rules

- NEVER push to `main` or `master`. ALWAYS work on a branch and open a PR.
- NEVER create tags or releases unless the user explicitly asks for one.
- NEVER force-push or rewrite history on a shared branch. Only use
  `--force-with-lease` on your own task branch, and only when needed.
- NEVER delete or overwrite a file without reading it first.
- NEVER disable, skip, or weaken a failing test to make CI pass. Fix the
  root cause, or leave the test failing and flag it in the ledger.
- NEVER merge your own PR. Leave that to the user or a required review.
- If a task adds a new dependency, call it out in the PR summary.

## 1. Before writing any code

The harness may auto-create a worktree and branch for the session. That
branch is NOT a substitute for the sequence below. It has no upstream, no
Draft PR, and no ledger — a fresh agent can't resume from it. Run steps 1-2
first, in every session, before any code change, even when the harness has
already put you on a branch.

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
3. If a branch/PR already exists for this task — you're resuming a lost
   session — reuse it. Never open a duplicate.

## 2. Open the Draft PR at the first opportunity

GitHub won't open a PR for a branch with no commits of its own, so the
Draft PR can't come before the first code change. Open it at the **earliest
convenient point instead: as soon as you have a first meaningful chunk of
work committed and pushed, and before you spend time on validation**
(tests, builds, lint, manual checks, long-running commands). Opening it
there still confirms `gh` access early, and leaves a fresh agent something
to find if this session is lost before validation finishes.

Concretely, for the first chunk of work: make the change, commit it, push
it, then run `cc-rc-pr-update` (see below). Only then start verifying.

For a task so small that the whole change *is* the first chunk, still open
the Draft PR before you run tests, not after.

## 3. `cc-rc-pr-update`: creating and updating the PR

Don't hand-craft `gh pr create`/`gh pr edit`/`gh pr comment` calls or PR
markdown yourself. Use the baked-in `cc-rc-pr-update` command instead — it
builds the PR consistently, picks create-vs-edit for you, and keeps the
plan and ledger in one comment rather than duplicating them.

Write three plain-markdown files (e.g. under `/tmp`), then run it:

```sh
cc-rc-pr-update \
  --title "feat(scope): short conventional-commit-style title" \
  --summary-file /tmp/pr-summary.md \
  --plan-file /tmp/pr-plan.md \
  --ledger-file /tmp/pr-ledger.md
```

- `--title`: the PR title. Conventional Commits format, same as commits.
- `--summary-file`: follow this repo's own rules for what a PR
  description/summary should contain, if it defines any — check for a PR
  template (e.g. `.github/PULL_REQUEST_TEMPLATE.md`), contributing docs, or
  an agent skill covering PR summaries, and use that format/content. If the
  repo defines none of these, fall back to 1-3 sentences on what the task
  is and why.
- `--plan-file`: a verbatim copy of the plan you intend to follow (from
  plan mode, or a short step list you write yourself if there was no
  separate planning step).
- `--ledger-file`: the progress ledger (see below). Leave it empty, or use
  a one-line placeholder, for the very first call.
- `--base` (optional): the PR's base branch. Omit it to target the repo's
  default branch. Only a PR in a stack needs it — see section 6.

Any of the three flags accepts `-` to read that section from stdin instead
of a file. Re-running the command regenerates everything from the three
inputs every time — always pass all three, even when only the ledger
changed, so nothing drifts out of the template.

**Where each section lands.** The PR *body* holds the summary only, so the
description stays short and reviewable. The plan and the progress ledger go
in a single **comment** on the PR, headed `🤖 Agent plan & progress ledger`
and tagged with a hidden `<!-- cc-rc-pr-update:plan-and-ledger -->` marker.
The command finds that comment by its marker and rewrites it in place, so
repeat calls update one comment instead of adding new ones. Both sections
inside it render **collapsed** (`<details>`, not `<details open>`) — expand
them only when you actually need the detail. To read the plan or ledger of
a PR you're resuming, look for that heading in the PR's comments.

First call with no PR open yet for this branch creates a **Draft PR** and
its plan/ledger comment. Later calls edit that same PR and comment in
place.

**Writing the section files:** GitHub renders a single `\n` inside a PR/
issue body as a literal line break, not as a space like most Markdown
renderers — so a hard-wrapped paragraph (each sentence or clause on its own
line, as you might write in a text editor) shows up as choppy, broken
lines instead of flowing prose. Write each paragraph in `--summary-file`/
`--plan-file`/`--ledger-file` as a single unwrapped line, and separate
paragraphs only with a blank line. Markdown lists/headings are unaffected —
keep those on their own lines as normal, since that line-per-item structure
is what you want rendered anyway.

## 4. While working

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

## 5. When the plan is complete

1. Verify the work — run tests/build as the repo's own conventions
   require.
2. Do one final `cc-rc-pr-update` call with a ledger summarizing the
   completed state.
3. Mark the PR ready: `cc-rc-pr-update --ready` (reuses the branch's
   existing PR; add `--title`/`--summary-file`/`--plan-file`/
   `--ledger-file` too if you want a final body and comment refresh at the
   same time).

## 6. Dependent PRs: use a GitHub PR stack

Sometimes a task ships as several PRs that depend on each other in order:
each PR builds on the one before it. Split a task this way only when the
user asks for it, or when one PR would be too large to review well. Changes
that don't depend on each other get separate, independent PRs against the
default branch.

When PRs do depend on each other, put them in a native **GitHub PR stack**.
Don't stop at chaining them by base branch. A stack is a first-class GitHub
object: `GET /repos/{owner}/{repo}/stacks/{number}` returns its base, its
`open` state, and the ordered `pull_requests`, and each PR's
`GET /pulls/{n}` carries a `stack` field (`id`, `number`, `base`, `size`,
`position`; `null` for a PR outside a stack).

`gh` has no `stack` subcommand, so use the REST API through `gh api`:

1. Branch each layer from the one below it. The bottom branch comes from
   `origin/<default-branch>` as in section 1; the next comes from the
   bottom branch, and so on. Push each one with `git push -u`.
2. Open each PR with `cc-rc-pr-update`. Omit `--base` for the bottom PR.
   For every PR above it, pass `--base <branch-of-the-PR-below>`. Each PR
   gets its own summary, plan, and ledger.
3. As soon as the bottom two PRs exist, create the stack. List PR numbers
   bottom to top; each PR's base must be the head branch of the PR before
   it:
   ```sh
   gh api -X POST 'repos/{owner}/{repo}/stacks' \
     -F 'pull_requests[]=101' -F 'pull_requests[]=102'
   ```
   The response holds the stack `number`.
4. Add each later PR to the top of the stack. List only the new PRs; the
   first one's base must be the head branch of the current top PR:
   ```sh
   gh api -X POST 'repos/{owner}/{repo}/stacks/<stack-number>/add' \
     -F 'pull_requests[]=103'
   ```
5. Confirm each PR is in the stack:
   `gh api 'repos/{owner}/{repo}/pulls/<n>' -q .stack`. Record the stack
   number and the PR's position in every PR's ledger, so a fresh agent can
   find the rest of the stack.

If a lower PR changes, bring the branches above it up to date (rebase or
merge, then push; `--force-with-lease` is fine on your own task branches).

Errors:

- `404` from the stacks endpoints means stacked PRs aren't enabled for that
  repo. Keep the base-branch chain, say so in each ledger, and tell the
  user.
- `422` means the PRs can't form a valid stack — usually a PR's base isn't
  the head branch of the PR below it. Fix the bases with
  `cc-rc-pr-update --base`, then retry.
