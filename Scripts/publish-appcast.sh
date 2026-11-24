#!/usr/bin/env bash
# Commits the appcast in a gh-pages checkout and pushes it.
source "$(dirname "$0")/common.sh"
PAGES="${1:?pages dir}"; VERSION="${2:?version}"
cd "$PAGES" || exit 1
touch .nojekyll
if [[ ! -d .git && ! -f .git ]]; then
  git init -q -b gh-pages
  git remote add origin "$(git -C "$ROOT" remote get-url origin)"
else
  git checkout -q -B gh-pages
fi
cat > index.html <<HTML
<!doctype html><meta charset="utf-8"><title>Meth updates</title>
<meta http-equiv="refresh" content="0; url=https://github.com/$GITHUB_REPO">
<p>Sparkle update feed for <a href="https://github.com/$GITHUB_REPO">Meth</a>: <a href="appcast.xml">appcast.xml</a></p>
HTML
git add appcast.xml index.html .nojekyll
git commit -q -m "Appcast: Meth $VERSION"
git push -q origin gh-pages
