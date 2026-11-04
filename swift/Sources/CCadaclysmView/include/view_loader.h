/* view_loader.h -- open a view library (cadaclysm_view.h) at run time, for the wrappers
 * that link the reader and the kernel: Go, Swift and C++. Every call of the view goes
 * through a table filled by dlopen/LoadLibrary, so choosing the library (the terminal,
 * wgpu, any other) is a run-time matter and a missing one is a message, not a loader
 * failure at start.
 *
 * The canonical copy is crates/cadaclysm-capi/examples/cpp/include/cadaclysm/view_loader.h;
 * go/view/view_loader.h and swift/Sources/CCadaclysmView/include/view_loader.h are copies,
 * byte for byte (line endings aside), checked by crates/cadaclysm-capi/tests/bindings.rs.
 * Valid C99 and C++17 (a strict -std=c99 on glibc: include it first, see below); every
 * function is static inline. Not thread-safe by itself: a wrapper serialises its own
 * table. cvl_draw_object with a `hint` sets CADACLYSM_TERMINAL_GRAPHICS process-wide around
 * its create and then restores (or unsets) it: another thread reading the environment then
 * sees the hint. */
#ifndef CADACLYSM_VIEW_LOADER_H
#define CADACLYSM_VIEW_LOADER_H

/* setenv, readlink, nanosleep: POSIX, which a strict -std=c99/c11 hides on glibc. Asked for
 * here only where nothing chose a feature set; it takes effect when this header is the first
 * one a translation unit includes. */
#if !defined(_WIN32) && !defined(__APPLE__) && defined(__STRICT_ANSI__) && !defined(_POSIX_C_SOURCE) && \
    !defined(_XOPEN_SOURCE) && !defined(_GNU_SOURCE) && !defined(_DEFAULT_SOURCE)
#  define _POSIX_C_SOURCE 200809L
#endif

/* The C headers first: cadaclysm_view.h uses size_t without including stddef.h. */
#include <math.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <cadaclysm_view.h>

/* A strict -std=c99/c11 on glibc with another header included first: the define above came
 * too late, and setenv/readlink/nanosleep would be implicit declarations. */
#if defined(__GLIBC__) && defined(__STRICT_ANSI__) && !defined(__USE_XOPEN2K8)
#  error "view_loader.h: include it first, or build with -std=gnu99 / -D_POSIX_C_SOURCE=200809L"
#endif

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#    define CVL_UNDEF_LEAN
#  endif
#  ifndef NOMINMAX
#    define NOMINMAX
#    define CVL_UNDEF_NOMINMAX
#  endif
#  include <windows.h>
#  ifdef CVL_UNDEF_LEAN
#    undef WIN32_LEAN_AND_MEAN
#    undef CVL_UNDEF_LEAN
#  endif
#  ifdef CVL_UNDEF_NOMINMAX
#    undef NOMINMAX
#    undef CVL_UNDEF_NOMINMAX
#  endif
#else
#  include <dlfcn.h>
#  include <sys/stat.h>
#  include <unistd.h>
#  if defined(__APPLE__)
#    include <mach-o/dyld.h>
#  endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define CVL_API static inline
#define CVL_PATH 4096
#define CVL_ERROR 8192
#define CVL_NO_NODE 0xFFFFFFFFu
#define CVL_ABI_MINOR 18u
#define CVL_PI 3.14159265358979323846
#define CVL_RADIANS_PER_PIXEL 0.01 /* cadaclysm_view::view::ORBIT_PER_PIXEL */
#define CVL_ZOOM_PER_STEP 0.9      /* cadaclysm_view::view::ZOOM_PER_STEP */

/* name, return type, parameters: 86 calls of cadaclysm_view.h 1.18 -- every one but 1.14's analysis calls
 * and 1.12's texture targets, which no linked wrapper uses yet -- in the header's order (a binding test
 * counts them against the header). */
