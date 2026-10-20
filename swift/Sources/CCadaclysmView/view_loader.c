/* The C target's one source: the loader is all static inline in include/view_loader.h.
 * This names the build's own library directory (Package.swift's libDir) for the search,
 * and the calling OS thread, which a View remembers as its maker's. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE /* syscall() */
#endif
#include "CCadaclysmView.h"

#if defined(__linux__)
#include <sys/syscall.h>
#include <unistd.h>
#elif defined(__APPLE__)
#include <pthread.h>
#elif !defined(_WIN32)
#include <pthread.h>
#endif

#ifndef CVL_SWIFT_LIBRARY_DIR
#define CVL_SWIFT_LIBRARY_DIR ""
#endif

const char *ccadaclysm_view_library_dir(void) { return CVL_SWIFT_LIBRARY_DIR; }

uint64_t ccadaclysm_view_thread(void) {
#if defined(_WIN32)
    return (uint64_t)GetCurrentThreadId();
#elif defined(__linux__)
    return (uint64_t)syscall(SYS_gettid); /* pthread_self() values are reused by glibc */
#elif defined(__APPLE__)
    uint64_t id = 0;
    pthread_threadid_np(NULL, &id);
    return id;
#else
    return (uint64_t)(uintptr_t)pthread_self();
#endif
}
