# RepoFabric adoption record — RingoSystems Graphite Forge v1.0

| | |
| --- | --- |
| Document | Design-language adoption record (standard §11, governance and adoption) |
| Product | RepoFabric |
| Owner | RingoSystems Heavy Industries |
| Design standard | RingoSystems Graphite Forge |
| Target version | v1.0 |
| Applies to | `linux/admin/static/**` (the admin console, setup wizard, and operator-facing HTML served by the admin container) |
| Status | Partially adopted — see §9 |
| Working branch | `feat/graphite-forge-ux` |
| Last reviewed | 2026-07-24 |

This is the record for RepoFabric only. It states what the product has adopted, what it has
not, and the rules a change must satisfy before it lands. It is not a copy of the standard;
where the two disagree, the standard wins and this file is wrong and should be corrected.

---

## 1. What Graphite Forge is, and what RepoFabric targets

Graphite Forge is the RingoSystems product design language: a dark-native system built on a
graphite surface ramp with a burnt-copper accent, Inter for human text and Consolas for
machine output, borders-before-shadows depth, and a fixed spacing and radius rhythm. It exists
so that every RingoSystems operator surface — RepoFabric, ConfigFabric, and whatever follows —
reads as one product family rather than as separate tools that happen to be dark.

RepoFabric targets **Graphite Forge v1.0**. The version is pinned deliberately: the vendored
foundation file carries the version in its header, and a bump to v1.1 is a reviewed change to
that file, not an ambient drift in product CSS.

Three properties of the language are load-bearing for RepoFabric specifically, because
RepoFabric is a dense operations console rather than a marketing surface:

1. **Dark-native only.** There is no light mode and no white canvas. `color-scheme: dark` is
   declared once in the foundation. Never add a light theme, a `prefers-color-scheme: light`
   branch, or a white panel. Operators run this on wall displays and in server rooms.
2. **The type split.** Machine output is set in Consolas, human text in Inter. This is what
   makes a table of package identifiers, versions, and byte counts scannable. See §5.
3. **Copper is scarce.** Copper marks intent, selection, and brand. It is not a fill colour.
   A screen where copper appears more than a few times has lost its ability to point at
   anything.

---

## 2. File layering

Load order is the contract. Each layer may consume the layer above it and must not redefine it.

```text
graphite-forge.css        foundation — the vendored standard
      |                   owns: --gf-* tokens, base element styling, gf-* primitives
      v
repofabric-tokens.css     application token map + product primitives
      |                   owns: --surface-*, --text*, --accent, --s-*, --r-*, --fs-*, wg-* classes
      |                   every value expressed in terms of --gf-*
      v
app.css / setup.css /     per-surface layout and behaviour styling
per-page styles           consumes the application tokens; defines no palette
```

Declared in `linux/admin/static/index.html`:

```html
<link rel="stylesheet" href="graphite-forge.css">
<link rel="stylesheet" href="repofabric-tokens.css">
<link rel="stylesheet" href="app.css">
<link rel="stylesheet" href="./app-linux.css">
```

Rules that follow from the layering:

- A page that loads `repofabric-tokens.css` **must** also load `graphite-forge.css`, and load
  it first. The token map is written entirely in `var(--gf-*)`; without the foundation those
  references resolve to nothing and the page falls back to unstyled defaults. Pages currently
  violating this are listed in §9.
- `app.css` and the per-page sheets are the last word on *layout*, never on *palette*.
- Nothing in the layering requires a network fetch. There is no webfont, no icon font, no CDN
  script, and no remote image anywhere in the stack. RepoFabric runs on isolated networks
  behind a strict CSP; an external request would either hang or advertise that the instance
  exists. Inline SVG and text glyphs only.

---

## 3. The token contract

**`--gf-*` is the standard.** Product code consumes it and never redefines it. If a
`--gf-*` value is wrong for every RingoSystems product, that is a change to the standard and
a version bump. If it is wrong only for RepoFabric, it is a change to the application map.

