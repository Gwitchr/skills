---
name: web-auth-debug
description: Inspect a web app's authenticated API traffic without extracting credentials, for a local dev server or a deployed dev/staging app. Open a separate headed Chrome using a throwaway profile and a Chrome DevTools Protocol (CDP) endpoint, attach playwright-cli, and let the user sign in by hand; then read requests, console output, and page state through the attached session, and delete the profile when done. Never bypasses or mocks the app's real sign-in flow (any OAuth or OpenID Connect provider), never opens the user's own browser profile, and never extracts, stores, reuses, or echoes cookies or tokens. Encodes the playwright-cli session practice: attach over CDP instead of launching, inspect with requests and request <index>, detach rather than close. Use when a route requires sign-in before a request can be inspected, when the user asks to "debug the authenticated frontend", "inspect requests after login", "attach playwright to my browser", or when an app answers 401 and reproducing it needs a real session.
---

# web-auth-debug

Open a debugging browser beside the user's normal one: a headed Chrome (a browser with a visible window, not headless), a profile directory that exists only for this debugging run, and a Chrome DevTools Protocol (CDP) endpoint that playwright-cli attaches to. The user does the sign-in; the agent inspects the signed-in session and never handles credentials.

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

## Workflow

1. When debugging a local run, start the frontend (and the API, when the bug needs a local one) the way the project's own docs say to; a deployed dev or staging app needs no setup.
2. Open a headed Chrome with a fresh throwaway profile and a CDP endpoint. Delete any leftover profile first, so an earlier run's signed-in session never leaks into this one. On macOS:

   ```sh
   rm -rf "${TMPDIR:-/tmp}/debug-browser-profile"
   open -na 'Google Chrome' --args \
     --user-data-dir="${TMPDIR:-/tmp}/debug-browser-profile" \
     --remote-debugging-port=9222
   ```

   On Linux, run `google-chrome` or `chromium` in the background with the same two flags. If port 9222 is taken, pick another and use it in the next step too.

3. Attach playwright-cli and open the local route under investigation:

   ```sh
   playwright-cli attach --cdp=http://127.0.0.1:9222 --session=debug-browser
   playwright-cli -s=debug-browser goto http://localhost:<port>/<route>
   ```

4. Ask the user to sign in inside the headed window, and wait for their word that they are done.
5. Inspect the signed-in session:

   ```sh
   playwright-cli -s=debug-browser requests            # numbered list of network requests
   playwright-cli -s=debug-browser request <index>     # full detail of one request
   playwright-cli -s=debug-browser console
   playwright-cli -s=debug-browser snapshot
   ```

   Remember the redaction rule when quoting any of this output.

6. When finished, detach (this leaves the browser running), have the user quit the debug Chrome window, and delete the throwaway profile so no signed-in session survives the debugging:

   ```sh
   playwright-cli -s=debug-browser detach
   rm -rf "${TMPDIR:-/tmp}/debug-browser-profile"
   ```

Most sign-in providers redirect back to the exact origin that started the flow, so when running locally, use one hostname consistently: localhost or 127.0.0.1, not a mix.
