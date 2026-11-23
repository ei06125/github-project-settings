#!/usr/bin/env bash
set -euo pipefail

# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡
# Configuration
# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Project Policy
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
policy=${WORK_ITEM_POLICY:-"$script_dir/../work-item-policy.json"}
repo=$(jq -r .repository "$policy")
owner=${repo%/*}
repo_name=${repo#*/}
project_owner=$(jq -r .project_owner "$policy")
project_number=$(jq -r .project_number "$policy")
owner_type=$(jq -r '.project_owner_type // "User"' "$policy")
case "$owner_type" in
  User) graphql_owner=user ;;
  Organization) graphql_owner=organization ;;
  *) echo 'Invalid project owner type' >&2; exit 1 ;;
esac
base_branch=$(jq -r .base_branch "$policy")
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Command Arguments
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

mode=${1:?Usage: transition-work-item.sh issue NUMBER STATUS | pr NUMBER review\|done}
number=${2:?Missing issue or PR number}
requested=${3:?Missing transition}
[[ "$number" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid number' >&2; exit 1; }

# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡
# Implementation
# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡

# ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈
# Transition Planning
# ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈

# ============================================================================
# Request Validation
# ============================================================================

if [[ "$mode" == pr ]]; then
  pr=$(gh api graphql -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state isDraft merged baseRefName author{login} closingIssuesReferences(first:100){pageInfo{hasNextPage} nodes{number repository{nameWithOwner}}}}}}' -f owner="$owner" -f repo="$repo_name" -F number="$number")
  jq -e --arg base "$base_branch" '.data.repository.pullRequest | .baseRefName == $base and (.closingIssuesReferences.pageInfo.hasNextPage | not)' <<<"$pr" >/dev/null
  case "$requested" in
    review)
      jq -e '.data.repository.pullRequest | .state == "OPEN" and (.isDraft | not)' <<<"$pr" >/dev/null
      author=$(jq -r .data.repository.pullRequest.author.login <<<"$pr")
      gh api "repos/$repo/collaborators/$author/permission" --jq .permission | command grep -Eq '^(admin|write|maintain)$'
      target='In Review'
      ;;
    done)
      jq -e '.data.repository.pullRequest.merged == true' <<<"$pr" >/dev/null
      target=Done
      ;;
    *) echo 'PR transition must be review or done' >&2; exit 1 ;;
  esac
  issues=$(jq -r --arg repo "$repo" '.data.repository.pullRequest.closingIssuesReferences.nodes[] | select(.repository.nameWithOwner == $repo) | .number' <<<"$pr")
elif [[ "$mode" == issue ]]; then
  case "$requested" in
    'To Do'|'In Progress') target=$requested ;;
    *) echo 'Agent transitions are limited to To Do and In Progress' >&2; exit 1 ;;
  esac
  issues=$number
else
  echo 'Mode must be issue or pr' >&2
  exit 1
fi
[[ -n "$issues" ]] || { echo 'No linked issues in the configured repository'; exit 0; }

# ============================================================================
# Project Fields
# ============================================================================

project=$(gh api graphql -f query="query(\$owner:String!,\$number:Int!){$graphql_owner(login:\$owner){projectV2(number:\$number){id fields(first:100){pageInfo{hasNextPage} nodes{... on ProjectV2SingleSelectField{id name options{id name}}}}}}}" -f owner="$project_owner" -F number="$project_number" | jq --arg owner "$graphql_owner" '.data[$owner].projectV2')
jq -e '. | .id != null and (.fields.pageInfo.hasNextPage | not)' <<<"$project" >/dev/null
project_id=$(jq -r .id <<<"$project")
field_id=$(jq -er '.fields.nodes[] | select(.name == "Status") | .id' <<<"$project")
option_id=$(jq -er --arg target "$target" '.fields.nodes[] | select(.name == "Status") | .options[] | select(.name == $target) | .id' <<<"$project")
status_label=$(jq -nr --arg status "$target" '"status:" + ($status | ascii_downcase | gsub(" "; "-"))')
plan='[]'

