# Home Assistant GitOps Config

This directory contains Kubernetes manifests that are applied into the
`home-assistant` namespace alongside the upstream Home Assistant Helm chart.

## RainBird Irrigation

`packages/rainbird.yaml` is rendered into the
`home-assistant-rainbird-package` ConfigMap and mounted at
`/config/packages/rainbird.yaml`. The package creates:

- `input_number.rainbird_duration`
- `timer.rainbird_time_left`
- `input_select.rainbird_active_zone`
- `script.rainbird_start_single_zone`
- `script.rainbird_stop_all_zones`
- `automation.rainbird_stop_when_shared_timer_finishes`

Starting a zone first cancels the shared timer, sets the active zone to `Idle`,
turns off all configured Rain Bird switches, waits two seconds, starts the
selected zone with `rainbird.start_irrigation`, starts the shared timer, and
sets the active zone name. This keeps only one irrigation zone active at a time.

Stopping cancels the timer, turns off all configured zones, and sets the active
zone back to `Idle`. The shared timer finishing also calls the stop script.

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

The live instance currently has UI/storage-created RainBird helpers, including
`input_number.rainbird_duration`, `input_number.rainbird_duration_2`, and
`timer.rainbird_time_left`. Remove or rename those UI-created helpers before
syncing this package if you want GitOps to be the single owner of these helper
entities and avoid duplicate entity IDs.

Keep the raw Rain Bird zone switches off the primary dashboard so users start
zones through `script.rainbird_start_single_zone` and preserve mutual exclusion.

## Lovelace

Use `lovelace-rainbird-card.yaml` as the dashboard card snippet. Add it to a
manual Lovelace dashboard or a YAML-backed dashboard as appropriate for the
Home Assistant instance.
