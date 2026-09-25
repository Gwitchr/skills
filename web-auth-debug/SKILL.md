---
name: web-auth-debug
description: Inspect a web app's authenticated API traffic without extracting credentials, for a local dev server or a deployed dev/staging app. Open a separate Chrome on a throwaway profile with a CDP endpoint, headless when the project can mint a sign-in link, headed in the background only when a human must type credentials, and attach playwright-cli; then read requests, console output, and page state, and delete the profile when done. Never bypasses or mocks the real sign-in flow (any OAuth or OpenID Connect provider), never opens the user's own browser profile, and never extracts, stores, reuses, or echoes cookies or tokens. Encodes the playwright-cli practice of attaching over CDP, inspecting with requests and request <index>, and detaching, not closing. Use when a route needs sign-in before a request can be inspected, when the user asks to "debug the authenticated frontend", "inspect requests after login", "attach playwright to my browser", or when an app answers 401 and reproducing it needs a real session.
---

# web-auth-debug

Open a debugging browser beside the user's normal one: a separate Chrome on a profile directory that exists only for this debugging run, with a Chrome DevTools Protocol (CDP) endpoint that playwright-cli attaches to. It runs headless when the project can mint a sign-in link, and headed, launched in the background, only when a human must type credentials: a window exists only for a human sign-in. The user types any credentials; the agent inspects the signed-in session and never handles them.

TRIGGER when: a web app calls an authenticated API and a request, response, console error, or page state can only be seen after sign-in; or the user asks to debug or inspect an authenticated app, whether it runs on a local dev server or a deployed dev or staging environment.

> **Stack assumed.** Google Chrome or Chromium, and `playwright-cli` on PATH. When `playwright-cli` is missing, ask the user to install it; never install it, or anything else, yourself.

> **Notation.** `<port>` is the local dev server's port and `<route>` the path under investigation; replace both with the project's real values. For a deployed dev or staging app, replace the whole `http://localhost:<port>` origin with that environment's URL.

> **Precedence.** Project conventions in `AGENTS.md` or `CLAUDE.md` win, including a project's own debugging workflow.

## Hard rules

- Never bypass the app's sign-in, add mock authentication, or special-case a route for local testing. The bug under investigation lives in the real flow, whatever OAuth or OpenID Connect provider backs it; a mocked flow hides it.
- Never extract, store, reuse, or echo credentials. Cookies and tokens stay inside the browser; when quoting a request in any output, redact the values of `Authorization` and `Cookie` headers.
- Never attach to the user's everyday browser or reuse its profile. A throwaway profile keeps their real sessions out of reach and makes cleanup one deletion.
- Sign-in belongs to the user. Never ask for credentials and never type them.
- Only navigate the session to the app under investigation: a local origin, or the deployed dev or staging environment the user names. The redirect the app itself performs to its sign-in provider is expected; unrelated sites are never the agent's navigation target, and production only when the user explicitly asks for it.
- This workflow inspects the app at the browser boundary. When an API request fails, read that request and its response here instead of querying the database behind the API; the browser shows what the app actually sent.

**Focus rules:**

- Prefer headless whenever the project prints a sign-in link (for example a `dev:login` script); the headed window exists only for a human to type credentials.
- Never call `page.bringToFront()`, `tab-select` or `tab-new` on a headed session; each raises the window over the user's work.
- Never use `resize` on a headed session; change the viewport only in headless mode.
- Never relaunch a profile in the other mode expecting the session to survive; it does not.
- One profile directory and one port per persona (9222, 9223, ...); all headless unless a human must sign in.

## Workflow

1. When debugging a local run, start the frontend (and the API, when the bug needs a local one) the way the project's own docs say to; a deployed dev or staging app needs no setup.
2. Open Chrome with a fresh throwaway profile and a CDP endpoint. Delete any leftover profile first, so an earlier run's signed-in session never leaks into this one. Pick the mode before sign-in, because a signed-in session does not survive relaunching the same profile in the other mode. On macOS:

   ```sh
   # A. Sign-in is scripted (the project prints a magic link): no window at all.
   rm -rf "${TMPDIR:-/tmp}/debug-browser-profile"
   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
     --headless=new \
     --user-data-dir="${TMPDIR:-/tmp}/debug-browser-profile" \
     --remote-debugging-port=9222 \
     --no-first-run --no-default-browser-check \
     --window-size=1440,900 about:blank >/dev/null 2>&1 &

   # B. A human must sign in: headed, launched in the background.
   rm -rf "${TMPDIR:-/tmp}/debug-browser-profile"
   open -g -na 'Google Chrome' --args \
     --user-data-dir="${TMPDIR:-/tmp}/debug-browser-profile" \
     --remote-debugging-port=9222 \
     --no-first-run --no-default-browser-check \
     --window-size=1440,900 about:blank
   ```

   Without the two prompt flags Chrome asks to become the default browser on every fresh profile, and without `-g` the headed window lands in front of the user's work. On Linux, both variants take the same flags with `google-chrome` or `chromium` run in the background. If port 9222 is taken, pick another and use it in the next step too.

3. Attach playwright-cli and open the local route under investigation:

   ```sh
   playwright-cli attach --cdp=http://127.0.0.1:9222 --session=debug-browser
   playwright-cli -s=debug-browser goto http://localhost:<port>/<route>
   ```

4. Variant B only: ask the user to sign in inside the headed window, and wait for their word that they are done. For variant A, navigate the session to the link the project's script printed, and never paste that link into any output.
5. Inspect the signed-in session:

   ```sh
   playwright-cli -s=debug-browser requests            # numbered list of network requests
   playwright-cli -s=debug-browser request <index>     # full detail of one request
   playwright-cli -s=debug-browser console
   playwright-cli -s=debug-browser snapshot
   ```

   These commands, like `goto` and `click`, leave a headed window where it is. Remember the redaction rule when quoting any of this output.

6. When finished, detach (this leaves the browser running), kill the debug Chrome by its profile path, and delete the throwaway profile so no signed-in session survives the debugging. A headless Chrome has no window for the user to quit, so the kill covers both variants; the pattern includes the full profile path so the user's own Chrome is never matched:

   ```sh
   playwright-cli -s=debug-browser detach
   pkill -f -- "--user-data-dir=${TMPDIR:-/tmp}/debug-browser-profile"
   rm -rf "${TMPDIR:-/tmp}/debug-browser-profile"
   ```

Most sign-in providers redirect back to the exact origin that started the flow, so when running locally, use one hostname consistently: localhost or 127.0.0.1, not a mix.