# ============================================================================
# Issue Validation and Update Plan
# ============================================================================

while IFS= read -r issue_number; do
  issue=$(gh api graphql -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){issue(number:$number){number state issueType{name} labels(first:100){pageInfo{hasNextPage} nodes{name}} projectItems(first:100){pageInfo{hasNextPage} nodes{id project{id} fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}} priority:fieldValueByName(name:"Priority"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}}}' -f owner="$owner" -f repo="$repo_name" -F number="$issue_number")
  jq -e --slurpfile policy "$policy" --arg project "$project_id" --arg target "$target" '
    .data.repository.issue as $i |
    ($i.projectItems.nodes | map(select(.project.id == $project))) as $items |
    ($i != null) and ($i.labels.pageInfo.hasNextPage | not) and
    ($i.projectItems.pageInfo.hasNextPage | not) and
    ($policy[0].types | index($i.issueType.name) != null) and
    ($i.labels.nodes | map(.name) | index("triage") == null) and
    ($items | length == 1) and
    ($target == "Done" or $i.state == "OPEN") and
    ($items[0].priority.name != null) and
    ($items[0].fieldValueByName.name as $current |
      $current == $target or ($policy[0].transitions[$target] | index($current) != null))
  ' <<<"$issue" >/dev/null || { echo "Issue #$issue_number failed type, triage, priority, membership, or transition checks" >&2; exit 1; }
  entry=$(jq -c --arg project "$project_id" --arg status "$status_label" '
    .data.repository.issue | {number, typeLabel:("type:" + (.issueType.name | ascii_downcase)), statusLabel:$status,
      item:(.projectItems.nodes[] | select(.project.id == $project) | .id),
      oldLabels:[.labels.nodes[].name | select(startswith("status:") or startswith("type:"))]}
  ' <<<"$issue")
  plan=$(jq -c --argjson entry "$entry" '. + [$entry]' <<<"$plan")
done <<<"$issues"

# ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈
# Transition Application
# ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈

# ============================================================================
# Preview and Label Preparation
# ============================================================================

jq -r '.[] | "#\(.number): \(.statusLabel), \(.typeLabel)"' <<<"$plan"
[[ ${DRY_RUN:-0} != 1 ]] || exit 0
known_labels=$(gh api --paginate "repos/$repo/labels?per_page=100" --jq '.[].name')
while IFS= read -r label; do
  if ! command grep -Fxq "$label" <<<"$known_labels"; then
    gh api --method POST "repos/$repo/labels" -f name="$label" -f color=1D76DB >/dev/null
  fi
done < <(jq -r '[.[] | .typeLabel,.statusLabel] | unique[]' <<<"$plan")

# ============================================================================
# Project and Label Updates
# ============================================================================

while IFS= read -r entry; do
  item_id=$(jq -r .item <<<"$entry")
  issue_number=$(jq -r .number <<<"$entry")
  gh api graphql -f query='mutation($project:ID!,$item:ID!,$field:ID!,$option:String!){updateProjectV2ItemFieldValue(input:{projectId:$project,itemId:$item,fieldId:$field,value:{singleSelectOptionId:$option}}){projectV2Item{id}}}' -f project="$project_id" -f item="$item_id" -f field="$field_id" -f option="$option_id" >/dev/null
  jq '{labels:[.typeLabel,.statusLabel]}' <<<"$entry" | gh api --method POST "repos/$repo/issues/$issue_number/labels" --input - >/dev/null
  while IFS= read -r stale_label; do
    [[ -n "$stale_label" ]] || continue
    encoded=$(jq -nr --arg label "$stale_label" '$label | @uri')
    gh api --method DELETE "repos/$repo/issues/$issue_number/labels/$encoded" >/dev/null
  done < <(jq -r '. as $item | .oldLabels[] | select(. != $item.typeLabel and . != $item.statusLabel)' <<<"$entry")
done < <(jq -c '.[]' <<<"$plan")
