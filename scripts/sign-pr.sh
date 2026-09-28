#!/usr/bin/env bash
# sign-pr — take over a PR's commits as their author, signed with YOUR key.
#
#   scripts/sign-pr.sh [<pr-number>] [--repo owner/name] [--yes] [--no-push]
#
# As a git alias, run from any repo:
#   git config --global alias.sign-pr '!<path to this clone>/scripts/sign-pr.sh'
#
# With no PR number, the ten most recently updated open PRs are listed and one is
# picked with the arrow keys (or j/k, a digit, Enter; q to quit).
#
# Like scripts/sign-branch.sh, but addressed by PR number, so it
# also works when the PR's branch lives on a contributor's fork (sign-branch.sh only
# looks at `origin`). It pushes straight to the PR's head repo by URL, which works
# for a fork when the PR allows maintainer edits.
#
# Each commit that is not authored by you, or not signed, is rebuilt with
# `git commit-tree` from the tree it already points at (identical content by
# construction), authored by you, signed (-S), keeping the author date and adding the
# original author as a `Co-authored-by:` trailer. Nothing is checked out.
#
# The trailer is added with `--if-exists addIfDifferent`, so the original author is
# kept when the message already has some other Co-authored-by (an agent's, say).
#
# --repo defaults to the repo `gh` resolves for the current directory.
set -euo pipefail

die() { echo "sign-pr: $*" >&2; exit 1; }

pr=; repo=; assume_yes=0; push=1
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)  assume_yes=1; shift ;;
    --no-push) push=0; shift ;;
    --repo)    repo=${2:?--repo needs owner/name}; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
    -*)        die "unknown flag: $1" ;;
    *)         [ -z "$pr" ] || die "only one PR, got '$pr' and '$1'"; pr=$1; shift ;;
  esac
done
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
command -v gh >/dev/null || die "needs the gh CLI"

me_name=$(git config user.name)   || die "no user.name configured"
me_email=$(git config user.email) || die "no user.email configured"
git config --get user.signingkey >/dev/null || die "no user.signingkey configured"
[ "$(git config --default openpgp --get gpg.format)" = ssh ] || die "gpg.format is not 'ssh'"

# Arrow-key menu (same as sign-branch.sh): sets $picked to the chosen index.
menu() {
  local n=$# cur=0 i key
  local items=("$@")
  draw() {
    for ((i = 0; i < n; i++)); do
      if [ "$i" = "$cur" ]; then printf '\033[K \033[7m> %d) %s\033[0m\n' $((i + 1)) "${items[i]}"
      else printf '\033[K   %d) %s\n' $((i + 1)) "${items[i]}"; fi
    done
  }
  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null || true' EXIT
  draw
  while :; do
    IFS= read -rsn1 key
    if [ "$key" = $'\033' ]; then IFS= read -rsn2 -t 1 key || key=esc; fi
    case "$key" in
      '[A' | k) cur=$(((cur + n - 1) % n)) ;;
      '[B' | j) cur=$(((cur + 1) % n)) ;;
      [1-9])    [ "$key" -le "$n" ] && { cur=$((key - 1)); break; } ;;
      '')       break ;;
      q | esc)  printf '\n'; die "aborted" ;;
    esac
    printf '\033[%dA' "$n"; draw
  done
  tput cnorm 2>/dev/null || true
  picked=$cur
}

if [ -z "$pr" ]; then
  [ -t 0 ] && [ -t 1 ] || die "no PR number given, and no terminal to pick one from"
  echo "fetching open PRs…"
  nums=(); labels=()
  while IFS=$'\t' read -r num author branch title; do
    nums+=("$num")
    labels+=("$(printf '#%-6s %-14.14s  %-30.30s  %.50s' "$num" "$author" "$branch" "$title")")
  done < <(gh pr list ${repo:+--repo "$repo"} --state open --limit 10 \
             --search 'sort:updated-desc' \
             --json number,author,headRefName,title \
             --jq '.[] | [.number, .author.login, .headRefName, .title] | @tsv')
  [ "${#nums[@]}" -gt 0 ] || die "no open PRs"
  echo
  echo "which PR to sign?  (${#nums[@]} most recently updated)"
  menu "${labels[@]}"
  pr=${nums[$picked]}
  echo
fi