**Application tokens map onto the foundation.** `repofabric-tokens.css` deliberately keeps the
pre-Graphite-Forge token *names* (`--accent`, `--surface-1`, `--text-dim`, `--r-md`, …) so the
several hundred existing `var()` references across `app.css` and the per-page sheets keep
resolving. What changed is what those names resolve *to*. Re-skinning happens in one file, not
in three hundred rules. Keep it that way: adding a name is cheap, renaming one is a JS and CSS
audit.

**Never hardcode a hex in product code.** Not in CSS, not in inline `style=` attributes, not in
JavaScript that sets `element.style.background`, not in inline SVG fills. If a colour is needed
and no token expresses it, add the token to `repofabric-tokens.css` with a comment explaining
what it means semantically — then use it. The only files permitted to contain raw colour
literals are `graphite-forge.css` (it defines the palette) and `repofabric-tokens.css` (where a
literal is unavoidable, e.g. `--surface-3: #0D0E10`, the input well that sits *below* the
panel, and `--bw-egress: #4C5666`, the deliberately recessive chart series).

**One sanctioned exception, with an exit path.** The in-product documentation reader
(`docs-static/docs.css`) restates the `--gf-*` block verbatim. It has to: docs pages are mounted
at `/docs/`, `/admin/docs/` and `/setup/docs/`, are served unauthenticated, exist during
first-run setup, and can only reach the `<mount>-static` directory, so they cannot link
`static/graphite-forge.css` without a server change. The rule for that file is *verbatim mirror,
same names, same numbers, no second opinions* — it is a copy, never a fork. The exception ends
when `server.js` `mountDocs()` exposes the foundation on the `-static` prefix; at that point the
mirrored block is deleted and the docs reader links the two stylesheets in order like
`index.html` does. Do not treat this exception as a precedent for any other surface.

Palette, for reference only — use the token, not the value:

| Role | Token | Value |
| --- | --- | --- |
| Page base | `--gf-bg-base` | `#101113` |
| Shell | `--gf-bg-shell` | `#14171B` |
| Surface | `--gf-surface` | `#16181C` |
| Raised | `--gf-surface-raised` | `#1E222A` |
| Elevated | `--gf-surface-elevated` | `#252932` |
| Text primary / secondary / muted / disabled | `--gf-text-*` | `#F7F9FB` / `#A7B0BE` / `#75808E` / `#505965` |
| Accent (burnt copper) | `--gf-accent` | `#C97A40` |
| Success / Warning / Danger | `--gf-success` / `--gf-warning` / `--gf-danger` | `#52B788` / `#F6C85F` / `#D65A4A` |
| Violet (comparison, anomaly) | `--gf-violet` | `#7B61FF` |
| Data cyan | `--gf-data` | `#6BD6E8` |
| Borders | `--gf-border-default` / `--gf-border-strong` | `rgba(255,255,255,.07)` / `.12` |
| Glass fills | `--gf-surface-glass` / `-hover` | `rgba(255,255,255,.045)` / `.065` |

Spacing is `--s-1..--s-6` = 4 / 8 / 12 / 16 / 22 / 32 px, mapped onto `--gf-space-*`. `--s-7`
(40px) is RepoFabric's one local extension, for page gutters above the 32px step. Radius is
`--r-sm` 8px, `--r-md` 11px (controls), `--r-lg` 18px (cards); the shell uses 20px.

Depth is borders first: a 1px border plus a low-contrast surface shift. Heavy drop shadows and
decorative gradients are out. `--gf-glow-copper` is **ambient only** — hero cards, the selected
preview rail, the brand mark. It is not a hover effect and not a button treatment.

---

## 4. Motion and interaction

Permitted: small translations (the 5px command-row slide), border tinting, opacity changes,
surface lift. Not permitted: bouncing, spinning, scaling, attention-seeking loops. Transitions
run on `--gf-ease` (180ms). `prefers-reduced-motion: reduce` is honoured globally in the
foundation and again per-component where a transform would otherwise survive; any new animation
must add itself to that guard. Information is always carried by text and position, so removing
motion loses nothing.

