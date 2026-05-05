import Link from "next/link";

export default function NotFound() {
  return (
    <div className="flex flex-col items-start gap-4 py-12">
      <span className="inline-flex items-center gap-2 rounded-pill border border-border bg-surface/60 px-3 py-1 text-xs text-text-muted">
        404
      </span>
      <h1 className="text-2xl font-semibold tracking-tight text-text">
        Page not found
      </h1>
      <p className="max-w-prose text-sm text-text-muted">
        The page you&apos;re looking for doesn&apos;t exist yet — or it lives
        somewhere else now.
      </p>
      <Link
        href="/"
        className="mt-2 rounded-md border border-border-strong bg-surface px-4 py-2 text-sm text-text transition-colors duration-fast ease-standard hover:bg-surface-raised"
      >
        Back home
      </Link>
    </div>
  );
}
