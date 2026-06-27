# Lumen website

A static showcase site for the Lumen language — pure HTML/CSS/JS, **no build step
and no compiler required**.

## Files

- `index.html` — landing page (hero, features, quickstart)
- `examples.html` — runnable example programs
- `stdlib.html` — standard-library reference
- `style.css` — styling
- `highlight.js` — tiny self-contained syntax highlighter

## Local preview

Just open `index.html` in a browser, or serve the folder:

```sh
python3 -m http.server -d website 8000
# open http://localhost:8000
```

## Cloudflare Pages

Connect the repo and configure:

- **Build command:** *(leave empty)*
- **Build output directory:** `website`
- **Framework preset:** None

Cloudflare serves the folder as-is. Pushing to the production branch redeploys.