#define CVL_CALLS(X) \
    X(abi_version, uint32_t, (void))                                                               \
    X(last_error, const char *, (void))                                                            \
    X(name, const char *, (void))                                                                  \
    X(parse_colour, bool, (const char *, float *))                                                 \
    X(create, CadaclysmView *, (const CadaclysmViewWindow *, const CadaclysmViewOptions *))        \
    X(destroy, void, (CadaclysmView *))                                                            \
    X(pump, uint32_t, (CadaclysmView *, uint32_t))                                                 \
    X(run, bool, (CadaclysmView *, CadaclysmViewCamera *, CadaclysmViewPick *))                    \
    X(resize, bool, (CadaclysmView *, uint32_t, uint32_t))                                         \
    X(needs_draw, bool, (const CadaclysmView *))                                                   \
    X(draw, bool, (CadaclysmView *))                                                               \
    X(size, bool, (CadaclysmView *, uint32_t *, uint32_t *))                                       \
    X(image, bool, (CadaclysmView *, uint8_t *, size_t))                                           \
    X(show, uint32_t, (CadaclysmView *, const CadaclysmScene *))                                   \
    X(remove, bool, (CadaclysmView *, uint32_t))                                                   \
    X(set_surfaces, bool, (CadaclysmView *, uint32_t))                                             \
    X(surfaces, uint32_t, (const CadaclysmView *))                                                 \
    X(orbit, void, (CadaclysmView *, float, float))                                                \
    X(pan, void, (CadaclysmView *, float, float))                                                  \
    X(zoom, void, (CadaclysmView *, float))                                                        \
    X(frame, bool, (CadaclysmView *, uint32_t))                                                    \
    X(standard, bool, (CadaclysmView *, uint32_t))                                                 \
    X(set_orthographic, void, (CadaclysmView *, bool))                                             \
    X(set_layer, bool, (CadaclysmView *, uint32_t, bool))                                          \
    X(set_background, void, (CadaclysmView *, const float *))                                      \
    X(set_lighting, bool, (CadaclysmView *, uint32_t))                                             \
    X(lighting, uint32_t, (const CadaclysmView *))                                                 \
    X(set_lod, bool, (CadaclysmView *, const CadaclysmViewLod *))                                  \
    X(wake_ms, uint32_t, (const CadaclysmView *))                                                  \
    X(set_node_visible, bool, (CadaclysmView *, uint32_t, uint32_t, bool))                         \
    X(set_node_color, bool, (CadaclysmView *, uint32_t, uint32_t, const float *))                  \
    X(set_node_highlight, bool, (CadaclysmView *, uint32_t, uint32_t, const float *))              \
    X(set_viewports, bool, (CadaclysmView *, const CadaclysmViewViewport *, uint32_t))             \
    X(request_pick, void, (CadaclysmView *, uint32_t, uint32_t))                                   \
    X(request_pick_in, void, (CadaclysmView *, uint32_t, uint32_t, uint32_t))                      \
    X(pick_result, bool, (CadaclysmView *, CadaclysmViewPick *))                                   \
    X(frame_node, bool, (CadaclysmView *, uint32_t, uint32_t))                                     \
    X(set_double_click_frames, void, (CadaclysmView *, bool))                                      \
    X(focus, bool, (CadaclysmView *, const float *))                                               \
    X(navigation, uint32_t, (CadaclysmView *))                                                     \
    X(look, void, (CadaclysmView *, float, float))                                                 \
    X(dolly, void, (CadaclysmView *, float))                                                       \
    X(input, uint32_t, (CadaclysmView *, const CadaclysmViewEvent *))                              \
    X(show_mesh, uint32_t, (CadaclysmView *, const CadaclysmViewMesh *))                           \
    X(show_lines, uint32_t, (CadaclysmView *, const float *, uint32_t, const float *))             \
    X(show_points, uint32_t, (CadaclysmView *, const float *, uint32_t, const float *, float))     \
    X(show_curves, uint32_t, (CadaclysmView *, const float *, uint32_t, const float *))            \
    X(show_image, uint32_t, (CadaclysmView *, const CadaclysmViewImage *))                         \
    X(set_colour, bool, (CadaclysmView *, uint32_t, const float *))                                \
    X(set_xray, bool, (CadaclysmView *, uint32_t, bool))                                           \
    X(set_occluded, bool, (CadaclysmView *, uint32_t, uint32_t))                                   \
    X(set_finish, bool, (CadaclysmView *, uint32_t, uint32_t))                                     \
    X(set_face_colours, bool, (CadaclysmView *, uint32_t, const uint32_t *, const float *, uint32_t)) \
    X(set_placement, bool, (CadaclysmView *, uint32_t, const double *))                            \
    X(set_node_transforms, bool, (CadaclysmView *, uint32_t, const double *, uint32_t))            \
    X(show_machining, uint32_t, (CadaclysmView *, const CadaclysmViewMachining *))               \
    X(machining_seek, bool, (CadaclysmView *, uint32_t, uint32_t))                               \
    X(machining_colour_by, bool, (CadaclysmView *, uint32_t, uint32_t))                          \
    X(machining_overlays, bool, (CadaclysmView *, uint32_t, bool, bool))                         \
    X(machining_info, bool, (CadaclysmView *, uint32_t, CadaclysmViewMachiningInfo *))           \
    X(machining_heights, bool, (CadaclysmView *, uint32_t, float *, size_t))                     \
    X(timeline_play, bool, (CadaclysmView *, double))                                            \
    X(timeline_pause, bool, (CadaclysmView *))                                                   \
    X(timeline_seek, bool, (CadaclysmView *, double))                                            \
    X(timeline_set_loop, bool, (CadaclysmView *, bool))                                          \
    X(timeline_time, double, (const CadaclysmView *))                                            \
    X(timeline_duration, double, (const CadaclysmView *))                                        \
    X(timeline_playing, bool, (const CadaclysmView *))                                           \
    X(timeline_status, size_t, (const CadaclysmView *, char *, size_t))                          \
    X(show_solid, uint32_t, (CadaclysmView *, const CadaclysmBlacksmithSolid *, double, const float *)) \
    X(load_font, uint32_t, (const uint8_t *, size_t))                                              \
    X(show_text, uint32_t, (CadaclysmView *, const CadaclysmViewText *))                           \
    X(set_text, bool, (CadaclysmView *, uint32_t, const char *))                                  \
    X(viewport_camera, bool, (const CadaclysmView *, uint32_t, CadaclysmViewViewportCamera *))    \
    X(set_viewport_camera, bool, (CadaclysmView *, uint32_t, const CadaclysmViewViewportCamera *))\
    X(set_viewport_rects, bool, (CadaclysmView *, const uint32_t *, uint32_t))                    \
    X(aim, bool, (CadaclysmView *, uint32_t, const float *, const float *))                       \
    X(set_pivot, bool, (CadaclysmView *, uint32_t, const float *))                                \
    X(set_tap, bool, (CadaclysmView *, float, double))                                            \
    X(orbit_in, void, (CadaclysmView *, uint32_t, float, float))                                  \
    X(pan_in, void, (CadaclysmView *, uint32_t, float, float))                                    \
    X(zoom_in, void, (CadaclysmView *, uint32_t, float))                                          \
    X(look_in, void, (CadaclysmView *, uint32_t, float, float))                                   \
    X(dolly_in, void, (CadaclysmView *, uint32_t, float))                                         \
    X(frame_in, bool, (CadaclysmView *, uint32_t, uint32_t))                                      \
    X(standard_in, bool, (CadaclysmView *, uint32_t, uint32_t))

