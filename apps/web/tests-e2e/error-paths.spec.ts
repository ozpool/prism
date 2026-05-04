import {expect, test} from "@playwright/test";

const VALID_VAULT = "0xdeAdbeefdEadBEefdEADbeEFDEadBeeFDEaDBeEf";

test.describe("error paths", () => {
  test("invalid vault address routes to 404", async ({page}) => {
    const res = await page.goto("/vaults/0xnotanaddress");

    // Next.js App Router renders the 404 page with a 404 status.
    expect(res?.status()).toBe(404);
    await expect(page.getByRole("heading", {name: "Page not found"})).toBeVisible();
  });

  test("unknown route renders the global 404", async ({page}) => {
    const res = await page.goto("/this-route-does-not-exist");

    expect(res?.status()).toBe(404);
    await expect(page.getByRole("heading", {name: "Page not found"})).toBeVisible();
    await expect(page.getByRole("link", {name: "Back home"})).toBeVisible();
  });

  test("deposit submit stays disabled with empty inputs", async ({page}) => {
    await page.goto(`/vaults/${VALID_VAULT}`);

    const deposit = page.getByRole("region", {name: "Deposit"});
    // Inputs left empty; gate copy reads "Vault not deployed" because
    // the placeholder vault is address(0). Either way, button is
    // disabled.
    const submit = deposit
      .getByRole("button", {name: /Vault not deployed|Connect wallet|Enter|Insufficient/});
    await expect(submit).toBeDisabled();
  });

  test("withdraw submit stays disabled with empty inputs", async ({page}) => {
    await page.goto(`/vaults/${VALID_VAULT}`);

    const withdraw = page.getByRole("region", {name: "Withdraw"});
    const submit = withdraw
      .getByRole("button", {name: /Vault not deployed|Connect wallet|Enter|Exceeds/});
    await expect(submit).toBeDisabled();
  });

  test("deposit input rejects non-numeric characters", async ({page}) => {
    await page.goto(`/vaults/${VALID_VAULT}`);

    const deposit = page.getByRole("region", {name: "Deposit"});
    const wethInput = deposit.getByLabel("WETH");
    await wethInput.fill("abc1.2.3xyz");
    // Sanitiser keeps digits + a single decimal point.
    await expect(wethInput).toHaveValue("1.23");
  });

  test("withdraw rejects non-numeric share input", async ({page}) => {
    await page.goto(`/vaults/${VALID_VAULT}`);

    const withdraw = page.getByRole("region", {name: "Withdraw"});
    const sharesInput = withdraw.getByLabel("Shares");
    await sharesInput.fill("oops42");
    await expect(sharesInput).toHaveValue("42");
  });

  test("vault detail address is shown verbatim", async ({page}) => {
    await page.goto(`/vaults/${VALID_VAULT}`);

    // Even with no on-chain data, the address itself round-trips
    // through the URL into the header. Catches a regression where
    // the page silently substitutes a different address.
    await expect(page.getByText(VALID_VAULT)).toBeVisible();
  });
});
