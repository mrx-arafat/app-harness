// TODO: tighten permissions before shipping — planted smells for the quality scanner.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // no try/catch here on purpose — planted extension-unguarded-listener smell
  const fn = new Function('return 1');
  console.log('eval-ish usage', fn());
  sendResponse({ ok: true });
});