typedef struct CvlTable {
    void *library;
    char path[CVL_PATH];
    char label[256]; /* cadaclysm_view_name(): "cadaclysm-view <v>" or "cadaclysm-terminal <v>" */
#define CVL_FIELD(n, r, p) r(*n) p;
    CVL_CALLS(CVL_FIELD)
#undef CVL_FIELD
} CvlTable;

/* ---- text ------------------------------------------------------------------------- */

CVL_API int cvl_fail(char *err, size_t n, const char *format, ...) {
    va_list args;
    va_start(args, format);
    if (err && n) vsnprintf(err, n, format, args);
    va_end(args);
    return 0;
}

CVL_API void cvl_copy(char *out, size_t n, const char *text) {
    size_t len = strlen(text);
    if (n == 0) return;
    if (len >= n) len = n - 1;
    memcpy(out, text, len);
    out[len] = 0;
}

CVL_API void cvl_append(char *out, size_t n, const char *text) {
    size_t used = strlen(out);
    if (used < n) cvl_copy(out + used, n - used, text);
}

CVL_API void cvl_join(const char *dir, const char *file, char *out, size_t n) {
    size_t len;
    cvl_copy(out, n, dir);
    len = strlen(out);
    if (len && out[len - 1] != '/' && out[len - 1] != '\\') cvl_append(out, n, "/");
    cvl_append(out, n, file);
}

CVL_API void cvl_dirname(char *path) {
    char *slash = strrchr(path, '/');
    char *back = strrchr(path, '\\');
    char *cut = slash;
    if (back && (!cut || back > cut)) cut = back;
    if (cut) *cut = 0;
    else path[0] = 0;
}

CVL_API void cvl_file_name(const char *stem, char *out, size_t n) {
#if defined(_WIN32)
    cvl_copy(out, n, stem);
    cvl_append(out, n, ".dll");
#elif defined(__APPLE__)
    cvl_copy(out, n, "lib");
    cvl_append(out, n, stem);
    cvl_append(out, n, ".dylib");
#else
    cvl_copy(out, n, "lib");
    cvl_append(out, n, stem);
    cvl_append(out, n, ".so");
#endif
}

/* ---- the platform ---------------------------------------------------------------- */

#if defined(_WIN32)
CVL_API int cvl_wide(const char *utf8, wchar_t *out, int n) {
    return MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, n) > 0;
}
CVL_API int cvl_narrow(const wchar_t *wide, char *out, int n) {
    return WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, n, NULL, NULL) > 0;
}
#endif

/* The environment as the process has it now. Windows reads the process block
 * (GetEnvironmentVariableW), not the C runtime's copy: Go's os.Setenv and Swift's
 * setenv reach the former, and Rust's std::env (inside the view libraries) reads it. */
CVL_API int cvl_getenv(const char *name, char *out, size_t n) {
#if defined(_WIN32)
    wchar_t wname[128];
    wchar_t value[CVL_PATH];
    DWORD got;
    if (!cvl_wide(name, wname, 128)) return 0;
    got = GetEnvironmentVariableW(wname, value, CVL_PATH);
    if (got == 0 || got >= CVL_PATH) return 0;
    return cvl_narrow(value, out, (int)n) && out[0];
#else
    const char *value = getenv(name);
    if (!value || !value[0]) return 0;
    cvl_copy(out, n, value);
    return 1;
#endif
}

/* `value` NULL: unset. */
CVL_API void cvl_setenv(const char *name, const char *value) {
#if defined(_WIN32)
    wchar_t wname[128];
    wchar_t wvalue[CVL_PATH];
    if (!cvl_wide(name, wname, 128)) return;
    if (value && cvl_wide(value, wvalue, CVL_PATH)) SetEnvironmentVariableW(wname, wvalue);
    else SetEnvironmentVariableW(wname, NULL);
#else
    if (value) setenv(name, value, 1);
    else unsetenv(name);
#endif
}

/* 0: nothing there, 1: a file, 2: a directory. */
CVL_API int cvl_kind(const char *path) {
#if defined(_WIN32)
    wchar_t w[CVL_PATH];
    DWORD attributes;
    if (!cvl_wide(path, w, CVL_PATH)) return 0;
    attributes = GetFileAttributesW(w);
    if (attributes == INVALID_FILE_ATTRIBUTES) return 0;
    return (attributes & FILE_ATTRIBUTE_DIRECTORY) ? 2 : 1;
#else
    struct stat s;
    if (stat(path, &s) != 0) return 0;
    return S_ISDIR(s.st_mode) ? 2 : 1;
#endif
}

/* The directory of a library this process has already loaded, by its stem; 0 if none. */
CVL_API int cvl_loaded_dir(const char *stem, char *out, size_t n) {
    char file[256];
    cvl_file_name(stem, file, sizeof file);
    out[0] = 0;
#if defined(_WIN32)
    {
        wchar_t wfile[256];
        wchar_t wpath[CVL_PATH];
        HMODULE module;
        DWORD got;
        if (!cvl_wide(file, wfile, 256)) return 0;
        module = GetModuleHandleW(wfile);
        if (!module) return 0;
        got = GetModuleFileNameW(module, wpath, CVL_PATH);
        if (got == 0 || got >= CVL_PATH || !cvl_narrow(wpath, out, (int)n)) return 0;
    }
#elif defined(__APPLE__)
    {
        uint32_t i, count = _dyld_image_count();
        size_t lf = strlen(file);
        for (i = 0; i < count; ++i) {
            const char *image = _dyld_get_image_name(i);
            size_t li = image ? strlen(image) : 0;
            if (li > lf && image[li - lf - 1] == '/' && strcmp(image + li - lf, file) == 0) {
                cvl_copy(out, n, image);
                break;
            }
        }
    }
#else
    {
        char line[CVL_PATH + 256];
        size_t lf = strlen(file);
        FILE *maps = fopen("/proc/self/maps", "r");
        if (!maps) return 0;
        while (fgets(line, sizeof line, maps)) {
            char *path = strchr(line, '/');
            size_t lp;
            if (!path) continue;
            path[strcspn(path, "\n")] = 0;
            lp = strlen(path);
            if (lp > lf && path[lp - lf - 1] == '/' && strcmp(path + lp - lf, file) == 0) {
                cvl_copy(out, n, path);
                break;
            }
        }
        fclose(maps);
    }
#endif
    if (!out[0]) return 0;
    cvl_dirname(out);
    return out[0] != 0;
}

