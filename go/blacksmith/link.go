//go:build !cadaclysm_reader && !cadaclysm_separate

package blacksmith

// The default: the single library's full flavour, which the reader package links too --
// one library, one licence, one error slot.

/*
#cgo windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -l:cadaclysm.dll
#cgo !windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -lcadaclysm
// cadaclysm_flavour.h's two calls, which every flavour of the single library exports.
const char *cadaclysm_flavour(void);
const char *cadaclysm_features(void);
*/
import "C"

// Flavour is which library this is: "full", the flavour this build links (see the reader
// package's comment for the build tags).
func Flavour() string { return C.GoString(C.cadaclysm_flavour()) }

// Features is the features the library was built with, comma-separated
// ("nodes,kernel,write-breps,write-meshes,bim,parts").
func Features() string { return C.GoString(C.cadaclysm_features()) }
