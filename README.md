# norns-guix

[norns](https://monome.org/norns) on Guix, without Docker: packages for
norns (desktop build), libmonome, libgpiod 1.x and sc3-plugins, and a Guix
Home service that runs norns as your own Shepherd services.

    herd start norns     # crone, SuperCollider and matron
    herd stop norns

Audio goes through PipeWire's JACK, and the norns screen is a window on
your desktop.

## Using it

Add the service to your home configuration and put this repository on the
load path (`guix home reconfigure -L ~/git/norns-guix ...`):

```scheme
(use-modules (norns-guix home services norns))

(service home-norns-service-type
         (home-norns-configuration
          ;; optional: use an existing dust (scripts, data, audio)
          (dust-directory "~/git/norns-desktop/dust")))
```

Options (`home-norns-configuration`):

| field | default | |
|---|---|---|
| `directory` | `~/.local/share/norns` | norns' home (see below) |
| `dust-directory` | `#f` | existing dust to link in; otherwise a fresh one |
| `sc-extensions` | `(list sc3-plugins)` | SuperCollider extension packages |
| `supercollider-startup` | four outputs | `startup.scd` (4deck's headphone cue uses outputs 3-4) |
| `repl-address` | `"127.0.0.1"` | where the matron/sclang REPLs (5555/5556) listen; `"*"` for every interface |
| `pipewire` | `pipewire` | whose `pw-jack` runs the audio processes; `#f` for plain JACK |
| `log-directory` | `~/.local/var/log` | `norns-crone.log`, `norns-sclang.log`, `norns-matron.log` |
| `auto-start?` | `#f` | start at login |

### The screen and keys

The matron window takes these keys when focused:

| keys | |
|---|---|
| Q, A, Z | K1, K2, K3 |
| W / E | E1 left / right |
| S / D | E2 left / right |
| X / C | E3 left / right |

Closing the window does nothing; stop norns with `herd stop norns`.

### norns' home

norns finds everything through `$HOME` (`~/norns`, `~/dust`,
`~/matronrc.lua`, sclang's config), so the services run with `HOME` and the
XDG directories pointing at `~/.local/share/norns`. That keeps norns out of
your real home and away from your own SuperCollider setup (quarks,
`startup.scd`). `norns-setup` rebuilds it before every start: `norns` links
to the package, sclang's `sclang_conf.yaml` includes the norns classes and
dust, and the SuperCollider extensions are linked into its Extensions.

### SYSTEM > RESTART

norns restarts itself with `sudo systemctl restart norns-...`; the services
put small `sudo` and `systemctl` stand-ins on norns' `PATH` that turn that
into `herd` commands.

## What's patched

norns is the v2.9.4 line (`f9fa0c5`, what the hardware runs); the v3 rewrite
on `main` doesn't build with `--desktop` yet. To build and run on current
Guix and x86:

- waf 2.1.9 instead of the bundled 2.0.14 (which needs Python's removed `imp`)
- SIMDe for the NEON intrinsics in the always-compiled OLED driver
- no glib for `device_hid.c` (one typedef and one macro), a missing
  `<string>`, the `lua53` pkg-config name
- metro threads get a 256 KiB stack: the 16 KiB `PTHREAD_STACK_MIN` fails
  (`EINVAL`) once static TLS outgrows it, and those metros never run
- `patches/norns-desktop-sdl-input.patch`: matron's event loop pumps SDL
  events (nothing did, so the window never handled any), the window surface
  is fetched on every paint (SDL invalidates it when the window is
  reconfigured, so on Wayland nothing was ever shown), the keys above, and
  no SDL signal handlers (they swallowed SIGTERM)
- the SELECT menu's hardcoded `/home/we/dust/code/`

## Not here yet

- maiden (the web editor): its Go server needs packaging, and its frontend
  needs Node 16 with an offline yarn cache. Meanwhile `maiden-repl` (in the
  norns package) is a terminal REPL for matron and sclang.
- The OSC ports (matron 10111 and 8888, crone 9999, sclang 57120) listen on
  every interface, as on a norns; liblo binds them inside matron and crone.