CVL_API int cvl_exe_dir(char *out, size_t n) {
#if defined(_WIN32)
    wchar_t w[CVL_PATH];
    DWORD got = GetModuleFileNameW(NULL, w, CVL_PATH);
    if (got == 0 || got >= CVL_PATH || !cvl_narrow(w, out, (int)n)) return 0;
#elif defined(__APPLE__)
    uint32_t size = (uint32_t)n;
    if (_NSGetExecutablePath(out, &size) != 0) return 0;
#else
    ssize_t got = readlink("/proc/self/exe", out, n - 1);
    if (got <= 0) return 0;
    out[got] = 0;
#endif
    cvl_dirname(out);
    return out[0] != 0;
}

CVL_API void *cvl_dlopen(const char *path, char *err, size_t n) {
#if defined(_WIN32)
    wchar_t w[CVL_PATH];
    wchar_t full[CVL_PATH];
    HMODULE module;
    int has_dir = 0;
    size_t i;
    DWORD got, code, mode = 0;
    BOOL quiet;
    if (!cvl_wide(path, w, CVL_PATH)) {
        cvl_fail(err, n, "not a UTF-8 path");
        return NULL;
    }
    for (i = 0; w[i]; ++i) {
        if (w[i] == L'/') w[i] = L'\\';
        if (w[i] == L'\\' || w[i] == L':') has_dir = 1;
    }
    if (has_dir) {
        /* LOAD_WITH_ALTERED_SEARCH_PATH is defined for an absolute path only: a relative one
         * (dir\x.dll) is made absolute first, so its dependencies are found beside it. */
        got = GetFullPathNameW(w, CVL_PATH, full, NULL);
        if (got == 0 || got >= CVL_PATH) {
            cvl_fail(err, n, "Windows error %lu", (unsigned long)GetLastError());
            return NULL;
        }
    }
    /* A file that is no library raises Windows' "Bad Image" box unless the error mode says
     * otherwise, and a box nobody can close hangs a headless run: the loader's reason is the
     * message instead. */
    quiet = SetThreadErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX, &mode);
    module = has_dir ? LoadLibraryExW(full, NULL, LOAD_WITH_ALTERED_SEARCH_PATH) : LoadLibraryExW(w, NULL, 0);
    code = module ? 0 : GetLastError();
    if (quiet) SetThreadErrorMode(mode, NULL);
    if (!module) {
        cvl_fail(err, n, "Windows error %lu", (unsigned long)code);
        return NULL;
    }
    return (void *)module;
#else
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *why = dlerror();
        cvl_fail(err, n, "%s", why ? why : "dlopen failed");
    }
    return handle;
#endif
}

/* Fills the function pointer at `slot` (the address of a table field). */
CVL_API int cvl_symbol(void *library, const char *name, void *slot) {
#if defined(_WIN32)
    FARPROC f = GetProcAddress((HMODULE)library, name);
#else
    void *f = dlsym(library, name);
#endif
    if (!f) return 0;
    memcpy(slot, &f, sizeof f);
    return 1;
}

/* ---- finding and opening ----------------------------------------------------------- */

/* Where the library `stem` is, without opening it for the table: `variable` (the library
 * or its directory) when set; else beside the loaded reader, beside the executable, each
 * of `dirs`; else the bare file name, if the platform loader finds it. 1 and `out`, or 0
 * and the message in `err`: "no view library: ..." where nothing was found (Python's
 * wording: `what` "terminal" names "the terminal library", anything else the file), the
 * variable's own "names nothing that exists" where it names something wrong. */
