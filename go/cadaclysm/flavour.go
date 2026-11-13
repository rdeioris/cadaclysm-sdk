//go:build !cadaclysm_separate

package cadaclysm

/*
// cadaclysm_flavour.h's two calls, which every flavour of the single library exports.
const char *cadaclysm_flavour(void);
const char *cadaclysm_features(void);
*/
import "C"

// Flavour is which library this is: "full" or "reader", as the build tag chose (see the
// package comment).
func Flavour() string { return C.GoString(C.cadaclysm_flavour()) }

// Features is the features the library was built with, comma-separated
// ("nodes,kernel,write-breps,write-meshes,bim,parts" for full, "nodes,write-meshes" for the reader).
func Features() string { return C.GoString(C.cadaclysm_features()) }
