## Experimental git branch management tool

function og(){
  if [ $# -eq 0 ]; then
    echo "Usage: og <command> [args]"
    echo "Commands:"
    echo "  branch <branch> - create a new branch off the current branch"
    echo "  parent [branch] - get the parent of the current branch or the given branch"
    echo "  children [branch] - get the children of the current branch or the given branch"
    echo "  downstream [branch] - list all branches that are downstream of the current branch"
    echo "  upchain [branch] - list the chain of branches from the current branch or the given 
branch"
    echo "  downchain [branch] - list the chain of branches from the current branch or the given 
branch"
    echo "  chain [branch] - list both upchain and downchain in order"
    echo "  evolve - rebase all children on top of the current branch, recursively"
    echo "  up - move one branch up the chain"
    echo "  down - move one branch down the chain"
    echo "  setparent <parent> - set the parent of the current branch"
    echo "  markmerged - mark the current branch as merged"
    return 1
  fi
  local command=og_$1
  shift
  if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "ERROR: Not in a git repository"
    return 1
  fi
  $command $@
}


function og_branch(){
  if [ $# -eq 0 ]; then
    echo "Usage: og branch <branch>"
    return 1
  fi
  local dependent=$1
  local base=$(git rev-parse --abbrev-ref HEAD)
  local base_commit=$(git rev-parse HEAD)

  # If branch has already been created, fail
  if git show-ref --verify --quiet refs/heads/$dependent; then
    echo "Branch $dependent already exists"
    return 1
  fi

  git checkout -b $dependent
  git config branch.$dependent.description "$base;$base_commit"
}

function og_parenttuple(){
  local branch
  if [ $# -eq 0 ]; then
    branch=$(git rev-parse --abbrev-ref HEAD)
  else
    branch=$1
  fi
  git config branch.$branch.description
}

function og_basecommit(){
  local branch
  if [ $# -eq 0 ]; then
    branch=$(git rev-parse --abbrev-ref HEAD)
  else
    branch=$1
  fi
  echo $(og_parenttuple $branch | cut -d';' -s -f2)
}

function og_parent(){
  local branch
  if [ $# -eq 0 ]; then
    branch=$(git rev-parse --abbrev-ref HEAD)
  else
    branch=$1
  fi
  echo $(og_parenttuple $branch | cut -d';' -f1)
}

function og_children(){
  local base_branch
  if [ $# -eq 0 ]; then
    base_branch=$(git rev-parse --abbrev-ref HEAD)
  else
    base_branch=$1
  fi
  git for-each-ref --format='%(refname:short)' refs/heads | while read b; do
    if [ "$(og_parent $b)" = "$base_branch" ]; then
      echo $b
    fi
  done
}

function listchain_helper(){
  local branch=$1
  echo $branch
  local parent=$(og_parent $branch)
  if [ -n "$parent" ]; then
    listchain_helper $parent
  fi
}

function og_upchain(){
  local branch
  if [ $# -eq 0 ]; then
    branch=$(git rev-parse --abbrev-ref HEAD)
  else
    branch=$1
  fi
  listchain_helper $branch
}

function og_downchain(){
  local branch
  if [ $# -eq 0 ]; then
    branch=$(git rev-parse --abbrev-ref HEAD)
  else
    branch=$1
  fi
  local children=$(og_children $branch)

  # if multiple children, print out a special message
  echo $branch
  if [ $(echo $children | wc -w) -gt 1 ]; then
    echo "[multiple children]"
  elif [ -n "$children" ]; then
    og_downchain $children
  fi
}

function og_chain(){
  local branch
  if [ $# -eq 0 ]; then
    branch=$(git rev-parse --abbrev-ref HEAD)
  else
    branch=$1
  fi
  # reverse the order of the upchain, appending a star as the last character on the last line
  og_upchain $branch | (tac 2> /dev/null || tail -r) | sed '$ s/$/*/'
  og_downchain $branch | tail -n +2
}

function og_evolve(){
  # rebase all children on top of the current branch, recursively
  local branch=$(git rev-parse --abbrev-ref HEAD)
  og_children $branch | while read child ; do
    echo "Rebasing $child on $branch"
    local newbase=$(git rev-parse HEAD)
    git checkout $child
    local basecommit=$(og_basecommit $child)
    if [ -z "$basecommit" ]; then
      echo "warning: no base commit found for $child, doing a normal rebase"
      git rebase $branch
      if [ $? -ne 0 ]; then
        echo "Rebase failed, aborting"
        git rebase --abort
        return 1
      fi
    else
      git rebase --onto $branch $basecommit
      if [ $? -ne 0 ]; then
        echo "Rebase failed, aborting"
        git rebase --abort
        return 1
      fi
      # Then rewrite base commit
      git config branch.$child.description "$branch;$newbase"
    fi
    og_evolve
    if [ $? -ne 0 ]; then
      return 1
    fi
  done
  git checkout $branch
}

function og_slog(){
  local branch=$1
  local base=$(og_basecommit $branch)
  if [ -z "$base" ]; then
    echo "warning: no base commit found for $branch, doing a normal log"
    git log $branch
  else
    git log $base..$branch
  fi
}

function og_up(){
  # Move one branch up the chain
  local branch=$(git rev-parse --abbrev-ref HEAD)
  local parent=$(og_parent $branch)
  if [ -n "$parent" ]; then
    git checkout $parent
  else 
    echo "No parent branch"
  fi
}

function og_down(){
  # Move one branch down the chain
  local branch=$(git rev-parse --abbrev-ref HEAD)
  local children=$(og_children $branch)
  # If multiple children, fail
  if [ $(echo $children | wc -w) -gt 1 ]; then  
    echo "Multiple children branches"
    return 1
  fi
  if [ -n "$children" ]; then
    git checkout $children
  else 
    echo "No child branch"
  fi
}

function og_setparent(){
  # Set the parent of the current branch
  local branch=$(git rev-parse --abbrev-ref HEAD)
  local parent=$1
  if [ -z "$parent" ]; then
    echo "Usage: og setparent <parent>"
    return 1
  fi
  echo "How many commits should oniongit consider to be part of this branch?"
  echo $(git log --oneline | head -n 5)
  echo "Enter the number of commits, or leave blank for one commit"
  read num_commits
  if [ -z "$num_commits" ]; then
    num_commits=1
  fi
  local basecommit=$(git rev-parse HEAD~$num_commits)
  git config branch.$branch.description "$parent;$basecommit"
}

function og_markmerged(){
  # Mark the current branch as merged

  local branch=$(git rev-parse --abbrev-ref HEAD)
  # If git disagrees that it's merged, fail
  if ! git branch --merged main | grep -q $branch; then
    echo "Branch $branch is not merged"
    return 1
  fi
  og_children $branch | while read child ; do
    git checkout $child
    og_setparent main
  done
  git checkout $branch
}

function og_downstream(){
  # List all branches that are downstream of the current branch
  if [ ! -z "$1" ]; then
    local branch=$1
  else
    local branch=$(git rev-parse --abbrev-ref HEAD)
  fi
  echo $branch
  og_children $branch | while read child ; do
    og_downstream $child
  done
}

function og_rpush(){
  # Push the current branch and all downstream branches
  local branch=$(git rev-parse --abbrev-ref HEAD)
  og_downstream $branch | while read downstream ; do
    echo "Pushing $downstream"
    git checkout $downstream
    git push origin $downstream --force-with-lease
  done
  git checkout $branch
}

function og_rebase_onto_parent(){
  # Rebase the current branch onto its parent
  local branch=$(git rev-parse --abbrev-ref HEAD)
  local parent=$(og_parent $branch)
  if [ -z "$parent" ]; then
    echo "No parent branch"
    return 1
  fi
  local basecommit=$(og_basecommit $branch)
  if [ -z "$basecommit" ]; then
    echo "warning: no base commit found for $branch, doing a normal rebase"
    git rebase $parent
    if [ $? -ne 0 ]; then
      echo "Rebase failed. Fix it up!!"
      return 1
    fi
  else
    git rebase --onto $parent $basecommit
    if [ $? -ne 0 ]; then
      echo "Rebase failed. Fix it up!!"
      return 1
    fi
  fi
}

function og_insert_base_commits_on_chain(){
  if [ ! -z "$1" ]; then
    local branch=$1
  else
    local branch=$(git rev-parse --abbrev-ref HEAD)
  fi
  local newbase=$(git rev-parse $branch)
  og_children $branch | while read child ; do
    echo "Branch $child: Setting base commit $newbase"
    git config branch.$child.description "$branch;$newbase"
    og_insert_base_commits_on_chain $child
  done
}

function og_remove_base_commits_on_chain(){
  if [ ! -z "$1" ]; then
    local branch=$1
  else
    local branch=$(git rev-parse --abbrev-ref HEAD)
  fi
  og_children $branch | while read child ; do
    git config branch.$child.description "$branch"
    remove_base_commits_on_chain $child
  done
}

function og_set_base_commit_to_parent(){
    if [ ! -z "$1" ]; then
    local branch=$1
  else
    local branch=$(git rev-parse --abbrev-ref HEAD)
  fi
  local parent=$(og_parent $branch)
  if [ -z "$parent" ]; then
    echo "No parent branch"
    return 1
  fi
  git config branch.$branch.description "$parent;$(git rev-parse $parent)"
}