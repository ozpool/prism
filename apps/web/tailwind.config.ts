import type {Config} from "tailwindcss";

// PRISM theme — sources values from app/tokens.css via CSS custom properties.
// The `<alpha-value>` placeholder lets Tailwind's `bg-canvas/80`, `text-text-muted/60`,
// etc. work alongside the variables.
const rgb = (varName: string) => `rgb(var(${varName}) / <alpha-value>)`;

const config: Config = {
  // PRISM is dark-only; the `dark` class is applied to <html> in
  // `app/layout.tsx`. Class strategy keeps SSR predictable.
  darkMode: "class",
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        canvas: rgb("--color-canvas"),
        surface: rgb("--color-surface"),
        "surface-raised": rgb("--color-surface-raised"),
        border: rgb("--color-border"),
        "border-strong": rgb("--color-border-strong"),
        text: rgb("--color-text"),
        "text-muted": rgb("--color-text-muted"),
        "text-faint": rgb("--color-text-faint"),
        spectrum: {
          violet: rgb("--color-spectrum-violet"),
          indigo: rgb("--color-spectrum-indigo"),
          teal: rgb("--color-spectrum-teal"),
          mint: rgb("--color-spectrum-mint"),
          amber: rgb("--color-spectrum-amber"),
          rose: rgb("--color-spectrum-rose"),
        },
        accent: rgb("--color-accent"),
        success: rgb("--color-success"),
        warning: rgb("--color-warning"),
        danger: rgb("--color-danger"),
      },
      fontFamily: {
        sans: "var(--font-sans)",
        mono: "var(--font-mono)",
      },
      fontSize: {
        xs: "var(--text-xs)",
        sm: "var(--text-sm)",
        base: "var(--text-base)",
        lg: "var(--text-lg)",
        xl: "var(--text-xl)",
        "2xl": "var(--text-2xl)",
        "3xl": "var(--text-3xl)",
        display: "var(--text-display)",
      },
      borderRadius: {
        sm: "var(--radius-sm)",
        md: "var(--radius-md)",
        lg: "var(--radius-lg)",
        xl: "var(--radius-xl)",
        "2xl": "var(--radius-2xl)",
        pill: "var(--radius-pill)",
      },
      boxShadow: {
        card: "var(--shadow-card)",
        popover: "var(--shadow-popover)",
        "glow-violet": "var(--shadow-glow-violet)",
        "glow-mint": "var(--shadow-glow-mint)",
        "glow-rose": "var(--shadow-glow-rose)",
      },
      transitionDuration: {
        fast: "var(--motion-fast)",
        base: "var(--motion-base)",
        slow: "var(--motion-slow)",
      },
      transitionTimingFunction: {
        standard: "var(--easing-standard)",
      },
      backgroundImage: {
        // Hero gradient — the prism refraction itself.
        "spectrum-arc":
          "linear-gradient(135deg, rgb(var(--color-spectrum-violet)) 0%, rgb(var(--color-spectrum-indigo)) 25%, rgb(var(--color-spectrum-teal)) 50%, rgb(var(--color-spectrum-mint)) 75%, rgb(var(--color-spectrum-amber)) 100%)",
      },
    },
  },
  plugins: [],
};

export default config;
