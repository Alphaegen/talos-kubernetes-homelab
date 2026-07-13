package rp1

import (
	"os"
	"path/filepath"
	"testing"
)

func TestVerifiedRegisterLayout(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		got  uint32
		want uint32
	}{
		{name: "PWM1 clock control", got: clockPWM1Ctrl, want: 0x18084},
		{name: "PWM1 integer divider", got: clockPWM1DivInt, want: 0x18088},
		{name: "PWM1 fractional divider", got: clockPWM1DivFrac, want: 0x1808c},
		{name: "PWM1 clock select", got: clockPWM1Select, want: 0x18090},
		{name: "GPIO45 control", got: gpio45Control, want: 0xd805c},
		{name: "PWM1 global control", got: pwmGlobalControl, want: 0x9c000},
		{name: "PWM1 channel 3 control", got: pwmChannelControl, want: 0x9c044},
		{name: "PWM1 channel 3 range", got: pwmRange, want: 0x9c048},
		{name: "PWM1 channel 3 duty", got: pwmDuty, want: 0x9c050},
		{name: "PWM channel configuration", got: pwmChannelDefault, want: 0x109},
		{name: "PWM period ticks", got: pwmRangeTicks, want: 2078},
		{name: "clock source mask", got: clockCtrlSourceMask, want: 0x3e1},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if test.got != test.want {
				t.Fatalf("got %#x, want %#x", test.got, test.want)
			}
		})
	}
}

func TestInitializeAndSetFanRegisters(t *testing.T) {
	t.Parallel()

	device := &Device{memory: make([]byte, mappingLength)}
	if err := device.write32(gpio45Control, 0xffffffff); err != nil {
		t.Fatalf("seed GPIO control: %v", err)
	}
	if err := device.InitializePWM(); err != nil {
		t.Fatalf("InitializePWM() error = %v", err)
	}
	if err := device.SetFanPercent(50); err != nil {
		t.Fatalf("SetFanPercent() error = %v", err)
	}

	assertRegister := func(name string, offset, want uint32) {
		t.Helper()
		got, err := device.read32(offset)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		if got != want {
			t.Fatalf("%s = %#x, want %#x", name, got, want)
		}
	}

	assertRegister("clock control", clockPWM1Ctrl, clockCtrlEnable|(clockAuxSourceXOSC<<5)|clockSourceAux)
	assertRegister("clock divider", clockPWM1DivInt, 1)
	assertRegister("clock fractional divider", clockPWM1DivFrac, 0)
	assertRegister("clock select", clockPWM1Select, clockSelectAux)
	assertRegister("GPIO45 function", gpio45Control, 0xffffffe0)
	assertRegister("channel control", pwmChannelControl, pwmChannelDefault)
	assertRegister("range", pwmRange, pwmRangeTicks)
	assertRegister("duty", pwmDuty, pwmRangeTicks/2)
	assertRegister("global control", pwmGlobalControl, pwmSetUpdate|pwmChannelEnable)

	if _, err := device.register(1); err == nil {
		t.Fatal("unaligned register offset was accepted")
	}
	if _, err := device.register(mappingLength); err == nil {
		t.Fatal("out-of-range register offset was accepted")
	}
}

func TestNativeFanControl(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		setup func(t *testing.T, root string)
		want  bool
	}{
		{name: "native control absent", want: false},
		{
			name: "bound driver symlink",
			setup: func(t *testing.T, root string) {
				t.Helper()
				devicePath := filepath.Join(root, "devices/platform/cooling_fan")
				if err := os.MkdirAll(devicePath, 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink("../../../bus/platform/drivers/pwm-fan", filepath.Join(devicePath, "driver")); err != nil {
					t.Fatal(err)
				}
			},
			want: true,
		},
		{
			name: "native hwmon child",
			setup: func(t *testing.T, root string) {
				t.Helper()
				if err := os.MkdirAll(filepath.Join(root, "devices/platform/cooling_fan/hwmon/hwmon0"), 0o755); err != nil {
					t.Fatal(err)
				}
			},
			want: true,
		},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			if test.setup != nil {
				test.setup(t, root)
			}
			got, _, err := NativeFanControl(root)
			if err != nil {
				t.Fatalf("NativeFanControl() error = %v", err)
			}
			if got != test.want {
				t.Fatalf("NativeFanControl() = %v, want %v", got, test.want)
			}
		})
	}
}
