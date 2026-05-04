import {expect, test} from "@playwright/test";

/// A real-looking checksum address. The vault detail page renders a
/// placeholder vault for any valid address until #31 (VaultFactory)
/// + the data layer wire-up land.
const SAMPLE_VAULT = "0xdeAdbeefdEadBEefdEADbeEFDEadBeeFDEaDBeEf";

test.describe("happy path — read-only walkthrough", () => {
  test("home page renders the PRISM hero", async ({page}) => {
    await page.goto("/");

    await expect(page.getByRole("heading", {name: "PRISM"})).toBeVisible();
    await expect(page.getByText("Base Sepolia testnet")).toBeVisible();
    await expect(
      page.getByText(/Permissionless automated liquidity management/i),
    ).toBeVisible();
  });

  test("/vaults shows the empty state when no vaults are deployed", async ({page}) => {
    await page.goto("/vaults");

    await expect(page.getByRole("heading", {name: "Vaults"})).toBeVisible();
    // Placeholder fetcher returns []; UI should land on the empty state.
    await expect(page.getByRole("heading", {name: "No vaults yet"})).toBeVisible();
  });

  test("/vaults/[address] composes the full detail page", async ({page}) => {
    await page.goto(`/vaults/${SAMPLE_VAULT}`);

    // Header renders the placeholder pair name + the address as mono.
    await expect(page.getByRole("heading", {name: "WETH / USDC"})).toBeVisible();
    await expect(page.getByText(SAMPLE_VAULT)).toBeVisible();

    // Three metric cards.
    await expect(page.getByText("TVL", {exact: true})).toBeVisible();
    await expect(page.getByText("APR (24h)")).toBeVisible();
    await expect(page.getByText("Share price")).toBeVisible();

    // Positions section.
    await expect(page.getByRole("heading", {name: "Positions"})).toBeVisible();

    // Deposit + withdraw forms render with the placeholder vault gate.
    await expect(page.getByRole("region", {name: "Deposit"})).toBeVisible();
    await expect(page.getByRole("region", {name: "Withdraw"})).toBeVisible();

    // Submit button on each form is disabled with the gate copy
    // because the placeholder vault address is `address(0)`.
    const depositBtn = page
      .getByRole("region", {name: "Deposit"})
      .getByRole("button", {name: /Vault not deployed|Connect wallet/});
    await expect(depositBtn).toBeDisabled();

    const withdrawBtn = page
      .getByRole("region", {name: "Withdraw"})
      .getByRole("button", {name: /Vault not deployed|Connect wallet/});
    await expect(withdrawBtn).toBeDisabled();
  });

  test("vault detail accepts amount input on the deposit form", async ({page}) => {
    await page.goto(`/vaults/${SAMPLE_VAULT}`);

    const deposit = page.getByRole("region", {name: "Deposit"});
    const wethInput = deposit.getByLabel("WETH");
    await wethInput.fill("1.5");
    await expect(wethInput).toHaveValue("1.5");

    // Slippage preset toggle keeps the form responsive.
    await deposit.getByRole("button", {name: "1.00%"}).click();
    // Highlighted state — the button gains the accent border via
    // `border-accent`. We assert via class presence as a cheap check.
    await expect(deposit.getByRole("button", {name: "1.00%"})).toHaveClass(/border-accent/);
  });
});
