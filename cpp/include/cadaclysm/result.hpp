// cadaclysm C++ wrapper -- what the two headers share: Error, Result<T>, Span<T>,
// the bad-access hook and the TRY macros. Header-only, C++17, and nothing here or
// in the headers built on it ever throws.
#ifndef CADACLYSM_RESULT_HPP
#define CADACLYSM_RESULT_HPP

#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <type_traits>
#include <utility>
#include <variant>

#if __has_include(<version>)
#include <version>
#endif
#if defined(__cpp_lib_span) && __cpp_lib_span >= 202002L
#include <span>
#define CADACLYSM_STD_SPAN 1
#else
#define CADACLYSM_STD_SPAN 0
#endif

// Checked mode: borrowed views and nodes verify their owner is alive and unchanged
// before every read. On unless NDEBUG; define it 0 or 1 before the first include to
// choose. Every translation unit of a program must agree, and on CADACLYSM_STD_SPAN
// (C++20's std::span or the C++17 Span, which lay Mesh and Face out differently): the
// inline namespace below names both, so most disagreements become link errors rather
// than silent ODR violations. Not all: GCC and Clang do not mangle a variable's type,
// so `extern Scene g;` defined in a TU that disagrees can still link.
#ifndef CADACLYSM_CHECKED
#ifdef NDEBUG
#define CADACLYSM_CHECKED 0
#else
#define CADACLYSM_CHECKED 1
#endif
#endif

#if CADACLYSM_CHECKED && CADACLYSM_STD_SPAN
#define CADACLYSM_ABI checked_stdspan_v1
#elif CADACLYSM_CHECKED
#define CADACLYSM_ABI checked_v1
#elif CADACLYSM_STD_SPAN
#define CADACLYSM_ABI unchecked_stdspan_v1
#else
#define CADACLYSM_ABI unchecked_v1
#endif

// What a misuse does: value() on an error, a read through a stale view, a call on a
// closed or moved-from owner. `message` is a const char*. Must not return. Define it
// before the first include to route it to your own assert or log; every translation
// unit must define it the same way (each bakes its hook into the inline bad_access
// below, and two different definitions break the one-definition rule).
//
// A hook may longjmp out instead of returning only from the plain view, node and
// placement accessors: nothing on their path from the check to here holds an object
// with a destructor. Other calls do (Node::visible_now and walk, Mesh::copy,
// EdgePolylines::rows and copy, Solid::step_text, a default Progress argument), and a
// longjmp out of them skips those destructors.
#ifndef CADACLYSM_BAD_ACCESS
#define CADACLYSM_BAD_ACCESS(message) \
    (std::fprintf(stderr, "cadaclysm: %s\n", (message)), std::fflush(stderr), std::abort())
#endif

