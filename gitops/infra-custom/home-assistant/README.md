# Home Assistant GitOps Config

This directory contains Kubernetes manifests that are applied into the
`home-assistant` namespace alongside the upstream Home Assistant Helm chart.

## RainBird Irrigation

`packages/rainbird.yaml` is rendered into the
`home-assistant-rainbird-package` ConfigMap and mounted at
`/config/packages/rainbird.yaml`.

The package creates manual run controls, confirmed-start status helpers, a
shared countdown timer, and a simple sequential watering program:

- `input_number.rainbird_duration`
- `input_number.rainbird_program_zone_1_duration`
- `input_number.rainbird_program_zone_2_duration`
- `input_number.rainbird_program_zone_3_duration`
- `input_number.rainbird_program_zone_4_duration`
- `input_boolean.rainbird_command_pending`
- `input_boolean.rainbird_last_start_confirmed`
- `input_boolean.rainbird_program_running`
- `input_text.rainbird_requested_zone`
- `input_text.rainbird_last_message`
- `timer.rainbird_time_left`
- `sensor.rainbird_active_zone`
- `sensor.rainbird_status`
- `sensor.rainbird_program_total_duration`
- `binary_sensor.rainbird_busy`
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
runs Zone 1 first and Zone 2 afterwards. Manual stop cancels the timer, turns
off all zones, and cancels any running program.

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

Use `lovelace-rainbird-card.yaml` as the card snippet for the RainBird page in
the main Home Assistant dashboard. The main dashboard itself is managed in Home
Assistant storage, so this file is the source-of-truth snippet to paste into
that page when the RainBird controls change.