---

## 5. Typography: the UI face and the data face

This is the rule most often broken, and the one that does the most work.

- **`--font-ui` (Inter)** — anything a *human* wrote: page and section titles, button labels,
  navigation and tab labels, table column headers, form field labels, help text, prose,
  explanatory copy in dialogs, empty-state guidance.
- **`--font-mono` (Consolas)** — anything a *machine* emitted: counts, sizes, durations,
  versions, identifiers, hashes, fingerprints, paths, URLs, timestamps, log lines, status and
  outcome values, and any raw evidence the operator is expected to compare character by
  character.

Both stacks degrade to system faces (Segoe UI / system-ui, Cascadia Mono / ui-monospace). No
webfont ships. That is deliberate, not a shortcut — see §2.

Concrete RepoFabric assignments:

| Element | Face | Why |
| --- | --- | --- |
| `PackageId` cell (e.g. `Microsoft.PowerShell`) | data | Machine identifier; operators diff these visually |
| Repo version, pinned version (`7.6.3`) | data | Machine value, compared digit by digit |
| `Size (MB)`, `Pubs`, `Retention`, `Bytes saved`, `Installs` | data | Quantities; alignment matters |
| Architecture, locale (`x64`, `en-US`) | data | Machine enumerations |
| Activity feed `Time` column, publish timestamps | data | Machine timestamps |
| Activity `Outcome` / `Status` values, ingest `Reason / signature` | data | Machine-emitted state strings |
| Gitea commit sha, manifest path (`manifests/m/Microsoft/PowerShell/7.6.3/…`) | data | Evidence; must be copyable and comparable |
| Ingest client id / RFC 9421 keyid (`kamino`) | data | Machine identifier that doubles as a protocol value |
| Public key fingerprint (SHA-256), bearer token, PKCS#8 PEM block | data | Raw credential material |
| Installer URL, repo hostname | data | Machine location |
| Rail navigation labels (Catalog, Inventory, Activity, Bandwidth, API Clients, Settings, About) | UI | Human-authored navigation |
| Rail group labels (Operate, Measure, Govern) | UI | Human-authored taxonomy |
| Table column headers (`PackageId`, `Track`, `Repo version`) | UI | Header is a label a human wrote, even when the column below is machine output |
| Button labels (Sync selected, Promote selected, Reconcile retention, Revoke) | UI | Human-authored action names |
| Dialog titles and explanatory copy ("Revocation is immediate and permanent…") | UI | Prose |
| Form field labels and hints ("type to search the local upstream index") | UI | Prose |
| Chart axis text | data, muted `#505965` | Machine values on an axis |

The pattern to internalise: **a table is machine output with a human-written header row.**
`.wg-table` sets the whole grid in the data face and re-sets `th` to the UI face. Do not undo
that per-column.

Type scale, all tokenised: display 44–56 / .96, page title 32–40 / 1.05, section heading
18–22 / 1.2, body 15–17 / 1.55, UI label 12–14 / 1.2, metric 24–32 / 1.0, code 12–13 / 1.4.
Display and heading weight is `--gf-weight-display` (760) with tight tracking
(`--gf-tracking-display` -.065em, `--gf-tracking-title` -.045em). Do not set display type at
700 or at the browser default; the heavy-and-tight pairing is a signature of the language.

---

## 6. Modal versus rail

The line the standard draws:

- **Modal** (`<dialog class="modal">`, centred, interrupts): destructive confirmation, high-risk
  configuration change, or a form that needs focused completion. A modal is a demand for the
  operator's full attention, and it should be rare enough to still mean that.
- **Rail** (`<dialog class="modal rail">`, right-hand preview panel): contextual detail that
  helps the operator decide whether to act. Read-mostly. Expands beside the work rather than
  covering it. Ambient copper glow is permitted here — a selected preview panel is one of the
  three places the glow belongs.

