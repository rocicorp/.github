#!/usr/bin/env bash
# sign-branch — take over a branch's commits as their author, signed with YOUR key.
#
#   scripts/sign-branch.sh [<branch>] [--yes] [--no-push]
#   scripts/sign-branch.sh <pr-number | pr-url> [--yes] [--no-push]
#   scripts/sign-branch.sh --pr [--yes] [--no-push]
#   scripts/sign-branch.sh --branch <branch> ...   (a branch whose name is all digits)
#
# With no branch, the ten most recently pushed branches on origin are listed and one is
# picked with the arrow keys (or j/k, a digit, Enter; q to quit). With --pr and no
# number, the ten most recently updated open pull requests are listed instead.
#
# A pull request (a number, `#123`, or its URL; needs the `gh` CLI) is signed wherever its
# branch lives, a contributor's fork included: its head and base are fetched and pushed by
# URL, which works for a fork when the PR allows maintainer edits. A plain branch name is
# looked up on origin.
#
# As git aliases, from any repo:
#   git config --global alias.sign-branch '!<this clone>/scripts/sign-branch.sh'
#   git config --global alias.sign-pr '!<this clone>/scripts/sign-branch.sh --pr'
#
# The rocicorp org requires every commit to be SSH-signed by a key in this repo's
# `.github/signing/allowed_signers`; the org-wide required workflow
# `.github/workflows/signed-commit-authors.yml` enforces it on every pull request. An
# agent-pushed commit carries a good signature made by a key that is not an allowed
# principal, so that check rejects it.
# This rebuilds those commits as yours, signed by your key, keeping the original author
# as a `Co-authored-by:` trailer and preserving the author date.
#
# Ported from rocicorp/rindle (scripts/sign-branch.sh).
#
# Nothing is checked out. A signature is a field of the commit object, not a property of
# the working tree, so each commit is rebuilt with `git commit-tree` from the tree the
# original already points at — your working tree, index and current branch are never
# touched, and it runs fine with uncommitted changes from any branch. Reusing trees by
# OID means the content is identical by construction and can never conflict. Works in a
# bare or blobless clone.
#
# Only the named branch's OWN commits are touched: the range is everything it added since
# it forked from origin's default branch (a PR's base branch), so shared history can never
# be rewritten. That fork point is derived (`ls-remote --symref` for the default branch,
# or the PR's base, then `merge-base`), never asked for.
#
# Within that range it starts at the FIRST commit that needs rebuilding — one whose author
# is not you, or that carries no signature — and runs to the tip, so commits already
# authored and signed by you keep their SHA and their completed checks. Merges are refused
# rather than flattened. It force-pushes, with the lease pinned to the SHA it fetched, so
# it asks first unless you pass --yes.
set -euo pipefail

self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
die() { echo "sign-branch: $*" >&2; exit 1; }
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$self"; }

target=; pr_mode=0; branch_mode=0; assume_yes=0; push=1
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)      pr_mode=1; shift ;;
    --branch)  branch_mode=1; shift ;;
    --yes|-y)  assume_yes=1; shift ;;
    --no-push) push=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown flag: $1" ;;
    *)         [ -z "$target" ] || die "only one branch or PR, got '$target' and '$1'"
               target=$1; shift ;;
  esac
