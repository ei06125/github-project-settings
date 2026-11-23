#!/usr/bin/env bash
set -euo pipefail

# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡
# Configuration
# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd -- "$script_dir/.." && pwd)
config="$root/config/kanban.json"
repo=''
project=''
target=''
base=main
owner_type=User
force=0
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Command Arguments
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2:?}; shift 2 ;;
    --project) project=${2:?}; shift 2 ;;
    --target) target=${2:?}; shift 2 ;;
    --base) base=${2:?}; shift 2 ;;
    --owner-type) owner_type=${2:?}; shift 2 ;;
    --config) config=${2:?}; shift 2 ;;
    --force) force=1; shift ;;
    *) echo 'Usage: install-repo-files.sh --repo OWNER/REPO --project NUMBER --target CHECKOUT [--base DEFAULT_BRANCH] [--owner-type User|Organization] [--config FILE] [--force]' >&2; exit 1 ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$project" =~ ^[1-9][0-9]*$ && -d "$target" ]] || { echo 'Invalid repo, project, or checkout' >&2; exit 1; }
[[ "$base" =~ ^[A-Za-z0-9_./-]+$ ]] || exit 1
[[ "$owner_type" == User || "$owner_type" == Organization ]] || exit 1

# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡
# Installation
# ≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡

# ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈
# Overwrite Protection
# ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈

for source in "$root"/templates/workflows/*.yml "$root"/templates/scripts/*.sh "$root"/templates/ISSUE_TEMPLATE/*.yml; do
  relative=${source#"$root/templates/"}
  if [[ -e "$target/.github/$relative" && "$force" == 0 ]]; then
    echo "Refusing to overwrite $target/.github/$relative; review it and use --force if intended" >&2; exit 1
  fi
done
if [[ -e "$target/.github/work-item-policy.json" && "$force" == 0 ]]; then
  echo 'Existing work-item-policy.json; review it before using --force' >&2; exit 1
fi
# ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈
# Template Rendering
# ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈

mkdir -p "$target/.github/workflows" "$target/.github/scripts" "$target/.github/ISSUE_TEMPLATE"
for source in "$root"/templates/workflows/*.yml; do
  sed "s/branches: \[main\]/branches: [\"${base//\//\\/}\"]/" "$source" > "$target/.github/workflows/${source##*/}"
done
cp "$root"/templates/scripts/*.sh "$target/.github/scripts/"
cp "$root"/templates/ISSUE_TEMPLATE/*.yml "$target/.github/ISSUE_TEMPLATE/"
jq --arg repo "$repo" --arg owner "${repo%/*}" --arg owner_type "$owner_type" --argjson number "$project" --arg base "$base" '{repository:$repo,project_owner:$owner,project_owner_type:$owner_type,project_number:$number,base_branch:$base,types:.delivery_types,transitions}' "$config" > "$target/.github/work-item-policy.json"
echo "Installed files into $target/.github. Review the diff; no commit, push, secret, or workflow activation was performed."