Both are native `<dialog>` opened with `showModal()`. The rail is purely a class; adopting it
requires **no JavaScript change**, which is why the classification below is a styling decision
and not a rewrite.

RepoFabric dialog register (`linux/admin/static/index.html`):

| Dialog id | Purpose | Correct form | Current |
| --- | --- | --- | --- |
| `dlg-ingest-register` | Register an RFIP ingest client (form) | Modal | Modal |
| `dlg-ingest-reveal` | One-time bearer token / private key reveal | Modal — must interrupt; credentials are unrecoverable | Modal |
| `dlg-ingest-detail` | Client metadata plus recent ingest audit events (read-only) | **Rail** | Modal (`modal wide`) |
| `dlg-ingest-revoke` | Revoke a client — immediate and permanent | Modal, `is-destructive` | Modal |
| `dlg-reconcile` | Retention preview then destructive prune | Modal, `is-destructive` on the apply step | Modal |
| `vrepo-modal` | Create / edit a virtual repo (form) | Modal | Modal |
| `multirepo-upgrade-modal` | Sandbox limitation explainer (informational) | **Rail** | Modal |
| `compare-modal` | Sandbox vs Recommended comparison (informational) | **Rail** | Modal |
| `promo-modal` | Promote a package to another repo (form, writes to Gitea) | Modal | Modal |
| `dlg-sub` | Add / edit subscription (form) | Modal | Unclassed `<dialog>` |
| `dlg-pkg-preview` | Upstream package detail before subscribing (read-only) | **Rail** | Unclassed `<dialog>` |
| `dlg-custom-edit` | Edit custom-app note (form) | Modal | Unclassed `<dialog>` |
| `dlg-custom-del` | Remove custom app; unpublishes manifests | Modal, `is-destructive` | Unclassed `<dialog>` |
| `dlg-custom-convert` | Convert custom app to a managed subscription; clears the custom binary | Modal, `is-destructive` | Unclassed `<dialog>` |
| `dlg-sub-del` | Remove subscription; unpublishes manifests | Modal, `is-destructive` | Unclassed `<dialog>` |

Unclassed dialogs fall through to the pre-Graphite-Forge generic `dialog` rule in `app.css`
(6px radius, 3px inputs, legacy accent). They are dark, so nothing is unreadable, but they are
not in the language. Adding `class="modal"` is sufficient; no markup restructuring is needed.

Rule for new work: **if the dialog does not change state, it is a rail.** A dialog whose only
button is "Close" or "Got it" has no business interrupting.

---

## 7. Accessibility rules

These are product requirements, not preferences.

1. **Colour is never the only indicator of state.** Every status carries a word, and usually a
   glyph or border, in addition to its hue. `.wg-pill` / `.gf-pill` render a dot plus the state
   text. Destructive dialogs carry a top border (`.is-destructive`) as well as danger-coloured
   buttons. The active rail item carries a copper border, a surface lift, a weight change, and
   a tinted icon — not just a colour. Roughly eight percent of operators have some colour
   vision deficiency; a red-only failure indicator is a broken indicator.
2. **Text on copper is `#101113`.** Copper (`#C97A40`) and the copper-to-green primary gradient
   are light surfaces. White text on them fails contrast. Use `--text-on-accent` /
   `--accent-fg`, both of which resolve to the graphite base. Any rule that sets
   `color: white` on an accent background is a defect.
3. **Focus is always visible.** The foundation sets a 2px copper `:focus-visible` outline with
   2px offset on every interactive element. Do not remove it, and do not replace it with a
   colour change alone.
4. **Motion is optional.** `prefers-reduced-motion` is honoured; see §4.
5. **Keyboard reach.** The admin console provides a skip link to `#main`. New shell regions
   must keep it reachable and must not trap focus outside a `showModal()` dialog.

---

## 8. Charts

