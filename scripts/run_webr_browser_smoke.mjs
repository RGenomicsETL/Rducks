#!/usr/bin/env node
import { chromium } from 'playwright';

const url = process.env.WEBR_SMOKE_URL || 'http://127.0.0.1:8000/scripts/webr-local-test.html';
const timeoutMs = Number(process.env.WEBR_SMOKE_TIMEOUT_MS || 900000);

function fail(message) {
  console.error(message);
  process.exitCode = 1;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitForServer() {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url, { cache: 'no-store' });
      if (response.ok) return;
      console.log(`Waiting for smoke server: HTTP ${response.status}`);
    } catch (err) {
      console.log(`Waiting for smoke server: ${err.message}`);
    }
    await sleep(5000);
  }
  throw new Error(`Timed out waiting for smoke server at ${url}`);
}

await waitForServer();

const browser = await chromium.launch({ args: ['--no-sandbox'] });
try {
  const page = await browser.newPage();
  page.on('console', (msg) => console.log(`[browser:${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err) => console.log(`[browser:pageerror] ${err.message}`));

  console.log(`Opening ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: timeoutMs });
  await page.click('#run', { timeout: timeoutMs });
  await page.waitForFunction(() => {
    const text = document.querySelector('#log')?.textContent || '';
    return /(^|\n)(PASS|FAIL:)/.test(text);
  }, null, { timeout: timeoutMs });

  const log = await page.locator('#log').textContent({ timeout: 5000 });
  console.log('--- webR smoke log ---');
  console.log(log);
  console.log('--- end webR smoke log ---');

  if (!/(^|\n)PASS(\n|$)/.test(log || '')) {
    fail('webR smoke did not report PASS');
  }
} finally {
  await browser.close();
}
