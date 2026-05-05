export function Footer() {
  return (
    <footer className="mt-auto border-t border-border bg-canvas/60">
      <div className="mx-auto flex max-w-6xl flex-col items-start justify-between gap-2 px-4 py-6 text-xs text-text-muted md:flex-row md:items-center">
        <p>
          PRISM v0.0.0 — Base Sepolia testnet only. Mainnet release gated on
          M5 audit.
        </p>
        <div className="flex items-center gap-4">
          <a
            href="https://github.com/ozpool/prism"
            target="_blank"
            rel="noreferrer noopener"
            className="transition-colors duration-fast ease-standard hover:text-text"
          >
            GitHub
          </a>
          <span aria-hidden className="opacity-50">
            •
          </span>
          <span>BUSL-1.1</span>
        </div>
      </div>
    </footer>
  );
}
