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
  export SCRIPT="$BATS_TEST_DIRNAME/../scripts/setup-project.sh"
  export FIXTURES="$BATS_TEST_TMPDIR"
  export PATH="$FIXTURES/bin:$PATH"
  mkdir -p "$FIXTURES/bin"
  config="$BATS_TEST_DIRNAME/../config/kanban.json"
  jq '[.issue_types|map({name})]' "$config" > "$FIXTURES/types"
  jq '[([.intake_labels[],.area_labels[],(.issue_types[]|"type:"+(.name|ascii_downcase)),(.fields[]|select(.name|endswith("Status"))|.options[]|"status:"+(ascii_downcase|gsub(" ";"-")))]|unique|map({name:.}))]' "$config" > "$FIXTURES/labels"
  jq '
    . as $c |
    ([.fields | to_entries[] | {id:("F"+(.key|tostring)),databaseId:(100+.key),name:.value.name,options:[.value.options[]|{id:.,name:.,color:"GRAY",description:""}]}] +
     [{id:"TITLE",databaseId:1,name:"Title"},{id:"ASSIGNEES",databaseId:2,name:"Assignees"},{id:"PARENT",databaseId:3,name:"Parent issue"},{id:"PROGRESS",databaseId:4,name:"Sub-issues progress"}]) as $fields |
    {id:"PROJECT",number:12,url:"https://example.invalid/project",fields:{pageInfo:{hasNextPage:false},nodes:$fields},
     views:{pageInfo:{hasNextPage:false},nodes:[$c.views[]|{id:.name,name,layout:"BOARD_LAYOUT",filter,verticalGroupByFields:{nodes:[{name:.column}]},fields:{nodes:[$c.card_fields[] as $name|$fields[]|select(.name==$name)|{id}]}}]}}
  ' "$config" > "$FIXTURES/project"
  cat > "$FIXTURES/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *'--method'*|*'--input -'*)
    echo "$*" >> "$FIXTURES/writes"
    [[ ${MOCK_WRITES:-0} == 1 ]] || { echo 'Unexpected mutation' >&2; exit 1; }
    if [[ "$*" == *'--input -'* ]]; then payload=$(cat); else payload='{}'; fi
    if [[ "$*" == *'graphql'* ]]; then
      query=$(jq -r .query <<<"$payload")
      input=$(jq -c .variables.input <<<"$payload")
      case "$query" in
        *'createIssueType'*)
          jq --argjson input "$input" '.[0] += [{name:$input.name}]' "$FIXTURES/types" > "$FIXTURES/changed"
          mv "$FIXTURES/changed" "$FIXTURES/types"
          ;;
        *'createProjectV2Field'*)
          jq --argjson input "$input" '.fields.nodes += [{id:$input.name,databaseId:(200+(.fields.nodes|length)),name:$input.name,options:[$input.singleSelectOptions[]|. + {id:.name}]}]' "$FIXTURES/project" > "$FIXTURES/changed"
          mv "$FIXTURES/changed" "$FIXTURES/project"
          ;;
        *'updateProjectV2Field'*)
          jq --argjson input "$input" '(.fields.nodes[]|select(.id==$input.fieldId)|.options) = $input.singleSelectOptions' "$FIXTURES/project" > "$FIXTURES/changed"
          mv "$FIXTURES/changed" "$FIXTURES/project"
          ;;
        *) echo "Unexpected mutation $query" >&2; exit 1 ;;
      esac
    elif [[ "$*" == *'/views'* ]]; then
      jq --argjson input "$payload" '.fields.nodes as $fields | .views.nodes += [{id:$input.name,name:$input.name,layout:"BOARD_LAYOUT",filter:$input.filter,verticalGroupByFields:{nodes:[$fields[]|select(.databaseId==$input.vertical_group_by[0])|{name}]},fields:{nodes:[$input.visible_fields[] as $id|$fields[]|select(.databaseId==$id)|{id}]}}]' "$FIXTURES/project" > "$FIXTURES/changed"
      mv "$FIXTURES/changed" "$FIXTURES/project"
    elif [[ "$*" == *'/labels'* ]]; then
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == name=* ]]; then
          jq --arg name "${1#name=}" '.[0] += [{name:$name}]' "$FIXTURES/labels" > "$FIXTURES/changed"
          mv "$FIXTURES/changed" "$FIXTURES/labels"
        fi
        shift
      done
    else
      echo 'Unexpected REST mutation' >&2; exit 1
    fi
    echo '{}'
    ;;
  'api users/example') printf '{"node_id":"OWNER","type":"%s"}\n' "${MOCK_OWNER_TYPE:-User}" ;;
  'api repos/example/project --jq .node_id') echo REPO ;;
  *'repos/example/project/issue-types'*) cat "$FIXTURES/types" ;;
  *'repos/example/project/labels?'*) cat "$FIXTURES/labels" ;;
  *'projectV2(number:'*) printf '%s\n' "$*" >> "$FIXTURES/queries"; cat "$FIXTURES/project" ;;
  *) echo "Unexpected call $*" >&2; exit 1 ;;
