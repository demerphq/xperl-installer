# agent-comms

This orphan branch is a coordination channel for the humans and agents
working on XPerl. It shares no history with `main` and holds no code.

`MESSAGES.md` is an **append-only** log. Agents post status updates,
claims, questions and hand-offs by appending one entry and pushing one
commit. Everyone else picks the entries up with `git fetch`.

## Rules

1. Only append to the end of `MESSAGES.md`. Never edit, reorder or delete an
   existing entry, even your own. To correct or retract an entry, append a
   new one that names it in `re:`.
2. Make one commit for each entry. The commit subject is
   `<kind>: <summary>`, for example `status: install-ported run 2 finished`.
   Use `git-compose-commit` as the workspace `AGENTS.md` requires.
3. Never force-push, rewrite or merge this branch. Rebase onto the remote
   branch and push a fast-forward. `.gitattributes` sets `merge=union` on
   `MESSAGES.md`, so two people who append at the same time get a rebase
   with no conflict.
4. Don't post secrets, credentials or private host details. Link to
   receipts, PRs and commits instead of pasting large logs.
5. Only `README.md` (this protocol) and the tools in `bin/` may be edited,
   and only after agreement. Announce the change in `MESSAGES.md`.

## Entry format

Each entry is a level-2 heading followed by fields, a blank line, and a
free-form body:

```markdown
## 2026-11-06T15:04:12Z atomicstack/claude

- kind: status
- to: all
- re: 2026-11-06T14:58:40Z demerphq/codex

Body text in Markdown. Keep it short and concrete.
```

- **Heading**: a UTC timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`) and
  `<human>/<agent>`. Together they form the entry's id, and other entries
  use that id in `re:`.
- **kind**: one of `status`, `claim`, `release`, `question`, `answer`,
  `handoff`, `blocker`, `note`.
  - `claim` / `release`: take or drop ownership of a module, file or
    task so parallel work doesn't collide.
  - `handoff`: work another person should pick up, with enough context
    to continue.
  - `blocker`: something that stops progress and needs a human.
- **to**: `all` or a comma-separated list of `<human>` / `<human>/<agent>`.
- **re**: optional. The id of the entry this one replies to or corrects.

## Setup

Use a dedicated worktree so the branch never disturbs anyone's checkout:

```sh
git fetch origin agent-comms
git worktree add .worktrees/agent-comms agent-comms   # tracks origin/agent-comms
```

## Tools

Two bash (4+) scripts in `bin/` handle posting and watching. Run them from
any checkout of the repository, e.g. `.worktrees/agent-comms/bin/comms-unread`.
Both take `--help`.

**`bin/comms-unread --reader ID`** prints the entries this reader has not
seen, then records how far it has read. It exits 0 when there's news and 1
when there isn't.

```sh
bin/comms-unread --reader atomicstack/claude --ignore-from atomicstack/claude
bin/comms-unread --reader atomicstack/claude --wait 0 --interval 60   # block until news
```

- Give each agent its own `--reader` name. Cursors live in the clone at
  `refs/agent-comms/seen/<reader>`, so agents sharing a clone would
  otherwise consume each other's news.
- `--wait SECS` fetches every `--interval` seconds until there's news, then
  prints it and exits; `0` waits forever. Run it as a background command
  and react when it exits: this works with any agent's scheduler.
- `--ignore-from ID` (repeatable) hides entries by that poster, e.g. your
  own.

**`bin/comms-post --from ID --kind KIND [--to WHO] [--re ENTRY-ID] BODY`**
appends a correctly formatted entry and commits it with
`git-compose-commit`. It pushes, and if someone else posted first it
rebases and retries. Before each push it checks that every unpushed commit
only appends one entry to `MESSAGES.md`. The body comes from the arguments
or stdin; pass `--trailer` for commit trailers such as `Co-Authored-By`.

```sh
bin/comms-post --from atomicstack/claude --kind claim --to demerphq \
  -- 'Claiming Foo::Bar on branch atomicstack/foo-bar.'
```

The rest of this file describes doing the same by hand.

## Posting

```sh
cd .worktrees/agent-comms
git pull --rebase origin agent-comms
cat >> MESSAGES.md <<'EOF'

## 2026-11-06T15:04:12Z atomicstack/claude

- kind: status
- to: all

install-ported run 2 finished: 41 pass, 3 fail. receipts in ...
EOF
git add MESSAGES.md
git-compose-commit --subject 'status: install-ported run 2 finished' --text '...'
git push origin agent-comms || { git pull --rebase origin agent-comms && git push origin agent-comms; }
```

## Monitoring

Run `git fetch` regularly, then read only what you haven't seen. A local,
never-pushed ref records how far you've read:

```sh
git fetch origin agent-comms
seen=$(git rev-parse -q --verify refs/agent-comms/seen) || seen=$(git hash-object -t tree /dev/null)
git diff "$seen" origin/agent-comms -- MESSAGES.md   # new entries only
git update-ref refs/agent-comms/seen origin/agent-comms
```

`git log --reverse -p <seen>..origin/agent-comms` shows the same entries
grouped by commit and author.

To confirm the log really is append-only, check that no commit deleted or
changed an existing line:

```sh
git log --format=%h --numstat origin/agent-comms -- MESSAGES.md | awk 'NF == 3 && $2 != 0'   # must print nothing
```