IFS=$'\t' read -r head_ref head_owner head_name base_ref state can_modify cross < <(
  gh pr view "$pr" ${repo:+--repo "$repo"} \
    --json headRefName,headRepositoryOwner,headRepository,baseRefName,state,maintainerCanModify,isCrossRepository \
    --jq '[.headRefName, .headRepositoryOwner.login, .headRepository.name, .baseRefName, .state, .maintainerCanModify, .isCrossRepository] | @tsv'
) || die "cannot read PR $pr"
[ "$state" = OPEN ] || die "PR $pr is $state"
[ "$cross" != true ] || [ "$can_modify" = true ] \
  || die "PR $pr is from a fork that does not allow maintainer edits — cannot push to it"

base_url=$(gh repo view ${repo:+"$repo"} --json sshUrl --jq .sshUrl)
head_url="git@github.com:$head_owner/$head_name.git"

echo "PR $pr: $head_owner/$head_name:$head_ref -> $base_ref"
git fetch --quiet "$base_url" "$base_ref" || die "cannot fetch $base_ref"
base_sha=$(git rev-parse FETCH_HEAD^{commit})
git fetch --quiet "$head_url" "$head_ref" || die "cannot fetch $head_owner:$head_ref"
head_sha=$(git rev-parse FETCH_HEAD^{commit})

base=$(git merge-base "$base_sha" "$head_sha") || die "no common history with $base_ref"
[ "$(git rev-list --count "$base..$head_sha")" -gt 0 ] || die "nothing on top of $base_ref"

# Raw object check: %G? only reports a *verified* signature.
needs_fix() {
  [ "$(git log -1 --format='%ae' "$1")" = "$me_email" ] || return 0
  git cat-file commit "$1" | sed -n '/^$/q;p' | grep -q '^gpgsig ' || return 0
  return 1
}
first_bad=
while read -r sha; do
  if needs_fix "$sha"; then first_bad=$sha; break; fi
done < <(git rev-list --reverse "$base..$head_sha")
[ -n "$first_bad" ] || { echo "every commit is already authored and signed by you"; exit 0; }

upstream=$(git rev-parse "$first_bad^")
merge=$(git rev-list --merges "$upstream..$head_sha" | head -1)
[ -z "$merge" ] || die "$(git rev-parse --short "$merge") is a merge — rewrite by hand"

echo "rebuilding as $me_name <$me_email>:"
git log --reverse --format='    %h  %an  %s' "$upstream..$head_sha"

new=$upstream
while read -r sha; do
  orig_name=$(git log -1 --format='%an' "$sha")
  orig_email=$(git log -1 --format='%ae' "$sha")
  trailer=()
  if [ "$orig_email" != "$me_email" ]; then
    trailer=(--trailer "Co-authored-by: $orig_name <$orig_email>")
  fi
  msg=$(git log -1 --format='%B' "$sha" \
        | git interpret-trailers --if-exists addIfDifferent ${trailer[@]+"${trailer[@]}"})
  new=$(
    export GIT_AUTHOR_NAME=$me_name GIT_AUTHOR_EMAIL=$me_email
    export GIT_AUTHOR_DATE=$(git log -1 --format='%aI' "$sha")
    export GIT_COMMITTER_NAME=$me_name GIT_COMMITTER_EMAIL=$me_email
    printf '%s\n' "$msg" | git commit-tree "$sha^{tree}" -p "$new" -S -F -
  )
  [ "$(git rev-parse "$new^{tree}")" = "$(git rev-parse "$sha^{tree}")" ] || die "tree mismatch"
  echo "    $(git rev-parse --short "$sha") -> $(git rev-parse --short "$new")"
done < <(git rev-list --reverse "$upstream..$head_sha")

staging=refs/sign-pr/$pr
git update-ref "$staging" "$new"
push_cmd=(git push --force-with-lease="refs/heads/$head_ref:$head_sha" "$head_url" "$new:refs/heads/$head_ref")

if [ "$push" != 1 ]; then
  echo "not pushed (--no-push) — rebuilt chain at $staging"
  echo "  push: ${push_cmd[*]}"
  exit 0
fi
if [ "$assume_yes" != 1 ]; then
  printf 'force-push to %s:%s? [y/N] ' "$head_owner" "$head_ref"
  read -r reply
  case "$reply" in y | Y | yes | YES) ;; *) die "aborted (chain kept at $staging)" ;; esac
fi
"${push_cmd[@]}"
git update-ref -d "$staging"
echo "pushed — local copies of $head_ref are now stale; reset them to $(git rev-parse --short "$new")"
