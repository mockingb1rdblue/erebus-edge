/**
 * @law Pragmatic Law — solving the full problem once is always faster than
 * deferring it. This gate exists because catching failures here is strictly
 * cheaper than catching them downstream. Never weaken, skip, or defer.
 * See: docs/constitutions/pragmatic-law.md
 */

import { describe, it, expect } from 'vitest';
import { withBrowser } from './browser.setup';

describe('e2e smoke', () => {
  it('opens a browser', async () => {
    await withBrowser(async (driver) => {
      await driver.get('about:blank');
      const title = await driver.getTitle();
      expect(title).toBeDefined();
    });
  }, 30000);
});
