# Home Assistant GitOps Config

This directory contains Kubernetes manifests that are applied into the
`home-assistant` namespace alongside the upstream Home Assistant Helm chart.

## RainBird Irrigation

`packages/rainbird.yaml`, `packages/airco.yaml`, `packages/afval.yaml`,
`packages/energie.yaml` and `packages/meldingen.yaml` are rendered into the
`home-assistant-packages` ConfigMap and mounted read-only under
`/config/packages`.

The package runs the four zones one at a time, logs every run, and runs the
watering schedule. The main entities:

- `script.rainbird_start_single_zone` (zone, minutes, source),
  `script.rainbird_run_program` and `script.rainbird_stop_all_zones`
- `input_number.rainbird_duration` (manual minutes) and
  `input_number.rainbird_program_zone_<1-4>_duration` (schedule minutes)
- `input_boolean.rainbird_schema_actief`, `input_boolean.rainbird_schema_<ma-zo>`
  and `input_datetime.rainbird_schema_starttijd` (the schedule)
- `input_boolean.rainbird_pauze_zone_<1-4>` (pause a zone in the schedule)
- `sensor.rainbird_status`, `sensor.rainbird_active_zone`,
  `sensor.rainbird_program_remaining`, `sensor.rainbird_volgende_beurt` and
  `binary_sensor.rainbird_bezig` (Dutch, with the zone names)
- `sensor.rainbird_logboek` (the log) and `timer.rainbird_time_left`
- `automation.rainbird_schema`, `automation.rainbird_instellingen_in_logboek` and
  `automation.rainbird_stop_when_shared_timer_finishes`

Starting a zone turns off all zones, sends `rainbird.start_irrigation` with
the duration, and waits up to 75 seconds for the switch to report `on` (the
integration polls once a minute). It tries twice. The controller enforces the
duration, so a zone stops even if Home Assistant goes away halfway; the
shared timer only shows the countdown. A start that is not confirmed is logged,
creates a persistent notification, and goes to everyone with the `tuin`
notification switched on.

The program runs every zone with schedule minutes above 0 that is not
paused, in zone order, and waits up to 15 minutes for the controller if it is
briefly unreachable. Stop cancels it; Volgende ends the current zone and goes
on with the next.

### Schedule

`automation.rainbird_schema` runs the program at the start time on the chosen
days while Automatisch sproeien is on. It skips the whole day, and logs why,
when the rain sensor reports rain (`regen gemeten`), a rain delay is set
(`regenpauze`), or something is already running. A paused zone keeps its
minutes but is left out and logged as `gepauzeerd`; the other zones still run.
Pausing is manual: switch Pauze on for as long as the zone should be skipped,
then off again. **Turn the controller's own programs off in the Rain Bird
app**, or zones water twice.

While the schedule is off, nothing is logged per day (a winter would fill the
log). `automation.rainbird_instellingen_in_logboek` logs switching the schedule
off or on and pausing or resuming a zone instead, with the person who did it.

### Log

Every entry has a kind (`beurt`, `overgeslagen`, `mislukt`, `pauze`, `hervat`,
`uit`, `aan`), a zone name, a start time, a short description (`wat`, e.g.
`15 min` or `overgeslagen: regen gemeten`) and a source (`bron`). The source
of a run is the start request the scripts announce with a `rainbird_logboek`
event (Handmatig, Schema, Schema (nu)). A zone that turns on without one was
started by the controller itself or the Rain Bird app and is logged as Rain
Bird. For pauses and the schedule switch the source is the person. Times are
accurate to the one-minute poll.

The log is kept twice:

- `sensor.rainbird_logboek` holds the last 50 entries, newest first, in its
  `runs` attribute, for the dashboard table and each zone's last run. It
  survives restarts and the recorder's 10-day purge, but not more than 50
  entries.
