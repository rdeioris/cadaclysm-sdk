//go:build cadaclysm_separate

package cadaclysm

// The cadaclysm_separate tag: the separate reader library of earlier releases, which
// exports neither flavour call.

/*
#cgo windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -l:cadaclysm_capi.dll
#cgo !windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -lcadaclysm_capi
*/
import "C"

// linked is what this build links, for flavour_test.go.
const linked = "separate"

// Flavour is which library this is: "reader" for the separate cadaclysm_capi of earlier
// releases this build links (the cadaclysm_separate tag).
func Flavour() string { return "reader" }

// Features is the features the library was built with: "" for the separate cadaclysm_capi.
func Features() string { return "" }
