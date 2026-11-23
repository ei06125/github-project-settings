# GitHub Project Settings

Reproduce the Jira-style Kanban configuration and deterministic work-item automation developed for `ei06125/claude-settings` project 12. Supports personal and organization-owned Projects through the GitHub API.

## What this configures

| Board | Issue types | Columns |
| --- | --- | --- |
| All work | All project items | Backlog → To Do → In Progress → In Review → Done |
| Themes | Theme | Proposed → Strategy Review → Approved → Active → Outcome Review → Closed |
| Initiatives | Initiative | Backlog → Business Case → Approved → In Progress → Benefits Validation → Done |
| Epics | Epic | Backlog → In Progress → Ready for Release → Released |
| Work | Bug, Story, Task | Backlog → To Do → In Progress → In Review → Done |

SubTask is an issue type with its own To Do / In Progress / Done field, but has no dedicated board. Priority is a single-select project field: **P0 - Critical, P1 - High, P2 - Medium, P3 - Low**. It is visible on the boards; no priority is assigned automatically.

Native issue types are account/organization-wide. Workflow status and priority fields are project-specific. Boards filter by native type; labels mirror types and states for repository searches. The All work board displays the delivery Status field, not a normalized rollup of the leadership status fields.

The source of truth is [config/kanban.json](config/kanban.json). Copy it and pass `--config` to both commands to customize it. The setup never fabricates or reclassifies issues and never creates Theme/Epic/Initiative tickets merely to populate empty boards.

## Prerequisites and authentication

- Bash or Zsh, GitHub CLI (`gh`), and `jq`.
- Authenticate with `gh auth login`, or supply `GH_TOKEN` through your environment.
- Access to the target repository and permission to administer the project and owner-level issue types.
- For a personal account using a classic token: `repo` for a private repository, `project` for project writes, and `user` for creating personal issue types. Organization issue-type creation requires appropriate organization permissions (`admin:org` for classic tokens).

The original CLI session could edit Projects but could not create personal issue types because it lacked the `user` scope. If your token has the same restriction, create the missing types at <https://github.com/settings/issue-types> first, then rerun. Existing types are reused. Do not paste tokens into configuration, issue bodies, or command arguments saved in shell history.

## Set up a project

Run from this repository. Replace the example values with the target repository and project number.

```bash
repo='ei06125/claude-settings'
project=12

# Read-only preview: shows the desired configuration, not an exact change diff.
bash scripts/setup-project.sh --repo "$repo" --project "$project"

# Apply the configuration to an existing project.
bash scripts/setup-project.sh --repo "$repo" --project "$project" --apply

# Alternatively, create a new project under the repository owner.
bash scripts/setup-project.sh --repo "$repo" --create 'Engineering Work' --apply
```

Record the new project number printed by `--create`. Subsequent runs must use `--project NUMBER`; invoking `--create` again creates another project.

Apply creates missing issue types, single-select fields, boards, and labels. Existing desired types are preserved. Existing single-select option IDs are retained, `Todo` is normalized to `To Do`, and extra options are retained rather than deleted. Existing same-named views have their layout, filter, and visible card fields reconciled; other views remain untouched. If a same-named view uses the wrong column field, the command stops and asks you to select the configured field in GitHub's view settings before rerunning. No issues, views, labels, or field options are deleted.

The first project snapshot is saved to ignored `.state/OWNER-NUMBER/before.json`; each successful run writes `after.json`. These snapshots are reference material, not an automatic rollback mechanism. Operations are not transactional. If a command fails, inspect its output and rerun with the existing project number after resolving the problem. Inventories beyond the supported query bounds fail rather than being silently truncated.

GitHub may create a default view when a project is created. The setup preserves it; rename or remove it manually if it is redundant. To reproduce the original project exactly, keep only the five configured views. Creating boards through the API does not configure GitHub's built-in project workflows or WIP limits; review those under project settings yourself.

## Install the repository automation

Install into a local checkout of the repository whose issues and PRs will be managed:

```bash
repo='ei06125/claude-settings'
project=12
target='../claude-settings'

bash scripts/install-repo-files.sh \
  --repo "$repo" --project "$project" --target "$target" --base main
```

Use `--owner-type Organization` for an organization project. `--base` must be the target repository's default branch, because GitHub closing references and the trusted workflow checkout use that branch. Existing target files cause a refusal before any files are written; review them before deliberately using `--force`.

The installer copies intake forms, the transition script, and three workflows into `.github/`, and generates `.github/work-item-policy.json`. It does not modify AGENTS.md, commit, push, create a PR, grant permissions, or configure secrets. Review and submit those changes using the target repository's normal process.

Then create an Actions repository secret named **WORK_ITEMS_TOKEN** with issue-write and project-write access. For the personal private-repository setup, a classic token with `repo` and `project` is the supported baseline; the runtime does not create issue types and does not need `user`. Add the secret through GitHub's Actions secrets UI or `gh secret set WORK_ITEMS_TOKEN --repo "$repo"` (interactive input). The standard Actions `GITHUB_TOKEN` alone cannot access account-level Projects.

