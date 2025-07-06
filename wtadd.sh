#!/usr/bin/env bash
# Based on: https://github.com/llimllib/personal_code/blob/master/homedir/.local/bin/worktree

# Adjusted to work with bare repos

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
CLEAR="\033[0m"
VERBOSE=

echo $1

function usage {
  cat <<EOF
worktree [-v] <branch name>

create a git worktree with <branch name>. Will create a worktree if one isn't
found that matches the given name.

Will copy over any .env, .envrc, or .tool-versions files to the new worktree
as well as node_modules
EOF
  kill -INT $$
}

function die {
  printf '%b%s%b\n' "$RED" "$1" "$CLEAR"
  # exit the script, but if it was sourced, don't kill the shell
  kill -INT $$
}

function warn {
  printf '%b%s%b\n' "$YELLOW" "$1" "$CLEAR"
}

# If at all possible, use copy-on-write to copy files. This is especially
# important to allow us to copy node_modules directories efficiently
#
# On mac or bsd: try to use -c
# see:
# https://spin.atomicobject.com/2021/02/23/git-worktrees-untracked-files/
#
# On gnu: use --reflink
#
# Use /bin/cp directly to avoid any of the user's aliases - this script is
# often eval'ed
#
# I tried to figure out how to actually determine the filesystem support for
# copy-on-write, but did not find any good references, so I'm falling back on
# "try and see if it fails"
function cp_cow {
  if ! /bin/cp -Rc "$1" "$2" 2>/dev/null; then
    if ! /bin/cp -R --reflink "$1" "$2" 2>/dev/null; then
      if ! /bin/cp -R "$1" "$2" 2>/dev/null; then
        warn "Unable to copy file $1 to $2 - folder may not exist"
      fi
    fi
  fi
}

# Create a worktree from a given branchname, and copy some untracked files
function _worktree {
  if [ -z "$1" ]; then
    usage
  fi

  if [ -n "$VERBOSE" ]; then
    set -x
  fi
  branchname="$1"

  # Replace slashes with underscores. If there's no slash, dirname will equal
  # branchname. So "alu/something-other" becomes "alu_something-other", but
  # "quick-fix" stays unchanged
  # https://www.tldp.org/LDP/abs/html/parameter-substitution.html
  dirname=${branchname//\//_}

  is_worktree=$(git rev-parse --is-inside-work-tree)
  if $is_worktree; then
    parent_dir=".."
  else
    parent_dir="."
  fi

  # if the branch name already exists, we want to check it out. Otherwise,
  # create a new branch. I'm sure there's probably a way to do that in one
  # command, but I'm done fiddling with git at this point
  #
  # As far as I can tell, we have to check locally and remotely separately if
  # we want to be accurate. See https://stackoverflow.com/a/75040377 for the
  # reasoning here. Also this has some caveats, but probably works well
  # enough :shrug:
  #
  # if the branch exists locally:
  if git for-each-ref --format='%(refname:lstrip=2)' refs/heads | grep -E "^$branchname$" >/dev/null 2>&1; then
    if ! git worktree add "$parent_dir/$dirname" "$branchname"; then
      die "failed to create git worktree $branchname"
    fi
  # if the branch exists on a remote:
  elif git for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin | grep -E "^$branchname$" >/dev/null 2>&1; then
    if ! git worktree add "$parent_dir/$dirname" "$branchname"; then
      die "failed to create git worktree $branchname"
    fi
  else
    # otherwise, create a new branch
    if ! git worktree add -b "$branchname" "$parent_dir/$dirname"; then
      die "failed to create git worktree $branchname"
    fi
  fi

  # Find untracked files that we want to copy to the new worktree

  # packages in node_modules packages can have sub-node-modules packages, and
  # we don't want to copy them; only copy the root node_modules directory
  if [ -d "node_modules" ]; then
    cp_cow node_modules "$parent_dir/$dirname"/node_modules
  fi

  # this will fail for any files with \n in their names. don't do that.
  IFS=$'\n'
  # Files to exclude
  FILE_EXTENSIONS=("envrc" "env" "env.local" "tool-versions" "mise.toml")
  YAML_FILES=("application-local.yml")

  # Build patterns
  extensions_pattern=$(
    IFS='|'
    echo "${FILE_EXTENSIONS[*]}"
  )
  yaml_pattern=$(
    IFS='|'
    echo "${YAML_FILES[*]}"
  )

  # Create combined regex pattern that handles both root and subdirectory files
  DOT_FILE_PATTERNS="(^|.*\/)\.(${extensions_pattern})"
  YAML_FILE_PATTERNS=".*\/(${yaml_pattern})"

  # Build exclude pattern
  EXCLUDE_PATHS=("*node_modules*" "*dist*" "*build*")

  platform=$(uname)
  if $is_worktree; then
    copy_source="."
  else
    copy_source=./$(git rev-parse --abbrev-ref HEAD)
  fi

  # Use array assignment (no mapfile)
  # shellcheck disable=SC2207
  if [ "$platform" = "Darwin" ]; then
    files_to_copy=($(find -E "$copy_source" \
      -not -path "*node_modules*" \
      -not -path "*dist*" \
      -not -path "*build*" \
      \( -iregex "$DOT_FILE_PATTERNS" -o -iregex "$YAML_FILE_PATTERNS" \)))
  else
    files_to_copy=($(find "$copy_source" \
      -not -path "*node_modules*" \
      -not -path "*dist*" \
      -not -path "*build*" \
      -regextype posix-extended \
      \( -iregex "$DOT_FILE_PATTERNS" -o -iregex "$YAML_FILE_PATTERNS" \)))
  fi

  # Copy the files from the files_to_copy array
  for f in "${files_to_copy[@]}"; do
    # Handle both cases: files in root and in subdirectories
    if [[ "$f" == "$copy_source/"* ]]; then
      # File in subdirectory - remove the copy_source prefix
      target_path="${f#$copy_source/}"
    else
      # File in root directory - just use the filename
      target_path="${f##*/}"
    fi

    # Create target directory if it doesn't exist
    target_dir="$parent_dir/$dirname/$(dirname "$target_path")"
    if [ "$target_dir" != "$parent_dir/$dirname/." ]; then
      mkdir -p "$target_dir"
    fi

    cp_cow "$f" "$parent_dir/$dirname/$target_path"
  done
  # return the shell to normal splitting mode
  unset IFS

  # pull the most recent version of the remote
  if ! git -C "$parent_dir/$dirname" pull; then
    warn "Unable to run git pull, there may not be an upstream"
  fi

  git -C "$parent_dir/$dirname" pull

  # if there was an envrc file, tell direnv that it's ok to run it
  if [ -f "$parent_dir/$dirname/.envrc" ]; then
    direnv allow "$parent_dir/$dirname"
  fi

  printf "%bcreated worktree %s%b\n" "$GREEN" "$parent_dir/$dirname" "$CLEAR"
}

while true; do
  case $1 in
  help | -h | --help)
    usage
    ;;
  -v | --verbose)
    VERBOSE=true
    shift
    ;;
  *)
    break
    ;;
  esac
done

_worktree "$@"