One series language across the product: copper (`--gf-chart-series`) for the primary trend,
cyan (`--gf-chart-point`) for data points, violet (`--gf-chart-selected`) for the selected or
anomalous series only, green (`--gf-chart-healthy`) for healthy, a hairline
`rgba(255,255,255,.085)` grid, and axis text in the muted disabled step, set in the data face.
No rainbow palettes and no BI-tool defaults.

RepoFabric has one chart today: the bandwidth savings chart on the Bandwidth tab. Its axis text
is already in the data face and its grid is a dashed hairline. Egress bars use `--bw-egress`, a
deliberately recessive slate: egress is the expected number and must not compete with
peer-cache savings, which is the number the operator came for. Two gaps remain: the savings
bars are filled from an SVG gradient whose stops are hardcoded in `app.js`
(`#5fd49a` / `#3fbf81`) rather than derived from `--bw-peer`, and `--bw-peer` / `--bw-alt` are
defined in the token map but not yet referenced. Both are open work (§9).

---

## 9. Adoption checklist

Marked honestly against the working tree on 2026-07-24 (branch `feat/graphite-forge-ux`).
Unchecked items are open work, not aspirations to be quietly dropped. The open list is a
point-in-time reading of the files named in it; re-verify it before the branch merges, and move
items rather than deleting them so the record shows what was fixed and when.

### 9.1 Foundation

- [x] Graphite Forge v1.0 foundation vendored at `linux/admin/static/graphite-forge.css`, version stated in its header
- [x] Application token map at `linux/admin/static/repofabric-tokens.css`, expressed entirely in `--gf-*`
- [x] No `--gf-*` token redefined in product code
- [x] Spacing re-cut onto 4 / 8 / 12 / 16 / 22 / 32; radius onto 8 / 11 / 18
- [x] No webfont, icon font, or any external asset in the stack
- [x] `prefers-reduced-motion` honoured globally and per-component

### 9.2 Admin console (`index.html`)

- [x] Loads the three layers in the correct order
- [x] Edge-to-edge app shell: sticky topbar plus left rail, replacing the old header-and-tab-strip
- [x] Left rail grouped by operator intent (Operate / Measure / Govern) with muted labels and a copper-tinted border on the active item
- [x] Brand block, product name, and owner line read RingoSystems Heavy Industries
- [x] Skip link to `#main`
- [x] Topbar identity string set in the data face

### 9.3 Entry and secondary surfaces

- [x] `setup/index.html` loads the foundation and the token map, in order
- [x] `connect-entra.html` loads the foundation and the token map, in order
- [x] In-product documentation reader re-cut in the language (`docs-static/docs.css`), with the mirrored foundation block documented and bounded (§3)
- [ ] `publish-custom.html` and `intune-deploy.html` not yet on the correct layering (§9.5)

### 9.4 Primitives

- [x] Card, table, pill, toolbar, field, disclosure, dialog, toast, banner, and input primitives re-cut in the language (`wg-*` in the token layer)
- [x] Tables set in the data face with UI-face uppercase headers, row hover, copper selection inset
- [x] Status pills carry dot plus word, never colour alone
- [x] Rail dialog variant (`dialog.modal.rail`) implemented and available with no JS change

### 9.5 Open

