# Code Signing

ClaudeHUD is signed with a local self-signed certificate so that macOS TCC grants
(Accessibility, Calendars, Contacts, Screen Recording, etc.) persist across rebuilds.

## Files

- `claudehud-dev.p12` — cert + private key (password: `claudehud`)
- `claudehud-dev-cert.pem` — public cert only

## Installing on a new machine

```bash
security import signing/claudehud-dev.p12 \
    -k ~/Library/Keychains/login.keychain-db \
    -P claudehud \
    -A -T /usr/bin/codesign -T /usr/bin/security
```

Then rebuild. `project.yml` has `CODE_SIGN_IDENTITY: "ClaudeHUD Dev"` so Xcode will
pick up the identity automatically.

## Verifying

```bash
security find-identity -v -p codesigning | grep ClaudeHUD
codesign -dvv /Applications/ClaudeHUD.app 2>&1 | grep Authority
```

The designated requirement will be pinned to the cert hash, meaning TCC treats every
rebuild as the same app.
