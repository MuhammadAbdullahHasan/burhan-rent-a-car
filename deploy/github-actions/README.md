# GitHub Actions deployment (staged)

`deploy-web.yml` is the CI workflow: it runs both test suites, builds the
release web bundle with the correct GitHub Pages base path, and deploys.

It is kept here rather than under `.github/workflows/` because GitHub only
accepts workflow files pushed with a token carrying the `workflow` OAuth
scope, which the current credential lacks. To activate it:

```sh
gh auth refresh -s workflow        # grant the scope once
git mv deploy/github-actions/deploy-web.yml .github/workflows/deploy-web.yml
git commit -m "Enable GitHub Actions deployment" && git push
```

Then switch Pages to *Source: GitHub Actions* in the repository settings.
Until then the site is published from the `gh-pages` branch (see
`deploy/publish_gh_pages.sh`).
