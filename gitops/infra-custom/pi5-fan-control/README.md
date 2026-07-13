# Raspberry Pi 5 fan control

`pi5-fan-control` is a privileged node agent for the dedicated PWM fan header
on the four Raspberry Pi 5 nodes fitted with
[Waveshare PoE M.2 HAT+](https://www.waveshare.com/wiki/PoE_M.2_HAT+) boards.
The two Noctua NF-A8 5V fans remain the continuous, independent baseline
cooling system. The small HAT fans are supplemental cooling for elevated CPU
temperatures only.

## Why this workaround exists

Talos detects `cooling_fan`, the `pwm-fan` driver, and the RP1 PWM platform
device, but the current kernel does not include the functional `PWM_RP1`
provider. Consequently no PWM chip, thermal cooling device, or fan hwmon
device is created and CPU load does not start the fan.

The controller maps RP1 PCI BAR1 from
`/host-sys/bus/pci/devices/0002:01:00.0/resource1` and directly configures the
50 MHz PWM1 clock, GPIO45, and PWM1 channel 3. This is deliberately limited to
Raspberry Pi 5 plus the Waveshare PoE M.2 HAT+ fan connected to the dedicated
fan header. It is not a generic ARM64 fan controller.

Before mapping the BAR, the controller checks the cooling-fan device for a
bound native driver and an `hwmon` child. If either exists, it logs that native
control is present, leaves all RP1 registers untouched, and remains inactive.
Remove this DaemonSet before enabling native RP1 PWM control; two controllers
must never program the same PWM hardware.

The RP1 implementation is a clean Go reimplementation based on Sung-jin
Hong's [fan-control gist](https://gist.github.com/serialx/d3213768026b15222ec8b86d92c06819).
The original BSD-0-Clause attribution is retained in
[`LICENSE-BSD-0-Clause`](LICENSE-BSD-0-Clause). Register values were checked
against Raspberry Pi's `rpi-6.12.y`
[`rp1.dtsi`](https://github.com/raspberrypi/linux/blob/rpi-6.12.y/arch/arm64/boot/dts/broadcom/rp1.dtsi),
[`clk-rp1.c`](https://github.com/raspberrypi/linux/blob/rpi-6.12.y/drivers/clk/clk-rp1.c),
[`pinctrl-rp1.c`](https://github.com/raspberrypi/linux/blob/rpi-6.12.y/drivers/pinctrl/pinctrl-rp1.c),
and [`pwm-rp1.c`](https://github.com/raspberrypi/linux/blob/rpi-6.12.y/drivers/pwm/pwm-rp1.c)
sources. The hardware-specific code is isolated in `internal/rp1`;
temperature curve logic has no hardware dependency.

## Effective configuration

The pod template supplies these environment defaults:

```text
INTERVAL_SECONDS=5
TEMP_OFF=65
FAN_CURVE=68:30,72:45,75:70,78:100
STARTUP_TEST_SECONDS=2
```

The resulting behavior is:

| CPU temperature | Supplemental HAT fan |
|---|---|
| At or below 65 C | Off |
| Above 65 C and below 68 C | Remains off if off; holds 30% if already running |
| 68 C | 30% |
| 72 C | 45% |
| 75 C | 70% |
| At or above 78 C | 100% |

Duty is interpolated linearly between curve points. On every start the fan
runs at 100% for two seconds, then moves to the temperature-derived duty.
Set `STARTUP_TEST_SECONDS=0` to disable the physical startup test. Changing
the environment values changes the pod template and triggers a DaemonSet
rollout. Controller source changes require a newly published immutable image
digest, which also changes the pod template and triggers a rollout.

## Build and image publication

The ArgoCD application uses a published image pinned by tag and immutable
digest. The multi-stage build produces a statically linked Linux ARM64 binary
with CGO disabled and copies it into a `scratch` runtime image. The official Go
builder is pinned by patch tag and immutable index digest.

From this directory, build and publish a new version:

```bash
docker buildx build --platform linux/arm64 --provenance=false \
  --tag ghcr.io/alphaegen/pi5-fan-control:v0.1.0 --push .
crane digest ghcr.io/alphaegen/pi5-fan-control:v0.1.0
```

Replace the DaemonSet image with the new
`ghcr.io/alphaegen/pi5-fan-control:<version>@sha256:<reported-digest>`. Never
deploy the application with only a mutable tag.

## Security boundary

Direct PCI BAR access requires root, a privileged container, and host `/sys`.
The full `/sys` mount is retained because it is the known-working Talos access
path for the PCI resource and thermal sensor. The pod has a read-only root
filesystem, no service-account token, no RBAC, and a dedicated service account.

The namespace uses Pod Security `privileged` labels. The optional repository
Kyverno baseline policy excludes only pods named and labeled
`pi5-fan-control` in this namespace from its privilege restriction. No
cluster-wide privileged or hostPath exclusion is added. This exception exists
only for RP1 MMIO and must be removed with the workaround.

## Canary rollout on rpi-w-2

`nodes.yaml` assigns `hardware.niekvlam.nl/pi5-fan: "true"` only to
`rpi-w-2` (`192.168.3.103`). The DaemonSet also requires ARM64 and this explicit
label, so it cannot schedule on the other nodes. Generate the Talos configs and
inspect the canary diff. Apply only the label to the live machine configuration
so unrelated Talos settings are not replaced:

```bash
./generate.sh
talosctl -n 192.168.3.103 patch machineconfig \
  --patch '{"machine":{"nodeLabels":{"hardware.niekvlam.nl/pi5-fan":"true"}}}'
```

Render the app-of-apps chart, commit the reviewed changes, and let ArgoCD
reconcile:

```bash
helm template infra-apps gitops/infra-helm
kubectl -n pi5-fan-control get pods -o wide
kubectl -n pi5-fan-control logs \
  -l app.kubernetes.io/name=pi5-fan-control --follow
```

Monitor the canary temperature from Fish shell:

```fish
while true
    set temp (talosctl -n 192.168.3.103 read /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    echo (date "+%H:%M:%S")" - "(math --scale=1 "$temp / 1000")"°C"
    sleep 2
end
```

Canary checks:

1. Confirm the HAT fan briefly runs at full speed when the pod starts.
2. Confirm it stops below 65 C.
3. Generate CPU load on `rpi-w-2`.
4. Confirm the fan starts at approximately 68 C.
5. Confirm fan speed audibly increases across the curve points.
6. Confirm temperature stabilizes below the Pi 5 throttling range.
7. Delete or stop the stress workload.
8. Confirm the fan eventually turns off after cooling below 65 C.
9. Restart the controller pod and verify startup and graceful shutdown logs.
10. Confirm the Noctua fans remain the independent baseline cooling system.

This implementation controls PWM duty only. It does not read tachometer
feedback and must not be described as RPM verification.

## Enabling the remaining nodes

Only after physical canary verification, add the same `nodeLabels` mapping to
`rpi-cp-1`, `rpi-w-1`, and `rpi-w-3` in `nodes.yaml`:

```yaml
nodeLabels:
  hardware.niekvlam.nl/pi5-fan: "true"
```

Regenerate and inspect the three node configs, then patch only the labels on the
live machines:

```bash
./generate.sh
talosctl -n 192.168.3.101 patch machineconfig --patch '{"machine":{"nodeLabels":{"hardware.niekvlam.nl/pi5-fan":"true"}}}'
talosctl -n 192.168.3.102 patch machineconfig --patch '{"machine":{"nodeLabels":{"hardware.niekvlam.nl/pi5-fan":"true"}}}'
talosctl -n 192.168.3.104 patch machineconfig --patch '{"machine":{"nodeLabels":{"hardware.niekvlam.nl/pi5-fan":"true"}}}'
```

The catch-all toleration allows the DaemonSet to run on the control-plane node
after it is explicitly labeled.

## Adjustment, rollback, and native-driver migration

Adjust the curve by editing the DaemonSet environment values and reviewing the
Kustomize render. To disable the controller, set `pi5FanControl.enabled: false`
and remove the opt-in `nodeLabels` entry from `nodes.yaml`. Remove the persistent
label from the live canary machine configuration; the Kubernetes label will then
be reconciled away:

```bash
talosctl -n 192.168.3.103 patch machineconfig \
  --patch '{"machine":{"nodeLabels":{"hardware.niekvlam.nl/pi5-fan":null}}}'
```

Graceful termination intentionally programs 100% before unmapping the BAR. An
abrupt process or node failure can leave the last PWM duty programmed. Keep the
external Noctua fans running throughout testing and rollback.

Native support is available when `cooling_fan/driver` is bound and/or a native
`hwmon` child appears (normally accompanied by a PWM chip and thermal cooling
device). The controller will report this and remain inactive. At that point,
disable and remove the Application, its Kyverno exception and opt-in labels
before enabling native RP1 PWM fan control.

## Local validation

```bash
go test ./...
go vet ./...
make lint
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./cmd/pi5-fan-control
kustomize build .
```
