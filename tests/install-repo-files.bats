#!/usr/bin/env bats

# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡
# Tests
# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡

# ============================================================================
# Test Fixtures
# ============================================================================

# ----------------------------------------------------------------------------
# @brief Create isolated fixtures for each test.
setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/install-repo-files.sh"
  target="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$target"
}

# ============================================================================
# Test Cases
# ============================================================================

# ----------------------------------------------------------------------------
# @brief Verify that install generates portable policy and templates.
@test "install generates portable policy and templates" {
  run bash "$SCRIPT" --repo example/project --project 42 --target "$target" --base trunk --owner-type Organization
  [ "$status" -eq 0 ]
  jq -e '.repository=="example/project" and .project_number==42 and .project_owner_type=="Organization" and .base_branch=="trunk"' "$target/.github/work-item-policy.json"
  command grep -q 'branches: \["trunk"\]' "$target/.github/workflows/work-item-review.yml"
  command grep -q 'intake:idea' "$target/.github/ISSUE_TEMPLATE/idea.yml"
}

# ----------------------------------------------------------------------------
# @brief Verify that install refuses overwrite before writing other files.
@test "install refuses overwrite before writing other files" {
  mkdir -p "$target/.github/scripts"
  echo original > "$target/.github/scripts/transition-work-item.sh"
  run bash "$SCRIPT" --repo example/project --project 42 --target "$target"
  [ "$status" -ne 0 ]
  [ "$(cat "$target/.github/scripts/transition-work-item.sh")" = original ]
  [ ! -d "$target/.github/workflows" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that explicit force permits template refresh.
@test "explicit force permits template refresh" {
  bash "$SCRIPT" --repo example/project --project 42 --target "$target"
  run bash "$SCRIPT" --repo example/project --project 42 --target "$target" --force
  [ "$status" -eq 0 ]
}

# ----------------------------------------------------------------------------
# @brief Verify that invalid project number is rejected.
@test "invalid project number is rejected" {
  run bash "$SCRIPT" --repo example/project --project invalid --target "$target"
  [ "$status" -ne 0 ]
  [ ! -d "$target/.github" ]
}
