// Minimal MV3 background service worker for the harness test fixture.
chrome.runtime.onInstalled.addListener(() => {
  console.log('harness fixture extension installed');
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  try {
    sendResponse({ ok: true, received: message });
  } catch (e) {
    console.error('message handling failed', e);
  }
  return true;
});
