import Link from "next/link";

export function Logo({className = ""}: {className?: string}) {
  return (
    <Link
      href="/"
      className={`group inline-flex items-center gap-2 ${className}`}
      aria-label="PRISM home"
    >
      <span
        aria-hidden
        className="h-5 w-5 rounded-md bg-spectrum-arc shadow-glow-violet transition-shadow duration-base ease-standard group-hover:shadow-glow-mint"
      />
      <span className="bg-spectrum-arc bg-clip-text text-lg font-semibold tracking-tight text-transparent">
        PRISM
      </span>
    </Link>
  );
}
