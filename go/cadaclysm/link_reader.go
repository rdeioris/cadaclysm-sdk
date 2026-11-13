//go:build cadaclysm_reader && !cadaclysm_separate

package cadaclysm

// The cadaclysm_reader tag: the reader flavour, for a program that imports this package
// alone.

/*
#cgo windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -l:cadaclysm_reader.dll
#cgo !windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -lcadaclysm_reader
*/
import "C"

// linked is what this build links, for flavour_test.go.
const linked = "reader"
