#!/usr/bin/env bats

# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡
# Tests
# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡

# ============================================================================
# Test Fixtures
# ============================================================================

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Fixture Lifecycle
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# ----------------------------------------------------------------------------
# @brief Prepare an isolated mock GitHub CLI and issue/project fixtures.
# @details Exports SCRIPT, FIXTURES, and PATH for each test.
setup() {
  export SCRIPT="$BATS_TEST_DIRNAME/../templates/scripts/transition-work-item.sh"
  export FIXTURES="$BATS_TEST_TMPDIR"
  export PATH="$FIXTURES/bin:$PATH"
  mkdir -p "$FIXTURES/bin"
  export WORK_ITEM_POLICY="$FIXTURES/policy.json"
  jq --arg repo "example/project" '{repository:$repo,project_owner:"example",project_number:12,base_branch:"main",types:.delivery_types,transitions}' "$BATS_TEST_DIRNAME/../config/kanban.json" > "$WORK_ITEM_POLICY"
  cat > "$FIXTURES/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURES/calls"
case "$*" in
  *'query('*'pullRequest(number:'*) cat "$FIXTURES/pr" ;;
  *'query('*'projectV2(number:'*) cat "$FIXTURES/project" ;;
  *'query('*'issue(number:'*) cat "$FIXTURES/issue" ;;
  *'/permission'*) echo "${MOCK_PERMISSION:-write}" ;;
  *'--paginate'*) printf '%s\n' 'type:story' 'status:in-review' 'status:done' 'status:to-do' 'status:in-progress' ;;
  *'mutation('*|*'--method'*)
    printf '%s\n' "$*" >> "$FIXTURES/writes"
    if [[ "$*" == *'--input -'* ]]; then cat >> "$FIXTURES/writes"; fi
    echo '{}'
    ;;
  *) echo "Unexpected call: $*" >&2; exit 1 ;;
esac
MOCK
  chmod +x "$FIXTURES/bin/gh"
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"state":"OPEN","isDraft":false,"merged":false,"baseRefName":"main","author":{"login":"maintainer"},"closingIssuesReferences":{"pageInfo":{"hasNextPage":false},"nodes":[{"number":1,"repository":{"nameWithOwner":"example/project"}}]}}}}}' > "$FIXTURES/pr"
  printf '%s\n' '{"data":{"user":{"projectV2":{"id":"PROJECT","fields":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"STATUS","name":"Status","options":[{"id":"TODO","name":"To Do"},{"id":"DOING","name":"In Progress"},{"id":"REVIEW","name":"In Review"},{"id":"DONE","name":"Done"}]}]}}}}}' > "$FIXTURES/project"
  printf '%s\n' '{"data":{"repository":{"issue":{"number":1,"state":"OPEN","issueType":{"name":"Story"},"labels":{"pageInfo":{"hasNextPage":false},"nodes":[{"name":"status:in-progress"},{"name":"type:task"},{"name":"intake:feature"}]},"projectItems":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"ITEM","project":{"id":"PROJECT"},"fieldValueByName":{"name":"In Progress"},"priority":{"name":"P2 - Medium"}}]}}}}}' > "$FIXTURES/issue"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Fixture Helpers
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# ----------------------------------------------------------------------------
# @brief Update a fixture with a jq expression.
# @param $1 Fixture filename within the test directory.
# @param $2 jq expression applied to the fixture.
# @return Nonzero if the fixture update fails.
change_fixture() {
  jq "$2" "$FIXTURES/$1" > "$FIXTURES/changed"
  mv "$FIXTURES/changed" "$FIXTURES/$1"
}

# ============================================================================
# Test Cases
# ============================================================================

# ----------------------------------------------------------------------------
# @brief Verify that review moves project and replaces only type/status labels.
@test "review moves project and replaces only type/status labels" {
  run bash "$SCRIPT" pr 10 review
  [ "$status" -eq 0 ]
  command grep -q 'option=REVIEW' "$FIXTURES/writes"
  command grep -q 'status%3Ain-progress' "$FIXTURES/writes"
  command grep -q 'type%3Atask' "$FIXTURES/writes"
  ! command grep -q 'intake' "$FIXTURES/writes"
}

