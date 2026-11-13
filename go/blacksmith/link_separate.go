//go:build cadaclysm_separate

package blacksmith

// The cadaclysm_separate tag: the separate kernel library of earlier releases, which
// exports neither flavour call.

/*
#cgo windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -l:cadaclysm_blacksmith.dll
#cgo !windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -lcadaclysm_blacksmith
*/
import "C"

// Flavour is which library this is: "kernel" for the separate cadaclysm_blacksmith of
// earlier releases this build links (the cadaclysm_separate tag).
func Flavour() string { return "kernel" }

// Features is the features the library was built with: "" for the separate
// cadaclysm_blacksmith.
func Features() string { return "" }
