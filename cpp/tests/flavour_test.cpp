// cadaclysm::flavour() / features() and blacksmith::flavour() / features(): the library
// CADACLYSM_FLAVOUR linked answers for itself, and the separate libraries answer "reader"
// and "kernel" with no features. Under the reader flavour there is no kernel to ask.
//
//     cadaclysm_flavour_test full|kernel-reader|reader|separate
#include <cstdio>
#include <string>

#include <cadaclysm/cadaclysm.hpp>
#ifndef CADACLYSM_FLAVOUR_TEST_READER
#include <cadaclysm/cadaclysm_blacksmith.hpp>
#endif

static int failures = 0;
static void expect(bool ok, const std::string& what) {
    if (!ok) {
        std::fprintf(stderr, "FAIL: %s\n", what.c_str());
        ++failures;
    }
}

static bool has(const std::string& features, const std::string& feature) {
    return ("," + features + ",").find("," + feature + ",") != std::string::npos;
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: cadaclysm_flavour_test full|kernel-reader|reader|separate\n");
        return 2;
    }
    const std::string linked = argv[1];
    const std::string flavour = cadaclysm::flavour();
    const std::string features = cadaclysm::features();
    if (linked == "separate") {
        expect(flavour == "reader", "the separate reader answers '" + flavour + "', not 'reader'");
        expect(features.empty(), "the separate reader has features '" + features + "'");
    } else {
        expect(flavour == linked, "the linked library answers '" + flavour + "', not '" + linked + "'");
        expect(has(features, "nodes"), "'" + features + "' has no nodes");
        expect(has(features, "kernel") == (linked != "reader"),
               "'" + features + "' and the kernel disagree with '" + linked + "'");
    }
#ifndef CADACLYSM_FLAVOUR_TEST_READER
    const std::string kernel = cadaclysm::blacksmith::flavour();
    const std::string kernel_features = cadaclysm::blacksmith::features();
    if (linked == "separate") {
        expect(kernel == "kernel", "the separate kernel answers '" + kernel + "', not 'kernel'");
        expect(kernel_features.empty(), "the separate kernel has features '" + kernel_features + "'");
    } else {
        expect(kernel == flavour, "the kernel answers '" + kernel + "', the reader '" + flavour + "'");
        expect(kernel_features == features, "the kernel's features '" + kernel_features + "' are not the reader's");
    }
#endif
    if (failures == 0) std::printf("flavour: %s (%s)\n", flavour.c_str(), features.c_str());
    return failures == 0 ? 0 : 1;
}