done
[ "$pr_mode" = 0 ] || [ "$branch_mode" = 0 ] || die "--pr and --branch are exclusive"
# A number, #number or pull request URL names a PR; anything else is a branch on origin.
# --branch forces the latter, for a branch whose name is all digits.
[ "$branch_mode" = 1 ] || case "$target" in
  https://*/pull/[0-9]*)           pr_mode=1 ;;
  '' | '#' | *[!0-9#]* | ?*'#'*)   ;;
  *)                               pr_mode=1; target=${target#\#} ;;
esac
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
[ "$pr_mode" = 0 ] || command -v gh >/dev/null || die "signing a pull request needs the gh CLI"

# Fail before building anything if signing cannot produce what the org accepts.
me_name=$(git config user.name)   || die "no user.name configured"
me_email=$(git config user.email) || die "no user.email configured"
git config --get user.signingkey >/dev/null \
  || die "no user.signingkey configured — set it to your SSH signing key first"
[ "$(git config --default openpgp --get gpg.format)" = ssh ] \
  || die "gpg.format is not 'ssh' — allowed_signers only accepts SSH signatures:
    git config --global gpg.format ssh"

# Arrow-key menu on the terminal: sets $picked to the chosen index. Up/Down or k/j move,
# a digit jumps, Enter picks, q or Esc aborts. Redraws in place with plain escapes so it
# needs nothing beyond bash 3.2 and a VT100-ish terminal.
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
    # An arrow arrives as ESC [ A; a bare ESC has nothing following it.
    if [ "$key" = $'\033' ]; then IFS= read -rsn2 -t 1 key || key=esc; fi
    case "$key" in
      '[A' | k) cur=$(((cur + n - 1) % n)) ;;
      '[B' | j) cur=$(((cur + 1) % n)) ;;
      [1-9])    [ "$key" -le "$n" ] && { cur=$((key - 1)); break; } ;;
      '')       break ;;   # Enter: -n1 hands back an empty key at the delimiter
      q | esc)  printf '\n'; die "aborted" ;;
    esac
    printf '\033[%dA' "$n"; draw
  done
  picked=$cur
}

recent=10
branch=

if [ "$pr_mode" = 1 ]; then
  # --pr with no number: offer the most recently updated open pull requests.
  if [ -z "$target" ]; then
    [ -t 0 ] && [ -t 1 ] || die "no pull request given, and no terminal to pick one from"
    echo "fetching open pull requests…"
    nums=(); labels=()
    while IFS=$'\t' read -r num author head title; do
      nums+=("$num")
      labels+=("$(printf '#%-6s %-16.16s  %-40.40s  %.40s' "$num" "$author" "$head" "$title")")
    done < <(gh pr list --state open --limit "$recent" --search 'sort:updated-desc' \
               --json number,author,headRepositoryOwner,headRefName,title \
               --jq '.[] | [.number, .author.login,
                            .headRepositoryOwner.login + ":" + .headRefName, .title] | @tsv')
    [ "${#nums[@]}" -gt 0 ] || die "no open pull requests"
    echo
    echo "which pull request to sign?  (${#nums[@]} most recently updated)"
    menu "${labels[@]}"
    target=${nums[$picked]}
    echo
  fi

  # Unit-separated, not tab-separated: tab is IFS whitespace, so an empty field would
  # collapse into its neighbour and shift every later one.
  IFS=$'\x1f' read -r branch base_branch head_repo host base_repo state cross can_modify < <(
    gh pr view "$target" \
      --json headRefName,baseRefName,headRepositoryOwner,headRepository,url,state,isCrossRepository,maintainerCanModify \
      --jq '(.url | capture("^https?://(?<h>[^/]+)/(?<r>[^/]+/[^/]+)/pull/")) as $u
            | [.headRefName, .baseRefName,
               (if .headRepository then .headRepositoryOwner.login + "/" + .headRepository.name
                else "" end),
               $u.h, $u.r, .state, .isCrossRepository, .maintainerCanModify]
            | map(tostring) | join("\u001f")'
  ) || die "cannot read pull request $target"
  [ "$state" = OPEN ] || die "pull request $target is $state"
  [ -n "$head_repo" ] || die "pull request $target's head repository no longer exists"
  [ "$cross" != true ] || [ "$can_modify" = true ] \
    || die "pull request $target is from a fork that does not allow maintainer edits"

  # Head and base by URL rather than a remote, since a fork's head usually has none; on the
  # PR's host, in origin's protocol, so whatever credentials origin uses apply.
  case "$(git remote get-url origin 2>/dev/null || true)" in
    https://*) repo_url() { echo "https://$host/$1.git"; } ;;
    *)         repo_url() { echo "git@$host:$1.git"; } ;;
  esac
  src=$(repo_url "$head_repo"); base_src=$(repo_url "$base_repo"); where=$head_repo

  # A PR from a branch of the base repo itself may have that repo's default branch as its
  # head (main into a release branch, say); that is shared history, never ours to rewrite.
  # A fork's default branch is the contributor's own, so it is fair game.
  if [ "$cross" != true ]; then
    head_default=$(git ls-remote --symref "$src" HEAD | sed -n 's|^ref: refs/heads/||p' | awk '{print $1}')
    [ -n "$head_default" ] || die "cannot determine $head_repo's default branch"
    [ "$branch" != "$head_default" ] \
      || die "$branch IS $head_repo's default branch — refusing to rewrite it"
  fi