namespace cadaclysm {
inline namespace CADACLYSM_ABI {

// Which library said no.
enum class Origin { reader, kernel };

// A failed call: the library's own message (cadaclysm_last_error or
// cadaclysm_blacksmith_last_error), or the wrapper's where it refused first.
struct Error {
    std::string message;
    Origin origin = Origin::reader;
};

namespace detail {

// CADACLYSM_BAD_ACCESS must not return. A longjmp out of it is only safe from the
// plain view, node and placement accessors, because other calls hold objects with
// destructors on the way here (see CADACLYSM_BAD_ACCESS above).
#if defined(_MSC_VER)
#pragma warning(push)
#pragma warning(disable : 4702)  // unreachable code: the trailing abort() is a belt-and-braces fallback
#endif

[[noreturn]] inline void bad_access(const char* message) {
    CADACLYSM_BAD_ACCESS(message);
    std::abort();
}

[[noreturn]] inline void bad_access(const char* what, const char* reason) {
    static thread_local char buffer[512];
    std::snprintf(buffer, sizeof buffer, "%s: %s", what, reason);
    bad_access(buffer);
}

#if defined(_MSC_VER)
#pragma warning(pop)
#endif

}  // namespace detail

// ---- Span -------------------------------------------------------------------------

#if CADACLYSM_STD_SPAN
template <class T>
using Span = std::span<T>;
#else
// std::span's read-only subset, for C++17.
template <class T>
class Span {
public:
    using element_type = T;
    using value_type = std::remove_cv_t<T>;
    using size_type = std::size_t;
    using pointer = T*;
    using iterator = T*;

    constexpr Span() noexcept = default;
    constexpr Span(T* data, std::size_t size) noexcept : data_(data), size_(size) {}

    constexpr T* data() const noexcept { return data_; }
    constexpr std::size_t size() const noexcept { return size_; }
    constexpr bool empty() const noexcept { return size_ == 0; }
    constexpr T* begin() const noexcept { return data_; }
    constexpr T* end() const noexcept { return data_ + size_; }
    constexpr T& operator[](std::size_t i) const noexcept { return data_[i]; }
    constexpr Span subspan(std::size_t offset, std::size_t count) const noexcept {
        return Span(data_ + offset, count);
    }

private:
    T* data_ = nullptr;
    std::size_t size_ = 0;
};
#endif

// ---- Result -----------------------------------------------------------------------

template <class T>
class Result;

namespace detail {
template <class R>
struct is_result : std::false_type {};
template <class U>
struct is_result<Result<U>> : std::true_type {};
}  // namespace detail

// Declared before the primary template's definition, so nothing instantiates the
// primary with T = void first.
template <>
class [[nodiscard]] Result<void> {
public:
    using value_type = void;

    Result() noexcept = default;
    Result(Error error) : error_(std::move(error)), failed_(true) {}

    bool ok() const noexcept { return !failed_; }
    explicit operator bool() const noexcept { return ok(); }

    void value() const {
        if (failed_) detail::bad_access(error_.message.c_str());
    }

    const Error& error() const {
        if (!failed_) detail::bad_access("error() on a Result that holds a value");
        return error_;
    }

    template <class F>
    auto and_then(F&& f) const -> std::invoke_result_t<F> {
        using R = std::invoke_result_t<F>;
        static_assert(detail::is_result<R>::value, "and_then's function must return a Result");
        if (failed_) return R(error_);
        return std::forward<F>(f)();
    }

    template <class F>
    auto map(F&& f) const -> Result<std::invoke_result_t<F>> {
        using U = std::invoke_result_t<F>;
        if (failed_) return Result<U>(error_);
        if constexpr (std::is_void_v<U>) {
            std::forward<F>(f)();
            return Result<void>();
        } else {
            return Result<U>(std::forward<F>(f)());
        }
    }

private:
    Error error_;
    bool failed_ = false;
};

// A value or an Error. Never throws: value() on an error is a bad access (see
// CADACLYSM_BAD_ACCESS). Test with ok() or `if (result)` first, or use
// CADACLYSM_TRY in a function that itself returns a Result.
template <class T>
class [[nodiscard]] Result {
    static_assert(!std::is_reference_v<T>, "Result holds values, not references");
    static_assert(!std::is_same_v<std::decay_t<T>, Error>, "Result<Error> would be ambiguous");

public:
    using value_type = T;

    Result(T value) : v_(std::in_place_index<0>, std::move(value)) {}
    Result(Error error) : v_(std::in_place_index<1>, std::move(error)) {}

    bool ok() const noexcept { return v_.index() == 0; }
    explicit operator bool() const noexcept { return ok(); }

    T& value() & { return *checked(); }
    const T& value() const& { return *checked(); }
    T&& value() && { return std::move(*checked()); }

    T& operator*() & { return *checked(); }
    const T& operator*() const& { return *checked(); }
    T&& operator*() && { return std::move(*checked()); }
    T* operator->() { return checked(); }
    const T* operator->() const { return checked(); }

    const Error& error() const {
        const Error* e = std::get_if<1>(&v_);
        if (!e) detail::bad_access("error() on a Result that holds a value");
        return *e;
    }

    template <class U>
    T value_or(U&& fallback) const& {
        if (const T* v = std::get_if<0>(&v_)) return *v;
        return static_cast<T>(std::forward<U>(fallback));
    }

    template <class U>
    T value_or(U&& fallback) && {
        if (T* v = std::get_if<0>(&v_)) return std::move(*v);
        return static_cast<T>(std::forward<U>(fallback));
    }

    template <class F>
    auto map(F&& f) && -> Result<std::invoke_result_t<F, T&&>> {
        using U = std::invoke_result_t<F, T&&>;
        if (!ok()) return Result<U>(std::move(*std::get_if<1>(&v_)));
        if constexpr (std::is_void_v<U>) {
            std::forward<F>(f)(std::move(*std::get_if<0>(&v_)));
            return Result<void>();
        } else {
            return Result<U>(std::forward<F>(f)(std::move(*std::get_if<0>(&v_))));
        }
    }

    template <class F>
    auto map(F&& f) const& -> Result<std::invoke_result_t<F, const T&>> {
        using U = std::invoke_result_t<F, const T&>;
        if (!ok()) return Result<U>(*std::get_if<1>(&v_));
        if constexpr (std::is_void_v<U>) {
            std::forward<F>(f)(*std::get_if<0>(&v_));
            return Result<void>();
        } else {
            return Result<U>(std::forward<F>(f)(*std::get_if<0>(&v_)));
        }
    }

    template <class F>
    auto and_then(F&& f) && -> std::invoke_result_t<F, T&&> {
        using R = std::invoke_result_t<F, T&&>;
        static_assert(detail::is_result<R>::value, "and_then's function must return a Result");
        if (!ok()) return R(std::move(*std::get_if<1>(&v_)));
        return std::forward<F>(f)(std::move(*std::get_if<0>(&v_)));
    }

    template <class F>
    auto and_then(F&& f) const& -> std::invoke_result_t<F, const T&> {
        using R = std::invoke_result_t<F, const T&>;
        static_assert(detail::is_result<R>::value, "and_then's function must return a Result");
        if (!ok()) return R(*std::get_if<1>(&v_));
        return std::forward<F>(f)(*std::get_if<0>(&v_));
    }

private:
    T* checked() {
        T* v = std::get_if<0>(&v_);
        if (!v) detail::bad_access(std::get_if<1>(&v_)->message.c_str());
        return v;
    }
    const T* checked() const {
        const T* v = std::get_if<0>(&v_);
        if (!v) detail::bad_access(std::get_if<1>(&v_)->message.c_str());
        return v;
    }

    std::variant<T, Error> v_;
};

}  // namespace CADACLYSM_ABI
}  // namespace cadaclysm

// ---- early return -------------------------------------------------------------------

#define CADACLYSM_JOIN2_(a, b) a##b
#define CADACLYSM_JOIN_(a, b) CADACLYSM_JOIN2_(a, b)

// `CADACLYSM_TRY(plate, Solid::cuboid(1, 2, 3));` declares `plate` from a successful
// Result, or returns its Error from the enclosing function (which must return a
// Result). One per line: the hidden temporary is named after __LINE__.
#define CADACLYSM_TRY(var, expr)                                          \
    auto CADACLYSM_JOIN_(cadaclysm_try_, __LINE__) = (expr);              \
    if (!CADACLYSM_JOIN_(cadaclysm_try_, __LINE__))                       \
        return CADACLYSM_JOIN_(cadaclysm_try_, __LINE__).error();         \
    auto var = std::move(CADACLYSM_JOIN_(cadaclysm_try_, __LINE__)).value()

// The same for a Result<void>: returns its Error, or carries on.
#define CADACLYSM_TRY_VOID(expr)                                          \
    do {                                                                  \
        auto cadaclysm_try_void_ = (expr);                                \
        if (!cadaclysm_try_void_) return cadaclysm_try_void_.error();     \
    } while (0)

#endif  // CADACLYSM_RESULT_HPP
