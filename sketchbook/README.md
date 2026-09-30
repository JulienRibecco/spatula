# Spatula motion sketchbook

A local banner studio with five generative studies: Orbit, Bloom, Flow, Resonance, and Convergence. The drawings use `../js_port/curve.js`, the repository's existing JavaScript port of Spatula. Flow follows the distance/falloff/gradient model in `field.lua`; it rebuilds each frame deterministically. No external fonts, image assets, network requests, or build step.

From the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1
```

Open <http://127.0.0.1:8765/sketchbook/>. Serve from the repository root so the shared curve module can load. Opening the HTML through `file://` will not load ES modules.

## Studio

- Choose a study; play or scrub its time. Each study remembers its selected moment for the session.
- Switch palettes, set line density, edit the signature, or hide the lettering.
- Enable **Code on the banner** to pair each study with its actual executable composition. The recipe is extracted from the same functions the renderer calls in `recipes.js`; the source panel shows line, character, and distinct Curve-operation counts, copies an importable recipe, and links to the full source. Counts cover the composition, with repetition, sampling, and drawing in `scenes.js`. This uses the JavaScript curve port, not Lua syntax. A direct code-view link is <http://127.0.0.1:8765/sketchbook/?code=1>.
- The photo guide approximates the profile-photo overlap. LinkedIn layouts and crops vary by device; check the actual upload preview.
- Slideshow preview cycles still images every three seconds.
- Save the selected banner as a 1584 × 396 PNG, or download all five and a settings manifest in one ZIP. Export freezes the motion and uses the selected moment of each study. Guides are never exported.
- Appearance preferences persist locally when browser storage is available. Reduced-motion preferences are respected.

Generated exports are written to `exports/` and kept local. The studio can generate new variants at any time.

The selected LinkedIn sequence is in `exports/linkedin/`: Orbit (art), Bloom (code), Flow (art), Resonance (code), and Convergence (art). Its ZIP contains only the five numbered PNGs in upload order. `settings.json` records the chosen moments and per-slide code settings; `index.html` previews the finished selection.

LinkedIn [recommends 1584 × 396 pixels, JPG or PNG, under 8 MB](https://www.linkedin.com/help/linkedin/answer/a568217/). Its [cover slideshow](https://www.linkedin.com/help/linkedin/answer/a7145577) accepts up to five images and is available to Premium Business, Sales Navigator, and Recruiter subscribers. A single image works as a standard cover.

## Verification

Install the sketchbook's optional test dependency, then run the check with Chrome installed:

```sh
npm ci --prefix sketchbook
npm test --prefix sketchbook
```

The check launches a temporary loopback server, exercises the controls and downloads, verifies determinism and scene changes, checks desktop/mobile layout and reduced motion, and writes the default banners, ZIP, and preview captures to `exports/`.