else
  src=origin; base_src=origin; where=origin
  # Ask the remote what its default branch is, rather than reading a local ref: this
  # works in a bare or fresh clone that has no refs/remotes/* at all, and cannot go stale.
  base_branch=$(git ls-remote --symref origin HEAD | sed -n 's|^ref: refs/heads/||p' | awk '{print $1}')
  [ -n "$base_branch" ] || die "cannot determine origin's default branch"
  branch=$target

  # No branch named: offer the most recently pushed branches on origin. Fetched into
  # refs/remotes/origin/* explicitly so this also works in a bare clone, which has none.
  if [ -z "$branch" ]; then
    [ -t 0 ] && [ -t 1 ] || die "no branch given, and no terminal to pick one from"
    echo "fetching branches from origin…"
    git fetch --quiet --prune origin '+refs/heads/*:refs/remotes/origin/*' \
      || die "cannot fetch branches from origin"
    names=(); labels=()
    while IFS=$'\t' read -r name date author subject; do
      case "$name" in "$base_branch" | HEAD) continue ;; esac
      names+=("$name")
      labels+=("$(printf '%-36.36s  %-14.14s  %-16.16s  %.40s' "$name" "$date" "$author" "$subject")")
      [ "${#names[@]}" -lt "$recent" ] || break
    done < <(git for-each-ref --sort=-committerdate \
               --format='%(refname:lstrip=3)%09%(committerdate:relative)%09%(authorname)%09%(contents:subject)' \
               refs/remotes/origin/)
    [ "${#names[@]}" -gt 0 ] || die "origin has no branches other than $base_branch"
    echo
    echo "which branch to sign?  (${#names[@]} most recently pushed; tip author shown)"
    menu "${labels[@]}"
    branch=${names[$picked]}
    echo
  fi

  [ "$branch" != "$base_branch" ] || die "$branch IS origin's default branch — refusing to rewrite it"
fi

echo "fetching $where…"
# FETCH_HEAD, not origin/<branch>: a bare clone has no remote-tracking refs, and it is
# precisely the SHA just fetched — which is what the push lease below must pin. Fetch the
# default branch first, since each fetch overwrites FETCH_HEAD.
git fetch --quiet "$base_src" "$base_branch" || die "cannot fetch $base_branch"
base_sha=$(git rev-parse FETCH_HEAD^{commit})
git fetch --quiet "$src" "$branch" || die "no branch '$branch' on $where"
head_sha=$(git rev-parse FETCH_HEAD^{commit})

# The fork point, so only what this branch added is ever in scope.
base=$(git merge-base "$base_sha" "$head_sha") || die "$branch shares no history with $base_branch"
[ "$(git rev-list --count "$base..$head_sha")" -gt 0 ] \
  || die "$branch adds nothing on top of $base_branch — nothing to do"

# The raw object is the signature check: `git log --format=%G?` only reports a *verified*
# signature, which needs gpg.ssh.allowedSignersFile set, and its absence would otherwise
# look identical to an unsigned commit.
needs_fix() {
  [ "$(git log -1 --format='%ae' "$1")" = "$me_email" ] || return 0
  git cat-file commit "$1" | sed -n '/^$/q;p' | grep -q '^gpgsig ' || return 0
  return 1
}

