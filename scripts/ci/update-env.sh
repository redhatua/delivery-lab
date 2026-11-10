#!/usr/bin/env bash
# Commits the new image digest to env/main. Needs GIT_USER and GIT_TOKEN.
set -euo pipefail
: "${SOURCE_SHA:?}" "${GIT_USER:?}" "${GIT_TOKEN:?}"
GITEA="${GITEA:-http://192.168.77.10:3000}"
HERE="$(cd "$(dirname "$0")" && pwd)"
export GIT_ASKPASS="$HERE/askpass.sh" GIT_TERMINAL_PROMPT=0
DIGEST=$(cat .ci/digest)
VERSION=$(cat VERSION)
rm -rf .ci/env
git clone -q "${GITEA}/${GIT_USER}/env.git" .ci/env
cd .ci/env
git config user.name "jenkins"
git config user.email "jenkins@lab.invalid"
FILE=environments/lab/values.yaml
sed -i "s|^  digest:.*|  digest: ${DIGEST}|" "$FILE"
if git diff --quiet; then
  echo "env already at ${DIGEST}"
else
  git commit -q -am "release ${VERSION}: ${DIGEST:0:19} (source ${SOURCE_SHA:0:8})"
  pushed=
  for i in 1 2 3; do
    if git push -q origin HEAD:main; then pushed=1; break; fi
    git pull -q --rebase origin main || true
  done
  [[ -n "$pushed" ]] || { echo "could not push the release commit to env/main" >&2; exit 1; }
  # what we record must really be on the remote branch
  git fetch -q origin main
  git merge-base --is-ancestor HEAD FETCH_HEAD || { echo "release commit is not on env/main" >&2; exit 1; }
fi
git rev-parse HEAD > ../env_commit
echo "env commit $(cat ../env_commit)"
