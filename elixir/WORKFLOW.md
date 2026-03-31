---
tracker:
  kind: jira
  base_url: "$JIRA_BASE_URL"
  api_email: "$JIRA_EMAIL"
  api_key: "$JIRA_API_TOKEN"
  project_key: "RDSP"
  dispatch_states:
    - Ready
  active_states:
    - Ready
    - In Progress
  terminal_states:
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/.symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 "${SOURCE_REPO_URL:-https://github.com/Stiward3/symphony.git}" .
    git checkout -B "codex/$(basename "$PWD")"
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise exec -- mix workspace.before_remove
    fi
agent:
  max_concurrent_agents: 3
  max_turns: 8
  stop_issue_state_on_error: Blocked
codex:
  command: bash -lc 'source ~/.profile >/dev/null 2>&1 || true; codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=medium --model gpt-5.3-codex app-server'
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
server:
  port: 4000
---

You are working on Jira issue `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:
- Retry/continuation attempt #{{ attempt }}.
- Resume from the current workspace state.
- Do not restart finished work.
{% endif %}

Issue context:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Current status: {{ issue.state }}
- Labels: {{ issue.labels }}
- URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Rules:
1. Work only inside the provided repository copy.
2. Never ask a human to take follow-up actions.
3. If a required Jira update or other required external action fails, stop immediately and treat it as a blocker.
4. Keep one persistent Jira comment headed `## Codex Workpad`. Update it in place; do not create separate summary comments.
5. For small concrete tasks, prefer one decisive implementation pass over long reasoning loops.
6. If the requested artifact already exists and validates, update Jira and stop.

GitHub delivery:
- Use the repository's existing Git history when available.
- If `GITHUB_REPO_OWNER` is configured, prefer creating or reusing a dedicated GitHub repo for this ticket and deliver there instead of opening a PR inside the source clone remote.
- If `GITHUB_REPO_OWNER` is not configured and a writable GitHub `origin` remote already exists, commit the finished work, push a branch, and create or update a PR before moving Jira to `Code Review`.
- Derive new repo names from the Jira identifier plus a short slug from the title. If `GITHUB_REPO_PREFIX` is set, prefix the repo name with it.
- Use `GITHUB_REPO_VISIBILITY` when set; otherwise default new repos to `private`.
- When creating a dedicated repo, pass `repoOwner`, `repoName`, and optional `repoVisibility` to `github_delivery` so delivery goes to that new repository instead of the source clone remote.
- Prefer the host-side `github_delivery` dynamic tool for commit, push, and PR creation or update whenever it is available.
- Use GitHub CLI commands (`gh repo create`, `gh pr create`, `gh pr edit`, `gh auth status`) directly only when the task truly needs something the dynamic tool does not cover.
- This Codex sandbox does not reliably inherit your interactive shell `PATH`, so shell-based GitHub delivery is not the default path here.
- For Elixir commands, prefer `bash -lc 'source ~/.profile >/dev/null 2>&1 || true; cd elixir && mise exec -- mix ...'`.
- For GitHub CLI commands, prefer `bash -lc 'source ~/.profile >/dev/null 2>&1 || true; gh ...'`.
- If GitHub auth, push access, or PR creation fails, record the exact blocker in the workpad and move Jira to `Blocked`.

Jira workflow:
- Poll `Ready` and `In Progress` tickets so active work stays visible.
- Dispatch new work only from `Ready`.
- Do not start implementation unless the issue has already been moved to `In Progress`.
- Continue active work only while the live Jira state is `In Progress`.
- If the issue becomes `Code Review`, `Awaiting QA`, `QA`, `Ready for Deployment`, `Blocked`, `Reopened`, or `Done`, stop and do not continue coding.

