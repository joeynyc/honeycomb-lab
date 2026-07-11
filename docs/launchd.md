# Running the gateway as a service (launchd)

Make the gateway start at login and restart if it ever dies. Save this as
`~/Library/LaunchAgents/com.honeycomb.gateway.plist`, adjusting the two
paths for your checkout and (optionally) the PATH line for your `lms`
install:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.honeycomb.gateway</string>
    <key>ProgramArguments</key>
    <array>
        <string>/PATH/TO/honeycomb-lab/gateway/start.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/PATH/TO/honeycomb-lab/gateway</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/Users/YOU/.lmstudio/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/tmp/honeycomb-gateway.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/honeycomb-gateway.log</string>
</dict>
</plist>
```

Manage it:

```bash
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.honeycomb.gateway.plist  # start
launchctl kickstart -k gui/$UID/com.honeycomb.gateway   # restart (after config edits)
launchctl bootout gui/$UID/com.honeycomb.gateway        # stop
```

Notes:
- `KeepAlive` restarts the gateway if it crashes; `ThrottleInterval`
  stops a broken config from spinning (the gateway also refuses to
  crash-loop on a missing `config.json` — it falls back to the example
  and logs what to do).
- Add `Honeycomb.app` to System Settings → Login Items to bring the map
  up at login too.
