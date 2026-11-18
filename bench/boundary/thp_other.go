//go:build !linux

package main

// disableTHP and thpOff are Linux's (thp_linux.go); elsewhere the
// measurements' processes have no transparent huge pages to turn off.
func disableTHP() error { return nil }

func thpOff(int) error { return nil }
