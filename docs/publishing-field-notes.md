# Publishing the player-facing field notes

`site/` is the standalone, buildless GitHub Pages website. It uses local HTML,
CSS, JavaScript and an SVG favicon, with no external fonts, analytics, package
installation or runtime API. Articles and the FAQ remain readable without
JavaScript; JavaScript only adds copy-link buttons with an address-bar fallback.

Preview from the repository root:

```powershell
python -m http.server 8765 --bind 127.0.0.1 --directory site
```

Open `http://127.0.0.1:8765/`. Check a narrow mobile viewport and a desktop
viewport, article anchors, copy-link buttons and FAQ disclosures after edits.

## Deployment

The repository's Pages publishing source is **GitHub Actions**. The
[`pages.yml`](../.github/workflows/pages.yml) workflow publishes only `site/`,
on relevant pushes to `master` or a manual workflow dispatch. Research captures,
artifacts and technical source directories are not included in its artifact.
The deployment environment is `github-pages`. GitHub documents this deployment
pattern in [custom Pages workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

## Writing another update

Add an `<article>` near the top of `site/index.html`, with a unique, stable ID,
a date, a short headline and a link to the reviewed evidence. Give its copy-link
button the same ID in `data-share`. Update the story count, status date and hero
status when appropriate. Preserve existing article IDs so shared links keep
working. Keep the evidence in the repository and the explanation on the site
short enough for someone who just wants their controller and game to work.

These are curated updates from the history, not an automatic rendering of commit
messages. An old commit title can contain an assumption that was later corrected.
Use current reviewed findings, distinguish lab results from player reports, and
mark meaningful corrections with an updated date. A faster API call is not a
measured FPS improvement. No supported download should be advertised until its
release requirements are met.

## Sources for the initial stories

- **Lab finding, October 29:** `0c9370b`, `83c7341`, `9909bbf`, and the
  [VM checklist](vm-validation-checklist.md). Queue reuse, earlier close/API
  comparisons and coarse controller checks; no proven game FPS benefit.
- **Movement and recovery, October 29:** `9909bbf`,
  [active-input evidence](../evidence/runtime/vm-active-input-growth-20261029.json),
  [negative idle comparison](../evidence/runtime/vm-xinput-fresh-reversed-pair-20261029.json)
  and [service recovery](../evidence/runtime/vm-service-recovery-20261029.json).
- **Community report, October 28:** `3f2e5f1`, `5cf42e7`, and the
  [same-session Left 4 Dead 2 comparison](community-capture-20261028-l4d2-pair.md).
  Preserve the distinction between reported FPS and recorded CPU samples.
- **Early tests, October 25; interpretation updated October 29:** `f43b9b2`
  contains the USB/Bluetooth negative results. The
  [current findings](gameinput-service-fault.md) include the later corrections
  concerning waits and the unproven rumble-off assumption.
