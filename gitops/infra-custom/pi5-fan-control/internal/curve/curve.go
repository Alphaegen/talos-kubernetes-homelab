// Package curve parses and evaluates a temperature-based fan curve.
package curve

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// Point maps a CPU temperature in degrees Celsius to a PWM duty percentage.
type Point struct {
	Temperature float64
	Percent     int
}

// Curve contains the off threshold and ordered interpolation points.
type Curve struct {
	OffTemperature float64
	Points         []Point
}

// Parse validates and parses TEMP_OFF and FAN_CURVE values.
func Parse(offValue, curveValue string) (Curve, error) {
	offTemperature, err := strconv.ParseFloat(strings.TrimSpace(offValue), 64)
	if err != nil || math.IsNaN(offTemperature) || math.IsInf(offTemperature, 0) {
		return Curve{}, fmt.Errorf("TEMP_OFF must be a finite number: %q", offValue)
	}

	entries := strings.Split(curveValue, ",")
	if len(entries) == 0 || strings.TrimSpace(curveValue) == "" {
		return Curve{}, fmt.Errorf("FAN_CURVE must contain at least one temperature:percentage point")
	}

	points := make([]Point, 0, len(entries))
	for _, entry := range entries {
		parts := strings.Split(entry, ":")
		if len(parts) != 2 {
			return Curve{}, fmt.Errorf("invalid FAN_CURVE point %q; expected temperature:percentage", entry)
		}

		temperature, parseErr := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64)
		if parseErr != nil || math.IsNaN(temperature) || math.IsInf(temperature, 0) {
			return Curve{}, fmt.Errorf("temperature in FAN_CURVE point %q must be finite", entry)
		}

		percent, parseErr := strconv.Atoi(strings.TrimSpace(parts[1]))
		if parseErr != nil || percent < 0 || percent > 100 {
			return Curve{}, fmt.Errorf("percentage in FAN_CURVE point %q must be an integer from 0 to 100", entry)
		}

		points = append(points, Point{Temperature: temperature, Percent: percent})
	}

	if points[0].Temperature <= offTemperature {
		return Curve{}, fmt.Errorf("first FAN_CURVE temperature %.1f must be greater than TEMP_OFF %.1f", points[0].Temperature, offTemperature)
	}

	for index := 1; index < len(points); index++ {
		if points[index].Temperature <= points[index-1].Temperature {
			return Curve{}, fmt.Errorf("FAN_CURVE temperatures must be strictly increasing")
		}
		if points[index].Percent < points[index-1].Percent {
			return Curve{}, fmt.Errorf("FAN_CURVE percentages must not decrease")
		}
	}

	return Curve{OffTemperature: offTemperature, Points: points}, nil
}

// Percent returns the integer duty percentage for a temperature. Values
// between curve points are linearly interpolated and truncated to a whole
// percentage so minor sensor changes do not produce noisy logs or MMIO writes.
func (fanCurve Curve) Percent(temperature float64, fanWasOn bool) int {
	if temperature <= fanCurve.OffTemperature {
		return 0
	}

	first := fanCurve.Points[0]
	if temperature < first.Temperature {
		if fanWasOn {
			return first.Percent
		}
		return 0
	}

	last := fanCurve.Points[len(fanCurve.Points)-1]
	if temperature >= last.Temperature {
		return last.Percent
	}

	for index := 0; index < len(fanCurve.Points)-1; index++ {
		lower := fanCurve.Points[index]
		upper := fanCurve.Points[index+1]
		if temperature >= lower.Temperature && temperature < upper.Temperature {
			ratio := (temperature - lower.Temperature) / (upper.Temperature - lower.Temperature)
			return lower.Percent + int(float64(upper.Percent-lower.Percent)*ratio)
		}
	}

	return last.Percent
}

// String returns a concise representation suitable for startup logs.
func (fanCurve Curve) String() string {
	parts := make([]string, 0, len(fanCurve.Points))
	for _, point := range fanCurve.Points {
		parts = append(parts, fmt.Sprintf("%gC:%d%%", point.Temperature, point.Percent))
	}
	return fmt.Sprintf("off<=%gC hysteresis<%gC points=[%s]", fanCurve.OffTemperature, fanCurve.Points[0].Temperature, strings.Join(parts, ","))
}
