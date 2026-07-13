// Package rp1 provides direct register access to the Raspberry Pi RP1 PWM
// controller used by the Raspberry Pi 5 dedicated fan header.
package rp1

import (
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	DefaultResourcePath = "/host-sys/bus/pci/devices/0002:01:00.0/resource1"
	mappingLength       = 4 * 1024 * 1024

	clockBase           uint32 = 0x18000
	clockPWM1Ctrl              = clockBase + 0x084
	clockPWM1DivInt            = clockBase + 0x088
	clockPWM1DivFrac           = clockBase + 0x08c
	clockPWM1Select            = clockBase + 0x090
	clockCtrlEnable            = uint32(1 << 11)
	clockCtrlSourceMask        = uint32(0x3e1)
	clockAuxSourceXOSC         = uint32(2)
	clockSourceAux             = uint32(1)
	clockSelectAux             = uint32(1 << 1)

	gpioBase          uint32 = 0xd0000
	gpioBank2Offset          = uint32(0x8000)
	gpio45BankPin            = uint32(11)
	gpioControlOffset        = uint32(0x004)
	gpioControlStride        = uint32(8)
	gpioFunctionMask         = uint32(0x1f)
	gpioPWMFunction          = uint32(0)
	gpio45Control            = gpioBase + gpioBank2Offset + gpio45BankPin*gpioControlStride + gpioControlOffset

	pwm1Base          uint32 = 0x9c000
	pwmChannel        uint32 = 3
	pwmGlobalControl         = pwm1Base + 0x000
	pwmChannelControl        = pwm1Base + 0x014 + pwmChannel*16
	pwmRange                 = pwm1Base + 0x018 + pwmChannel*16
	pwmDuty                  = pwm1Base + 0x020 + pwmChannel*16
	pwmChannelDefault        = uint32((1 << 8) | (1 << 3) | (1 << 0))
	pwmChannelEnable         = uint32(1 << pwmChannel)
	pwmSetUpdate             = uint32(1 << 31)
	pwmRangeTicks            = uint32(41566 / 20)
)

// Device is an active mapping of the RP1 PCI BAR1 resource.
type Device struct {
	memory []byte
}

// Open maps RP1 PCI BAR1 for read/write MMIO access.
func Open(resourcePath string) (*Device, error) {
	fileDescriptor, err := unix.Open(resourcePath, unix.O_RDWR|unix.O_SYNC, 0)
	if err != nil {
		return nil, fmt.Errorf("open RP1 PCI resource %s: %w", resourcePath, err)
	}

	memory, mapErr := unix.Mmap(fileDescriptor, 0, mappingLength, unix.PROT_READ|unix.PROT_WRITE, unix.MAP_SHARED)
	closeErr := unix.Close(fileDescriptor)
	if mapErr != nil {
		if closeErr != nil {
			return nil, fmt.Errorf("mmap RP1 PCI resource %s: %w; close resource: %v", resourcePath, mapErr, closeErr)
		}
		return nil, fmt.Errorf("mmap RP1 PCI resource %s: %w", resourcePath, mapErr)
	}
	if closeErr != nil {
		if unmapErr := unix.Munmap(memory); unmapErr != nil {
			return nil, fmt.Errorf("close RP1 PCI resource %s: %v; release mapping: %w", resourcePath, closeErr, unmapErr)
		}
		return nil, fmt.Errorf("close RP1 PCI resource %s: %w", resourcePath, closeErr)
	}

	return &Device{memory: memory}, nil
}

// Close releases the RP1 PCI BAR mapping.
func (device *Device) Close() error {
	if len(device.memory) == 0 {
		return nil
	}
	if err := unix.Munmap(device.memory); err != nil {
		return fmt.Errorf("unmap RP1 PCI resource: %w", err)
	}
	device.memory = nil
	return nil
}

func (device *Device) register(offset uint32) (*uint32, error) {
	if offset%4 != 0 {
		return nil, fmt.Errorf("unaligned RP1 MMIO offset %#x", offset)
	}
	if uint64(offset)+4 > uint64(len(device.memory)) {
		return nil, fmt.Errorf("RP1 MMIO offset %#x is outside mapped BAR", offset)
	}
	return (*uint32)(unsafe.Pointer(&device.memory[offset])), nil
}

