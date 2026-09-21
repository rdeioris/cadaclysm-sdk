// result.hpp on its own: Result<T>, Result<void>, the TRY macros, Span, and the
// bad-access hook. The exit code is the verdict.
#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>

#if defined(_MSC_VER)
#pragma warning(disable : 4611)  // setjmp and C++ destruction: nothing here needs destroying
#endif

namespace trap {
inline std::jmp_buf* where = nullptr;
inline std::string message;
}  // namespace trap
#define CADACLYSM_BAD_ACCESS(text) \
    (::trap::message = (text), ::trap::where ? std::longjmp(*::trap::where, 1) : std::abort())

#include <cadaclysm/result.hpp>

using cadaclysm::Error;
using cadaclysm::Result;

// Whether `f` reached CADACLYSM_BAD_ACCESS.
template <class F>
static bool trips(F&& f) {
    std::jmp_buf buffer;
    trap::where = &buffer;
    trap::message.clear();
    if (setjmp(buffer) == 0) {
        f();
        trap::where = nullptr;
        return false;
    }
    trap::where = nullptr;
    return true;
}

static int failures = 0;
static void expect(bool ok, const char* what) {
    if (!ok) {
        std::fprintf(stderr, "FAIL: %s\n", what);
        ++failures;
    }
}

static Result<int> half(int n) {
    if (n % 2) return Error{"odd: " + std::to_string(n), cadaclysm::Origin::kernel};
    return n / 2;
}

static Result<int> quarter(int n) {
    CADACLYSM_TRY(h, half(n));
    CADACLYSM_TRY(q, half(h));
    return q;
}

static Result<void> must_be_even(int n) {
    if (n % 2) return Error{"odd"};
    return {};
}

static Result<void> both_even(int a, int b) {
    CADACLYSM_TRY_VOID(must_be_even(a));
    CADACLYSM_TRY_VOID(must_be_even(b));
    return {};
}

int main() {
    // Values and errors.
    auto four = half(8);
    expect(four.ok() && static_cast<bool>(four) && *four == 4 && four.value() == 4, "a value reads back");
    auto odd = half(3);
    expect(!odd && odd.error().message == "odd: 3" && odd.error().origin == cadaclysm::Origin::kernel,
           "an error carries its message and origin");
    expect(odd.value_or(-1) == -1 && four.value_or(-1) == 4, "value_or");

    // map / and_then.
    auto doubled = half(8).map([](int v) { return v * 2; });
    expect(doubled.ok() && *doubled == 8, "map on a value");
    expect(!half(3).map([](int v) { return v * 2; }), "map on an error keeps the error");
    auto chained = half(8).and_then([](int v) { return half(v); });
    expect(chained.ok() && *chained == 2, "and_then on a value");
    auto broken = half(6).and_then([](int v) { return half(v); });
    expect(!broken && broken.error().message == "odd: 3", "and_then stops at the first error");

    // TRY propagates the first error; TRY_VOID for Result<void>.
    expect(quarter(8).ok() && *quarter(8) == 2, "TRY passes values through");
    expect(!quarter(6) && quarter(6).error().message == "odd: 3", "TRY returns the error it met");
    expect(both_even(2, 4).ok(), "TRY_VOID on success");
    expect(!both_even(2, 3) && both_even(2, 3).error().message == "odd", "TRY_VOID on failure");

    // Move-only values.
    Result<std::unique_ptr<int>> boxed = std::make_unique<int>(7);
    std::unique_ptr<int> taken = std::move(boxed).value();
    expect(taken && *taken == 7, "a move-only value moves out");

    // Span.
    const float data[] = {1.0f, 2.0f, 3.0f, 4.0f};
    cadaclysm::Span<const float> span(data, 4);
    float sum = 0;
    for (float v : span) sum += v;
    expect(span.size() == 4 && !span.empty() && span[2] == 3.0f && sum == 10.0f, "Span reads its data");
    expect(span.subspan(1, 2).size() == 2 && span.subspan(1, 2)[0] == 2.0f, "Span::subspan");
    expect(cadaclysm::Span<const float>().empty(), "an empty Span");

    // Bad access: value() on an error, error() on a value.
    expect(trips([&] { (void)odd.value(); }) && trap::message == "odd: 3", "value() on an error trips with its message");
    expect(trips([&] { (void)four.error(); }), "error() on a value trips");
    expect(!trips([&] { (void)four.value(); }), "value() on a value does not trip");

    if (failures) return 1;
    std::puts("result: OK");
    return 0;
}
