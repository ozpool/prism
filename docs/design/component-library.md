# PRISM Component Library Spec

shadcn/ui aligned, dark-only, brand-tokenised. This document is the
**design contract** for the components the dApp uses (and the Figma
mirror image). It pairs with [`docs/design/dark-mode-contrast.md`](./dark-mode-contrast.md)
for color rules and [`apps/web/app/tokens.css`](../../apps/web/app/tokens.css)
for the underlying token values.

The implementation lands incrementally as features need each component;
this spec is what every PR adding or changing a component must conform
to.

## Architecture

PRISM uses [shadcn/ui](https://ui.shadcn.com) — components are copied
into the repo (`apps/web/components/ui/*.tsx`), not installed as a
package. Customisation happens by editing the copy.

**Why shadcn:**

- Each component is a few hundred lines of Radix UI + Tailwind. We can
  read and audit the whole thing.
- No version coupling — bumping shadcn itself is a no-op; bumping a
  specific component is an explicit copy-paste.
- Styles are in our Tailwind config, not in a black-box stylesheet.

**Why not [chosen alternative]:**

- MUI / Chakra: heavy runtime, hard to thin, opinionated theming
- Headless UI alone: leaves us writing too much from scratch
- Pure custom: fine for 5 components, painful for 20

## Component inventory

The following components are in scope for v1.0. Build order matches
PRD-driven feature work, not alphabetical.

| Component | Wraps | First consumer | Status |
|---|---|---|---|
| `Button` | shadcn `button` | header connect, deposit/withdraw forms | spec only |
| `Input` | shadcn `input` | deposit/withdraw amount fields | spec only |
| `Card` | shadcn `card` | VaultCard on list page (#49) | spec only |
| `Dialog` | shadcn `dialog` | confirm-deposit modal | spec only |
| `Toast` | shadcn `sonner` | tx success/error notifications | spec only |
| `Tooltip` | shadcn `tooltip` | hover hints (sharePrice, MEV bonus) | spec only |
| `Tabs` | shadcn `tabs` | vault detail (positions / events / params) | spec only |
| `Skeleton` | shadcn `skeleton` | loading states for vault data | spec only |
| `Badge` | shadcn `badge` | network indicators, vault tags | spec only |

Out of scope for v1.0 (revisit post-launch):

- `Combobox`, `DatePicker`, `Calendar` — no need yet
- `DataTable` — vault list is small; rebuild as a `<table>` if needed
- `Slider` — no slider-driven inputs in v1.0

## Per-component contracts

### Button

**Variants** (Tailwind classes; align to brand tokens):

| Variant | Foreground | Background | Border | Use for |
|---|---|---|---|---|
| `primary` | `canvas` | `accent` | none | Deposit, Withdraw, Confirm |
| `secondary` | `text` | `surface-raised` | `border-strong` | Cancel, secondary CTAs |
| `ghost` | `text-muted` | `transparent` | none | Inline links, "Show more" |
| `danger` | `canvas` | `danger` | none | Destructive confirm in modal |
| `outline` | `text` | `transparent` | `border` | Form-level secondary |

**Sizes:** `sm` (h-8), `md` (h-10, default), `lg` (h-12 — hero CTA only).

**States:**

- `:hover` — fill brightens by 4-6% (Tailwind opacity utilities)
- `:focus-visible` — `ring-2 ring-accent ring-offset-canvas ring-offset-2`
- `:disabled` — `opacity-60 cursor-not-allowed`, retains color (no greyscale)
- `:loading` — replaces children with a `Spinner`; button is `aria-busy="true"`

**Accessibility:**

- Always render an HTML `<button>` (no `<div role="button">`)
- Loading state must announce to screen readers via `aria-busy`
- Min hit target 40×40 — enforce via `min-h-10 min-w-10` even when content is small

### Input

**Variants:**

| Variant | Use for |
|---|---|
| `default` | Standard text/number input |
| `address` | 0x-address input — monospace, 0.5x letter-spacing |
| `amount` | Token amount — right-aligned, mono, large step counter |

**States:**

- `:focus-within` — `border-accent`
- `:invalid` (or with `aria-invalid="true"`) — `border-danger`, helper text below in `text-danger`
- `:disabled` — `opacity-60`

Always pair with `<Label>`. Required fields get `*` suffix in the label,
not a placeholder hint.

**Slots:** prefix (e.g., `$`), suffix (e.g., `WETH`), `MAX` button (token
amounts only). All slots are tokenised — no inline color overrides.

### Card

**Default style:**

- `bg-surface`, `border border-border`, `rounded-xl`, `shadow-card`
- Padding: 20px (`p-5`), or 24px (`p-6`) for hero cards

**Hover:** `hover:shadow-glow-violet hover:border-border-strong` —
applied to interactive cards (links to detail). Static metric cards do
not animate on hover.

**Compound layout:**

```tsx
<Card>
  <Card.Header>
    <Card.Title>Vault name</Card.Title>
    <Card.Description>Subtitle</Card.Description>
  </Card.Header>
  <Card.Content>{...}</Card.Content>
  <Card.Footer>{...}</Card.Footer>
</Card>
```

The `.Title` always uses `text-base font-medium` (not larger) — vault
names compete with TVL numbers for visual weight, and the spec is that
TVL wins.

### Dialog (modal)

- Backdrop: `bg-canvas/70 backdrop-blur-sm`
- Surface: `bg-surface-raised`, `border border-border-strong`,
  `rounded-2xl`, `shadow-popover`, max-width 480px
- Close affordance: top-right `Button[ghost]` with X icon, `aria-label="Close"`
- Animations: `data-[state=open]:animate-in data-[state=open]:fade-in`
  (200ms, standard easing). Reduced-motion users see no animation.

**Body structure:**

```
Header  : title (text-lg) + description (text-sm text-muted)
Body    : 16-24px vertical rhythm
Footer  : button row, right-aligned, primary CTA last
```

**Focus:** focus moves to the first interactive element on open;
`Escape` and click-outside both close (dismissable). For destructive
confirmation modals (e.g., big withdrawals), require explicit confirm
button click — set `dismissable={false}` and remove the X close.

### Toast

Powered by [Sonner](https://sonner.emilkowal.ski) via shadcn's `sonner`
component. Position: bottom-right. Stack vertical, max 4 visible.

| Variant | Icon | Foreground | Background | Use for |
|---|---|---|---|---|
| `success` | check | `canvas` | `success` | Deposit confirmed, withdraw landed |
| `error` | x-circle | `canvas` | `danger` | Tx rejected, network mismatch |
| `info` | info | `text` | `surface-raised` | Fee changed, oracle stale warning |
| `warning` | alert | `canvas` | `warning` | Approaching TVL cap |

**Duration:**

- success: 4s
- info: 6s
- warning: 8s
- error: persistent (manual dismiss) — error must not disappear before the user reads it

**Tx hash toasts:** the toast for a confirmed tx includes a "View on
Basescan" inline link. Clicking the link does not dismiss the toast.

### Tooltip

- 200ms open delay, 0ms close delay
- `bg-surface-raised`, `border border-border-strong`, `text-xs`,
  `rounded-md`, `px-2 py-1`, `shadow-popover`
- Always pair with the trigger element via `aria-describedby`

Use sparingly — tooltips hide information from touch users. Reserve for
*supplementary* hints (e.g., explaining what "share price" means);
never put critical info behind a hover.

### Tabs

- Underline-style indicator (not pill-style) — minimises visual weight
  vs the surface
- Active: `text-text border-b-2 border-accent`
- Inactive: `text-text-muted hover:text-text`
- Use for: vault detail (Positions / Rebalances / Strategy params)
- Avoid for: anything where horizontal space is tight

### Skeleton

- `bg-surface-raised`, `animate-pulse` (Tailwind built-in)
- Shape matches the loaded content's layout — never use a generic
  block. Skeleton for a TVL number is `w-24 h-7`; skeleton for an
  address is `w-32 h-4`
- Reduced-motion: replace pulse with static `bg-surface-raised`

### Badge

| Variant | Use for |
|---|---|
| `neutral` | "Base Sepolia testnet" header chip |
| `success` | "Active" vault |
| `warning` | "Paused" vault |
| `danger` | "Wrong network" |
| `accent` | "New" or "Featured" tag |

Compact only — height 20px, padding `px-2`. Use `text-xs font-medium`.

## Implementation rules

- Component files live in `apps/web/components/ui/<name>.tsx`
- Re-exports are explicit — no barrel files; downstream code imports
  from the file directly
- Never use `style={{...}}` for color or spacing; go through Tailwind +
  brand tokens
- Forward refs always: every component takes `React.ForwardRef`. Required
  for headless UI compatibility and Radix portals.
- Each component must accept `className` and merge it via the
  `cn()`/clsx utility, so consumer code can extend without forking

## What changes the spec

Add a new variant or component? Update this file in the same PR.
Remove a variant? Same. Drop a component? Same. The Figma is downstream
of this doc — when they conflict, this doc wins.
