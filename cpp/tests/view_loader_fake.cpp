// A stand-in view library for view_loader_test: every call of cadaclysm_view.h, exported
// by the loader's own CVL_CALLS list, answering zero -- but for abi_version (1.11; 1.<n> while
// CVL_FAKE_ABI_MINOR is n, for the loader's refusal of an older library) and name, which
// answers NULL (a library that names nothing must not crash cvl_open).
#include <cadaclysm/view_loader.h>

#include <cstdlib>
#include <cstring>

namespace {
template <class T>
T answer(const char*) {
    return T();
}
template <>
void answer<void>(const char*) {}
template <>
uint32_t answer<uint32_t>(const char* call) {
    if (std::strcmp(call, "abi_version") != 0) return 0u;
    // The process's environment block (cvl_getenv), where the test's cvl_setenv writes.
    char minor[32];
    if (cvl_getenv("CVL_FAKE_ABI_MINOR", minor, sizeof minor))
        return (1u << 16) | static_cast<uint32_t>(std::strtoul(minor, nullptr, 10));
    return (1u << 16) | 11u;
}
}  // namespace

extern "C" {
#if defined(_WIN32)
// cadaclysm_view.h already declared each call without dllexport, and a redeclaration may not
// add it: the stand-ins get their own names and the linker exports them under the view's.
#  define CVL_FAKE(n, r, p)                                                        \
    __pragma(comment(linker, "/export:cadaclysm_view_" #n "=cvl_fake_" #n))      \
    r cvl_fake_##n p { return answer<r>(#n); }
#else
#  define CVL_FAKE(n, r, p) \
    __attribute__((visibility("default"))) r cadaclysm_view_##n p { return answer<r>(#n); }
#endif
CVL_CALLS(CVL_FAKE)
#undef CVL_FAKE
}
