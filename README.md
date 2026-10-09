# localsend.yazi

Send the files selected in [yazi](https://github.com/sxyazi/yazi) to a nearby
device over [LocalSend](https://github.com/localsend/localsend): press a key,
pick a device in an fzf window, hit Enter.

`localsend-cli` has no non-interactive "send to this device" flag — it only
opens its own TUI, where you pick a device with the number keys — so this plugin
talks the LocalSend v2 protocol directly from a small Ruby helper (stdlib only).

## Requirements

- `fzf`
- `ruby` (3.x; stdlib only, no gems)

LocalSend speaks mutual TLS: a receiver aborts the handshake unless the sender
presents a client certificate, and a device's fingerprint is the SHA-256 of that
certificate. The helper generates one on first run with `OpenSSL::X509` and
caches it in `$XDG_CACHE_HOME/localsend-yazi/`. Keep that directory if you want
your fingerprint — and therefore any pairing — to stay stable.

## Install

```sh
ya pkg add tasnimAlam/localsend
```
or

```sh
git clone https://github.com/tasnimAlam/localsend.yazi ~/.config/yazi/plugins/localsend.yazi
```

No build step. Run `ruby test_send.rb` in the plugin directory to check it works.

Then bind a key in `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = "W"
run  = "plugin localsend"
desc = "Send files via LocalSend"
```

## Usage

Select files (or just hover one) and press `shift+w`. The plugin discovers devices,
lists them in fzf, and uploads to whichever you pick. The receiving device shows
its usual accept prompt.

Set `LOCALSEND_ALIAS` to change the name other devices see.

## How discovery works

Two strategies, in order:

1. **Multicast.** One UDP packet to `224.0.0.167:53317`. A device may answer on
   the group, or by POSTing its info to `/api/localsend/v2/register` on the port
   we advertised — the app commonly does the latter — so the scan runs a
   short-lived HTTPS server on 53317 to catch those replies. Fast, and
   independent of subnet size. If a LocalSend app is already running locally it
   owns that port, and this step is skipped.
2. **Subnet sweep**, if multicast returns nothing. `POST
   /api/localsend/v2/register` to every host on the interface's real subnet,
   128 at a time. Anything answering `200` is a device. A `/24` takes about
   three seconds, a `/23` about thirteen.

Both are link-local. `224.0.0.167` sits in the `224.0.0.0/24` control block —
TTL 1, never forwarded by routers — so neither reaches another subnet.

## Limitations

- **Files only.** Directories are rejected; archive them first.
- **The sweep gives up past a `/22`.** It reads the real prefix off the
  interface rather than assuming a `/24`, but beyond 1022 addresses it takes
  longer than anyone will wait, and only multicast will find anything.
- **The sweep only probes port 53317.** A multicast reply carries the sender's
  port, so a device on a custom port is found that way — but the sweep cannot
  guess it.
- **No PIN-protected receivers.** 
