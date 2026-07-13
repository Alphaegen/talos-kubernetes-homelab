package curve

import "testing"

func TestParse(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		off       string
		curve     string
		wantError bool
	}{
		{name: "valid defaults", off: "65", curve: "68:30,72:45,75:70,78:100"},
		{name: "invalid percentage above maximum", off: "65", curve: "68:101", wantError: true},
		{name: "invalid negative percentage", off: "65", curve: "68:-1", wantError: true},
		{name: "invalid percentage format", off: "65", curve: "68:30.5", wantError: true},
		{name: "unsorted temperatures", off: "65", curve: "72:45,68:30", wantError: true},
		{name: "duplicate temperatures", off: "65", curve: "68:30,68:45", wantError: true},
		{name: "curve starts at off threshold", off: "65", curve: "65:30,72:45", wantError: true},
		{name: "decreasing percentages", off: "65", curve: "68:45,72:30", wantError: true},
		{name: "empty curve", off: "65", curve: "", wantError: true},
		{name: "invalid off temperature", off: "not-a-number", curve: "68:30", wantError: true},
		{name: "non-finite curve temperature", off: "65", curve: "NaN:30", wantError: true},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			_, err := Parse(test.off, test.curve)
			if test.wantError && err == nil {
				t.Fatal("Parse() returned no error")
			}
			if !test.wantError && err != nil {
				t.Fatalf("Parse() error = %v", err)
			}
		})
	}
}

func TestPercent(t *testing.T) {
	t.Parallel()

	fanCurve, err := Parse("65", "68:30,72:45,75:70,78:100")
	if err != nil {
		t.Fatalf("Parse() error = %v", err)
	}

	tests := []struct {
		name        string
		temperature float64
		fanWasOn    bool
		want        int
	}{
		{name: "below TEMP_OFF", temperature: 60, want: 0},
		{name: "at TEMP_OFF", temperature: 65, want: 0},
		{name: "hysteresis while off", temperature: 66.5, fanWasOn: false, want: 0},
		{name: "hysteresis while on", temperature: 66.5, fanWasOn: true, want: 30},
		{name: "first exact curve point", temperature: 68, want: 30},
		{name: "second exact curve point", temperature: 72, want: 45},
		{name: "third exact curve point", temperature: 75, want: 70},
		{name: "final exact curve point", temperature: 78, want: 100},
		{name: "linear interpolation first segment", temperature: 70, want: 37},
		{name: "linear interpolation second segment", temperature: 73.5, want: 57},
		{name: "linear interpolation final segment", temperature: 76.5, want: 85},
		{name: "above final point", temperature: 90, want: 100},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if got := fanCurve.Percent(test.temperature, test.fanWasOn); got != test.want {
				t.Fatalf("Percent(%v, %v) = %d, want %d", test.temperature, test.fanWasOn, got, test.want)
			}
		})
	}
}
