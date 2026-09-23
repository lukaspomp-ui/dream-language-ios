/* Standalone relay: no React, Supabase, analytics, network calls or storage. */
(() => {
  "use strict";
  const status = document.getElementById("status");
  const button = document.getElementById("return");
  if (window.top !== window || location.origin !== "https://dream-language.lovable.app") {
    status.textContent = "Open sign-in from the Dream Language iPhone app.";
    return;
  }
  const url = new URL(location.href);
  const query = url.searchParams;
  const fragment = new URLSearchParams(url.hash.slice(1));
  const expected = query.get("native_state");
  // Remove credentials before any UI interaction. No arbitrary redirect target.
  history.replaceState(null, "", url.pathname);
  if (query.getAll("native_state").length !== 1 || !/^[a-f0-9]{64}$/.test(expected || "")) {
    status.textContent = "This sign-in link has expired. Start again in the app.";
    return;
  }
  const output = new URLSearchParams({state: expected});
  const get = name => {
    const values = [...query.getAll(name), ...fragment.getAll(name)];
    if (values.length > 1) throw new Error("ambiguous_response");
    return values[0];
  };
  try {
    if (get("state") !== expected) throw new Error("state_mismatch");
    if (get("error")) throw new Error("provider_error");
    const access = get("access_token");
    const refresh = get("refresh_token");
    if (!access || !refresh) throw new Error("missing_tokens");
    output.set("access_token", access);
    output.set("refresh_token", refresh);
  } catch {
    output.set("error", "oauth_failed");
  }
  const callback = "app.lovable.dream-language://oauth/callback#" + output.toString();
  button.href = callback;
  button.hidden = false;
  status.textContent = "Returning to Dream Language. If needed, tap Return to app.";
  location.replace(callback);
})();
