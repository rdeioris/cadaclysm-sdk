//go:build cadaclysm_reader && !cadaclysm_separate

package blacksmith

// The cadaclysm_reader tag links the reader flavour, which has no kernel: this package is
// refused at build time, naming the flavours that do, rather than linking a library it
// cannot call. The undefined name below is the message.
//
// the 'reader' flavour has no kernel; load cadaclysm, cadaclysm_kernel_reader or
// cadaclysm_kernel (build without the cadaclysm_reader tag)
var _ = the_reader_flavour_has_no_kernel__build_without_the_cadaclysm_reader_tag
