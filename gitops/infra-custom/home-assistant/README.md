# Home Assistant GitOps Config

This directory contains Kubernetes manifests that are applied into the
`home-assistant` namespace alongside the upstream Home Assistant Helm chart.

## RainBird Irrigation

`packages/rainbird.yaml` and `packages/airco.yaml` are rendered into the
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
°C daytime limit, an 18 °C sleep target, and a 22:00-07:00 sleep period for
each room. The targets and sleep periods can be adjusted independently for
upstairs and downstairs. These helpers restore their last value on subsequent
restarts, so changes made from the dashboard survive a Home Assistant pod replacement. If
the Home Assistant PVC is replaced, Git recreates these helper definitions and
defaults, but UI-managed integration credentials and dashboard storage still
need to be restored from a Home Assistant backup (or configured again).

During the day, a managed unit starts cooling at the configured day limit. Its
setpoint is one degree below the limit, and it turns fully off below the limit.
During the sleep period, it cools at the configured sleep target and turns off
only if the room is already colder than the target. Fan speed is `high` while
the room is more than 1 °C above the active setpoint and `low` when it is close
to the target. Jet mode and the display-light setting are left entirely under
manual control.

The controller runs when a relevant setting or measured temperature changes
and at least every five minutes. When a unit is switched to cooling, the
controller waits for the `cool` state and then gives the LG unit five seconds
to become ready before sending its temperature and fan settings.
`lovelace-airco-card.yaml` is a standalone Lovelace card containing both
thermostats, automation toggles, targets, and sleep schedules. Paste it into a
Manual card on the storage-managed main dashboard.
