# fatop-global.com

Export marketing website for **Teamwork Automation / FaTop Automation**
(協群自動化機械股份有限公司), Taichung, Taiwan — founded 1992. Automation
equipment for brushed, brushless (BLDC) and universal motor production.

Published via GitHub Pages from this repository.

> ⚠️ **This repository is PUBLIC.** Everything committed here is world-readable.
>
> Only original, publishable website content belongs here: markup, styles, scripts,
> and imagery the client owns or has cleared. Working notes and any third-party
> reference material stay **local only** and are never committed or pushed.

## Approval gate — do not push without it

**Nothing is pushed without the client's explicit approval, every time.** Images and
written copy in particular must be reviewed and approved by the client before any
push. Commit locally, show the client what changed, wait for a clear yes.

An approval for one push does not carry over to the next.

## How the site is built

There is no Node and no usable Python on this machine, so the generator is
PowerShell and the output is plain static HTML that GitHub Pages serves with no
build step of its own.

```
src/data/       site.json, catalogue.json — facts and copy
src/templates/  layout.html + one template per page type
src/assets/     css/, js/ — copied to assets/ verbatim
build.ps1       generator; writes output to the repository root
```

```bash
powershell -NoProfile -File site/build.ps1 -Serve -Port 8080
```

`-Clean` removes only what the generator owns, so hand-maintained root files
(CNAME, README) survive. Templates use `{{key}}`, `{{{raw}}}`, `{{#each list}}`
and `{{#if key}}` — the engine is at the top of `build.ps1`.

**Generated output is committed.** GitHub Pages serves the repository root, so
`index.html`, `assets/`, `sitemap.xml` and `robots.txt` must be in git even
though they are build artefacts.

### PowerShell scripts must be ASCII, saved with a UTF-8 BOM

The system ANSI codepage on this machine is Big5. In a BOM-less script,
PowerShell 5.1 decodes non-ASCII bytes as double-byte characters that **swallow
the following ASCII character** — a `…` in a comment silently ate a `{` and
broke the parser. Keep scripts ASCII-only and save them with a BOM.

## Build conventions

- **All images WebP.** ImageMagick 7.1.2 is installed (`magick`). Provide
  responsive `srcset`, lazy-load below the fold, and set explicit `width`/`height`
  to prevent layout shift.
- **Fully responsive** on every page. Buyers browse on phones on the factory floor.
- **Semantic HTML.** Specifications must be real `<table>` markup with proper
  headers — never images of tables, never CSS grids pretending to be tables.
- **Schema.org**: `Product` and `Organization` markup, unique title and meta per
  page built around model number plus capability.
- **Accessibility**: WCAG 2.1 AA. Visible focus states, adequate contrast, alt text
  that describes what the machine does.
- **Performance budget**: LCP under 2.5s on 4G, CLS under 0.1, total JS under
  150KB gzipped.
- **Motion**: restrained, and always respect `prefers-reduced-motion`.

## Environment

- No Node, no real Python (the `python.exe` on PATH is the Microsoft Store stub,
  exits 9009).
- Tooling is **PowerShell 5.1** + ImageMagick. No `&&`, no ternary `?:`, no `??`.

## Git

This repo uses a **local** git identity (`FactoryTopTaiwan`) rather than a global
one, so it cannot be confused with any other project on this machine. Do not set a
global git identity.
