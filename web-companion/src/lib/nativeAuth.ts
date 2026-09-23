/** Matches the iOS oauth-signin / oauth-result bridge. */
export type NativeOAuthProvider = "google" | "apple";
type Tokens = { access_token: string; refresh_token: string };
type NativeOAuthResult = ({ ok: true } & Tokens) | { ok: false; error: string };
const HANDLER = "oauth-signin";
let inFlight = false;

export function isNativeIOSApp(): boolean {
  if (typeof window === "undefined") return false;
  const handlers = (window as any).webkit?.messageHandlers;
  return !!(handlers?.["iap-purchase"] || handlers?.[HANDLER]) ||
    /DreamLanguageApp/i.test(navigator.userAgent || "");
}

export function hasNativeOAuth(): boolean {
  return typeof window !== "undefined" && !!(window as any).webkit?.messageHandlers?.[HANDLER];
}

export function nativeOAuthSignIn(
  provider: NativeOAuthProvider,
  redirectUri: string,
  timeoutMs = 180_000,
): Promise<Tokens> {
  if (!hasNativeOAuth()) return Promise.reject(new Error("native oauth bridge unavailable"));
  if (inFlight) return Promise.reject(new Error("sign-in already in progress"));
  inFlight = true;
  return new Promise((resolve, reject) => {
    let settled = false;
    const cleanup = () => {
      inFlight = false;
      window.removeEventListener("oauth-result", onResult);
      clearTimeout(timer);
    };
    const onResult = (event: Event) => {
      if (settled) return;
      const result = (event as CustomEvent<NativeOAuthResult>).detail;
      settled = true;
      cleanup();
      if (result?.ok && typeof result.access_token === "string" && result.access_token &&
          typeof result.refresh_token === "string" && result.refresh_token) {
        resolve({ access_token: result.access_token, refresh_token: result.refresh_token });
      } else {
        reject(new Error(result?.ok === false ? result.error : "native sign-in failed"));
      }
    };
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error("native sign-in timed out"));
    }, timeoutMs);
    window.addEventListener("oauth-result", onResult);
    try {
      (window as any).webkit.messageHandlers[HANDLER].postMessage({provider, redirect_uri: redirectUri});
    } catch (error) {
      settled = true;
      cleanup();
      reject(error instanceof Error ? error : new Error("native bridge error"));
    }
  });
}
