/* cadaclysm_viewer.h -- the contract between the cadaclysm SDK and a viewer library.
 *
 * The SDK owns this file; every viewer library in this repository implements it (the
 * terminal viewer, crates/cadaclysm-terminal, is the first). The SDK loads a viewer by
 * path at run time, refuses one whose major version differs, builds a scene from plain
 * arrays and calls show() or view(). Both block: show() until the picture is out, view()
 * until the user closes it.
 *
 * Arrays are copied on add; a scene may be shown or viewed any number of times. A failed
 * call returns false (or null) and cadaclysm_viewer_last_error() says why, per thread.
 * One call at a time per scene.
 */
#ifndef CADACLYSM_VIEWER_H
#define CADACLYSM_VIEWER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CADACLYSM_VIEWER_ABI_MAJOR 1
#define CADACLYSM_VIEWER_ABI_MINOR 0

/* Options.flags */
#define CADACLYSM_VIEWER_NO_EDGES 1u

typedef struct CadaclysmViewerScene CadaclysmViewerScene;

/* Minor versions only append fields: set `size` to sizeof(CadaclysmViewerOptions) and a
 * viewer reads the fields that size covers, defaulting the rest. The same rule runs the
 * other way for view()'s out_last: the caller sets its `size`, the viewer writes at most
 * that many bytes and sets `size` to the bytes it wrote. */
typedef struct CadaclysmViewerOptions {
    uint32_t size;
    uint32_t up;          /* 0 = Z up, 1 = Y up */
    double azimuth;       /* degrees about the up axis from +X (-90 looks from -Y, the front); NaN = viewer default */
    double elevation;     /* degrees above the horizon; NaN = viewer default */
    double zoom;          /* multiplies the viewer's fit; NaN or <= 0 means 1 */
    uint32_t width;       /* pixels; 0 = the viewer decides */
    uint32_t height;      /* pixels; 0 = the viewer decides */
    uint32_t flags;       /* CADACLYSM_VIEWER_NO_EDGES */
    const char *hint;     /* viewer-specific, may be null (terminal: "sixel", "kitty", "blocks") */
} CadaclysmViewerOptions;

/* (CADACLYSM_VIEWER_ABI_MAJOR << 16) | CADACLYSM_VIEWER_ABI_MINOR of the library. */
uint32_t cadaclysm_viewer_abi_version(void);
/* The viewer and its version, e.g. "cadaclysm-terminal 0.1.0". Static. */
const char *cadaclysm_viewer_name(void);
/* This thread's last failure, "" if the last call succeeded. Valid until the next call. */
const char *cadaclysm_viewer_last_error(void);

/* name may be null; it is shown in captions. */
CadaclysmViewerScene *cadaclysm_viewer_scene_new(const char *name_utf8);
void cadaclysm_viewer_scene_free(CadaclysmViewerScene *scene);

/* positions and normals: vertex_count xyz triples; normals may be null.
 * indices: index_count, three to a triangle. matrix: 16 doubles, column-major, may be null.
 * rgba: 4 floats in 0..1, may be null (the viewer's default colour). */
bool cadaclysm_viewer_scene_add_mesh(CadaclysmViewerScene *scene,
                                     const float *positions, const float *normals, uint32_t vertex_count,
                                     const uint32_t *indices, uint32_t index_count,
                                     const double *matrix, const float *rgba);

/* points: point_count xyz triples; counts: polyline_count lengths, summing to at most point_count. */
bool cadaclysm_viewer_scene_add_polylines(CadaclysmViewerScene *scene,
                                          const float *points, uint32_t point_count,
                                          const uint32_t *counts, uint32_t polyline_count,
                                          const double *matrix, const float *rgba);

/* options may be null (all defaults). */
bool cadaclysm_viewer_show(const CadaclysmViewerScene *scene, const CadaclysmViewerOptions *options);
/* out_last may be null; otherwise it receives the camera the user closed on (azimuth,
 * elevation, zoom; the other fields echo options). Set out_last->size to
 * sizeof(CadaclysmViewerOptions) before the call: the viewer writes
 * min(out_last->size, its own sizeof) bytes, then sets out_last->size to the bytes it
 * wrote. A size under 4 writes nothing. */
bool cadaclysm_viewer_view(const CadaclysmViewerScene *scene, const CadaclysmViewerOptions *options,
                           CadaclysmViewerOptions *out_last);

#ifdef __cplusplus
}
#endif

#endif /* CADACLYSM_VIEWER_H */