func (device *Device) read32(offset uint32) (uint32, error) {
	register, err := device.register(offset)
	if err != nil {
		return 0, err
	}
	return atomic.LoadUint32(register), nil
}

func (device *Device) write32(offset, value uint32) error {
	register, err := device.register(offset)
	if err != nil {
		return err
	}
	atomic.StoreUint32(register, value)
	return nil
}

// InitializePWM configures the 50 MHz RP1 PWM1 clock, GPIO45 function select,
// and PWM1 channel 3. The sequence matches the BSD-0-Clause reference gist and
// Raspberry Pi's rpi-6.12.y clock, pinctrl, PWM driver, and device-tree sources.
func (device *Device) InitializePWM() error {
	clockControl, err := device.read32(clockPWM1Ctrl)
	if err != nil {
		return err
	}
	if err = device.write32(clockPWM1Ctrl, clockControl&^clockCtrlEnable); err != nil {
		return err
	}
	if err = device.write32(clockPWM1DivInt, 1); err != nil {
		return err
	}
	if err = device.write32(clockPWM1DivFrac, 0); err != nil {
		return err
	}

	clockControl, err = device.read32(clockPWM1Ctrl)
	if err != nil {
		return err
	}
	clockControl &^= clockCtrlSourceMask
	clockControl |= clockAuxSourceXOSC << 5
	clockControl |= clockSourceAux
	clockControl |= clockCtrlEnable
	if err = device.write32(clockPWM1Ctrl, clockControl); err != nil {
		return err
	}
	if err = device.write32(clockPWM1Select, clockSelectAux); err != nil {
		return err
	}

	gpioControl, err := device.read32(gpio45Control)
	if err != nil {
		return err
	}
	if gpioControl&gpioFunctionMask != gpioPWMFunction {
		gpioControl = (gpioControl &^ gpioFunctionMask) | gpioPWMFunction
		if err = device.write32(gpio45Control, gpioControl); err != nil {
			return err
		}
	}

	return nil
}

// SetFanPercent updates the inverted PWM duty for PWM1 channel 3.
func (device *Device) SetFanPercent(percent int) error {
	if percent < 0 || percent > 100 {
		return fmt.Errorf("fan percentage must be from 0 to 100, got %d", percent)
	}

	dutyTicks := pwmRangeTicks * uint32(percent) / 100
	if err := device.write32(pwmChannelControl, pwmChannelDefault); err != nil {
		return err
	}
	if err := device.write32(pwmDuty, dutyTicks); err != nil {
		return err
	}
	if err := device.write32(pwmRange, pwmRangeTicks); err != nil {
		return err
	}

	globalControl, err := device.read32(pwmGlobalControl)
	if err != nil {
		return err
	}
	if err = device.write32(pwmGlobalControl, globalControl|pwmChannelEnable); err != nil {
		return err
	}

	globalControl, err = device.read32(pwmGlobalControl)
	if err != nil {
		return err
	}
	return device.write32(pwmGlobalControl, globalControl|pwmSetUpdate)
}

// NativeFanControl reports a bound cooling-fan driver or hwmon child. It must
// be called before Open and InitializePWM to avoid conflicting register access.
func NativeFanControl(hostSysRoot string) (bool, string, error) {
	devicePaths := []string{
		filepath.Join(hostSysRoot, "devices/platform/cooling_fan"),
		filepath.Join(hostSysRoot, "bus/platform/devices/cooling_fan"),
	}

	for _, devicePath := range devicePaths {
		if _, err := os.Lstat(filepath.Join(devicePath, "driver")); err == nil {
			return true, filepath.Join(devicePath, "driver"), nil
		} else if !os.IsNotExist(err) {
			return false, "", fmt.Errorf("inspect native fan driver: %w", err)
		}

		hwmonEntries, err := filepath.Glob(filepath.Join(devicePath, "hwmon", "hwmon*"))
		if err != nil {
			return false, "", fmt.Errorf("inspect native fan hwmon children: %w", err)
		}
		if len(hwmonEntries) > 0 {
			return true, hwmonEntries[0], nil
		}
	}

	return false, "", nil
}
