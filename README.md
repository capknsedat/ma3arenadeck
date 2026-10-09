# ResolumeControlPanel

**Resolume composition grid for grandMA3**

ResolumeControlPanel mirrors your Resolume Arena / Avenue clip deck on a grandMA3 layout: thumbnails, live “what’s playing” highlights, and optional tap-to-trigger control from the console.

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

ResolumeControlPanel talks to Resolume over **HTTP**. The grandMA3 system must be able to open a TCP connection to Resolume’s webserver address and port.

1. On the Resolume machine: **Preferences → Webserver**
2. Enable **Webserver & REST API**
3. Note the **Listen Address** and **Listen Port**
4. From the MA3 machine, confirm you can open the Resolume web UI in a browser, e.g. `http://<resolume-ip>:<port>/`

Official Resolume documentation:

- [REST API & Webserver](https://www.resolume.com/support/en/restapi)

### Port conflict with grandMA3

Resolume’s default webserver port is often **8080**. grandMA3 also commonly uses **8080**.

If both run on the **same computer**, change Resolume’s listen port (for example to **8090**) and enter that port in ResolumeControlPanel’s setup dialog. The plugin default is Resolume’s usual `127.0.0.1:8080` — only change it when 8080 is already taken (e.g. by grandMA3).

### Different machines

- Put Resolume’s **LAN IP** in ResolumeControlPanel (not only `127.0.0.1` — that always means “this machine”)
- Allow the port through the OS firewall on the Resolume PC
- Both machines must be on a network that can route to each other (same subnet is simplest)

---

## Install

1. Copy this folder into your grandMA3 plugins library as:

   `…/gma3_library/datapools/plugins/ResolumeControlPanel/`

2. Files expected:

   | File | Role |
   | --- | --- |
   | `ResolumeControlPanel.xml` | Plugin definition (import this) |
   | `ResolumeControlPanel.lua` | Plugin code |
   | `LICENSE` | MIT license |
   | `README.md` | This document |

3. In grandMA3: **Import** `ResolumeControlPanel.xml` into the **Plugin** pool.

4. On the ComponentLua object, set:

   - **Installed** = **Yes**
   - **FileName** = `ResolumeControlPanel.lua`
   - **Path** = `ResolumeControlPanel` (must match the folder name under `datapools/plugins`)

5. Keep the plugin **external** (`Installed = Yes`). Pasting the full Lua into the showfile editor can hit a size limit and will not update from disk.

6. After changing the `.lua` file on disk, run:

   `ReloadAllPlugins`

---

## Quick start

1. Enable the Resolume webserver (see above) and load a composition with clips.
2. Tap the **ResolumeControlPanel** plugin in the Plugin pool → setup dialog opens.
3. Set **Host** / **Port** (and layout / pool starts if you need non-defaults) → **Sync**.
4. Open **Layout** (default: Layout 1, labelled *ResolumeControlPanel*).
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
| **B** | Layer bypass (toggles, red when on; macro `Res_L<n>_B`) |
| **S** | Layer solo (toggles, yellow when on; macro `Res_L<n>_S`) |
| **M** | Layer master |
| **A** | Layer audio volume |
| **V** | Layer video opacity |

Above the top layer, the **COMPOSITION** row has **X ALL** (disconnect all clips), **B** (composition bypass, toggles), **BO** (blackout: composition video opacity to 0 and back, macro `Res_Blackout`) and **GM** (grand master).

Above that, next to **BPM**: **TAP** (tap tempo, `Res_Tap`) and **RESYNC** (restart the beat, `Res_Resync`). One row higher: **SPEED** (composition speed fader, middle = 100 %, top = 200 %, `Res_Speed`) and **A ◀▶ B** (crossfader, `Res_Crossfader`); both open a fader popup like GM.

Over the clip grid, every column gets a header button with its Resolume name (`Res_Col<n>`): tapping it launches that whole column. The launched column has a red frame. **◀ / ▶** after TRIG (`Res_ColPrev`, `Res_ColNext`) launch the previous / next column. Below the control row, one button per Resolume deck (`Res_Deck<n>`, selected deck cyan) switches deck and runs SYNC by itself so the new deck's clips appear. Like the other controls these work while POLL ON runs.

**M / A / V / GM** show the current level. Tapping one opens a fader popup; drag it and Resolume follows (the newest position is sent on each poll step). The popup takes over only once it reaches the current level (shown as `A 20% -> 50%` until then), so grabbing it never makes the sound or picture jump. Changes made directly in Resolume are not read back until the next **SYNC**.

Playing clips: thicker **red** border (and optional name prefix `>`). Idle clips: black border.

With **TRIG ON**, a tapped clip is sent to Resolume within a few tens of milliseconds (taps are checked between every poll request and while waiting for the next poll) and turns red immediately; the next poll confirms the state. Run **SYNC** once after updating so the playing-clip appearances get the new tint.

---

## Setup dialog options

Opened when you run the plugin from the pool (no argument):

| Field | Meaning |
| --- | --- |
| Host | Resolume IP or hostname (`127.0.0.1` if on the same PC) |
| Port | Resolume webserver port |
| Layout Index / Name | Where the grid is built |
| Image / Appearance / Macro start | Pool indexes used for generated objects |
| Poll interval | Default polling period |
| Fetch thumbnails | Import PNG thumbs from Resolume |
| Only clips with thumbnail | Skip empty / default slots |
| Highlight previewing | Also treat “Previewing” as active |

Use **Sync** to save and rebuild, **Save Only** to store settings without rebuilding, or **Cancel**.

---

## Command-line / macro arguments

Useful if you call the plugin from your own macros:

| Argument | Effect |
| --- | --- |
| *(none)* / `setup` | Setup dialog, then sync if confirmed |
| `sync` | Full sync (no dialog) |
| `monitor` | Start poll loop |
| `stop` | Stop poll loop |
| `interval` | Cycle poll interval |
| `trigtoggle` | Toggle tap-to-trigger |

Example:

```text
Plugin "ResolumeControlPanel" "sync"
Plugin "ResolumeControlPanel" "monitor"
```

---

## Scene recorder (REC / PLAY)

At the top, right of the COMPOSITION label, there are 5 pairs: **REC 1 / PLAY 1 … REC 5 / PLAY 5** (macros `Res_Rec1-5`, `Res_Play1-5`). POLL ON must be running.

- Tap **REC n**: recording starts (red). Tap clips, X and B buttons; each tap and its timing is stored. Tap **REC n** again to stop and save.
- Tap **PLAY n**: the scene loops with the same order and timing until **PLAY n** is tapped again (green while playing).
- Each saved scene is also written as macro `Res_Scene<n>` (one line per tap, Wait = time to the next tap; plays once).
- Fader moves (M / A / V / GM) are not recorded.

---

## Tips

- Run **SYNC** after you change the Resolume composition (new clips, rearranged deck).
- Keep **POLL ON** (or **TRIG ON**) while performing if you want live highlights.
- Image and appearance slots default from **200** upward (change them in setup). Macros start at **Macro Start** (setup, default **300**): each `Res_*` macro reuses the slot with its own name at or after that number, otherwise the next empty slot from there on. Used slots are never overwritten.
- Tapping the plugin in the Plugin pool first asks **Kur** (setup dialog, then Sync) or **Kaldır** (uninstall). Kaldır shows how many objects it found, and after confirming deletes only what the plugin created: its layout, the `Res_*` macros, `Res_` / `ResP_` appearances, `Res_` images and their PNG files, and the `ResArena_` settings. `Plugin "ResolumeControlPanel" "setup"` opens setup directly.
- **BPM** (above COMPOSITION, macro `Res_BPM`): tap it to pick an MA3 speed master. While POLL ON runs, Resolume's composition tempo follows that speed master's BPM (tempo only, not beat phase; use RESYNC in Resolume if the beat drifts). Pick "No link" to stop following.
- The GM button spans the A and V columns.
- The fader popup opens in the middle of the screen at 0 and picks up once it reaches the current level.
- Poll interval cycles 0.1 / 0.25 / 0.5 / 1 / 2 / 5 / 10 / 30 s / 1 m / 5 m. It only sets how fast the red 'playing' frames update; tapping a clip fires it in Resolume at once either way, and the BPM link keeps updating every 0.25 s.
- The layout is only built at Layout Index when that slot is empty, empty of elements, or already a ResolumeControlPanel / MA3ArenaDeck layout. Otherwise SYNC stops before creating anything and says which layout is in the way.
- If Resolume closes or stops answering while POLL ON runs, the plugin waits 1 s between tries and turns POLL off by itself after 3 polls with no answer. Tap POLL ON again once Resolume is back.
- If sync fails, check System Monitor for HTTP errors, then verify the webserver URL in a browser from the MA3 machine.

---

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Setup / sync cannot reach Resolume | Webserver enabled; host/port; firewall; browser test from the MA3 PC |
| Works on Resolume PC but not from console | Use LAN IP, not `127.0.0.1`; same network / routing |
| Port already in use / odd HTTP failures on one machine | Change Resolume off **8080** (MA conflict); set the new port in ResolumeControlPanel |
| Plugin changes not loading | `Installed = Yes`, external `.lua`, then `ReloadAllPlugins` |
| Layout buttons missing / wrong | Run **SYNC** once after install or after changing macro start index |
| Tap does nothing | **TRIG ON**; then **SYNC** once so clip fire macros are rebuilt |
| Tap is slow | System Monitor shows `triggered Lx Cy (tap waited …s, POST …s)` and `poll #n … fetch=…s`; a large *tap waited* means the poll was blocked, a large *POST* means Resolume itself answered slowly |
| Frame colours do not change | System Monitor prints `border colour via …` or `border colour not confirmed …` after SYNC; clip appearances also get a black background |

---

## Privacy & safety

- ResolumeControlPanel only contacts the Resolume host/port you configure.
- Trigger mode sends clip **connect** commands to Resolume — disable **TRIG** for monitor-only operation.
- Generated Images, Appearances, Macros, and Layout content live in your showfile / pools; review pool start indexes before large shows.

---

## License

This project is licensed under the [MIT License](LICENSE).

---

## Credits

ResolumeControlPanel is based on **MA3ArenaDeck** by Simon Kotting, used and modified under the MIT License (original copyright notice kept in [LICENSE](LICENSE)).

Built for grandMA3 + Resolume Arena/Avenue workflows using the [Resolume REST API](https://www.resolume.com/support/en/restapi).