# ----------------------------------------------------------------------------
# @brief Verify that draft PR cannot change issues.
@test "draft PR cannot change issues" {
  change_fixture pr '.data.repository.pullRequest.isDraft = true'
  run bash "$SCRIPT" pr 10 review
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that unmerged PR cannot complete work.
@test "unmerged PR cannot complete work" {
  run bash "$SCRIPT" pr 10 done
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that merge completes an already auto-closed issue.
@test "merge completes an already auto-closed issue" {
  change_fixture pr '.data.repository.pullRequest |= (.merged=true | .state="MERGED")'
  change_fixture issue '.data.repository.issue.state="CLOSED"'
  run bash "$SCRIPT" pr 10 done
  [ "$status" -eq 0 ]
  command grep -q 'option=DONE' "$FIXTURES/writes"
}

# ----------------------------------------------------------------------------
# @brief Verify that triage issues cannot enter delivery.
@test "triage issues cannot enter delivery" {
  change_fixture issue '.data.repository.issue.labels.nodes += [{"name":"triage"}]'
  run bash "$SCRIPT" pr 10 review
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that priority is required.
@test "priority is required" {
  change_fixture issue '.data.repository.issue.projectItems.nodes[0].priority=null'
  run bash "$SCRIPT" pr 10 review
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that umbrella issue types cannot be completed by a PR.
@test "umbrella issue types cannot be completed by a PR" {
  change_fixture issue '.data.repository.issue.issueType.name="Epic"'
  run bash "$SCRIPT" pr 10 review
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that cross-repository closing links are ignored.
@test "cross-repository closing links are ignored" {
  change_fixture pr '.data.repository.pullRequest.closingIssuesReferences.nodes[0].repository.nameWithOwner="elsewhere/repo"'
  run bash "$SCRIPT" pr 10 review
  [ "$status" -eq 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that agent cannot bypass the merge guard.
@test "agent cannot bypass the merge guard" {
  run bash "$SCRIPT" issue 1 Done
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that agent can promote prioritized backlog without a model.
@test "agent can promote prioritized backlog without a model" {
  change_fixture issue '.data.repository.issue.projectItems.nodes[0].fieldValueByName.name="Backlog"'
  run bash "$SCRIPT" issue 1 'To Do'
  [ "$status" -eq 0 ]
  command grep -q 'option=TODO' "$FIXTURES/writes"
}

# ----------------------------------------------------------------------------
# @brief Verify that dry run validates without writes.
@test "dry run validates without writes" {
  run env DRY_RUN=1 bash "$SCRIPT" pr 10 review
  [ "$status" -eq 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that rerun repairs labels without requiring a new transition.
@test "rerun repairs labels without requiring a new transition" {
  change_fixture issue '.data.repository.issue.projectItems.nodes[0].fieldValueByName.name="In Review"'
  run bash "$SCRIPT" pr 10 review
  [ "$status" -eq 0 ]
  command grep -q 'status%3Ain-progress' "$FIXTURES/writes"
}

# ----------------------------------------------------------------------------
# @brief Verify that outside contributor cannot move work into review.
@test "outside contributor cannot move work into review" {
  run env MOCK_PERMISSION=read bash "$SCRIPT" pr 10 review
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that wrong base branch cannot trigger transitions.
@test "wrong base branch cannot trigger transitions" {
  change_fixture pr '.data.repository.pullRequest.baseRefName="dev"'
  run bash "$SCRIPT" pr 10 review
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that issue outside project cannot be changed.
@test "issue outside project cannot be changed" {
  change_fixture issue '.data.repository.issue.projectItems.nodes[0].project.id="OTHER"'
  run bash "$SCRIPT" pr 10 review
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that backlog cannot skip directly to review.
@test "backlog cannot skip directly to review" {
  change_fixture issue '.data.repository.issue.projectItems.nodes[0].fieldValueByName.name="Backlog"'
  run bash "$SCRIPT" pr 10 review
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that completed work cannot regress on a stale PR event.
@test "completed work cannot regress on a stale PR event" {
  change_fixture issue '.data.repository.issue.projectItems.nodes[0].fieldValueByName.name="Done"'
  run bash "$SCRIPT" pr 10 review
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that truncated closing references fail before writes.
@test "truncated closing references fail before writes" {
  change_fixture pr '.data.repository.pullRequest.closingIssuesReferences.pageInfo.hasNextPage=true'
  run bash "$SCRIPT" pr 10 review
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURES/writes" ]
}
