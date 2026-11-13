//go:build !cadaclysm_reader && !cadaclysm_separate

package cadaclysm

// The default: the single library's full flavour, which the kernel package links too.

/*
#cgo windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -l:cadaclysm.dll
#cgo !windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -lcadaclysm
*/
import "C"

// linked is what this build links, for flavour_test.go.
const linked = "full"
