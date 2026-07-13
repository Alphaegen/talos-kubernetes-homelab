package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/Alphaegen/talos-kubernetes-homelab/gitops/infra-custom/pi5-fan-control/internal/curve"
	"github.com/Alphaegen/talos-kubernetes-homelab/gitops/infra-custom/pi5-fan-control/internal/rp1"
)

const (
	hostSysRoot        = "/host-sys"
	temperaturePath    = hostSysRoot + "/class/thermal/thermal_zone0/temp"
	defaultTempOff     = "65"
	defaultFanCurve    = "68:30,72:45,75:70,78:100"
	defaultInterval    = "5"
	defaultStartupTest = "2"
)

type config struct {
	nodeName        string
	curve           curve.Curve
	interval        time.Duration
	startupTestTime time.Duration
}

func main() {
	logger := log.New(os.Stdout, "pi5-fan-control ", log.LstdFlags|log.LUTC|log.Lmsgprefix)
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if err := run(ctx, logger); err != nil {
		logger.Printf("fatal: %v", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, logger *log.Logger) error {
	controllerConfig, err := loadConfig()
	if err != nil {
		return fmt.Errorf("invalid configuration: %w", err)
	}

	logger.Printf("node=%s starting interval=%s startup_test=%s curve=%s", controllerConfig.nodeName, controllerConfig.interval, controllerConfig.startupTestTime, controllerConfig.curve.String())

	native, reason, err := rp1.NativeFanControl(hostSysRoot)
	if err != nil {
		return err
	}
	if native {
		logger.Printf("node=%s native fan control detected at %s; RP1 registers will not be modified; controller is inactive", controllerConfig.nodeName, reason)
		<-ctx.Done()
		logger.Printf("node=%s inactive controller stopping", controllerConfig.nodeName)
		return nil
	}

	device, err := rp1.Open(rp1.DefaultResourcePath)
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := device.Close(); closeErr != nil {
			logger.Printf("node=%s error closing RP1 mapping: %v", controllerConfig.nodeName, closeErr)
		}
	}()

	if err = device.InitializePWM(); err != nil {
		return fmt.Errorf("initialize RP1 PWM: %w", err)
	}
	defer func() {
		logger.Printf("node=%s graceful shutdown: setting fan to 100%% before unmapping RP1", controllerConfig.nodeName)
		if shutdownErr := device.SetFanPercent(100); shutdownErr != nil {
			logger.Printf("node=%s fail-safe shutdown write failed: %v", controllerConfig.nodeName, shutdownErr)
		}
	}()

	lastPercent := -1
	if controllerConfig.startupTestTime > 0 {
		if err = device.SetFanPercent(100); err != nil {
			return fmt.Errorf("startup fan test: set fan to 100%%: %w", err)
		}
		lastPercent = 100
		logger.Printf("node=%s startup fan test: fan=100%% duration=%s", controllerConfig.nodeName, controllerConfig.startupTestTime)
		if !wait(ctx, controllerConfig.startupTestTime) {
			return nil
		}
	} else {
		logger.Printf("node=%s startup fan test disabled", controllerConfig.nodeName)
	}

	fanWasOn := false
	for {
		temperature, readErr := readTemperature(temperaturePath)
		if readErr != nil {
			fanWasOn = true
			lastPercent = 100
			if failSafeErr := device.SetFanPercent(100); failSafeErr != nil {
				logger.Printf("node=%s temperature read failed: %v; fail-safe fan=100%% write also failed: %v", controllerConfig.nodeName, readErr, failSafeErr)
			} else {
				logger.Printf("node=%s temperature read failed: %v; fail-safe fan=100%%; will retry", controllerConfig.nodeName, readErr)
			}
		} else {
			percent := controllerConfig.curve.Percent(temperature, fanWasOn)
			if percent != lastPercent {
				if err = device.SetFanPercent(percent); err != nil {
					logger.Printf("node=%s set fan=%d%% failed: %v; attempting fail-safe fan=100%%", controllerConfig.nodeName, percent, err)
					if failSafeErr := device.SetFanPercent(100); failSafeErr != nil {
						logger.Printf("node=%s fail-safe fan=100%% write failed: %v", controllerConfig.nodeName, failSafeErr)
						lastPercent = -1
						fanWasOn = true
						if !wait(ctx, controllerConfig.interval) {
							return nil
						}
						continue
					}
					percent = 100
				}
				logger.Printf("node=%s temperature=%.1fC fan=%d%%", controllerConfig.nodeName, temperature, percent)
				lastPercent = percent
			}
			fanWasOn = lastPercent > 0
		}

		if !wait(ctx, controllerConfig.interval) {
			return nil
		}
	}
}

func loadConfig() (config, error) {
	fanCurve, err := curve.Parse(envOrDefault("TEMP_OFF", defaultTempOff), envOrDefault("FAN_CURVE", defaultFanCurve))
	if err != nil {
		return config{}, err
	}

	interval, err := parseSeconds("INTERVAL_SECONDS", envOrDefault("INTERVAL_SECONDS", defaultInterval), false)
	if err != nil {
		return config{}, err
	}
	startupTestTime, err := parseSeconds("STARTUP_TEST_SECONDS", envOrDefault("STARTUP_TEST_SECONDS", defaultStartupTest), true)
	if err != nil {
		return config{}, err
	}

	return config{
		nodeName:        envOrDefault("NODE_NAME", "unknown"),
		curve:           fanCurve,
		interval:        interval,
		startupTestTime: startupTestTime,
	}, nil
}

func parseSeconds(name, value string, allowZero bool) (time.Duration, error) {
	seconds, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil || math.IsNaN(seconds) || math.IsInf(seconds, 0) || seconds < 0 || (!allowZero && seconds == 0) {
		if allowZero {
			return 0, fmt.Errorf("%s must be a finite number greater than or equal to zero", name)
		}
		return 0, fmt.Errorf("%s must be a finite number greater than zero", name)
	}
	return time.Duration(seconds * float64(time.Second)), nil
}

func envOrDefault(name, fallback string) string {
	if value, ok := os.LookupEnv(name); ok {
		return value
	}
	return fallback
}

func readTemperature(path string) (float64, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	milliCelsius, err := strconv.ParseInt(strings.TrimSpace(string(contents)), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parse %s: %w", path, err)
	}
	return float64(milliCelsius) / 1000, nil
}

func wait(ctx context.Context, duration time.Duration) bool {
	if duration == 0 {
		return !errors.Is(ctx.Err(), context.Canceled)
	}
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