CVL_API int cvl_find(const char *stem, const char *variable, const char *what, const char *const *dirs,
                     size_t dir_count, char *out, size_t out_size, char *err, size_t err_size) {
    char file[256];
    char value[CVL_PATH];
    char dir[CVL_PATH];
    char candidate[CVL_PATH];
    char searched[CVL_ERROR];
    char why[1024];
    size_t step;
    void *bare;
    cvl_file_name(stem, file, sizeof file);
    if (cvl_getenv(variable, value, sizeof value)) {
        int kind = cvl_kind(value);
        if (kind == 1) {
            cvl_copy(out, out_size, value);
            return 1;
        }
        if (kind == 2) {
            cvl_join(value, file, candidate, sizeof candidate);
            if (cvl_kind(candidate) == 1) {
                cvl_copy(out, out_size, candidate);
                return 1;
            }
            /* Python's cadaclysm_terminal.py names the missing file; cadaclysm_view.py does not. */
            if (strcmp(what, "terminal") == 0)
                return cvl_fail(err, err_size, "%s=%s names nothing that exists (no %s in that directory)",
                                variable, value, file);
            return cvl_fail(err, err_size, "%s=%s names nothing that exists", variable, value);
        }
        return cvl_fail(err, err_size, "%s=%s names nothing that exists", variable, value);
    }
    searched[0] = 0;
    for (step = 0; step < 2 + dir_count; ++step) {
        int have;
        if (step == 0) have = cvl_loaded_dir("cadaclysm_capi", dir, sizeof dir);
        else if (step == 1) have = cvl_exe_dir(dir, sizeof dir);
        else {
            const char *given = dirs ? dirs[step - 2] : NULL;
            cvl_copy(dir, sizeof dir, given ? given : "");
            have = dir[0] != 0;
        }
        if (!have) continue;
        cvl_join(dir, file, candidate, sizeof candidate);
        if (cvl_kind(candidate) == 1) {
            cvl_copy(out, out_size, candidate);
            return 1;
        }
        if (searched[0]) cvl_append(searched, sizeof searched, ", ");
        cvl_append(searched, sizeof searched, candidate);
    }
    bare = cvl_dlopen(file, why, sizeof why);
    if (bare) {
        cvl_copy(out, out_size, file);
        return 1;
    }
    if (searched[0]) cvl_append(searched, sizeof searched, ", ");
    cvl_append(searched, sizeof searched, file);
    cvl_append(searched, sizeof searched, " on the loader's path");
    /* Python's cadaclysm_view.py words, word for word but for the call to name: */
    if (strcmp(what, "terminal") == 0)
        return cvl_fail(err, err_size,
                        "no view library: the terminal library was not found (searched: %s) -- reinstall "
                        "cadaclysm, set %s to the library, or set CADACLYSM_VIEW",
                        searched, variable);
    return cvl_fail(err, err_size,
                    "no view library: %s was not found (searched: %s) -- reinstall cadaclysm, set %s to it, "
                    "or use the terminal",
                    file, searched, variable);
}

/* A library's cadaclysm_view_abi_version() answer against the table's: 1.x, x >= 18
 * (CVL_ABI_MINOR). 1, or 0 and the refusal (Python's words) in `err`. */
CVL_API int cvl_check_abi(uint32_t version, const char *path, char *err, size_t n) {
    uint32_t major = version >> 16, minor = version & 0xFFFFu;
    if (major != 1u || minor < CVL_ABI_MINOR)
        return cvl_fail(err, n, "%s: view ABI %u.%u, this SDK needs 1.%u or a later 1.x", path, (unsigned)major,
                        (unsigned)minor, (unsigned)CVL_ABI_MINOR);
    return 1;
}