esac
MOCK
  chmod +x "$FIXTURES/bin/gh"
}

# ============================================================================
# Test Cases
# ============================================================================

# ----------------------------------------------------------------------------
# @brief Verify that preview never writes.
@test "preview never writes" {
  run bash "$SCRIPT" --repo example/project --project 12
  [ "$status" -eq 0 ]
  [[ "$output" == *'Preview only'* ]]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that already configured project is a remote no-op.
@test "already configured project is a remote no-op" {
  run bash "$SCRIPT" --repo example/project --project 12 --apply
  [ "$status" -eq 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that organization owner uses organization GraphQL root.
@test "organization owner uses organization GraphQL root" {
  run env MOCK_OWNER_TYPE=Organization bash "$SCRIPT" --repo example/project --project 12
  [ "$status" -eq 0 ]
  command grep -q 'organization(login:' "$FIXTURES/queries"
}

# ----------------------------------------------------------------------------
# @brief Verify that wrong column field requires deliberate repair.
@test "wrong column field requires deliberate repair" {
  jq '.views.nodes[0].verticalGroupByFields.nodes[0].name="Other"' "$FIXTURES/project" > "$FIXTURES/changed"
  mv "$FIXTURES/changed" "$FIXTURES/project"
  run bash "$SCRIPT" --repo example/project --project 12 --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *'different column field'* ]]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that truncated inventory is rejected.
@test "truncated inventory is rejected" {
  jq '.fields.pageInfo.hasNextPage=true' "$FIXTURES/project" > "$FIXTURES/changed"
  mv "$FIXTURES/changed" "$FIXTURES/project"
  run bash "$SCRIPT" --repo example/project --project 12
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify that create preview never creates a project.
@test "create preview never creates a project" {
  run bash "$SCRIPT" --repo example/project --create 'Example Board'
  [ "$status" -eq 0 ]
  [ ! -e "$FIXTURES/writes" ]
}

# ----------------------------------------------------------------------------
# @brief Verify creation and safe replay of missing configuration.
@test "apply fills missing configuration and a second apply makes no writes" {
  printf '[[]]\n' > "$FIXTURES/types"
  printf '[[]]\n' > "$FIXTURES/labels"
  jq '.views.nodes=[] | .fields.nodes |= map(select(.name=="Status" or (has("options")|not))) | (.fields.nodes[]|select(.name=="Status")|.options)=[{id:"LEGACY",name:"Todo",color:"BLUE",description:"Existing state"}]' "$FIXTURES/project" > "$FIXTURES/changed"
  mv "$FIXTURES/changed" "$FIXTURES/project"
  run env MOCK_WRITES=1 bash "$SCRIPT" --repo example/project --project 12 --apply
  [ "$status" -eq 0 ]
  jq -e '(.views.nodes|length)==5 and ([.fields.nodes[]|select(.name=="Status")|.options[]|select(.name=="To Do")|.id]==["LEGACY"])' "$FIXTURES/project"
  writes_before=$(wc -l < "$FIXTURES/writes")
  run bash "$SCRIPT" --repo example/project --project 12 --apply
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$FIXTURES/writes")" = "$writes_before" ]
}
