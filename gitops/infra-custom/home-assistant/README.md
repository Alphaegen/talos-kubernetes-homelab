# Home Assistant GitOps Config

This directory contains Kubernetes manifests that are applied into the
`home-assistant` namespace alongside the upstream Home Assistant Helm chart.

## RainBird Irrigation

`packages/rainbird.yaml`, `packages/airco.yaml`, `packages/afval.yaml` and
`packages/energie.yaml` are rendered into the
`home-assistant-packages` ConfigMap and mounted read-only under
`/config/packages`.

The package creates manual run controls, confirmed-start status helpers, a
shared countdown timer, and a simple sequential watering program:

- `input_number.rainbird_duration`
- `input_number.rainbird_program_zone_1_duration`
- `input_number.rainbird_program_zone_2_duration`
- `input_number.rainbird_program_zone_3_duration`
- `input_number.rainbird_program_zone_4_duration`
- `input_number.rainbird_program_step`
- `input_boolean.rainbird_command_pending`
- `input_boolean.rainbird_last_start_confirmed`
- `input_boolean.rainbird_program_running`
- `input_text.rainbird_requested_zone`
- `input_text.rainbird_last_message`
- `timer.rainbird_time_left`
- `sensor.rainbird_active_zone`
- `sensor.rainbird_status`
- `sensor.rainbird_program_total_duration`
- `sensor.rainbird_program_remaining`
- `sensor.rainbird_last_message`
- `script.rainbird_start_single_zone`
- `script.rainbird_run_program`
- `script.rainbird_stop_all_zones`
- `automation.rainbird_stop_when_shared_timer_finishes`

Starting a zone first cancels the shared timer, turns off all configured Rain
Bird switches, sends `rainbird.start_irrigation`, then waits for the requested
switch to report a fresh `on` state before starting the local countdown. If the
zone cannot be confirmed, no timer is started and a persistent notification is
created.

The program runner uses the four program duration helpers in zone order. Set a
zone duration to `0` to skip it; for example, Zone 1 at `45` and Zone 2 at `30`
runs Zone 1 first and Zone 2 afterwards. `sensor.rainbird_program_remaining`
shows the scheduled zones that have not started yet. Manual stop cancels the
timer, turns off all zones, and cancels any running program.

The active-zone entity is a read-only template sensor derived from the real Rain
Bird switch states. It cannot start zones from the UI, and it shows zones
started from the Rain Bird app as long as the Home Assistant integration reports
the switch as `on`.

## Entity IDs

The package assumes these Rain Bird switch entity IDs:

- `switch.rain_bird_sprinkler_1`
- `switch.rain_bird_sprinkler_2`
- `switch.rain_bird_sprinkler_3`
- `switch.rain_bird_sprinkler_4`

These IDs were verified in the live Home Assistant entity registry using the
repo-root `kubeconfig`. Their current friendly names are `Gras`, `Achtertuin`,
`Voortuin + zijkant`, and `Druppelslang`.

If Home Assistant generated different entity IDs, update both
`packages/rainbird.yaml` and `lovelace-rainbird-card.yaml`.

The live instance may have UI/storage-created RainBird helpers, including
`input_number.rainbird_duration`, `input_number.rainbird_duration_2`, and
`timer.rainbird_time_left`. Remove or rename conflicting UI-created helpers
before syncing this package if you want GitOps to be the single owner of these
helper entities and avoid duplicate entity IDs.

Keep the raw Rain Bird zone switches off the primary dashboard so users start
zones through `script.rainbird_start_single_zone` or
`script.rainbird_run_program` and preserve mutual exclusion.

## Lovelace

Use these snippets on the RainBird page in the main Home Assistant dashboard:

- `lovelace-rainbird-status-card.yaml`
- `lovelace-rainbird-manual-card.yaml`
- `lovelace-rainbird-program-card.yaml`

`lovelace-rainbird-card.yaml` contains the same three cards as one
`vertical-stack` for quick full-page replacement. The main dashboard itself is
managed in Home Assistant storage, so these files are the source-of-truth
snippets to paste into that page when the RainBird controls change.

## Thuis Dashboard

`dashboards/` holds a second, Git-managed dashboard, **Thuis (nieuw)** at
`/dashboard-thuis`, built for phones first. It sits next to the
storage-managed main dashboard, which it does not change. The `lovelace:`
block in `helm-values.yaml` registers it in YAML mode for every user. The
`home-assistant-dashboards` ConfigMap mounts the files flat at
`/config/dashboards`, so `!include` takes plain file names.

| View | Contents |
|---|---|
| Thuis | Weather, next waste pickup, today's solar, usage, export and import, Woonkamer lamp switch, both airco units with filter life and automation toggle, Rain Bird status while watering |
| Energie | The energy dashboard cards: distribution, live power, electricity, solar, gas, water, devices, self-sufficiency |
| Klimaat | Per room, in groups: the unit (mode, target, fan, both louvre directions), functions (ionizer, display light, jet mode while cooling), the automation with its settings while it is on (day and night maxima, night period, maintenance fan level), and filter and power use |
| Tuin | Rain Bird status, manual zones, and the program |

Pop-ups (`popup-*.yaml`) open from the Thuis view: all lights and scenes, each
airco unit, and the waste pickups. `airco-boven.yaml` and
`airco-beneden.yaml` hold the room controls once for both the Klimaat view
and the pop-ups. Keep the two files identical apart from the room name.