- **The full history** goes to the Local Calendar `calendar.tuin`, one event
  per entry (e.g. "Gras · 15 min", "Schema · overgeslagen: regen gemeten"),
  kept without limit and shown per month or as a list in the Logboek pop-up
  and in the Calendar sidebar. The calendar is UI-made: add the **Local
  Calendar** integration once with the name `Tuin`. It lives in Home
  Assistant storage (`.storage/local_calendar.tuin.ics`), so it is covered
  by the same Home Assistant backups as the other UI data, not by Git. Until
  it exists only the last 50 are kept.

The active-zone and status sensors also show zones started outside Home
Assistant, as long as the integration reports the switch as `on`.

## Entity IDs

The package assumes these Rain Bird switch entity IDs:

- `switch.rain_bird_sprinkler_1`
- `switch.rain_bird_sprinkler_2`
- `switch.rain_bird_sprinkler_3`
- `switch.rain_bird_sprinkler_4`

These IDs were verified in the live Home Assistant entity registry using the
repo-root `kubeconfig`. Their current friendly names are `Gras`, `Achtertuin`,
`Voortuin + zijkant`, and `Druppelslang`.

If Home Assistant generated different entity IDs, update
`packages/rainbird.yaml`, `dashboards/view-tuin.yaml` and
`lovelace-rainbird-card.yaml`.

The entity registry still holds three orphans from earlier UI-made helpers:
`binary_sensor.rainbird_busy`, `input_select.rainbird_active_zone` and
`sensor.rainbird_program_status`. Nothing uses them; delete them under
**Settings → Entities**.

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
| Thuis | Weather, next waste pickup, today's solar, usage, export and import, Woonkamer lamp switch, both airco units with filter life and automation toggle, the Tuin status card with Stop while watering |
| Energie | The energy dashboard cards: distribution, live power, electricity, solar, gas, water, devices, self-sufficiency |
| Klimaat | Per room, in groups: the unit (mode, target, fan, both louvre directions), functions (ionizer, display light, jet mode while cooling), the automation with its settings while it is on (day and night maxima, night period, maintenance fan level), and filter and power use |
| Tuin | What runs now with Stop, the zones to start by hand (pop-up per zone with the minutes) and the log per day; next to it the automatic schedule (days, start time, minutes and pause per zone, rain delay). The log pop-up has the last 50 and the full history |
| Meldingen | The viewer's own notification toggles (see below) |

Pop-ups (`popup-*.yaml`) open from the Thuis view: all lights and scenes, each
airco unit, and the waste pickups. `tuin-nu.yaml` is the garden status
card shared by the Tuin view, its pop-ups and the Thuis view. `airco-boven.yaml` and
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

### Notifications

`packages/meldingen.yaml` lets each person choose which phone notifications
they get. Every notification has an `input_boolean.melding_<melding>_<persoon>`
per person (`niek`, `marc`, `wil`), and automations send through
`script.melding_versturen`, which maps each person to their phone and only
notifies the people whose helper is on. The Meldingen view has one section per
person, shown only to that person's Home Assistant user, so everyone sees and
switches their own toggles.

| Melding | When |
|---|---|
| `afval` | 19:00 the evening before a pickup, e.g. "GFT moet morgen aan straat!" |
| `aircofilter` | When an airco filter drops below 10% life |
| `tuin` | When a Rain Bird zone does not start |

New helpers start off. To add a notification, add its helpers, a toggle in
each person's section of `dashboards/view-meldingen.yaml`, and call the script
with the new key. To add a person, add their helpers, their phone under
`telefoons` in the script, and a section with their user id.

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
Assistant notifies everyone who has the `aircofilter` notification switched on
(see Notifications above). The notification identifies whether the upstairs or
downstairs filter needs attention.

`lovelace-airco-card.yaml` is a standalone Lovelace card containing both
thermostats, automation toggles, targets, and sleep schedules. Paste it into a
Manual card on the storage-managed main dashboard.
