/**
 * Placeholder landing page — proves the scaffold renders end-to-end.
 *
 * #47 replaces this with the full app shell (header + nav + footer +
 * error boundary) once the design tokens (#1) and providers (#44)
 * are in place.
 */
export default function HomePage() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-6 px-6 text-center">
      <h1 className="text-4xl font-semibold tracking-tight">PRISM</h1>
      <p className="max-w-prose text-lg opacity-80">
        Permissionless automated liquidity management on Uniswap V4. One LP deposit refracted into N tick-range
        positions.
      </p>
      <p className="text-sm opacity-50">App shell + wallet connect coming online in subsequent issues.</p>
    </main>
  );
}