Requirements and editing:

- The dashboard needs **Bubble Card**, installed through HACS (Frontend). Like
  the other HACS cards, its resource lives in Home Assistant storage, not in
  Git.
- A new file must be listed under `home-assistant-dashboards` in
  `kustomization.yaml`. `scripts/validate.sh` checks this, that every file
  parses, and that every `!include` target is shipped.
- After Argo CD syncs a change, the mounted files update within about a
  minute. Then use **⋮ → Refresh** on the dashboard. Only changes to the
  `lovelace:` block itself restart Home Assistant.
- The `Homelab` theme (`themes/homelab.yaml`, mounted at `/config/themes`) is
  set per view, with light and dark modes. After a theme change, run the
  `frontend.reload_themes` action.
- To switch over, each person can pick the dashboard as their default in
  **Settings → Dashboards** or in their profile on each device. The old
  dashboard keeps working until it is removed.

### Waste pickups

`packages/afval.yaml` adds `sensor.afval_ophaalschema`. Every hour, and just
after midnight, it reads the Circulus calendar from today through Sunday of
next week. Its state is the next bin type (`GFT`, or `GFT + Papier` when two
share a day), which the Thuis card uses as its title. Its attributes hold the
Dutch day and countdown (`wanneer`), an icon, and every pickup in the window
(`ophalingen`, with `week` 0 for this week and 1 for next week) for the
pop-up's list. If the calendar is not loaded yet after a restart, the sensor
keeps its last value until the next hourly run.

### Energy today

`packages/energie.yaml` adds today's electricity totals for the Thuis view:
`sensor.zon_opgewekt_vandaag`, `sensor.stroomverbruik_vandaag`,
`sensor.stroom_teruggeleverd_vandaag` and `sensor.stroom_afgenomen_vandaag`
(kWh), plus `sensor.stroomverbruik_nu` (W, P1 power plus solar output) for
the usage badge. The P1 meter only reports lifetime totals, so every 15
minutes, and just after midnight, `sensor.stroom_beginstand_vandaag` looks up
the meter readings at midnight in the recorder's 5-minute statistics. The
day totals are the current readings minus those. Solar comes from the Growatt
day total, which resets a minute after midnight. Usage is import plus solar
minus export.

New or changed packages are not picked up by a running Home Assistant: run
**Developer tools → YAML → Template entities** (or restart) after Argo CD
syncs.

## Air Conditioning

`packages/airco.yaml` manages the two LG air conditioners exposed by the
SmartThinQ integration:

- `climate.airco_beneden`
- `climate.airco_boven`

The package is opt-in per room. After deployment, review the targets and sleep
times, then enable `input_boolean.airco_beneden_automation` and/or
`input_boolean.airco_boven_automation`. While a room's toggle is off, the
package does not change that air conditioner, so manual control remains
available.

The first Home Assistant start after installing the package initializes a 24
°C daytime maximum, an 18 °C nighttime maximum, and a 22:00-07:00 sleep period
for each room. The maxima and sleep periods can be adjusted independently for
upstairs and downstairs. These helpers restore their last value on subsequent
restarts, so changes made from the dashboard survive a Home Assistant pod replacement. If
the Home Assistant PVC is replaced, Git recreates these helper definitions and
defaults, but UI-managed integration credentials and dashboard storage still
need to be restored from a Home Assistant backup (or configured again).

The active maximum is also the air conditioner's setpoint. An off unit starts
at 1 °C above that maximum and uses `high` fan until the room reaches the
maximum, then starts maintenance at the quietest supported fan speed. The
maintenance ladder is built from the modes each LG unit exposes, ordered as
`low`, `LOW_MID`, `medium`, `MID_HIGH`, and `high`.

During the day, a rise to more than 2 °C above the maximum means the current
maintenance level was insufficient. The controller advances one maintenance
level, uses `high` to pull the room back to the maximum, then maintains the new
level. During the sleep period it escalates maintenance directly: more than 1
°C above the maximum requires at least the first intermediate level, more than
2 °C requires the next, and so on. Maintenance levels never decrease within a
day or sleep period, but reset to the quietest level at the next schedule
transition. Per-room helpers preserve the current phase and level across a Home
Assistant restart. Jet mode and the display-light setting remain under manual
control.

The Lovelace card exposes each room's current maintenance level as an editable
numeric control: `0` is `low`, `1` is `LOW_MID`, `2` is `medium`, `3` is
`MID_HIGH`, and `4` is `high`. Lowering the helper applies immediately. During
the sleep period, the controller can raise it again when the measured
temperature still requires a higher minimum level.

The controller runs when a relevant setting or measured temperature changes
and at least every five minutes. When a unit is switched to cooling, the
controller waits for the `cool` state and then gives the LG unit five seconds
to become ready before sending its temperature and fan settings.

When either air conditioner's remaining filter life drops below 10%, Home
Assistant sends a notification to every registered mobile: `alpha-mobile`,
`M.J.Vlam iPhone`, and `Wil Mobiel`. The notification identifies whether the
upstairs or downstairs filter needs attention.

`lovelace-airco-card.yaml` is a standalone Lovelace card containing both
thermostats, automation toggles, targets, and sleep schedules. Paste it into a
Manual card on the storage-managed main dashboard.