- [ ] `app.css` still opens with a pre-Graphite-Forge `:root` block (line 1) defining the legacy blue accent and grey palette; because it loads after the token map, those declarations win the cascade for every name they repeat. It must be deleted, not amended.
- [ ] Approximately 47 raw colour literals remain in the body of `app.css`
- [ ] `linux/admin/static/app.js` sets ten raw hex values inline; these must move to tokens
- [ ] `app-linux.css` sets `color: white` on `.toolbar a.btn` over the accent background — fails §7.2
- [ ] `dialog menu button.primary` in `app.css` sets `color: white` over the accent — fails §7.2
- [ ] Six dialogs still carry no `modal` class (§6 table)
- [ ] No dialog yet uses `class="modal rail"`; the four read-only detail surfaces are still centred modals
- [ ] `publish-custom.html` and `intune-deploy.html` load `repofabric-tokens.css` **without** `graphite-forge.css`, so every `--gf-*` reference in the map is unresolved on those pages
- [ ] `setup/setup.css` still opens with its own `:root` palette (14 literals). The setup page now loads the foundation and the token map, so this block actively overrides them and must be deleted.
- [ ] `docs-static/docs.css` mirrors the foundation block by necessity (§3). Open work is the permanent fix: expose the foundation on the `-static` mount in `server.js` `mountDocs()`, then delete the mirror and link the layers in order.
- [ ] `connect-entra.html` still carries an inline `<style>` block; it now loads the foundation and token map, so the inline rules should be reduced to layout only, with no palette
- [ ] `multirepo-upgrade-modal` and `compare-modal` use emoji glyphs, which are not part of the language's glyph vocabulary
- [ ] Bandwidth chart not yet re-pointed at the `--gf-chart-*` names
- [ ] No automated guard: nothing in CI fails a pull request that introduces a raw hex or a redefined `--gf-*` token in product CSS
- [ ] Brand mark is a placeholder (§10)
- [ ] No dark-surface contrast audit has been run against the finished screens

---

## 10. Brand mark

The mark in the topbar (`.gf-logo`, a rounded copper-to-green tile carrying the letter `R`) is
an **explicit placeholder**. It exists so the shell has correct geometry, weight, and optical
balance at 34px, not because it is the identity. It will be replaced when the final RingoSystems
identity lands.

Constraints the replacement must satisfy: inline SVG or a locally served asset (no CDN, no
webfont icon), legible at 34px on `#101113`, and it must not introduce a second accent colour.
Until then, do not reproduce the placeholder in documentation, screenshots intended for
publication, or anything a customer would read as final.

---

## 11. Change control

- **Changing a `--gf-*` value or adding a `--gf-*` token** is a change to the standard. It
  affects every RingoSystems product, requires a version bump in the foundation header, and
  should not be made inside a RepoFabric feature branch.
- **Changing what an application token resolves to** is a RepoFabric decision and belongs in
  `repofabric-tokens.css`, with a comment saying what the token means semantically.
- **Adding a colour to a rule** is almost always wrong. Find the token, or add one.
- **Renaming an id, class, `data-` attribute, `name`, or form field** is out of scope for any
  styling change. `app.js` and the server read these. Restyle; do not rewire. Grep before
  touching a selector.
- **Behaviour, endpoints, request payloads, and validation** are not design surface and are not
  changed by design work.

---

## 12. Review checklist for pull requests touching the admin UI

1. Any new hex literal outside the two token files? Reject.
2. Any `--gf-*` token redefined in product CSS? Reject.
3. Machine output set in Inter, or human copy set in Consolas? Fix per §5.
4. New dialog: is it a state change (modal) or detail (rail)? Per §6.
5. Any state conveyed by colour alone? Add the word, glyph, or border.
6. Any text set white on copper or on the primary gradient? Use `--accent-fg`.
7. New motion: does it survive `prefers-reduced-motion: reduce`? Guard it.
8. Any external asset — font, icon set, script, image? Reject; the CSP blocks it and the
   network may not exist.
9. Did any id, class, `data-` attribute, or form field name change? Grep `app.js` and the
   server handlers before merging.
10. Does the page still load the foundation before the token map before the product styles?

---

## Related files

| Path | Role |
| --- | --- |
| `linux/admin/static/graphite-forge.css` | Vendored foundation — the standard |
| `linux/admin/static/repofabric-tokens.css` | Application token map and `wg-*` primitives |
| `linux/admin/static/app.css` | Admin console layout, per-tab styling, app shell |
| `linux/admin/static/app-linux.css` | Linux-fork additions layered on `app.css` |
| `linux/admin/static/index.html` | Admin console; reference implementation of the shell |
| `linux/admin/static/setup/setup.css` | Setup wizard styling — legacy palette still present |
| `linux/admin/static/docs-static/docs.css` | In-product documentation reader; mirrors the foundation block by necessity (§3) |
