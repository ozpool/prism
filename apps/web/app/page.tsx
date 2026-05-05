export default function HomePage() {
  return (
    <div className="flex flex-col items-start gap-10 py-12">
      <header className="flex flex-col gap-4">
        <span className="inline-flex items-center gap-2 rounded-pill border border-border bg-surface/60 px-3 py-1 text-xs text-text-muted">
          <span className="h-1.5 w-1.5 rounded-pill bg-spectrum-mint" />
          Base Sepolia testnet
        </span>
        <h1 className="bg-spectrum-arc bg-clip-text text-display font-semibold tracking-tight text-transparent">
          PRISM
        </h1>
        <p className="max-w-2xl text-lg text-text-muted">
          Permissionless automated liquidity management on Uniswap V4. One LP
          deposit, refracted into N tick-range positions — rebalanced on
          volatility, paid for by MEV.
        </p>
      </header>

      <section className="grid w-full grid-cols-1 gap-4 md:grid-cols-3">
        <Card title="Vaults" body="Create or deposit into permissionless ALM vaults. Coming online with M2." />
        <Card title="Rebalances" body="Trigger and watch on-chain rebalances. Surface lands with M3." />
        <Card title="MEV-funded" body="Hook captures arb deltas at every swap and routes them back to LPs." />
      </section>
    </div>
  );
}

function Card({title, body}: {title: string; body: string}) {
  return (
    <article className="rounded-xl border border-border bg-surface p-5 shadow-card transition-shadow duration-base ease-standard hover:shadow-glow-violet">
      <h3 className="mb-2 text-sm font-medium text-text">{title}</h3>
      <p className="text-sm text-text-muted">{body}</p>
    </article>
  );
}