first_bad=
while read -r sha; do
  if needs_fix "$sha"; then first_bad=$sha; break; fi
done < <(git rev-list --reverse "$base..$head_sha")
[ -n "$first_bad" ] \
  || { echo "every commit on $branch is already authored and signed by you"; exit 0; }

upstream=$(git rev-parse "$first_bad^")
echo
echo "branch: $where:$branch    forked from: $base_branch    author: $me_name <$me_email>"
if [ "$(git rev-list --count "$base..$upstream")" -gt 0 ]; then
  echo "keeping untouched:"
  git log --reverse --format='    %h  %an  %s' "$base..$upstream"
fi
echo "rebuilding:"
git log --reverse --format='    %h  %an  %s' "$upstream..$head_sha"
echo

# --no-push only writes a local ref, so there is nothing to confirm.
if [ "$assume_yes" != 1 ] && [ "$push" = 1 ]; then
  printf 'rebuild and force-push to %s:%s? [y/N] ' "$where" "$branch"
  read -r reply
  case "$reply" in y | Y | yes | YES) ;; *) die "aborted" ;; esac
fi

# Rebuilding passes one -p, which would silently flatten a merge into its first side.
# Checked up front so nothing is built before refusing.
merge=$(git rev-list --merges "$upstream..$head_sha" | head -1)
[ -z "$merge" ] \
  || die "$(git rev-parse --short "$merge") is a merge — rewrite this branch by hand"

new=$upstream
while read -r sha; do
  orig_email=$(git log -1 --format='%ae' "$sha")
  trailer=()
  if [ "$orig_email" != "$me_email" ]; then
    trailer=(--trailer "Co-authored-by: $(git log -1 --format='%an' "$sha") <$orig_email>")
  fi
  # ${arr[@]+...} so an empty array is not an unbound-variable error under bash 3.2,
  # which is still what macOS ships as /bin/bash. addIfDifferent, not doNothing:
  # --if-exists matches on the key alone, so doNothing dropped the original author
  # whenever the message already had any Co-authored-by (an agent's, say).
  msg=$(git log -1 --format='%B' "$sha" \
        | git interpret-trailers --if-exists addIfDifferent ${trailer[@]+"${trailer[@]}"})
  new=$(
    export GIT_AUTHOR_NAME=$me_name GIT_AUTHOR_EMAIL=$me_email
    export GIT_AUTHOR_DATE=$(git log -1 --format='%aI' "$sha")
    export GIT_COMMITTER_NAME=$me_name GIT_COMMITTER_EMAIL=$me_email
    printf '%s\n' "$msg" | git commit-tree "$sha^{tree}" -p "$new" -S -F -
  )
  echo "    $(git rev-parse --short "$sha") -> $(git rev-parse --short "$new")  $(git log -1 --format=%s "$sha")"
done < <(git rev-list --reverse "$upstream..$head_sha")

# Park the chain on a ref so it survives gc, and so --no-push leaves something to look at.
staging=refs/sign-branch/$branch
git update-ref "$staging" "$new"

# The lease names the full ref: with a URL rather than a remote there is no
# remote-tracking ref for a short name to resolve against.
if [ "$push" != 1 ]; then
  echo "not pushed (--no-push) — rebuilt chain at $staging ($(git rev-parse --short "$new"))"
  echo "  inspect: git log $base..$staging"
  echo "  push:    git push --force-with-lease=refs/heads/$branch:$head_sha $src $staging:refs/heads/$branch"
  exit 0
fi

git push --force-with-lease="refs/heads/$branch:$head_sha" "$src" "$new:refs/heads/$branch"
git update-ref -d "$staging"
echo "pushed — your local $branch is now behind; git fetch when you next need it"
