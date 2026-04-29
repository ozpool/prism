"use client";

import Link from "next/link";
import {usePathname} from "next/navigation";

const LINKS = [
  {href: "/", label: "Vaults"},
  {href: "/rebalances", label: "Rebalances"},
  {href: "/docs", label: "Docs"},
] as const;

export function Nav() {
  const pathname = usePathname();
  return (
    <nav aria-label="Primary" className="hidden md:block">
      <ul className="flex items-center gap-6 text-sm">
        {LINKS.map(({href, label}) => {
          const active = pathname === href || (href !== "/" && pathname.startsWith(href));
          return (
            <li key={href}>
              <Link
                href={href}
                className={`transition-colors duration-fast ease-standard ${
                  active ? "text-text" : "text-text-muted hover:text-text"
                }`}
                aria-current={active ? "page" : undefined}
              >
                {label}
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
