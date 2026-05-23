# autoclaw-output-check-patcher

Reversible local patcher for the AutoClaw desktop app.

It disables AutoClaw's local output replacement check in the Electron client by patching `app.asar`:

- main process: `agentOutputCheck` returns a local non-sensitive result
- renderer process: the message-complete output replacement hook is short-circuited

The OpenClaw gateway and model provider settings are not changed.

## Usage

Quit AutoClaw first, then run:

```bash
git clone https://github.com/YOUR_NAME/autoclaw-output-check-patcher.git
cd autoclaw-output-check-patcher
bash patch-autoclaw.sh
```

If AutoClaw is installed somewhere else:

```bash
AUTOCLAW_APP_PATH="/path/to/AutoClaw.app" bash patch-autoclaw.sh
```

For automated testing against a copied app bundle only, you can bypass the running-process guard:

```bash
AUTOCLAW_SKIP_RUNNING_CHECK=1 AUTOCLAW_APP_PATH="/tmp/AutoClawCopy.app" bash patch-autoclaw.sh
```

## Restore

The script creates a timestamped backup under:

```text
/Applications/AutoClaw.app/Contents/Resources/autoclaw-patcher-backups/
```

At the end of a successful run, it prints the exact restore command, for example:

```bash
cp '/Applications/AutoClaw.app/Contents/Resources/autoclaw-patcher-backups/app.asar.20260523-180000.bak' '/Applications/AutoClaw.app/Contents/Resources/app.asar'
```

## Notes

- Tested against the AutoClaw layout where the app bundle contains `Contents/Resources/app.asar`.
- Requires Node.js and `npx`.
- On macOS, the script attempts an ad-hoc `codesign` after repacking the app.
- AutoClaw updates may replace `app.asar`; rerun the patcher after updating.
