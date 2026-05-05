import type {Config} from "tailwindcss";

const config: Config = {
  // PRISM is dark-only; the `dark` class is applied to <html> in
  // `app/layout.tsx`. Class strategy keeps SSR predictable.
  darkMode: "class",
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      // Real brand tokens land in #1 (apps/web/styles/tokens.css /
      // tailwind theme extend). This file ships with empty extends
      // so #1 can drop them in without churn.
    },
  },
  plugins: [],
};

export default config;