/* Opens `path` into `t`: the ABI version first (cvl_check_abi), then every call. */
CVL_API int cvl_open(CvlTable *t, const char *path, char *err, size_t n) {
    CvlTable fresh;
    char why[1024];
    void *library;
    memset(&fresh, 0, sizeof fresh);
    library = cvl_dlopen(path, why, sizeof why);
    if (!library) return cvl_fail(err, n, "%s: could not load the view library: %s", path, why);
    if (!cvl_symbol(library, "cadaclysm_view_abi_version", &fresh.abi_version))
        return cvl_fail(err, n, "%s: not a view library (no cadaclysm_view_abi_version)", path);
    if (!cvl_check_abi(fresh.abi_version(), path, err, n)) return 0;
#define CVL_BIND(n_, r, p)                                                    \
    if (!cvl_symbol(library, "cadaclysm_view_" #n_, &fresh.n_))               \
        return cvl_fail(err, n, "%s: not a view library (no cadaclysm_view_" #n_ ")", path);
    CVL_CALLS(CVL_BIND)
#undef CVL_BIND
    fresh.library = library;
    cvl_copy(fresh.path, sizeof fresh.path, path);
    {
        const char *label = fresh.name();
        cvl_copy(fresh.label, sizeof fresh.label, label ? label : "");
    }
    *t = fresh;
    return 1;
}

/* "terminal", "wgpu" or a path. */
CVL_API int cvl_use(CvlTable *t, const char *which, const char *const *dirs, size_t count, char *err, size_t n) {
    char path[CVL_PATH];
    if (strcmp(which, "terminal") == 0) {
        if (!cvl_find("cadaclysm_terminal", "CADACLYSM_TERMINAL_LIBRARY", "terminal", dirs, count, path, sizeof path,
                      err, n))
            return 0;
    } else if (strcmp(which, "wgpu") == 0) {
        if (!cvl_find("cadaclysm_view", "CADACLYSM_VIEW_LIBRARY", "wgpu", dirs, count, path, sizeof path, err, n))
            return 0;
    } else {
        cvl_copy(path, sizeof path, which);
    }
    return cvl_open(t, path, err, n);
}

/* The library a wrapper uses when none was chosen, as Python's current(): CADACLYSM_VIEW
 * ("terminal", "wgpu" or a path, opened as given), else the terminal. */
CVL_API int cvl_default(CvlTable *t, const char *const *dirs, size_t count, char *err, size_t n) {
    char value[CVL_PATH];
    if (!cvl_getenv("CADACLYSM_VIEW", value, sizeof value)) return cvl_use(t, "terminal", dirs, count, err, n);
    return cvl_use(t, value, dirs, count, err, n);
}

CVL_API int cvl_is_terminal(const CvlTable *t) { return strncmp(t->label, "cadaclysm-terminal ", 19) == 0; }

/* The wgpu library (cadaclysm_view): Python's kind "wgpu", the one whose show() runs a
 * window. Anything else -- the terminal or a library of one's own -- draws a still. */
CVL_API int cvl_is_wgpu(const CvlTable *t) { return strncmp(t->label, "cadaclysm-view ", 15) == 0; }

/* The library's last message, or Python's fallback when it left none. */
CVL_API const char *cvl_error(const CvlTable *t) {
    const char *said = t->last_error();
    return (said && said[0]) ? said : "the view library failed";
}

/* A failed create, as Python's View(): the library's bare message, plus `no_display` (the
 * skin's " -- draw without a display with <offscreen>, or <the terminal>"; NULL: none) when
 * the message says "no display". Returns 0. */
CVL_API int cvl_create_failed(const CvlTable *t, const char *no_display, char *err, size_t n) {
    const char *said = cvl_error(t);
    if (no_display && strstr(said, "no display")) return cvl_fail(err, n, "%s%s", said, no_display);
    return cvl_fail(err, n, "%s", said);
}

/* ---- views -------------------------------------------------------------------------- */

CVL_API CadaclysmView *cvl_create(const CvlTable *t, const CadaclysmViewWindow *window, const char *title,
                                  uint32_t width, uint32_t height, uint32_t surfaces, uint32_t y_up,
                                  uint32_t offscreen) {
    CadaclysmViewOptions o;
    memset(&o, 0, sizeof o);
    o.size = (uint32_t)sizeof o;
    o.surfaces = surfaces;
    o.y_up = y_up;
    o.title = (title && title[0]) ? title : NULL;
    o.width = width;
    o.height = height;
    o.offscreen = offscreen;
    return t->create(window, &o);
}

CVL_API void cvl_sleep_ms(unsigned ms) {
#if defined(_WIN32)
    Sleep(ms);
#else
    struct timespec wait;
    wait.tv_sec = (time_t)(ms / 1000u);
    wait.tv_nsec = (long)(ms % 1000u) * 1000000L;
    nanosleep(&wait, NULL);
#endif
}

/* Python's View.pick: a view never drawn (`*drawn` 0) is drawn first -- the library answers
 * from the frame it has drawn -- then the pick is asked and frames are drawn, 10 ms apart, until
 * it lands (at most 200). 1 with `out` (`out->item` 0: nothing there); 0 with the library's own
 * message (or cvl_error's fallback) for any failure but "no pick result", or "pick: the answer
 * never landed (...)". */
CVL_API int cvl_pick(const CvlTable *t, CadaclysmView *v, int *drawn, uint32_t viewport, uint32_t x, uint32_t y,
                     CadaclysmViewPick *out, char *err, size_t n) {
    char waiting[1024];
    const char *said;
    size_t len;
    int i;
    memset(out, 0, sizeof *out);
    out->size = (uint32_t)sizeof *out;
    if (!*drawn) {
        if (!t->draw(v)) return cvl_fail(err, n, "%s", cvl_error(t));
        *drawn = 1;
    }
    t->request_pick_in(v, viewport, x, y);
    said = t->last_error();
    if (said && said[0]) return cvl_fail(err, n, "%s", said);
    waiting[0] = 0;
    for (i = 0; i < 200; ++i) {
        if (!t->draw(v)) return cvl_fail(err, n, "%s", cvl_error(t));
        if (t->pick_result(v, out)) return 1;
        said = t->last_error();
        if (!said) said = "";
        /* The suffix is read off the whole message, not the copy kept for the last line. */
        len = strlen(said);
        if (len && (len < 14 || strcmp(said + len - 14, "no pick result") != 0))
            return cvl_fail(err, n, "%s", said);
        cvl_copy(waiting, sizeof waiting, said);
        cvl_sleep_ms(10);
    }
    return cvl_fail(err, n, "pick: the answer never landed (%s)", waiting[0] ? waiting : "no error reported");
}

/* ---- the camera ----------------------------------------------------------------------- */

CVL_API int cvl_standard_angles(const char *name, double *az, double *el) {
    static const struct {
        const char *name;
        double az, el;
    } views[] = {{"front", -90.0, 0.0}, {"back", 90.0, 0.0},    {"left", 180.0, 0.0},  {"right", 0.0, 0.0},
                 {"top", -90.0, 90.0},  {"bottom", -90.0, -90.0}, {"iso", -50.0, 28.0}};
    size_t i;
    for (i = 0; i < sizeof views / sizeof views[0]; ++i) {
        if (strcmp(name, views[i].name) == 0) {
            *az = views[i].az;
            *el = views[i].el;
            return 1;
        }
    }
    return 0;
}

/* Python's _aim: the top view straight down the up axis, any other angle an orbit from
 * the front, then the fit. The zoom is cvl_zoom, after whichever framing runs last. The
 * calls are unchecked, as Python's are. */
CVL_API void cvl_aim(const CvlTable *t, CadaclysmView *v, double az, double el) {
    if (el >= 90.0 && az == -90.0) {
        t->standard(v, CADACLYSM_VIEW_STANDARD_TOP);
    } else {
        double dx = -((az + 90.0) * CVL_PI / 180.0) / CVL_RADIANS_PER_PIXEL;
        double dy = (el * CVL_PI / 180.0) / CVL_RADIANS_PER_PIXEL;
        t->standard(v, CADACLYSM_VIEW_STANDARD_FRONT);
        if (dx != 0.0 || dy != 0.0) t->orbit(v, (float)dx, (float)dy);
    }
    t->frame(v, 0);
}

/* Python's _zoom: a multiple of the fit, as wheel steps; after the last framing step. */
CVL_API void cvl_zoom(const CvlTable *t, CadaclysmView *v, double zoom) {
    if (zoom > 0.0 && isfinite(zoom)) t->zoom(v, (float)(log(zoom) / -log(CVL_ZOOM_PER_STEP)));
}

/* Python's _camera: the eye's direction from the target in the Z-up orbit frame (a Y-up
 * view's camera, `y_up` 1, turned into it first); at a pole the azimuth comes from the up
 * vector. */
CVL_API void cvl_angles(const CadaclysmViewCamera *c, int y_up, double *azimuth, double *elevation) {
    double d[3], u[3], length, z;
    int i;
    for (i = 0; i < 3; ++i) {
        d[i] = (double)c->eye[i] - (double)c->target[i];
        u[i] = (double)c->up[i];
    }
    if (y_up) {
        double d1 = d[1], u1 = u[1];
        d[1] = -d[2];
        d[2] = d1;
        u[1] = -u[2];
        u[2] = u1;
    }
    length = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
    if (length == 0.0) length = 1.0;
    for (i = 0; i < 3; ++i) d[i] /= length;
    if (hypot(d[0], d[1]) < 1e-4) {
        double sign = d[2] < 0.0 ? -1.0 : 1.0;
        *azimuth = atan2(-sign * u[1], -sign * u[0]) * 180.0 / CVL_PI;
    } else {
        *azimuth = atan2(d[1], d[0]) * 180.0 / CVL_PI;
    }
    z = d[2] < -1.0 ? -1.0 : (d[2] > 1.0 ? 1.0 : d[2]);
    *elevation = asin(z) * 180.0 / CVL_PI;
}

/* ---- show()/view() on an object ------------------------------------------------------ */

typedef struct CvlShow {
    const char *view;   /* front back left right top bottom iso; NULL or "": the object's default */
    const char *title;  /* NULL or "": "Cadaclysm" */
    const char *hint;   /* NULL, or CADACLYSM_TERMINAL_GRAPHICS for this one draw */
    uint32_t width, height;
    uint32_t y_up;
    double azimuth, elevation; /* NAN: the view's own */
    double zoom;               /* a multiple of the fit; 0: the fit */
    uint32_t edges;            /* 1: the B-rep edges over the shapes */
    const char *no_display;    /* appended to a create failure that says "no display" (see
                                  cvl_create_failed); NULL: none */
} CvlShow;

/* A fresh view (own window or terminal) of one solid or one scene, by handle, in Python's
 * present() order: show; `transforms` (a Pose: `transform_count` column-major 4x4s, one per
 * scene node; NULL for none, while a non-NULL pointer with count 0 reaches the library, which
 * refuses it) through set_node_transforms; every node in `hide` hidden (the siblings along the
 * path to `node`, which the wrapper computes); the edges layer; the aim; with `node` not
 * CVL_NO_NODE, `node` framed; the zoom. Then the wgpu library runs its window for both modes,
 * and any other (the terminal, a library of one's own) draws one still for `interactive` 0
 * (show) and runs for 1 (view), filling `camera`/`pick` (either may be NULL; read the camera's
 * angles with cvl_angles(camera, o->y_up, ...)). A refused show, transforms, hide, layer,
 * frame_node, draw or run fails with the library's message (cvl_error); the aim and the zoom
 * are unchecked, as in Python. Buffered stdio (C's, C++'s synced iostreams, Swift's print) is
 * flushed first, as Python flushes before a still; Go's os.Stdout is unbuffered. The view is
 * destroyed before this returns. */
CVL_API int cvl_draw_object(const CvlTable *t, int interactive, const char *default_view,
                            const CadaclysmBlacksmithSolid *solid, double tolerance, const CadaclysmScene *scene,
                            const double *transforms, uint32_t transform_count, const uint32_t *hide,
                            uint32_t hide_count, uint32_t node, const CvlShow *o, CadaclysmViewCamera *camera,
                            CadaclysmViewPick *pick, char *err, size_t n) {
    const char *name = (o->view && o->view[0]) ? o->view : default_view;
    char old_hint[CVL_PATH];
    int had_hint = 0, hinted = o->hint && o->hint[0], ok;
    double az = 0.0, el = 0.0;
    CadaclysmView *v;
    uint32_t item, i;
    fflush(NULL);
    if (!cvl_standard_angles(name, &az, &el))
        return cvl_fail(err, n, "view '%s': one of front, back, left, right, top, bottom, iso", name);
    if (!isnan(o->azimuth)) az = o->azimuth;
    if (!isnan(o->elevation)) el = o->elevation;
    if (hinted) {
        had_hint = cvl_getenv("CADACLYSM_TERMINAL_GRAPHICS", old_hint, sizeof old_hint);
        cvl_setenv("CADACLYSM_TERMINAL_GRAPHICS", o->hint);
    }
    v = cvl_create(t, NULL, o->title, o->width, o->height, CADACLYSM_VIEW_SURFACES_EXACT, o->y_up, 0);
    if (hinted) cvl_setenv("CADACLYSM_TERMINAL_GRAPHICS", had_hint ? old_hint : NULL);
    if (!v) return cvl_create_failed(t, o->no_display, err, n);
    item = solid ? t->show_solid(v, solid, tolerance, NULL) : t->show(v, scene);
    ok = item != 0;
    if (ok && transforms) ok = t->set_node_transforms(v, item, transforms, transform_count);
    for (i = 0; ok && i < hide_count; ++i) ok = t->set_node_visible(v, item, hide[i], false);
    if (ok) ok = t->set_layer(v, CADACLYSM_VIEW_LAYER_EDGES, o->edges != 0);
    if (ok) {
        cvl_aim(t, v, az, el);
        if (node != CVL_NO_NODE) ok = t->frame_node(v, item, node);
    }
    if (ok) {
        cvl_zoom(t, v, o->zoom);
        if (interactive || cvl_is_wgpu(t)) ok = t->run(v, camera, pick);
        else ok = t->draw(v);
    }
    if (!ok) cvl_fail(err, n, "%s", cvl_error(t));
    t->destroy(v);
    return ok;
}

/* ---- PNG ---------------------------------------------------------------------------------- */

CVL_API uint32_t cvl_crc32(uint32_t crc, const unsigned char *p, size_t n) {
    size_t i;
    int k;
    crc = ~crc;
    for (i = 0; i < n; ++i) {
        crc ^= p[i];
        for (k = 0; k < 8; ++k) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

CVL_API void cvl_be32(unsigned char *p, uint32_t v) {
    p[0] = (unsigned char)(v >> 24);
    p[1] = (unsigned char)(v >> 16);
    p[2] = (unsigned char)(v >> 8);
    p[3] = (unsigned char)v;
}

CVL_API int cvl_write_file(const char *path, const unsigned char *data, size_t size, char *err, size_t n) {
#if defined(_WIN32)
    wchar_t w[CVL_PATH];
    HANDLE f;
    DWORD wrote = 0;
    BOOL ok;
    if (!cvl_wide(path, w, CVL_PATH)) return cvl_fail(err, n, "%s: not a UTF-8 path", path);
    f = CreateFileW(w, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE)
        return cvl_fail(err, n, "%s: could not write (Windows error %lu)", path, (unsigned long)GetLastError());
    ok = WriteFile(f, data, (DWORD)size, &wrote, NULL) && wrote == size;
    CloseHandle(f);
    if (!ok) return cvl_fail(err, n, "%s: could not write", path);
#else
    size_t wrote;
    int closed;
    FILE *f = fopen(path, "wb");
    if (!f) return cvl_fail(err, n, "%s: could not write", path);
    wrote = fwrite(data, 1, size, f);
    closed = fclose(f);
    if (wrote != size || closed != 0) return cvl_fail(err, n, "%s: could not write", path);
#endif
    return 1;
}

/* RGBA8, rows from the top, as cadaclysm_view_image writes them; stored deflate, so no
 * zlib. One IDAT chunk, whose length a PNG caps at 2^31 - 1: a bigger image is refused. */
CVL_API int cvl_write_png(const char *path, const uint8_t *rgba, uint32_t width, uint32_t height, char *err,
                          size_t n) {
    static const unsigned char signature[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    uint64_t row64 = (uint64_t)width * 4u + 1u, raw64, blocks64;
    size_t row, raw_size, y, k, at = 0, i, blocks, z_size, total;
    unsigned char *raw, *png, *p, *q;
    uint32_t a = 1, b = 0;
    int ok;
    /* In 64 bits, without wrapping: row64 <= 2^31 keeps raw64 under 2^63 and the IDAT sum
     * under 2^51; the IDAT bound then keeps every size below 2^32, so size_t holds them on a
     * 32-bit target too. */
    if (row64 > 0x7FFFFFFFu)
        return cvl_fail(err, n, "%s: a %ux%u image is too large for a PNG of one IDAT chunk", path,
                        (unsigned)width, (unsigned)height);
    raw64 = row64 * height;
    blocks64 = raw64 ? (raw64 + 65534u) / 65535u : 1u;
    if (raw64 + 5u * blocks64 + 6u > 0x7FFFFFFFu)
        return cvl_fail(err, n, "%s: a %ux%u image is too large for a PNG of one IDAT chunk", path,
                        (unsigned)width, (unsigned)height);
    row = (size_t)row64;
    raw_size = (size_t)raw64;
    blocks = (size_t)blocks64;
    z_size = 2 + raw_size + 5 * blocks + 4;
    total = 8 + 25 + 12 + z_size + 12;
    raw = (unsigned char *)malloc(raw_size ? raw_size : 1);
    png = (unsigned char *)malloc(total);
    if (!raw || !png) {
        free(raw);
        free(png);
        return cvl_fail(err, n, "%s: out of memory for a %ux%u image", path, (unsigned)width, (unsigned)height);
    }
    for (y = 0; y < height; ++y) {
        raw[y * row] = 0;
        memcpy(raw + y * row + 1, rgba + y * (row - 1), row - 1);
    }
    p = png;
    memcpy(p, signature, 8);
    p += 8;
    cvl_be32(p, 13);
    memcpy(p + 4, "IHDR", 4);
    cvl_be32(p + 8, width);
    cvl_be32(p + 12, height);
    p[16] = 8; /* bit depth */
    p[17] = 6; /* RGBA */
    p[18] = 0;
    p[19] = 0;
    p[20] = 0;
    cvl_be32(p + 21, cvl_crc32(0, p + 4, 17));
    p += 25;
    cvl_be32(p, (uint32_t)z_size);
    memcpy(p + 4, "IDAT", 4);
    q = p + 8;
    *q++ = 0x78;
    *q++ = 0x01;
    for (k = 0; k < blocks; ++k) {
        size_t len = raw_size - at < 65535 ? raw_size - at : 65535;
        *q++ = (unsigned char)(k + 1 == blocks ? 1 : 0);
        q[0] = (unsigned char)(len & 0xFFu);
        q[1] = (unsigned char)((len >> 8) & 0xFFu);
        q[2] = (unsigned char)(~len & 0xFFu);
        q[3] = (unsigned char)((~len >> 8) & 0xFFu);
        q += 4;
        memcpy(q, raw + at, len);
        q += len;
        at += len;
    }
    for (i = 0; i < raw_size; ++i) {
        a = (a + raw[i]) % 65521u;
        b = (b + a) % 65521u;
    }
    cvl_be32(q, (b << 16) | a);
    q += 4;
    cvl_be32(q, cvl_crc32(0, p + 4, 4 + z_size));
    q += 4;
    cvl_be32(q, 0);
    memcpy(q + 4, "IEND", 4);
    cvl_be32(q + 8, cvl_crc32(0, q + 4, 4));
    q += 12;
    ok = cvl_write_file(path, png, (size_t)(q - png), err, n);
    free(raw);
    free(png);
    return ok;
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CADACLYSM_VIEW_LOADER_H */
