import { Builder, Browser, WebDriver } from 'selenium-webdriver';

export type BrowserName = 'safari' | 'chrome' | 'firefox';

export async function createDriver(browser: BrowserName = 'safari'): Promise<WebDriver> {
  const browserMap: Record<BrowserName, string> = {
    safari: Browser.SAFARI,
    chrome: Browser.CHROME,
    firefox: Browser.FIREFOX,
  };
  return new Builder().forBrowser(browserMap[browser]).build();
}

export async function withBrowser(
  fn: (driver: WebDriver) => Promise<void>,
  browser: BrowserName = 'safari'
): Promise<void> {
  const driver = await createDriver(browser);
  try {
    await fn(driver);
  } finally {
    await driver.quit();
  }
}
