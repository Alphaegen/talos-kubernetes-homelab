package main

import (
	"testing"
	"time"
)

func TestParseSeconds(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		value     string
		allowZero bool
		want      time.Duration
		wantError bool
	}{
		{name: "interval", value: "5", want: 5 * time.Second},
		{name: "fractional interval", value: "0.5", want: 500 * time.Millisecond},
		{name: "startup test disabled", value: "0", allowZero: true, want: 0},
		{name: "zero interval rejected", value: "0", wantError: true},
		{name: "negative rejected", value: "-1", allowZero: true, wantError: true},
		{name: "non-numeric rejected", value: "five", wantError: true},
		{name: "non-finite rejected", value: "NaN", allowZero: true, wantError: true},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := parseSeconds("TEST_SECONDS", test.value, test.allowZero)
			if test.wantError && err == nil {
				t.Fatal("parseSeconds() returned no error")
			}
			if !test.wantError && err != nil {
				t.Fatalf("parseSeconds() error = %v", err)
			}
			if got != test.want {
				t.Fatalf("parseSeconds() = %v, want %v", got, test.want)
			}
		})
	}
}
