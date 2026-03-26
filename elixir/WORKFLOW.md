---
tracker:
  kind: jira
  base_url: "$JIRA_BASE_URL"
  api_email: "$JIRA_EMAIL"
  api_key: "$JIRA_API_TOKEN"
  project_key: "RDSP"
  active_states:
    - Ready
  terminal_states:
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/.symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
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
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=medium --model gpt-5.3-codex app-server
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

Jira workflow:
- Poll only `Ready` tickets.
- Do not start implementation unless the issue has already been moved to `In Progress`.
- Continue active work only while the live Jira state is `In Progress`.
- If the issue becomes `Code Review`, `Awaiting QA`, `QA`, `Ready for Deployment`, `Blocked`, `Reopened`, or `Done`, stop and do not continue coding.

Jira tool usage:
- Use `jira_issue_update` to refresh the single `## Codex Workpad` comment.
- Use `jira_issue_update` to move the issue to the correct state.
- When the deliverable is complete, validated as far as this environment allows, and the workspace changes are ready, move the issue forward immediately and stop.

Execution flow:
1. Confirm the live Jira state for this ticket.
2. If it is `Ready`, transition it to `In Progress` and confirm the transition before coding.
3. Find or create the `## Codex Workpad` comment and keep it current.
4. Write a short plan, acceptance criteria, and validation checklist in the workpad.
5. Implement the smallest complete change that satisfies the ticket.
6. Run the most direct validation available.
7. Update the workpad with results, changed files, and blockers.
8. Move the issue to the next correct state and stop.

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
- [ ] exact command or proof used

### Notes
- brief progress notes

### Confusions
- only include if something about the task or state mapping was unclear

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
- If work is complete and files changed, update the workpad, move the issue forward, and stop.
- If validation is blocked by missing required tools/auth, move the issue to `Blocked`, explain why in the workpad, and stop.
- Do not keep the issue in `In Progress` just to continue analyzing after the artifact is already done.
