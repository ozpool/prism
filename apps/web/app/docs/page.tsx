import Link from "next/link";

interface DocLink {
  title: string;
  description: string;
  href: string;
  external?: boolean;
}

const SECTIONS: {heading: string; links: DocLink[]}[] = [
  {
    heading: "Product",
    links: [
      {
        title: "Walkthrough",
        description: "End-to-end product tour with screenshots — basic to advanced features.",
        href: "https://github.com/ozpool/prism/blob/main/docs/walkthrough/index.html",
        external: true,
      },
      {
        title: "PRD v1.0",
        description: "Original product requirements doc that drove the M0–M5 plan.",
        href: "https://github.com/ozpool/prism/blob/main/docs/PRISM_PRD_v1.0.html",
        external: true,
      },
    ],
  },
  {
    heading: "Architecture",
    links: [
      {
        title: "ADR-002 — Hook scoping",
        description: "Which V4 hook permissions PRISM needs and why.",
        href: "https://github.com/ozpool/prism/blob/main/docs/adrs/ADR-002-hook-scoping.md",
        external: true,
      },
      {
        title: "ADR-003 — Oracle strategy",
        description: "Chainlink fail-soft, sequencer gate, deviation thresholds.",
        href: "https://github.com/ozpool/prism/blob/main/docs/adrs/ADR-003-oracle-strategy.md",
        external: true,
      },
      {
        title: "ADR-004 — Flash accounting",
        description: "V4 unlock callback control flow.",
        href: "https://github.com/ozpool/prism/blob/main/docs/adrs/ADR-004-flash-accounting.md",
        external: true,
      },
      {
        title: "ADR-005 — Strategy purity",
        description: "Why IStrategy is pure / stateless / vault-agnostic.",
        href: "https://github.com/ozpool/prism/blob/main/docs/adrs/ADR-005-strategy-purity.md",
        external: true,
      },
      {
        title: "ADR-006 — Immutable core",
        description: "No proxies, no upgrades; rotation = redeploy.",
        href: "https://github.com/ozpool/prism/blob/main/docs/adrs/ADR-006-immutable-core.md",
        external: true,
      },
      {
        title: "ADR-007 — Gas budget",
        description: "Hook ≤30k, rebalance ≤700k, beforeSwap ≤18k.",
        href: "https://github.com/ozpool/prism/blob/main/docs/adrs/ADR-007-gas-budget.md",
        external: true,
      },
    ],
  },
  {
    heading: "Operations",
    links: [
      {
        title: "Deploy runbook",
        description: "Pre-deploy gate, broadcast, post-deploy, rollback.",
        href: "https://github.com/ozpool/prism/blob/main/docs/deploy-runbook.md",
        external: true,
      },
      {
        title: "Incident runbook",
        description: "Severity matrix, on-call, SEV-1/2 playbooks.",
        href: "https://github.com/ozpool/prism/blob/main/docs/runbook.md",
        external: true,
      },
      {
        title: "Monitoring",
        description: "Sentry projects + Tenderly alert rule definitions.",
        href: "https://github.com/ozpool/prism/blob/main/docs/monitoring.md",
        external: true,
      },
      {
        title: "Test plan",
        description: "Six-layer pre-deploy test plan + preflight runner.",
        href: "https://github.com/ozpool/prism/blob/main/docs/test-plan.md",
        external: true,
      },
    ],
  },
  {
    heading: "Design",
    links: [
      {
        title: "Component library",
        description: "Shared UI primitives spec.",
        href: "https://github.com/ozpool/prism/blob/main/docs/design/component-library.md",
        external: true,
      },
      {
        title: "Dark-mode contrast",
        description: "WCAG contrast guide.",
        href: "https://github.com/ozpool/prism/blob/main/docs/design/dark-mode-contrast.md",
        external: true,
      },
      {
        title: "Vault list spec",
        description: "Layout + 4 card states.",
        href: "https://github.com/ozpool/prism/blob/main/docs/design/vault-list.md",
        external: true,
      },
    ],
  },
];

export default function DocsPage() {
  return (
    <section className="flex flex-col gap-8 py-2">
      <header className="flex flex-col gap-2">
        <h1 className="text-3xl font-semibold tracking-tight text-text">Docs</h1>
        <p className="max-w-2xl text-base text-text-muted">
          Architecture decisions, operational runbooks, and design specs. Source-of-truth lives in the repo.
        </p>
      </header>

      {SECTIONS.map((section) => (
        <div key={section.heading} className="flex flex-col gap-3">
          <h2 className="text-xs uppercase tracking-wider text-text-muted">{section.heading}</h2>
          <ul className="grid gap-3 md:grid-cols-2">
            {section.links.map((link) => (
              <li key={link.href}>
                <DocCard link={link} />
              </li>
            ))}
          </ul>
        </div>
      ))}
    </section>
  );
}

function DocCard({link}: {link: DocLink}) {
  const Comp = (link.external ? "a" : Link) as React.ElementType;
  const props = link.external
    ? {href: link.href, target: "_blank", rel: "noreferrer noopener"}
    : {href: link.href};
  return (
    <Comp
      {...props}
      className="group flex flex-col gap-1 rounded-xl border border-border bg-surface/60 p-4 transition-colors duration-fast ease-standard hover:border-border-strong hover:bg-surface"
    >
      <span className="text-sm font-semibold text-text">
        {link.title}
        {link.external && <span className="ml-1 text-text-faint group-hover:text-text-muted">↗</span>}
      </span>
      <span className="text-xs text-text-muted">{link.description}</span>
    </Comp>
  );
}
