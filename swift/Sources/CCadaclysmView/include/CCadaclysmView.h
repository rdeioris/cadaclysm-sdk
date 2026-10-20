/* CCadaclysmView's umbrella header (SwiftPM takes include/<target>.h as the module's
 * umbrella): view_loader.h first, so cadaclysm_view.h is read after the C headers it needs
 * (size_t) -- an umbrella *directory* would parse the headers in name order, cadaclysm_view.h
 * before view_loader.h, and fail on glibc and macOS. */
#ifndef CCADACLYSM_VIEW_H
#define CCADACLYSM_VIEW_H
#include "view_loader.h"
/* Package.swift's library directory, compiled in: one place the view library is looked for. */
const char *ccadaclysm_view_library_dir(void);
/* The OS thread this runs on, as a number never shared by two live threads (the kernel's
 * thread id, not a reusable pthread_t): a View belongs to the thread that made it. */
uint64_t ccadaclysm_view_thread(void);
#endif
