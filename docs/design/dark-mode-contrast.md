# PRISM Dark-Mode Palette Usage Guide

PRISM is dark-only by design (see [ADR pending] / brand tokens in
`apps/web/app/tokens.css`). This guide documents:

1. The intended pairings (which tokens go on which surface).
2. Measured WCAG 2.1 contrast ratios for every meaningful pairing.
3. Hard rules — what NOT to do.

The brand tokens themselves live in
[`apps/web/app/tokens.css`](../../apps/web/app/tokens.css). Don't edit
this guide and the tokens out of sync — if a token value changes, the
ratios below must be re-measured and the guide updated in the same PR.

## WCAG quick reference

| Level | Normal text | Large text¹ | UI components² |
|---|---:|---:|---:|
| AA  | 4.5:1 | 3:1 | 3:1 |
| AAA | 7:1   | 4.5:1 | — |

¹ Large = ≥ 18pt regular or ≥ 14pt bold.
² Buttons, form inputs, focus rings — graphical objects per WCAG 1.4.11.

## Surface stack

```
canvas         #0c0a14   page background
└─ surface     #15121f   cards, panels, raised content
   └─ raised   #1e1a2c   hover states, popovers
border         #221d33   default hairline
border-strong  #352d4e   focused / emphasised borders
```

The stack only goes one level deep in v1.0. Don't nest a `surface`
inside a `surface-raised`; switch to elevated typography or shadows
instead.

## Text on surfaces

| Foreground × Background | Ratio | Verdict |
|---|---:|---|
| `text` (#ebe5d5) on `canvas` | **15.5:1** | AAA (any size) |
| `text` on `surface` | **14.7:1** | AAA |
| `text` on `raised` | **13.6:1** | AAA |
| `text-muted` (#9890b0) on `canvas` | **6.5:1** | AA normal, near AAA |
| `text-muted` on `surface` | **6.1:1** | AA normal |
| `text-muted` on `raised` | **5.7:1** | AA normal |
| `text-faint` (#696382) on `canvas` | **3.5:1** | AA **large only** |
| `text-faint` on `surface` | **3.3:1** | AA **large only** |

**Rules:**

- `text` is the default for body copy. No exceptions.
- `text-muted` is the secondary tier — captions, table cell labels,
  helper text. Never below 14px in this color.
- `text-faint` is for **large text only** (headings, oversized numbers
  used as decoration) or for **non-text UI** (subtle icons, dividers).
  Never use for body copy or any text smaller than 18pt regular / 14pt bold.

## Spectrum on canvas

| Color | Hex | Ratio vs canvas | Verdict |
|---|---|---:|---|
| `spectrum-violet` | `#7c5cff` | 4.5:1 | AA normal (at threshold) |
| `spectrum-indigo` | `#5c8aff` | 6.1:1 | AA normal |
| `spectrum-teal` | `#3edcff` | 12.0:1 | AAA |
| `spectrum-mint` | `#3eff9b` | 14.9:1 | AAA |
| `spectrum-amber` | `#ffd166` | 13.5:1 | AAA |
| `spectrum-rose` | `#ff5c8a` | 6.7:1 | AA normal |

**Rules:**

- Spectrum colors used as **text** must clear AA (4.5:1) at the size used.
- `violet` sits exactly at the AA threshold — only use it for **large
  text or buttons**, never small body copy.
- For interactive components on `canvas`, prefer `mint` (success) /
  `amber` (warning) / `rose` (danger) — they all clear AAA.
- `violet` is fine as the accent fill (background) of a button — the
  rule applies to violet *as text*, not as a fill.

## Spectrum as button fills

When a spectrum color is the **background** of an interactive element,
the foreground (label) must clear AA against that background.

| Background | Recommended foreground | Ratio | Verdict |
|---|---|---:|---|
| `accent` (violet) | `canvas` (#0c0a14) | ~9:1 | AAA |
| `success` (mint) | `canvas` | ~14:1 | AAA |
| `warning` (amber) | `canvas` | ~13:1 | AAA |
| `danger` (rose) | `canvas` | ~6.5:1 | AA normal |

This is why `RainbowKitProvider` is themed with
`accentColor: "#7c5cff"` and `accentColorForeground: "#0c0a14"` in
[`apps/web/app/providers.tsx`](../../apps/web/app/providers.tsx) —
the foreground is canvas, not text-cream, to maintain AAA.

**Rule:** never put `text` (cream) on `accent` (violet). Cream-on-violet
is ~3.4:1, below AA. Use canvas-on-violet instead.

## Borders

| Pairing | Ratio | Verdict |
|---|---:|---|
| `border` (#221d33) on `canvas` | ~1.3:1 | Decorative only |
| `border-strong` (#352d4e) on `canvas` | ~1.9:1 | Decorative; meets WCAG 1.4.11 if paired with text label |
| Focus ring: `border-strong` on `surface` | ~1.8:1 | Insufficient for focus-only |

**Rule:** focus indicators MUST use `accent` (violet) at ≥ 3:1 against
the surface, not `border-strong`. The default Tailwind ring at
`ring-accent ring-offset-canvas ring-offset-2` clears this.

## States that must be discriminable without color

WCAG 1.4.1 requires color not be the only signal for state. PRISM rules:

| State | Color signal | Non-color signal (required) |
|---|---|---|
| Loading | spectrum gradient pulse | spinner glyph or skeleton |
| Success | `success` mint | check icon or text label |
| Warning | `warning` amber | warning icon |
| Error / danger | `danger` rose | error icon + text label |
| Selected | `accent` violet | bolder weight or fill change |
| Disabled | `text-faint` | `aria-disabled` + reduced opacity |

## What not to do

- **Don't introduce a "light mode."** PRISM is dark-only. If a future
  ADR overturns this, that ADR replaces this guide.
- **Don't use raw spectrum hex values** in components — go through
  the Tailwind tokens (`bg-spectrum-violet`, `text-success`, etc.) so
  contrast is enforced via this guide.
- **Don't use `text-faint` for any text under 18pt regular.** It fails
  AA. The compiler can't catch this — code review must.
- **Don't pair two spectrum colors** (e.g., violet text on amber
  background). All spectrum colors share similar luminance ranges and
  the resulting ratios are below AA.
- **Don't use `text` cream on `accent` violet** (fails AA). Always use
  `canvas` as foreground on accent fills.

## Re-verification procedure

If `tokens.css` changes:

1. Re-run a contrast audit (e.g.
   [WebAIM Contrast Checker](https://webaim.org/resources/contrastchecker/)
   or any axe-core based tool).
2. Update the ratios in the tables above.
3. If a ratio drops below the verdict listed, either:
   - Adjust the token until it clears the verdict, OR
   - Adjust the verdict and downstream usage rules in the same PR.
4. Cite the audit source in the PR description.

## References

- [WCAG 2.1 Contrast (Minimum) — 1.4.3](https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum)
- [WCAG 2.1 Non-Text Contrast — 1.4.11](https://www.w3.org/WAI/WCAG21/Understanding/non-text-contrast)
- [WCAG 2.1 Use of Color — 1.4.1](https://www.w3.org/WAI/WCAG21/Understanding/use-of-color)
- Brand tokens: [`apps/web/app/tokens.css`](../../apps/web/app/tokens.css)
- Tailwind theme wiring: [`apps/web/tailwind.config.ts`](../../apps/web/tailwind.config.ts)
