#!/usr/bin/env bash
set -euo pipefail

# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡
# Configuration
# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
config="$script_dir/../config/kanban.json"
repo=''
project_number=''
title=''
apply=0
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Command Arguments
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2:?}; shift 2 ;;
    --project) project_number=${2:?}; shift 2 ;;
    --create) title=${2:?}; shift 2 ;;
    --config) config=${2:?}; shift 2 ;;
    --apply) apply=1; shift ;;
    *) echo 'Usage: setup-project.sh --repo OWNER/REPO (--project NUMBER | --create TITLE) [--config FILE] [--apply]' >&2; exit 1 ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Expected --repo OWNER/REPO' >&2; exit 1; }
[[ (-n "$project_number" && -z "$title") || (-z "$project_number" && -n "$title") ]] || { echo 'Choose --project or --create' >&2; exit 1; }
[[ -z "$project_number" || "$project_number" =~ ^[1-9][0-9]*$ ]] || exit 1
jq -e '(.issue_types|length)>0 and (.fields|length)>0 and (.views|length)>0' "$config" >/dev/null
owner=${repo%/*}
owner_data=$(gh api "users/$owner")
owner_id=$(jq -er .node_id <<<"$owner_data")
owner_type=$(jq -er .type <<<"$owner_data")
case "$owner_type" in
  User) graphql_owner=user; rest_owner=users ;;
  Organization) graphql_owner=organization; rest_owner=orgs ;;
  *) echo "Unsupported owner type: $owner_type" >&2; exit 1 ;;
esac
repo_id=$(gh api "repos/$repo" --jq .node_id)

# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡
# Implementation
# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# GitHub API Helpers
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# ----------------------------------------------------------------------------
# @brief Execute a GraphQL mutation from a JSON input object.
# @param $1 Mutation text with a variable named input.
# @param $2 JSON object to bind to input.
mutate() {
  jq -nc --arg query "$1" --argjson input "$2" '{query:$query,variables:{input:$input}}' | gh api graphql --input -
}

# ----------------------------------------------------------------------------
# @brief Read project fields and views, refusing truncated inventories.
# @return Nonzero if the project is absent or an inventory exceeds 100 entries.
read_project() {
  project=$(gh api graphql -f query="query(\$owner:String!,\$number:Int!){$graphql_owner(login:\$owner){projectV2(number:\$number){id number url fields(first:100){pageInfo{hasNextPage} nodes{... on ProjectV2FieldCommon{id name databaseId} ... on ProjectV2SingleSelectField{options{id name color description}}}} views(first:100){pageInfo{hasNextPage} nodes{id name layout filter verticalGroupByFields(first:10){nodes{... on ProjectV2FieldCommon{name}}} fields(first:100){nodes{... on ProjectV2FieldCommon{id}}}}}}}}" -f owner="$owner" -F number="$project_number" --jq ".data.$graphql_owner.projectV2")
  jq -e '.id != null and (.fields.pageInfo.hasNextPage|not) and (.views.pageInfo.hasNextPage|not)' <<<"$project" >/dev/null
}

# ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈
# Discovery and Preview
# ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈

if [[ -n "$project_number" ]]; then read_project; fi
types=$(gh api --paginate "repos/$repo/issue-types" --slurp | jq 'add')
if [[ "$apply" == 0 ]]; then
  printf 'Preview only: repository=%s owner-type=%s project=%s\n' "$repo" "$owner_type" "${project_number:-new: $title}"
  jq -r '.issue_types[] | "Ensure issue type: \(.name)"' "$config"
  jq -r '.fields[] | "Ensure field: \(.name) [\(.options|join(", "))]"' "$config"
  jq -r '.views[] | "Ensure board: \(.name); filter=\(.filter); columns=\(.column)"' "$config"
  echo 'Ensure intake, area, type, and status labels. Existing issues remain untouched.'
  echo 'Use --apply to write. Native issue-type creation requires account/organization permissions.'
  exit 0
fi

# ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈
# Configuration Updates
# ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈

# ============================================================================
# Native Issue Types
# ============================================================================

while IFS= read -r spec; do
  name=$(jq -r .name <<<"$spec")
  if ! jq -e --arg name "$name" 'any(.[]; .name == $name)' <<<"$types" >/dev/null; then
    input=$(jq -c --arg owner "$owner_id" '. + {ownerId:$owner,isEnabled:true}' <<<"$spec")
    mutate 'mutation($input:CreateIssueTypeInput!){createIssueType(input:$input){issueType{id name}}}' "$input"
  fi
done < <(jq -c '.issue_types[]' "$config")

# ============================================================================
# Project Creation and Snapshot
# ============================================================================

if [[ -n "$title" ]]; then
  input=$(jq -nc --arg owner "$owner_id" --arg title "$title" --arg repo "$repo_id" '{ownerId:$owner,title:$title,repositoryId:$repo}')
  created=$(mutate 'mutation($input:CreateProjectV2Input!){createProjectV2(input:$input){projectV2{id number url}}}' "$input")
  project_number=$(jq -er .data.createProjectV2.projectV2.number <<<"$created")
  echo "Created project $project_number. Rerun with --project $project_number to resume safely."
  read_project
fi
project_id=$(jq -r .id <<<"$project")
state_dir="$script_dir/../.state/$owner-$project_number"
mkdir -p "$state_dir"
if [[ ! -f "$state_dir/before.json" ]]; then printf '%s\n' "$project" > "$state_dir/before.json"; fi

# ============================================================================
# Project Fields
# ============================================================================

while IFS= read -r spec; do
  name=$(jq -r .name <<<"$spec")
  existing=$(jq -c --arg name "$name" '[.fields.nodes[] | select(.name==$name)] | if length>1 then error("Duplicate field name") else .[0] end' <<<"$project")
  if [[ "$existing" != null ]] && ! jq -e 'has("options")' <<<"$existing" >/dev/null; then
    echo "Existing field '$name' is not single-select; resolve manually" >&2; exit 1
  fi
  options=$(jq -nc --argjson spec "$spec" --argjson existing "$existing" '
    def normalized: if .name=="Todo" and $spec.name=="Status" then .name="To Do" else . end;
    [($existing.options // [])[] | normalized] as $old |
    [$spec.options[] as $name | ($old | map(select(.name==$name)) | .[0]) // {name:$name,color:"GRAY",description:""}] +
    [$old[] | select(.name as $name | $spec.options | index($name) | not)]')
  if [[ "$existing" == null ]]; then
    input=$(jq -nc --arg project "$project_id" --arg name "$name" --argjson options "$options" '{projectId:$project,name:$name,dataType:"SINGLE_SELECT",singleSelectOptions:$options}')
    mutate 'mutation($input:CreateProjectV2FieldInput!){createProjectV2Field(input:$input){projectV2Field{... on ProjectV2FieldCommon{id name}}}}' "$input"
  elif ! jq -e --argjson options "$options" '.options == $options' <<<"$existing" >/dev/null; then
    input=$(jq -nc --arg id "$(jq -r .id <<<"$existing")" --argjson options "$options" '{fieldId:$id,singleSelectOptions:$options}')
    mutate 'mutation($input:UpdateProjectV2FieldInput!){updateProjectV2Field(input:$input){projectV2Field{... on ProjectV2FieldCommon{id name}}}}' "$input"
  fi
done < <(jq -c '.fields[]' "$config")
read_project

# ============================================================================
# Board Views
# ============================================================================

while IFS= read -r spec; do
  name=$(jq -r .name <<<"$spec")
  existing=$(jq -c --arg name "$name" '[.views.nodes[]|select(.name==$name)] | if length>1 then error("Duplicate view name") else .[0] end' <<<"$project")
  column=$(jq -r .column <<<"$spec")
  if [[ "$existing" == null ]]; then
    payload=$(jq -nc --argjson spec "$spec" --argjson project "$project" --slurpfile config "$config" '
      {name:$spec.name,layout:"board",filter:$spec.filter,
       vertical_group_by:[$project.fields.nodes[]|select(.name==$spec.column)|.databaseId],
       visible_fields:[$config[0].card_fields[] as $name|$project.fields.nodes[]|select(.name==$name)|.databaseId]}')
    gh api --method POST "/$rest_owner/$owner/projectsV2/$project_number/views" --input - <<<"$payload" --jq '{name,number,filter}'
  else
    jq -e --arg column "$column" '[.verticalGroupByFields.nodes[].name]==[$column]' <<<"$existing" >/dev/null || {
      echo "Board '$name' uses a different column field. Set it to '$column' in the UI, then rerun." >&2; exit 1;
    }
    visible=$(jq -nc --argjson existing "$existing" --argjson project "$project" --slurpfile config "$config" '([$existing.fields.nodes[].id]+[$config[0].card_fields[] as $name|$project.fields.nodes[]|select(.name==$name)|.id])|unique')
    input=$(jq -nc --argjson existing "$existing" --argjson spec "$spec" --argjson visible "$visible" '{viewId:$existing.id,layout:"BOARD_LAYOUT",filter:$spec.filter,configuration:{visibleFieldIds:$visible}}')
    if ! jq -e --argjson spec "$spec" --argjson visible "$visible" '.layout=="BOARD_LAYOUT" and .filter==$spec.filter and ([.fields.nodes[].id]|sort)==$visible' <<<"$existing" >/dev/null; then
      mutate 'mutation($input:UpdateProjectV2ViewInput!){updateProjectV2View(input:$input){projectV2View{id name}}}' "$input"
    fi
  fi
done < <(jq -c '.views[]' "$config")

# ============================================================================
# Repository Labels
# ============================================================================

labels=$(gh api --paginate "repos/$repo/labels?per_page=100" --slurp | jq 'add | map(.name)')
while IFS= read -r label; do
  if ! jq -e --arg label "$label" 'index($label)!=null' <<<"$labels" >/dev/null; then
    gh api --method POST "repos/$repo/labels" -f name="$label" -f color=1D76DB >/dev/null
  fi
done < <(jq -r '[.intake_labels[],.area_labels[],(.issue_types[]|"type:"+(.name|ascii_downcase)),(.fields[]|select(.name|endswith("Status"))|.options[]|"status:"+(ascii_downcase|gsub(" ";"-")))]|unique[]' "$config")
read_project
printf '%s\n' "$project" > "$state_dir/after.json"
echo "Configured $(jq -r .url <<<"$project")"
