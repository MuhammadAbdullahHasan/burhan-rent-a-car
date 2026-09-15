#!/usr/bin/env sh
# Builds the release web bundle and publishes it to the gh-pages branch.
# Usage: deploy/publish_gh_pages.sh [repo-name]   (default: burhan-rent-a-car)
set -eu
REPO_NAME="${1:-burhan-rent-a-car}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT/app"
flutter build web --release --base-href "/$REPO_NAME/"
cp build/web/index.html build/web/404.html   # SPA fallback for deep links
touch build/web/.nojekyll                    # serve files verbatim

WORKTREE="$(mktemp -d)"
cd "$ROOT"
git worktree prune
# The branch is rebuilt from scratch every publish; drop any local copy so
# the orphan checkout below never collides with a previous run.
git branch -D gh-pages >/dev/null 2>&1 || true
git worktree add --detach "$WORKTREE" >/dev/null 2>&1
cd "$WORKTREE"
git checkout -q --orphan gh-pages
git rm -rfq . >/dev/null 2>&1 || true
cp -R "$ROOT/app/build/web/." .
git add -A
git -c user.name="$(git -C "$ROOT" config user.name)" \
    -c user.email="$(git -C "$ROOT" config user.email)" \
    commit -q -m "Publish web build $(date -u +%Y-%m-%dT%H:%MZ)"
git -c http.postBuffer=157286400 push -f origin gh-pages
cd "$ROOT"
git worktree remove --force "$WORKTREE"
git branch -D gh-pages >/dev/null 2>&1 || true
echo "Published to gh-pages."
