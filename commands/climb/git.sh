# git.sh: arx climb's git steps, sourced by arx-climb. The agent works in
# the project checkout on refs/heads/climb/RUN, a branch climb owns: at
# each round end climb puts HEAD back on it, commits the change paths
# itself (never the agent's commits), and keeps or reverts the change.
# Every candidate stays reachable at refs/climb/RUN/rN.

# Checks the repository before a climb starts or resumes; exits 2 with the
# fix when something is wrong.
git_preflight() {
  local top v major minor dirty
  git rev-parse --git-dir >/dev/null 2>&1 ||
    die 2 "this folder is not a git repository; climb keeps every change as a commit (git init, then commit the project)"
  top=$(git rev-parse --show-toplevel)
  [ "$(cd "$top" && pwd -P)" = "$(pwd -P)" ] ||
    die 2 "run arx climb at the top of the repository: cd $top"
  v=$(git --version | awk '{ print $3 }') major=${v%%.*} minor=${v#*.}
  minor=${minor%%.*}
  [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 23 ]; } ||
    die 2 "climb needs git 2.23 or later (git restore); this is git $v"
  git rev-parse -q --verify HEAD >/dev/null || die 2 "the repository has no commit yet; commit the project first"
  mkdir -p .arx/climb
  git check-ignore -q .arx/climb ||
    die 2 "add .arx/ to .gitignore: climb keeps its files in .arx/climb/, and they must not be scored"
  dirty=$(git status --porcelain -- "${c_change[@]}" ${e_files[@]+"${e_files[@]}"})
  [ -z "$dirty" ] || die 2 "commit or stash these first; climb scores only what it commits:
$dirty"
}

# True when path $1 is in commit $2.
in_commit() {
  case "$1" in . | ./) return 0 ;; esac
  git cat-file -e "$2:${1%/}" 2>/dev/null
}

# Sets `found` to the paths of the list $2... that exist in the tree or in
# commit $1, so a pathspec never names nothing.
present() {
  local c=$1 p
  shift
  found=()
  for p in "$@"; do
    if [ -e "$p" ] || in_commit "$p" "$c"; then found+=("$p"); fi
  done
}

# Starts the branch climb/RUN at HEAD and puts HEAD on it. The tree and
# the index stay as they are.
git_branch() {
  git update-ref "refs/heads/$branch" "$best" "" 2>/dev/null ||
    die 2 "the branch $branch exists; pick another --name, or remove it with \`arx climb rm $name\`"
  git symbolic-ref HEAD "refs/heads/$branch" || die 1 "cannot check out $branch"
}

# Puts git back in climb's shape at a round end: no merge, rebase or
# cherry-pick in progress (their edits stay in the tree), HEAD on the
# branch, the branch and the index at BEST. Commits the agent made are
# folded back into the working tree; nothing in the tree is lost.
git_fold() {
  local gd
  gd=$(git rev-parse --git-dir) || return 1
  if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
    git rebase --quit >/dev/null 2>&1 || git am --quit >/dev/null 2>&1
  fi
  [ -f "$gd/MERGE_HEAD" ] && git merge --quit >/dev/null 2>&1
  [ -f "$gd/CHERRY_PICK_HEAD" ] && git cherry-pick --quit >/dev/null 2>&1
  [ -f "$gd/REVERT_HEAD" ] && git revert --quit >/dev/null 2>&1
  rm -f "$gd/MERGE_HEAD" "$gd/CHERRY_PICK_HEAD" "$gd/REVERT_HEAD"
  git symbolic-ref HEAD "refs/heads/$branch" &&
    git update-ref "refs/heads/$branch" "$best" &&
    git reset -q --mixed "$best"
}

# Puts eval.files in the tree back to EVAL's version and prints the paths
# that differed: the agent's edits to its copy of the scorer.
git_repair_eval() {
  local idx=$tmp/eval-index changed
  [ "$n_files" -gt 0 ] || return 0
  present "$eval_commit" "${e_files[@]}"
  [ "${#found[@]}" -gt 0 ] || return 0
  rm -f "$idx"
  GIT_INDEX_FILE=$idx git read-tree "$eval_commit" || return 1
  GIT_INDEX_FILE=$idx git add -A -- "${found[@]}" 2>/dev/null
  changed=$(GIT_INDEX_FILE=$idx git diff --cached --name-only --no-renames "$eval_commit" -- "${e_files[@]}")
  [ -n "$changed" ] || return 0
  git restore -q --source="$eval_commit" --worktree -- "${e_files[@]}" &&
    git clean -fdq -- "${e_files[@]}" || return 1
  printf '%s\n' "$changed"
}

# Commits the change paths as they are in the tree, on top of BEST,
# without touching the agent's index. Sets `target` to the new commit and
# `files` to what changed, or `target` to "" when nothing did.
git_snapshot() {
  local idx=$tmp/index tree
  target="" files=""
  present "$best" "${c_change[@]}"
  [ "${#found[@]}" -gt 0 ] || return 0
  rm -f "$idx"
  GIT_INDEX_FILE=$idx git read-tree "$best" || return 1
  GIT_INDEX_FILE=$idx git add -A -- "${found[@]}" || return 1
  tree=$(GIT_INDEX_FILE=$idx git write-tree) || return 1
  [ "$tree" != "$(git rev-parse "$best^{tree}")" ] || return 0
  files=$(git diff-tree -r --name-only --no-renames "$best" "$tree")
  if [ -z "$(git config user.email)" ]; then
    export GIT_AUTHOR_NAME="arx climb" GIT_AUTHOR_EMAIL="climb@arx.invalid"
    export GIT_COMMITTER_NAME="arx climb" GIT_COMMITTER_EMAIL="climb@arx.invalid"
  fi
  target=$(printf 'climb %s round %s: %s\n' "$name" "$round" "${note:-no note}" |
    git commit-tree "$tree" -p "$best") || return 1
  git update-ref "refs/climb/$name/r$round" "$target"
}

# Keeps the candidate: the branch moves to it, and the index follows.
git_keep() {
  git update-ref "refs/heads/$branch" "$target" "$best" && git reset -q &&
    best=$target
}

# Reverts the change paths to BEST: restores what the change edited or
# deleted, and removes what it added.
git_revert() {
  local p
  for p in "${c_change[@]}"; do
    if in_commit "$p" "$best"; then
      git restore -q --source="$best" --staged --worktree -- "$p" || return 1
    fi
  done
  git clean -fdq -- "${c_change[@]}"
}

# Prints the edits outside the change paths and eval.files: carried along
# in the tree, never scored, never committed by climb.
git_outside() {
  local p args=()
  for p in "${c_change[@]}" ${e_files[@]+"${e_files[@]}"}; do args+=(":(exclude)$p"); done
  git status --porcelain --untracked-files=all -- . "${args[@]}" | cut -c4- | head -n 50
}
