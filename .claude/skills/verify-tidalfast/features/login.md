# Login against the mock

With no saved login the app shows a login screen. TIDALfast logs in with a device code or with TIDAL's Android PKCE flow, where the user pastes the redirect address. The login is saved in the Keychain and restored at the next start. `docs/tidal-data.md` has the details.

## Sub-features

- `login-pkce`: the PKCE login completes and the library loads.
- `login-restore`: a second launch restores the saved login without the login screen.
- `login-device`: the device-code login, approved by the mock about 3 s after the first poll.
- `login-revoked`: a revoked login returns to the login screen (mock `-revoke-after=N`).

## How to get to it (user POV)

- Start the app with no saved login and follow the login screen.

## Driving it with verify.sh

- **PKCE at start.** Any mock run logs in through `TIDALFAST_PKCE_REDIRECT`. `app.log` shows `POST .../oauth2/token: HTTP 200`, then `GET .../sessions` and `GET .../users/123`. Capture at 3 s to see the library.
- **Restore.** Run two mock runs without `cleanup` between them. Both use the same `tidalfast-verify-*` item from `/tmp/tidalfast-verify/run/keychain`. The second run's `app.log` has no `POST .../oauth2/token` before the library requests.
- **Login screen.** To see the screen itself, the run needs no saved login and no `TIDALFAST_PKCE_REDIRECT`. `verify.sh` always sets the redirect, so this sub-feature has no recipe yet. Report it as not covered.
- **Revoked login.** Stop the mock with `$V mock-stop`, start `/tmp/tidalfast-verify/bin/mock_tidal -port=0 -revoke-after=20` by hand, and write its URL and PID to `/tmp/tidalfast-verify/run/mock.url` and `mock.pid` so `run` and `cleanup` pick it up.

## Gotchas

- Never run these recipes against real TIDAL or with `TIDALFAST_KEYCHAIN=tidalfast`.
- The app logs no token, Authorization header or redirect address. A log line with one is a bug to report.
- `cleanup` deletes the test keychain item, so the next mock run logs in fresh.