Activate by merging the files into the default branch. If your integration branch is `dev`, merging there alone does not activate this setup. Review branch protection and required checks separately; these scripts do not grant or change repository access.

## Intake, triage, and delivery

1. Create an Idea, Feature request, Bug report, or Automation opportunity. The forms apply `intake:*` plus `triage`, without setting a native work type. Agents creating issues through the CLI must apply these labels explicitly; forms are not executed by `gh issue create`.
2. Triage duplicates, scope, acceptance criteria, dependencies, and priority. Assign a native Story/Bug/Task type, or deliberately create a strategic Theme. Initiatives and Epics are intentional umbrella items, not automatic intake categories.
3. Add the issue to the project and link Parent issue / sub-issues and dependencies. Keep the original issue number unless splitting independently deliverable work. GitHub does not enforce the Theme → Initiative → Epic → Story/Bug/Task → SubTask type hierarchy.
4. Set the appropriate status to Backlog (or the first leadership status), mirror `type:*` and `status:*` labels, and remove `triage` after specification is ready. This triage step is manual/agent-led; the setup does not infer it.
5. Agents request To Do or In Progress through the dispatch workflow. Check completion, not just dispatch acceptance:

```bash
gh workflow run work-item-transition.yml --repo "$repo" \
  -f issue=123 -f status='To Do'
gh run list --repo "$repo" --workflow work-item-transition.yml
```

6. A non-draft PR from a collaborator with write access, explicitly linked with `Closes #123`, moves eligible work to In Review. A merge into the default branch moves it to Done. Unmerged closure and draft PRs do not complete work.

The runtime checks fresh PR state, project membership, native type, absence of `triage`, priority, and allowed transitions before writes. It manages Story/Bug/Task only; leadership and SubTask transitions remain manual. All target issues are checked before mutation. Each transition leaves one `type:*` and one `status:*` label and preserves unrelated labels. The workflows share a bounded queue, never execute PR branch code, and support reruns to repair partial status/label updates.

Manual board dragging and native type edits are not automatically mirrored to labels by these three workflows. Scheduled reconciliation is a separate follow-up. Likewise, automation does not verify acceptance prose or tests itself; review and required CI checks remain responsible for whether a merge is appropriate. GitHub's built-in issue-close workflow can independently change Status, so review or disable conflicting built-in rules when adopting the guarded path.

For local read-only validation in the installed repository:

```bash
DRY_RUN=1 bash .github/scripts/transition-work-item.sh issue 123 'To Do'
```

Area labels are Quality, Engineering, Security, Privacy, Finance, and Legal. Themes should express measurable objectives, such as “Reduce agent operating costs,” rather than merely copying a domain name.

## Comments and banners

Use `≡` → `≈` → `=` → `~` → `-`, from outermost section to function documentation. Banner lines end at column 78, including indentation and comment delimiters, counting Unicode characters. Titles sit between matching banners. Omit unnecessary levels. Document every function; dashed banners remain outside functions. Python/Starlark docstrings stay inside without banners. No banners inside function bodies, and no comments in JSON.

The formatter/checker is tracked in [claude-settings issue #26](https://github.com/ei06125/claude-settings/issues/26). The original implementation is [PR #25](https://github.com/ei06125/claude-settings/pull/25).

## Validation

Install `pre-commit` and run `pre-commit install` in every checkout. Hooks include Gitleaks (default rules), detect-secrets, private-key detection, JSON/YAML validation, conflict markers, whitespace, and file-size checks. `.secrets.baseline` is generated specifically for this repository; review any new finding before changing it. Never refresh a baseline just to silence a real credential. The baseline contains hashes and scanner metadata, not permission to commit secrets.

```bash
pre-commit install
pre-commit run --all-files
bats tests
shellcheck --exclude=SC2016 scripts/*.sh templates/scripts/*.sh
```

The repository's validation workflow runs these checks on pushes and pull requests without project credentials. Configure it as a required branch-protection check if you want merges to depend on it. Installing these hooks does not install hooks into target repositories; target repositories retain their own secret-scanning policy.

Tests mock GitHub; they do not create or change remote resources. `SC2016` is excluded because GraphQL and jq variables intentionally remain literal in single-quoted strings.

## References

- [GitHub: managing issue types](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/managing-issue-types)
- [GitHub: personal-account issue types and fields](https://github.blog/changelog/2026-11-11-issue-types-and-fields-are-available-for-personal-accounts/)
- [GitHub: Projects API](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects)
- [GitHub: project views API](https://docs.github.com/en/rest/projects/views)
- [GitHub: workflow automation](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/automating-projects-using-actions)
- [Atlassian: hierarchy](https://support.atlassian.com/jira-cloud-administration/docs/configure-the-issue-type-hierarchy/)
- [Atlassian: workflows](https://support.atlassian.com/jira-software-cloud/docs/what-are-jira-workflows/)
