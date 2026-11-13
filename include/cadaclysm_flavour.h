/* Which flavour of the single cadaclysm library this is, and the features it was built
 * with. Answered by the four flavour libraries (cadaclysm, cadaclysm_kernel_reader,
 * cadaclysm_kernel, cadaclysm_reader); the separate cadaclysm_capi and cadaclysm_blacksmith
 * libraries of earlier releases do not export them, which is how a caller tells them apart.
 * Both strings are static and never freed. */
#ifndef CADACLYSM_FLAVOUR_H
#define CADACLYSM_FLAVOUR_H

#ifdef __cplusplus
extern "C" {
#endif

/* "full", "kernel-reader", "kernel" or "reader". */
const char *cadaclysm_flavour(void);

/* The features, comma-separated: "nodes,kernel,write-breps,write-meshes,bim,parts" for
 * full, "nodes,write-meshes" for the reader. */
const char *cadaclysm_features(void);

#ifdef __cplusplus
}
#endif

#endif
