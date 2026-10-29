"use strict";

const status = document.getElementById("share-status");
let statusTimer;
for (const button of document.querySelectorAll("[data-share]")) {
  button.hidden = false;
  button.addEventListener("click", async () => {
    const url = new URL(window.location.href);
    url.hash = button.dataset.share;
    try {
      if (!navigator.clipboard?.writeText) throw new Error("Clipboard unavailable");
      await navigator.clipboard.writeText(url.href);
      status.textContent = "Update link copied.";
    } catch {
      // The address remains shareable when clipboard access is unavailable.
      window.location.hash = button.dataset.share;
      status.textContent = "This update is now in the address bar. Copy the address to share it.";
    }
    clearTimeout(statusTimer);
    statusTimer = setTimeout(() => { status.textContent = ""; }, 5500);
  });
}
