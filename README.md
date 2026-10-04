# ResArena Control for MA3

*Based on **MA3ArenaDeck** by Simon Kotting (MIT License).*

*Works with Resolume Arena / Avenue. Resolume, Arena and Avenue are trademarks of Resolume; grandMA3 is a trademark of MA Lighting. This project is not affiliated with or endorsed by either company.*

**Resolume composition grid for grandMA3**

ResArena Control for MA3 mirrors your Resolume Arena / Avenue clip deck on a grandMA3 layout: thumbnails, live “what’s playing” highlights, and optional tap-to-trigger control from the console.

Ideal for busking, hybrid lighting + video shows, and keeping the media operator’s deck visible (and optionally playable) on the lighting surface.

![image](MA3ArenaDeck_Screenshot.png)

---

## Features

- Builds a **layout grid** that matches your Resolume layers and columns (layer 1 at the bottom, like Resolume)
- Imports **clip thumbnails** into Images / Appearances
- **POLL** mode highlights the currently connected (playing) clips in red
- **TRIG** mode lets you tap a clip on the layout to fire it in Resolume via the REST API
- On-layout controls: **SYNC**, **POLL ON / OFF**, **poll interval**, **TRIG ON / OFF**
- Setup dialog for host, port, layout slot, and pool indexes (values are remembered)

---

## Requirements

| Software | Notes |
| --- | --- |
| **grandMA3** | onPC or console (developed against ~2.2 / 2.3+) |
| **Resolume Arena or Avenue** | with **Webserver & REST API** enabled |
| **Network path** | MA3 machine must reach the Resolume machine (same PC, LAN, or routed network) |

Lua HTTP modules shipped with grandMA3 (`http`, `ltn12`, `json`) are used; no extra installs on the console.

---

## Network & Resolume webserver (important)

ResArena Control for MA3 talks to Resolume over **HTTP**. The grandMA3 system must be able to open a TCP connection to Resolume’s webserver address and port.

1. On the Resolume machine: **Preferences → Webserver**
2. Enable **Webserver & REST API**
3. Note the **Listen Address** and **Listen Port**
4. From the MA3 machine, confirm you can open the Resolume web UI in a browser, e.g. `http://<resolume-ip>:<port>/`

Official Resolume documentation:

