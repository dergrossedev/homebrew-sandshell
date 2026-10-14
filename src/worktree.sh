# shellcheck shell=bash
# Host Git worktree sandboxes: sbxwt, managed worktree metadata, and the Git
# worktree lookup helpers shared with sbxr.

# _sbx_git_worktrees — print "path<TAB>branch" for every worktree of DIR.
_sbx_git_worktrees() {
  local dir=$1 line wt_path='' branch=''
  git -C "$dir" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
    case $line in
      'worktree '*) wt_path=${line#worktree }; branch='' ;;
      'branch refs/heads/'*) branch=${line#branch refs/heads/} ;;
      '')
        [[ -n $wt_path ]] && printf '%s\t%s\n' "$wt_path" "${branch:--}"
        wt_path=''; branch='' ;;
    esac
  done
}

# _sbx_git_main_worktree — print the primary worktree path of DIR.
_sbx_git_main_worktree() {
  local line
  line=$(git -C "$1" worktree list --porcelain 2>/dev/null | grep -m1 '^worktree ') || return
  printf '%s\n' "${line#worktree }"
}

# _sbx_git_worktree_for_branch — print the worktree path checked out on BRANCH.
_sbx_git_worktree_for_branch() {
  local dir=$1 wanted=$2 wt_path branch
  while IFS=$'\t' read -r wt_path branch; do
    [[ $branch == "$wanted" ]] && { printf '%s\n' "$wt_path"; return 0; }
  done < <(_sbx_git_worktrees "$dir")
  return 1
}