Jira tool usage:
- Use `jira_issue_update` to refresh the single `## Codex Workpad` comment.
- Use `jira_issue_update` to move the issue to the correct state.
- Use `github_delivery` for required host-side commit, push, and PR delivery.
- When `GITHUB_REPO_OWNER` is configured, call `github_delivery` with dedicated repo arguments by default so each ticket lands in its own repository.
- When the deliverable is complete, validated as far as this environment allows, and the workspace changes are ready, complete GitHub delivery first, then move the issue forward and stop.

Execution flow:
1. Confirm the live Jira state for this ticket.
2. If it is `Ready`, transition it to `In Progress` and confirm the transition before coding.
3. Find or create the `## Codex Workpad` comment and keep it current.
4. Write a short plan, acceptance criteria, and validation checklist in the workpad.
5. Implement the smallest complete change that satisfies the ticket.
6. Run the most direct validation available.
7. Commit the finished work, push it to GitHub, and create or update the PR when GitHub delivery is expected for this repo.
8. Update the workpad with results, changed files, GitHub delivery details, environment limits, and blockers.
9. Move the issue to the next correct state and stop.

Command guidance:
- Prefer the host-side `github_delivery` dynamic tool over sandbox `git` + `gh` commands for normal Jira ticket delivery.
- When running `mix`, `make`, `gh`, or other tools that may come from profile-loaded paths, do not call them bare.
- Use wrappers like `bash -lc 'source ~/.profile >/dev/null 2>&1 || true; cd elixir && mise exec -- mix test test/symphony_elixir/jira_mock_fixture_test.exs'`.
- Use wrappers like `bash -lc 'source ~/.profile >/dev/null 2>&1 || true; gh auth status'`.
- Use wrappers like `bash -lc 'source ~/.profile >/dev/null 2>&1 || true; make -C elixir all'`.

Workpad shape:

## Codex Workpad

```text
<host>:<abs-workdir>@<short-sha>
```

### Plan
- [ ] concise task steps

### Acceptance Criteria
- [ ] deliverable exists
- [ ] validation evidence recorded

### Validation
- [ ] short evidence statements with outcomes
- [ ] if a stronger validation could not run, say exactly why in plain English

### Notes
- brief progress notes
- include branch URL, repo URL, and PR URL when GitHub delivery succeeds

### Confusions
- include only for unresolved questions, state-mapping mismatches, or blockers
- do not include this section for normal environment limitations; put those in `Validation` or `Notes` instead

State guidance:
- `Ready`: transition to `In Progress`, confirm it, then work.
- `In Progress`: implement and validate.
- `Code Review`: stop coding.
- `Awaiting QA`: stop coding.
- `QA`: stop coding.
- `Ready for Deployment`: stop coding.
- `Blocked`: record blocker in the workpad and stop.
- `Reopened`: wait for re-triage into `Ready` or `In Progress`.
- `Done`: do nothing.

Completion guidance:
- If work is complete and files changed, deliver it to GitHub, update the workpad, move the issue forward, and stop.
- If direct validation succeeded but stronger environment-specific checks are unavailable in the Codex sandbox, record that gap clearly and continue unless delivery itself is blocked.
- If GitHub delivery is required but blocked by missing `gh` auth, missing push access, or repo creation failure, move the issue to `Blocked`, explain why in the workpad, and stop.
- Do not keep the issue in `In Progress` just to continue analyzing after the artifact is already done.

Workpad writing guidance:
- Write for a human teammate reading Jira quickly.
- In `Validation`, prefer lines like `Passed: python3 parsed ...` or `Not run: mix test ... because mix is unavailable in this environment`.
- In `Notes`, summarize what was found or changed, not raw thought process.
- In `Notes`, include concise GitHub delivery evidence such as `Branch URL: ...`, `Repo: ...`, and `PR: ...`.
- Only add `Confusions` when something remains unresolved after the work is complete enough to hand off or block.
- If a wrapped `bash -lc 'source ~/.profile ...'` command still fails, record that exact wrapped command and its stderr in `Validation` or `Confusions`.