- [REST API & Webserver](https://www.resolume.com/support/en/restapi)

### Port conflict with grandMA3

Resolume’s default webserver port is often **8080**. grandMA3 also commonly uses **8080**.

If both run on the **same computer**, change Resolume’s listen port (for example to **8090**) and enter that port in ResArena Control for MA3’s setup dialog. The plugin default is Resolume’s usual `127.0.0.1:8080` — only change it when 8080 is already taken (e.g. by grandMA3).

### Different machines

- Put Resolume’s **LAN IP** in ResArena Control for MA3 (not only `127.0.0.1` — that always means “this machine”)
- Allow the port through the OS firewall on the Resolume PC
- Both machines must be on a network that can route to each other (same subnet is simplest)

---

## Install

1. Copy this folder into your grandMA3 plugins library as:

   `…/gma3_library/datapools/plugins/ResArenaControl/`

2. Files expected:

   | File | Role |
   | --- | --- |
   | `ResArenaControl.xml` | Plugin definition (import this) |
   | `ResArenaControl.lua` | Plugin code |
   | `LICENSE` | MIT license |
   | `README.md` | This document |

3. In grandMA3: **Import** `ResArenaControl.xml` into the **Plugin** pool.

4. On the ComponentLua object, set:

   - **Installed** = **Yes**
   - **FileName** = `ResArenaControl.lua`
   - **Path** = `ResArenaControl` (must match the folder name under `datapools/plugins`)

5. Keep the plugin **external** (`Installed = Yes`). Pasting the full Lua into the showfile editor can hit a size limit and will not update from disk.

6. After changing the `.lua` file on disk, run:

   `ReloadAllPlugins`

---

## Quick start

1. Enable the Resolume webserver (see above) and load a composition with clips.
2. Tap the **ResArena Control for MA3** plugin in the Plugin pool → choose **Install** → setup dialog opens.
3. Set **Host** / **Port** (and layout / pool starts if you need non-defaults) → **Sync**.
4. Open **Layout** (default: Layout 1, labelled *ResArena*).
5. Tap **POLL ON** to follow playing clips, or **TRIG ON** to also fire clips from the layout (poll starts automatically with trigger).

---

## Layout controls

| Button | Action |
| --- | --- |
| **SYNC** | Stops polling, re-fetches the composition, rebuilds the layout and media |
| **POLL ON** | Starts status polling; playing clips get a red frame |
| **POLL OFF** | Stops polling |
| **POLL x.xxs** | Cycles poll interval (`0.10` → `0.25` → `0.50` → `1.00` → `2.00` s) |
| **TRIG ON / OFF** | When **ON**, tapping a clip cell triggers that clip in Resolume; poll is started so highlights stay in sync |

### Layer & composition controls

Left of the layer labels, every layer row gets:

| Control | Action in Resolume |
| --- | --- |
| **X** | Clear the layer (same as the layer's X) |
| **M** | Layer master |
| **A** | Layer audio volume |
| **V** | Layer video opacity |

Above the top layer, the **COMPOSITION** row has **X ALL** (disconnect all clips), **B** (composition bypass / blackout, toggles) and **GM** (grand master).

**M / A / V / GM** show the current level. Tapping one opens a fader popup; drag it and Resolume follows (the newest position is sent on each poll step). The popup takes over only once it reaches the current level (shown as `A 20% -> 50%` until then), so grabbing it never makes the sound or picture jump. Changes made directly in Resolume are not read back until the next **SYNC**.

Playing clips: thicker **red** border (and optional name prefix `>`). Idle clips: black border.

With **TRIG ON**, a tapped clip is sent to Resolume within a few tens of milliseconds (taps are checked between every poll request and while waiting for the next poll) and turns red immediately; the next poll confirms the state. Run **SYNC** once after updating so the playing-clip appearances get the new tint.

---

## Setup dialog options

Opened when you run the plugin from the pool (no argument) and pick **Install**. The poll interval is set with the **POLL x.xxs** layout button, not here.

| Field | Meaning |
| --- | --- |
| Host | Resolume IP or hostname (`127.0.0.1` if on the same PC) |
| Port | Resolume webserver port |
| Layout Index / Name | Where the grid is built |
| Image / Appearance / Macro start | Pool indexes used for generated objects |
| Fetch thumbnails | Import PNG thumbs from Resolume |
| Only clips with thumbnail | Skip empty / default slots |
| Highlight previewing | Also treat “Previewing” as active |

Use **Sync** to save and rebuild, **Save Only** to store settings without rebuilding, or **Cancel**.

### Uninstall

Tapping the plugin first shows **Install / Uninstall / Cancel**. **Uninstall** (after a confirm) removes everything the plugin created: the layout (only if it still has the configured name), every `Res_*` macro, `Res_*` / `ResP_*` appearance and `Res_*` image (plus old `MAD_*` / `MADP_*` ones from MA3ArenaDeck) in the configured pool ranges, the thumbnail PNG files in the user image library, and all saved `ResArena_*` (and old `MA3ArenaDeck_*`) settings. Objects with other names in those ranges are left alone.

---

## Command-line / macro arguments

Useful if you call the plugin from your own macros:

| Argument | Effect |
| --- | --- |
| *(none)* / `setup` | Install / Uninstall / Cancel, then setup dialog or uninstall |
| `sync` | Full sync (no dialog) |
| `monitor` | Start poll loop |
| `stop` | Stop poll loop |
| `interval` | Cycle poll interval |
| `trigtoggle` | Toggle tap-to-trigger |

Example:

```text
Plugin "ResArena Control for MA3" "sync"
Plugin "ResArena Control for MA3" "monitor"
```

---

## Tips

- Run **SYNC** after you change the Resolume composition (new clips, rearranged deck).
- Keep **POLL ON** (or **TRIG ON**) while performing if you want live highlights.
- Pool indexes default from **200** upward — change them in setup if those slots are already used in your show.
- If sync fails, check System Monitor for HTTP errors, then verify the webserver URL in a browser from the MA3 machine.

---

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Setup / sync cannot reach Resolume | Webserver enabled; host/port; firewall; browser test from the MA3 PC |
| Works on Resolume PC but not from console | Use LAN IP, not `127.0.0.1`; same network / routing |
| Port already in use / odd HTTP failures on one machine | Change Resolume off **8080** (MA conflict); set the new port in ResArena Control for MA3 |
| Plugin changes not loading | `Installed = Yes`, external `.lua`, then `ReloadAllPlugins` |
| Layout buttons missing / wrong | Run **SYNC** once after install or after changing macro start index |
| Tap does nothing | **TRIG ON**; then **SYNC** once so clip fire macros are rebuilt |
| Tap is slow | System Monitor shows `triggered Lx Cy (tap waited …s, POST …s)` and `poll #n … fetch=…s`; a large *tap waited* means the poll was blocked, a large *POST* means Resolume itself answered slowly |
| Frame colours do not change | System Monitor prints `border colour via …` or `border colour not confirmed …` after SYNC; clip appearances also get a black background |

---

## Privacy & safety

- ResArena Control for MA3 only contacts the Resolume host/port you configure.
- Trigger mode sends clip **connect** commands to Resolume — disable **TRIG** for monitor-only operation.
- Generated Images, Appearances, Macros, and Layout content live in your showfile / pools; review pool start indexes before large shows.

---

## License

This project is licensed under the [MIT License](LICENSE).

It is a modified version of **MA3ArenaDeck**, Copyright (c) 2026 Simon Kotting, used under the MIT License. As that license requires, the original copyright notice and permission notice are kept in [LICENSE](LICENSE) and must be included in all copies or substantial portions of the software.

---

## Credits

- Original plugin: **MA3ArenaDeck** by Simon Kotting (MIT License).
- Modifications (layout controls, faders, Install/Uninstall, naming): Sedat.


Built for grandMA3 + Resolume Arena/Avenue workflows using the [Resolume REST API](https://www.resolume.com/support/en/restapi).