# _sbx_worktree_state_file — path of the managed-worktree metadata for SANDBOX.
_sbx_worktree_state_file() {
  local sandbox=$1
  if [[ ! $sandbox =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
    printf 'sbxwt: invalid sandbox name: %s\n' "$sandbox" >&2
    return 2
  fi
  printf '%s/worktrees/%s.meta\n' "$(_sbx_config_dir)" "$sandbox"
}

# _sbx_worktree_state_write — atomically record worktree metadata.
_sbx_worktree_state_write() {
  local sandbox=$1 repository=$2 worktree=$3 branch=$4 base_branch=$5
  local dir file tmp
  dir="$(_sbx_config_dir)/worktrees"
  file="$dir/$sandbox.meta"
  [[ ! -L $dir && ! -L $file && ( ! -e $file || -f $file ) ]] || {
    printf 'sbxwt: refusing symlink or non-file metadata path: %s\n' "$file" >&2
    return 2
  }
  (umask 077; mkdir -p -- "$dir") || return
  tmp=$(umask 077; mktemp "$dir/.${sandbox}.meta.XXXXXX") || return
  {
    printf 'repository\t%s\n' "$repository"
    printf 'worktree\t%s\n' "$worktree"
    printf 'branch\t%s\n' "$branch"
    printf 'base_branch\t%s\n' "$base_branch"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -- "$tmp" "$file"
}

# _sbx_worktree_state_read — print "repository<TAB>worktree<TAB>branch<TAB>base".
_sbx_worktree_state_read() {
  local sandbox=$1 file
  file=$(_sbx_worktree_state_file "$sandbox") || return
  if [[ -L $file || ! -f $file ]]; then
    printf 'sbxwt: managed worktree metadata not found: %s\n' "$sandbox" >&2
    return 1
  fi
  awk -F '\t' '
    $1 == "repository"  { repository = substr($0, index($0, "\t") + 1) }
    $1 == "worktree"    { worktree = substr($0, index($0, "\t") + 1) }
    $1 == "branch"      { branch = substr($0, index($0, "\t") + 1) }
    $1 == "base_branch" { base = substr($0, index($0, "\t") + 1) }
    END {
      if (!repository || !worktree || !branch || !base) exit 1
      printf "%s\t%s\t%s\t%s\n", repository, worktree, branch, base
    }
  ' "$file"
}

# _sandshell_sbxwt_help — print sbxwt usage.
_sandshell_sbxwt_help() {
  printf '%s\n' \
    'Usage:' \
    '  sbxwt create BRANCH [-a AGENT] [-s SIZE] [--base BRANCH] [--env-file FILE]' \
    '  sbxwt ls' \
    '  sbxwt commit SANDBOX [-m MESSAGE]' \
    '  sbxwt merge SANDBOX [--into BRANCH]' \
    '  sbxwt done SANDBOX' \
    '' \
    'create  Create a host worktree and a sandbox for it.' \
    'ls      Show repository worktrees and associated sandboxes.' \
    'commit  Stage all worktree changes and commit them after confirmation.' \
    'merge   Merge the worktree branch into its recorded base branch.' \
    'done    Remove the sandbox and clean worktree after confirmation; preserve the branch.' \
    '' \
    "Metadata: $(_sbx_config_dir)/worktrees/<sandbox>.meta"
}

# Manage host Git worktrees paired with Docker sandboxes.
sbxwt() {
  local command=${1:-ls}
  local branch='' base_branch='' target_branch='' agent=opencode size=micro env_file='' default_env=''
  local repository worktree_root worktree project branch_slug sandbox listing rows row
  local wt_path wt_branch sandbox_name sandbox_agent sandbox_status rest
  local metadata changes commits target_worktree registered=0 merged=0
  local mcp_state skill_state sandbox_meta
  local -a create_args

  case $command in
    -h|--help)
      _sandshell_sbxwt_help
      return 0 ;;
  esac
  # `sbxwt SUBCOMMAND --help` shows help instead of a confusing error.
  if [[ ${2:-} == -h || ${2:-} == --help ]]; then
    case $command in
      create|ls|commit|merge|done)
        _sandshell_sbxwt_help
        return 0 ;;
    esac
  fi

  if ! command -v git >/dev/null 2>&1; then
    printf 'sbxwt: git not found\n' >&2
    return 127
  fi

  case $command in
    create)
      shift
      if (( $# < 1 )); then
        printf 'sbxwt: usage: sbxwt create BRANCH [-a AGENT] [-s SIZE] [--base BRANCH] [--env-file FILE]\n' >&2
        return 2
      fi
      branch=$1; shift
      while (( $# )); do
        case $1 in
          -a|--agent|-s|--size|--base|--env-file)
            if (( $# < 2 )) || [[ -z $2 ]]; then
              printf 'sbxwt: missing value for %s\n' "$1" >&2
              return 2
            fi
            case $1 in
              -a|--agent) agent=$2 ;;
              -s|--size) size=$2 ;;
              --base) base_branch=$2 ;;
              --env-file) env_file=$2 ;;
            esac
            shift 2 ;;
          *) printf 'sbxwt: unknown option: %s\n' "$1" >&2; return 2 ;;
        esac
      done

      git check-ref-format --branch "$branch" >/dev/null 2>&1 || {
        printf 'sbxwt: invalid branch name: %s\n' "$branch" >&2
        return 2
      }
      _sbx_agent_target "$agent" >/dev/null || {
        printf 'sbxwt: unsupported agent: %s\n' "$agent" >&2
        return 2
      }
      case $size in micro|small|medium) ;; *) printf 'sbxwt: invalid size: %s\n' "$size" >&2; return 2 ;; esac
      git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        printf 'sbxwt: current directory is not inside a Git working tree\n' >&2
        return 2
      }

      repository=$(_sbx_git_main_worktree "$PWD") || {
        printf 'sbxwt: could not resolve the main Git worktree\n' >&2
        return 1
      }
      if [[ -z $base_branch ]]; then
        base_branch=$(git -C "$PWD" branch --show-current) || return
        [[ -n $base_branch ]] || {
          printf 'sbxwt: detached HEAD; specify --base BRANCH\n' >&2
          return 2
        }
      fi
      git -C "$repository" show-ref --verify --quiet "refs/heads/$base_branch" || {
        printf 'sbxwt: base must be an existing local branch: %s\n' "$base_branch" >&2
        return 2
      }
      [[ $branch != "$base_branch" ]] || {
        printf 'sbxwt: worktree branch must differ from its base branch\n' >&2
        return 2
      }

      branch_slug=${branch//\//-}
      branch_slug=${branch_slug//[^a-zA-Z0-9.-]/-}
      branch_slug=${branch_slug:0:32}
      project=$(_sbx_project_name "$repository") || return
      worktree_root="${repository}.worktrees"
      worktree="$worktree_root/$branch_slug"
      sandbox="sbx-${project}-${branch_slug}-${agent}-$(printf '%04x%04x' "$RANDOM" "$RANDOM")"

      if [[ -L $worktree_root || -e $worktree ]]; then
        printf 'sbxwt: worktree path already exists or is unsafe: %s\n' "$worktree" >&2
        return 2
      fi
      if [[ -n $env_file && ( ! -f $env_file || ! -r $env_file ) ]]; then
        printf 'sbxwt: env file not readable: %s\n' "$env_file" >&2
        return 2
      fi

      mkdir -p -- "$worktree_root" || return
      if git -C "$repository" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$repository" worktree add "$worktree" "$branch" || return
      else
        git -C "$repository" worktree add -b "$branch" "$worktree" "$base_branch" || return
      fi

      create_args=(-a "$agent" -s "$size" -d "$worktree" -n "$sandbox")
      if [[ -n $env_file ]]; then
        create_args+=(--env-file "$env_file")
      else
        default_env="$(_sbx_config_dir)/envs/$project.env"
        [[ -r $default_env ]] && create_args+=(--env-file "$default_env")
      fi

      # sbxc prints a resume hint of its own; the worktree summary below ends
      # with the same hint, so suppress the duplicate for this call only.
      if ! ( _sandshell_skip_resume_hint=1; sbxc "${create_args[@]}" ); then
        printf 'sbxwt: sandbox creation failed; worktree was left intact at %s\n' "$worktree" >&2
        return 1
      fi
      if ! _sbx_worktree_state_write "$sandbox" "$repository" "$worktree" "$branch" "$base_branch"; then
        printf 'sbxwt: warning: sandbox and worktree exist, but metadata could not be saved\n' >&2
        return 1
      fi
      printf 'Worktree: %s\nBranch:   %s\nSandbox:  %s\n' "$worktree" "$branch" "$sandbox"
      printf 'Resume with: sbxr %s\n' "$sandbox" >&2
      ;;

    ls)
      shift
      (( $# == 0 )) || { printf 'sbxwt: usage: sbxwt ls\n' >&2; return 2; }
      git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        printf 'sbxwt: current directory is not inside a Git working tree\n' >&2
        return 2
      }
      listing=$(sbx ls) || return
      printf 'BRANCH\tWORKTREE\tSANDBOX\tSTATE\n'
      while IFS=$'\t' read -r wt_path wt_branch; do
        rows=$(_sbx_workspace_rows "$wt_path" "$listing") || return
        if [[ -z $rows ]]; then
          printf '%s\t%s\t-\t-\n' "$wt_branch" "$wt_path"
          continue
        fi
        while IFS= read -r row; do
          # sandbox_agent is intentionally ignored; only name and status are shown.
          # shellcheck disable=SC2034
          IFS=$' \t' read -r sandbox_name sandbox_agent sandbox_status rest <<< "$row"
          printf '%s\t%s\t%s\t%s\n' "$wt_branch" "$wt_path" "$sandbox_name" "$sandbox_status"
        done <<< "$rows"
      done < <(_sbx_git_worktrees "$PWD")
      ;;

    commit)
      shift
      if (( $# < 1 || $# > 3 )); then
        printf 'sbxwt: usage: sbxwt commit SANDBOX [-m MESSAGE]\n' >&2
        return 2
      fi
      sandbox=$1; shift
      local message=''
      if (( $# )); then
        [[ $1 == -m && $# == 2 && -n $2 ]] || { printf 'sbxwt: usage: sbxwt commit SANDBOX [-m MESSAGE]\n' >&2; return 2; }
        message=$2
      fi
      metadata=$(_sbx_worktree_state_read "$sandbox") || return
      IFS=$'\t' read -r repository worktree branch base_branch <<< "$metadata"
      [[ -d $worktree ]] || { printf 'sbxwt: worktree directory missing: %s\n' "$worktree" >&2; return 1; }
      [[ $(git -C "$worktree" branch --show-current) == "$branch" ]] || {
        printf 'sbxwt: worktree is no longer on expected branch: %s\n' "$branch" >&2
        return 1
      }
      if [[ -n $(git -C "$worktree" diff --name-only --diff-filter=U) ]]; then
        printf 'sbxwt: resolve merge conflicts before committing\n' >&2
        return 1
      fi
      changes=$(git -C "$worktree" status --short) || return
      if [[ -z $changes ]]; then
        printf 'sbxwt: no changes to commit in %s\n' "$branch"
        return 0
      fi
      printf '%s\n' "$changes"
      _sbx_confirm sbxwt "Stage all changes and commit on $branch?" || { printf 'sbxwt: cancelled\n' >&2; return 1; }
      git -C "$worktree" add -A || return
      if [[ -n $message ]]; then
        git -C "$worktree" commit -m "$message"
      else
        git -C "$worktree" commit
      fi
      ;;

    merge)
      shift
      if (( $# < 1 || $# > 3 )); then
        printf 'sbxwt: usage: sbxwt merge SANDBOX [--into BRANCH]\n' >&2
        return 2
      fi
      sandbox=$1; shift
      if (( $# )); then
        [[ $1 == --into && $# == 2 && -n $2 ]] || { printf 'sbxwt: usage: sbxwt merge SANDBOX [--into BRANCH]\n' >&2; return 2; }
        target_branch=$2
      fi
      metadata=$(_sbx_worktree_state_read "$sandbox") || return
      IFS=$'\t' read -r repository worktree branch base_branch <<< "$metadata"
      [[ -n $target_branch ]] || target_branch=$base_branch
      [[ $target_branch != "$branch" ]] || { printf 'sbxwt: source and target branches are the same\n' >&2; return 2; }
      git -C "$repository" show-ref --verify --quiet "refs/heads/$target_branch" || {
        printf 'sbxwt: target branch does not exist locally: %s\n' "$target_branch" >&2
        return 1
      }
      target_worktree=$(_sbx_git_worktree_for_branch "$repository" "$target_branch") || {
        printf 'sbxwt: target branch must be checked out in a worktree: %s\n' "$target_branch" >&2
        return 1
      }
      [[ -z $(git -C "$worktree" status --porcelain) ]] || {
        printf 'sbxwt: source worktree has uncommitted changes; commit them first\n' >&2
        return 1
      }
      [[ -z $(git -C "$target_worktree" status --porcelain) ]] || {
        printf 'sbxwt: target worktree has uncommitted changes: %s\n' "$target_worktree" >&2
        return 1
      }
      if git -C "$repository" merge-base --is-ancestor "$branch" "$target_branch"; then
        printf 'sbxwt: %s is already merged into %s\n' "$branch" "$target_branch"
        return 0
      fi
      commits=$(git -C "$repository" log --oneline "$target_branch..$branch") || return
      printf 'Merge %s -> %s\n' "$branch" "$target_branch"
      [[ -n $commits ]] && printf '%s\n' "$commits"
      _sbx_confirm sbxwt "Merge $branch into $target_branch?" || { printf 'sbxwt: cancelled\n' >&2; return 1; }
      git -C "$target_worktree" merge "$branch"
      ;;

    done)
      shift
      (( $# == 1 )) || { printf 'sbxwt: usage: sbxwt done SANDBOX\n' >&2; return 2; }
      sandbox=$1
      metadata=$(_sbx_worktree_state_read "$sandbox") || return
      IFS=$'\t' read -r repository worktree branch base_branch <<< "$metadata"
      registered=0
      while IFS=$'\t' read -r wt_path wt_branch; do
        [[ $wt_path == "$worktree" ]] && { registered=1; break; }
      done < <(_sbx_git_worktrees "$repository")

      if (( registered )); then
        [[ -z $(git -C "$worktree" status --porcelain) ]] || {
          printf 'sbxwt: worktree has uncommitted or untracked changes; commit or remove them first\n' >&2
          git -C "$worktree" status --short >&2
          return 1
        }
      elif [[ -e $worktree ]]; then
        printf 'sbxwt: path exists but is no longer a registered worktree; refusing to remove it: %s\n' "$worktree" >&2
        return 1
      fi

      if git -C "$repository" show-ref --verify --quiet "refs/heads/$base_branch" && \
         git -C "$repository" merge-base --is-ancestor "$branch" "$base_branch" 2>/dev/null; then
        merged=1
      fi
      printf 'Sandbox:  %s\nWorktree: %s\nBranch:   %s (preserved)\nBase:     %s\n' \
        "$sandbox" "$worktree" "$branch" "$base_branch"
      (( merged )) || printf 'Warning: %s is not merged into %s; the branch will still be preserved.\n' "$branch" "$base_branch" >&2
      _sbx_confirm sbxwt 'Remove this sandbox and host worktree?' || { printf 'sbxwt: cancelled\n' >&2; return 1; }

      if _sbx_sandbox_exists "$sandbox"; then
        sbx rm --force "$sandbox" || return
      fi
      if (( registered )); then
        git -C "$repository" worktree remove "$worktree" || return
      fi

      mcp_state="$(_sbx_config_dir)/mcp/$sandbox.servers"
      skill_state="$(_sbx_config_dir)/skills/$sandbox.skills"
      sandbox_meta=$(_sbx_sandbox_meta_file "$sandbox") || return
      metadata=$(_sbx_worktree_state_file "$sandbox") || return
      rm -f -- "$metadata" "$mcp_state" "$skill_state" "$sandbox_meta" || return
      printf 'Removed sandbox and worktree. Branch preserved: %s\n' "$branch"
      ;;

    *)
      printf 'sbxwt: unknown command: %s\n' "$command" >&2
      printf 'Run sbxwt --help for usage.\n' >&2
      return 2 ;;
  esac
}
