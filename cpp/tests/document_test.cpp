// The blacksmith document -- Document over the cadaclysm_blacksmith_document_* and
// cadaclysm_bim_* calls -- at parity with the Python reference's document tests in
// test_cadaclysm_blacksmith.py (plate_document .. the bim tests), on the JSON-text shape the
// document plan (2026-11-06) gives every wrapper but Node: the document answers JSON text,
// read here by the small reader below (the header reads none). Needs the kernel library and
// a license; writes two small files in the working directory (ctest's: the build directory)
// and removes them. The exit code is the verdict.
//
//     cadaclysm_document_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <set>
#include <string>
#include <vector>

#if defined(__cpp_exceptions) || defined(_CPPUNWIND)
#include <stdexcept>
#define DOCUMENT_TEST_EXCEPTIONS 1
#else
#define DOCUMENT_TEST_EXCEPTIONS 0
#endif

using cadaclysm::Error;
using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Document;
using bs::Vec3;

static int failures = 0;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

// The message `r` was refused with; a failure (and "") when it was not refused.
template <class T>
static std::string refusal(const Result<T>& r, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return "";
    }
    return r.error().message;
}

template <class T>
static void refused_with(const Result<T>& r, const std::string& prefix, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.compare(0, prefix.size(), prefix) == 0, what + ": refused with \"" + got + "\", wanted \"" + prefix + "...\"");
}

// ---- a just-enough JSON reader (objects keep their order), and a writer back --------------

struct Json {
    enum class Kind { null, boolean, number, string, array, object };
    Kind kind = Kind::null;
    bool b = false;
    double n = 0.0;
    std::string s;
    std::vector<Json> items;      // an array's items, or an object's values
    std::vector<std::string> keys;  // an object's keys, beside its values

    bool is_null() const { return kind == Kind::null; }
    std::size_t size() const { return items.size(); }
    const Json& operator[](std::size_t i) const { return items.at(i); }
    bool has(const std::string& key) const {
        for (const std::string& k : keys) {
            if (k == key) return true;
        }
        return false;
    }
    const Json& operator[](const std::string& key) const {
        static const Json missing;
        for (std::size_t i = 0; i < keys.size(); ++i) {
            if (keys[i] == key) return items[i];
        }
        return missing;
    }
    bool is(const std::string& text) const { return kind == Kind::string && s == text; }
    bool is(double number) const { return kind == Kind::number && n == number; }
    void erase(const std::string& key) {
        for (std::size_t i = 0; i < keys.size(); ++i) {
            if (keys[i] == key) {
                keys.erase(keys.begin() + static_cast<std::ptrdiff_t>(i));
                items.erase(items.begin() + static_cast<std::ptrdiff_t>(i));
                return;
            }
        }
    }
};

class JsonReader {
public:
    static Json parse(const std::string& text) {
        JsonReader r(text);
        Json v = r.value();
        r.space();
        if (r.i_ != text.size()) check(false, "trailing JSON in " + text);
        return v;
    }

private:
    explicit JsonReader(const std::string& s) : s_(s) {}

    void space() {
        while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\n' || s_[i_] == '\r')) ++i_;
    }
    bool at(char c) const { return i_ < s_.size() && s_[i_] == c; }

    Json value() {
        space();
        Json v;
        if (i_ >= s_.size()) return v;
        char c = s_[i_];
        if (c == '{') {
            v.kind = Json::Kind::object;
            ++i_;
            space();
            if (at('}')) {
                ++i_;
                return v;
            }
            while (i_ < s_.size()) {
                space();
                v.keys.push_back(string());
                space();
                ++i_;  // ':'
                v.items.push_back(value());
                space();
                if (s_[i_++] == '}') return v;
            }
            return v;
        }
        if (c == '[') {
            v.kind = Json::Kind::array;
            ++i_;
            space();
            if (at(']')) {
                ++i_;
                return v;
            }
            while (i_ < s_.size()) {
                v.items.push_back(value());
                space();
                if (s_[i_++] == ']') return v;
            }
            return v;
        }
        if (c == '"') {
            v.kind = Json::Kind::string;
            v.s = string();
            return v;
        }
        if (s_.compare(i_, 4, "true") == 0) {
            i_ += 4;
            v.kind = Json::Kind::boolean;
            v.b = true;
            return v;
        }
        if (s_.compare(i_, 5, "false") == 0) {
            i_ += 5;
            v.kind = Json::Kind::boolean;
            return v;
        }
        if (s_.compare(i_, 4, "null") == 0) {
            i_ += 4;
            return v;
        }
        std::size_t start = i_;
        while (i_ < s_.size() && std::string("+-0123456789.eE").find(s_[i_]) != std::string::npos) ++i_;
        v.kind = Json::Kind::number;
        v.n = std::strtod(s_.substr(start, i_ - start).c_str(), nullptr);
        return v;
    }

    std::string string() {
        std::string out;
        ++i_;  // '"'
        while (i_ < s_.size()) {
            char c = s_[i_++];
            if (c == '"') return out;
            if (c != '\\') {
                out.push_back(c);
                continue;
            }
            char e = s_[i_++];
            switch (e) {
                case 'n': out.push_back('\n'); break;
                case 't': out.push_back('\t'); break;
                case 'r': out.push_back('\r'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'u': {
                    unsigned long code = std::strtoul(s_.substr(i_, 4).c_str(), nullptr, 16);
                    i_ += 4;
                    if (code < 0x80) {
                        out.push_back(static_cast<char>(code));
                    } else if (code < 0x800) {
                        out.push_back(static_cast<char>(0xC0 | (code >> 6)));
                        out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                    } else {
                        out.push_back(static_cast<char>(0xE0 | (code >> 12)));
                        out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
                        out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                    }
                    break;
                }
                default: out.push_back(e);
            }
        }
        return out;
    }

    const std::string& s_;
    std::size_t i_ = 0;
};

static Json json(const std::string& text) { return JsonReader::parse(text); }

static void write_json(const Json& v, std::string& out) {
    switch (v.kind) {
        case Json::Kind::null: out += "null"; return;
        case Json::Kind::boolean: out += v.b ? "true" : "false"; return;
        case Json::Kind::number: {
            char buffer[40];
            std::snprintf(buffer, sizeof buffer, "%.17g", v.n);
            out += buffer;
            return;
        }
        case Json::Kind::string: {
            out.push_back('"');
            for (char c : v.s) {
                if (c == '"' || c == '\\') {
                    out.push_back('\\');
                    out.push_back(c);
                } else if (static_cast<unsigned char>(c) < 0x20) {
                    char buffer[8];
                    std::snprintf(buffer, sizeof buffer, "\\u%04x", static_cast<unsigned>(c));
                    out += buffer;
                } else {
                    out.push_back(c);
                }
            }
            out.push_back('"');
            return;
        }
        case Json::Kind::array:
            out.push_back('[');
            for (std::size_t i = 0; i < v.items.size(); ++i) {
                if (i) out.push_back(',');
                write_json(v.items[i], out);
            }
            out.push_back(']');
            return;
        case Json::Kind::object:
            out.push_back('{');
            for (std::size_t i = 0; i < v.items.size(); ++i) {
                if (i) out.push_back(',');
                Json key;
                key.kind = Json::Kind::string;
                key.s = v.keys[i];
                write_json(key, out);
                out.push_back(':');
                write_json(v.items[i], out);
            }
            out.push_back('}');
            return;
    }
}

static std::string written(const Json& v) {
    std::string out;
    write_json(v, out);
    return out;
}

// An array of strings as a vector (a non-string item reads as "<?>").
static std::vector<std::string> strings(const Json& v) {
    std::vector<std::string> out;
    for (const Json& item : v.items) out.push_back(item.kind == Json::Kind::string ? item.s : std::string("<?>"));
    return out;
}

static std::set<std::string> key_set(const Json& v) { return std::set<std::string>(v.keys.begin(), v.keys.end()); }

// ---- the plate and small helpers ----------------------------------------------------------

static std::string add_op(const std::string& node) { return "{\"op\": \"add\", \"node\": " + node + "}"; }

static std::string set_op(const std::string& id, const std::string& fields) {
    return "{\"op\": \"set\", \"id\": \"" + id + "\", \"fields\": " + fields + "}";
}

// Python's plate_document: a 10 x 10 rectangle r1 and its 10 mm extrusion x1.
static Result<Document> plate_document() {
    CADACLYSM_TRY(doc, Document::make("mm"));
    CADACLYSM_TRY(a, doc.apply(add_op(R"J({"id": "r1", "kind": "profile.rect", "w": 10, "h": 10})J")));
    check(strings(json(a)["added"]) == std::vector<std::string>{"r1"}, "adding r1 answered " + a);
    CADACLYSM_TRY(b, doc.apply(add_op(R"J({"id": "x1", "kind": "solid.extrude", "profile": "r1", "frame": "xy", "distance": 10})J")));
    check(strings(json(b)["added"]) == std::vector<std::string>{"x1"}, "adding x1 answered " + b);
    return doc;
}

static std::vector<std::string> states(const std::string& status) {
    std::vector<std::string> out;
    for (const Json& row : json(status).items) out.push_back(row["state"].s);
    return out;
}

static double volume(const bs::Solid& solid) {
    Result<bs::Mass> m = solid.mass(1e-7);
    if (!m) {
        check(false, "mass: " + m.error().message);
        return -1.0;
    }
    return m->volume;
}

static double volume_of(Document& doc, const std::string& id) {
    Result<bs::Solid> s = doc.result_solid(id);
    if (!s) {
        check(false, "result_solid(" + id + "): " + s.error().message);
        return -1.0;
    }
    return volume(*s);
}

static bool approx(double a, double b) { return std::fabs(a - b) <= 1e-6 * std::max(1.0, std::fabs(b)); }

static std::string kind_of(Document& doc, const std::string& id) {
    Result<std::string> k = doc.result_kind(id);
    if (!k) {
        check(false, "result_kind(" + id + "): " + k.error().message);
        return "";
    }
    return *k;
}

static Json branch_list(const Document& doc) {
    Result<std::string> text = doc.branches();
    if (!text) {
        check(false, "branches: " + text.error().message);
        return Json();
    }
    return json(*text);
}

static bool can_undo(const Document& doc) { return branch_list(doc)["can_undo"].b; }
static bool can_redo(const Document& doc) { return branch_list(doc)["can_redo"].b; }

static Json log_of(const Document& doc, const std::optional<std::string>& branch) {
    Result<std::string> text = doc.log(branch);
    if (!text) {
        check(false, "log: " + text.error().message);
        return Json();
    }
    return json(*text);
}

// The head's line through a named empty optional, not a `std::nullopt` temporary: GCC 13 -O2
// reports -Wmaybe-uninitialized on that temporary's string destructor, inlined into head_id.
static Json log_of(const Document& doc) {
    static const std::optional<std::string> head;
    return log_of(doc, head);
}

static std::vector<std::string> ids(const Json& commits) {
    std::vector<std::string> out;
    for (const Json& c : commits.items) out.push_back(c["id"].s);
    return out;
}

static std::string head_id(const Document& doc) { return log_of(doc)[0]["id"].s; }

static const Json& first_op(const Json& commit) { return commit["ops"][0]; }

static bool same_floats(const std::optional<Vec3>& got, const Vec3& want) { return got && *got == want; }

// ---- 1b. evaluate_with: progress naming the node being built --------------------------------
// The plate with a 4 x 4 bar x2 cut through it (c1): a node that reports its progress.
static Result<Document> cut_plate_document() {
    CADACLYSM_TRY(doc, plate_document());
    CADACLYSM_TRY(a, doc.apply(add_op(R"J({"id": "r2", "kind": "profile.rect", "w": 4, "h": 4})J")));
    CADACLYSM_TRY(b, doc.apply(add_op(R"J({"id": "x2", "kind": "solid.extrude", "profile": "r2", "frame": "xy", "distance": 20})J")));
    CADACLYSM_TRY(c, doc.apply(add_op(R"J({"id": "c1", "kind": "solid.cut", "target": "x1", "tool": "x2", "tolerance": 0.01})J")));
    (void)a; (void)b; (void)c;
    return doc;
}

static Result<void> evaluate_with_progress() {
    CADACLYSM_TRY(quiet, cut_plate_document());
    CADACLYSM_TRY(plain, quiet.evaluate());
    check(states(plain) == std::vector<std::string>(5, "ok"), "the cut plate evaluates to " + plain);
    CADACLYSM_TRY(doc, cut_plate_document());
    std::vector<std::pair<std::string, std::string>> ticks;
    bs::DocumentProgress heard = [&](std::string_view node, std::string_view phase, std::size_t, std::size_t) {
        ticks.emplace_back(std::string(node), std::string(phase));
    };
    CADACLYSM_TRY(cheap, doc.evaluate_with(heard, true));
    (void)cheap;
    check(ticks.empty(), "a cheap-only pass reported " + std::to_string(ticks.size()) + " ticks");
    CADACLYSM_TRY(status, doc.evaluate_with(heard));
    check(status == plain, "evaluate_with's statuses " + status + " are not the plain " + plain);
    bool cut = false, named = true;
    const std::set<std::string> nodes = {"r1", "x1", "r2", "x2", "c1"};
    for (const auto& t : ticks) {
        cut = cut || (t.first == "c1" && t.second != "start");
        named = named && nodes.count(t.first) == 1;
    }
    check(cut, "no progress from the cut c1");
    check(named, "a tick names no node");
    CADACLYSM_TRY(silent, cut_plate_document());
    CADACLYSM_TRY(none, silent.evaluate_with({}));
    check(none == plain, "a silent evaluate_with's statuses " + none);
    return {};
}

// ---- 1. evaluate and results ----------------------------------------------------------------
static Result<void> evaluate_and_results() {
    CADACLYSM_TRY(doc, plate_document());
    CADACLYSM_TRY(status, doc.evaluate());
    check(states(status) == std::vector<std::string>{"ok", "ok"}, "the plate evaluates to " + status);
    CADACLYSM_TRY(errors, doc.errors());
    check(json(errors).size() == 0 && json(errors).kind == Json::Kind::array, "the plate has errors " + errors);
    CADACLYSM_TRY(solid, doc.result_solid("x1"));
    check(solid.faces() == 6, "x1 has " + std::to_string(solid.faces()) + " faces");
    check(kind_of(doc, "r1") == "profile" && doc.result_profile("r1").ok(), "r1 is not a profile");
    check(kind_of(doc, "nope") == "none", "a missing node's kind is " + kind_of(doc, "nope"));
    refused_with(doc.value("nope"), "document_value: ", "value of a missing node");
    CADACLYSM_TRY(changed, doc.apply(set_op("x1", R"J({"distance": 20})J")));
    (void)changed;
    check(solid.faces() == 6 && approx(volume(solid), 1000), "the old result changed with the edit");
    check(approx(volume_of(doc, "x1"), 2000), "the new x1 reads " + std::to_string(volume_of(doc, "x1")));
    return {};
}

// ---- 2. save, load, open, refusals ---------------------------------------------------------
static Result<void> save_load_open_and_refusals() {
    CADACLYSM_TRY(doc, plate_document());
    CADACLYSM_TRY(first, doc.save());
    {
        CADACLYSM_TRY(loaded, Document::load(first));
        check(loaded.save().value_or("") == first, "save -> load -> save differs");
        CADACLYSM_TRY(status, loaded.evaluate());
        check(states(status) == std::vector<std::string>{"ok", "ok"}, "the loaded plate evaluates to " + status);
        CADACLYSM_TRY(x1, loaded.result_solid("x1"));
        check(x1.faces() == 6, "the loaded x1 is not a box");
    }
    const std::string file = "cadaclysm-document-test-plate.json";
    {
        std::ofstream out(file, std::ios::binary);
        out << first;
    }
    Result<Document> opened = Document::open(file);
    std::remove(file.c_str());
    check(opened.ok() && opened->save().value_or("") == first, "open of the written file differs");
    refused_with(Document::load("not a document"), "document_load: ", "load of not a document");
    refused_with(Document::make("furlongs"), "document_new: ", "new in furlongs");
    return {};
}

// ---- 3. undo and redo (test_document_undo_takes_the_node_away_and_redo_puts_it_back) --------
static Result<void> undo_and_redo() {
    CADACLYSM_TRY(doc, plate_document());
    check(can_undo(doc) && !can_redo(doc), "a fresh plate's branch list reads " + doc.branches().value_or(""));
    CADACLYSM_TRY(u1, doc.undo());
    check(u1, "undo did nothing");
    check(kind_of(doc, "x1") == "none" && kind_of(doc, "r1") != "none", "undo did not take x1 alone away");
    check(can_redo(doc), "nothing to redo after an undo");
    CADACLYSM_TRY(r1, doc.redo());
    check(r1, "redo did nothing");
    check(kind_of(doc, "x1") != "none", "redo did not put x1 back");
    CADACLYSM_TRY(r2, doc.redo());
    check(!r2 && !can_redo(doc), "a second redo did something");
    CADACLYSM_TRY(u2, doc.undo());
    CADACLYSM_TRY(u3, doc.undo());
    check(u2 && u3, "two undos did not both take a commit back");
    check(!can_undo(doc), "can_undo at the root");
    CADACLYSM_TRY(u4, doc.undo());
    check(!u4, "an undo at the root did something");
    CADACLYSM_TRY(status, doc.evaluate());
    check(json(status).size() == 0 && can_redo(doc), "back at the root: " + status);
    return {};
}

// ---- 4. a refusal leaves the document unchanged ---------------------------------------------
static Result<void> a_refusal_leaves_the_document_unchanged() {
    CADACLYSM_TRY(doc, plate_document());
    CADACLYSM_TRY(before, doc.save());
    CADACLYSM_TRY(log, doc.log());
    std::string said = refusal(doc.apply(R"J({"op": "remove", "id": "r1"})J"), "removing r1");
    check(said == "document_apply: r1 is read by x1", "removing r1 said '" + said + "'");
    check(doc.save().value_or("") == before && doc.log().value_or("") == log, "a refused remove changed the document");
    refused_with(doc.apply(add_op(R"J({"kind": "no.such.kind"})J")), "document_apply: ", "an unknown kind");
    CADACLYSM_TRY(cascade, doc.apply(R"J({"op": "remove", "id": "r1", "cascade": true})J"));
    (void)cascade;
    check(kind_of(doc, "r1") == "none" && kind_of(doc, "x1") == "none", "the cascade left a node");
    check(log_of(doc).size() == json(log).size() + 1, "the cascade was not one commit");
    refused_with(doc.apply("{not json"), "document_apply: ", "bad op text");
    return {};
}

// ---- 5. values, lists and kinds ---------------------------------------------------------------
static Result<void> values_lists_and_kinds() {
    {
        CADACLYSM_TRY(doc, plate_document());
        CADACLYSM_TRY(added, doc.apply(add_op(R"J({"id": "m", "kind": "measure.mass", "solid": "x1"})J")));
        (void)added;
        CADACLYSM_TRY(m, doc.value("m"));
        const Json parsed = json(m);  // kept: operator[] returns a reference into it
        const Json& v = parsed["volume"];
        check(v.kind == Json::Kind::number && std::fabs(v.n - 1000) < 1e-6, "the mass node's volume is " + m);
    }
    {
        CADACLYSM_TRY(doc, Document::make());
        CADACLYSM_TRY_VOID(doc.apply(add_op(R"J({"id": "w", "kind": "value", "value": "=range(10, 40, 10)"})J")).map([](const std::string&) {}));
        CADACLYSM_TRY_VOID(doc.apply(add_op(R"J({"id": "c", "kind": "solid.cuboid", "x": "=w", "y": "=[1, 2]", "z": 1})J")).map([](const std::string&) {}));
        CADACLYSM_TRY_VOID(doc.apply(add_op(R"J({"id": "x", "kind": "solid.cuboid", "x": "=w", "y": "=[1, 2]", "z": 1, "lacing": "cross"})J"))
                               .map([](const std::string&) {}));
        CADACLYSM_TRY(w, doc.value("w"));
        Json wj = json(w);
        check(wj.size() == 3 && wj[0].is(10) && wj[1].is(20) && wj[2].is(30), "w is " + w);
        check(kind_of(doc, "c") == "list", "c is a " + kind_of(doc, "c"));
        CADACLYSM_TRY(c, doc.value("c"));
        std::size_t n = json(c).size();
        check(n == 3, "c holds " + std::to_string(n) + " items, not 3 (longest: the depths' last item repeats)");
        const double want[] = {10, 40, 60};
        for (std::size_t i = 0; i < n && i < 3; ++i) {
            double got = volume_of(doc, "c#" + std::to_string(i));
            check(approx(got, want[i]), "c#" + std::to_string(i) + " has volume " + std::to_string(got));
        }
        check(kind_of(doc, "c#1") == "solid", "c#1 is a " + kind_of(doc, "c#1"));
        const double cross[] = {10, 20, 30, 20, 40, 60};
        CADACLYSM_TRY(x, doc.value("x"));
        std::size_t m = json(x).size();
        check(m == 6, "x holds " + std::to_string(m) + " items");
        for (std::size_t i = 0; i < m && i < 6; ++i) {
            check(approx(volume_of(doc, "x#" + std::to_string(i)), cross[i]), "x#" + std::to_string(i) + "'s volume");
        }
        CADACLYSM_TRY(text, doc.save());
        CADACLYSM_TRY(back, Document::load(text));
        check(back.save().value_or("") == text, "the laced document does not round-trip");
    }
    CADACLYSM_TRY(kinds, Document::kinds());
    Json rows = json(kinds);
    std::set<std::string> names;
    for (const Json& r : rows.items) names.insert(r["name"].s);
    check(rows.size() > 100 && names.count("profile.rect") && names.count("solid.extrude") && names.count("measure.mass"),
          "kinds lists " + std::to_string(rows.size()) + " rows");
    {
        CADACLYSM_TRY(doc, Document::make());
        CADACLYSM_TRY(p, doc.apply(R"J({"op": "param", "name": "k", "value": -5})J"));
        (void)p;
        CADACLYSM_TRY(a, doc.apply(add_op(R"J({"id": "bad", "kind": "profile.rect", "w": "=k", "h": 1})J")));
        (void)a;
        CADACLYSM_TRY(errors, doc.errors());
        Json e = json(errors);
        check(e.size() == 1 && e[0]["id"].is("bad") && e[0]["state"].is("error") && e[0]["message"].kind == Json::Kind::string &&
                  !e[0]["message"].s.empty(),
              "the bad profile's errors are " + errors);
        CADACLYSM_TRY(cheap, doc.evaluate(true));
        check(json(cheap).size() > 0 && json(cheap)[0]["id"].is("bad"), "evaluate(cheap_only) first row: " + cheap);
    }
    return {};
}

// ---- 6. params ---------------------------------------------------------------------------------
static Result<void> params() {
    CADACLYSM_TRY(doc, Document::make());
    CADACLYSM_TRY(empty, doc.params());
    check(json(empty).kind == Json::Kind::object && json(empty).size() == 0, "a new document has params " + empty);
    CADACLYSM_TRY(p1, doc.apply(R"J({"op": "param", "name": "w", "value": 200})J"));
    (void)p1;
    CADACLYSM_TRY(params, doc.params());
    check(json(params).size() == 1 && json(params)["w"].is(200), "params read " + params);
    CADACLYSM_TRY(a, doc.apply(add_op(R"J({"id": "rect", "kind": "profile.rect", "w": "=w", "h": 100})J")));
    CADACLYSM_TRY(b, doc.apply(add_op(R"J({"id": "ext", "kind": "solid.extrude", "profile": "rect", "frame": "xy", "distance": 10})J")));
    (void)a;
    (void)b;
    check(approx(volume_of(doc, "ext"), 200 * 100 * 10), "w 200 gives " + std::to_string(volume_of(doc, "ext")));
    CADACLYSM_TRY(p2, doc.apply(R"J({"op": "param", "name": "w", "value": 300})J"));
    (void)p2;
    check(approx(volume_of(doc, "ext"), 300 * 100 * 10), "w 300 gives " + std::to_string(volume_of(doc, "ext")));
    Json op = first_op(log_of(doc)[0]);
    check(op.size() == 3 && op["op"].is("param") && op["name"].is("w") && op["value"].is(300), "the param commit's op is " + written(op));
    CADACLYSM_TRY(before, doc.save());
    refused_with(doc.apply(R"J({"op": "param", "name": "w", "value": null})J"), "document_apply: ", "deleting a read parameter");
    check(doc.save().value_or("") == before && json(doc.params().value_or("{}"))["w"].is(300), "a refused delete changed the document");
    return {};
}

// ---- 7. branches and the log --------------------------------------------------------------------
static Result<void> branches_and_the_log() {
    CADACLYSM_TRY(doc, plate_document());
    Json list = branch_list(doc);
    check(list["branch"].is("main") && list["branches"].size() == 1 && list["branches"]["main"].is(head_id(doc)),
          "a new plate's branches: " + written(list));
    CADACLYSM_TRY_VOID(doc.branch_new("idea"));
    list = branch_list(doc);
    check(list["branch"].is("idea") && key_set(list["branches"]) == std::set<std::string>{"main", "idea"},
          "after branch_new: " + written(list));
    check(list["branches"]["idea"].s == list["branches"]["main"].s, "idea does not start at main's tip");
    check(ids(log_of(doc, std::string("main"))) == ids(log_of(doc)), "log(main) is not the head's line");
    CADACLYSM_TRY_VOID(doc.switch_to("main"));
    CADACLYSM_TRY_VOID(doc.branch_rename("idea", "plan"));
    check(key_set(branch_list(doc)["branches"]) == std::set<std::string>{"main", "plan"}, "after the rename");
    CADACLYSM_TRY_VOID(doc.branch_delete("plan"));
    check(key_set(branch_list(doc)["branches"]) == std::set<std::string>{"main"}, "after the delete");
    refused_with(doc.branch_delete("plan"), "document_branch_delete: ", "deleting a missing branch");
    refused_with(doc.branch_delete("main"), "document_branch_delete: ", "deleting the current branch");
    refused_with(doc.branch_rename("plan", "x"), "document_branch_rename: ", "renaming a missing branch");
    refused_with(doc.log(std::string("plan")), "document_log: ", "the log of a missing branch");
    refused_with(doc.switch_to("nowhere"), "document_branch_switch: ", "switching nowhere");
    CADACLYSM_TRY(tips, doc.tips());
    check(json(tips).size() == 0, "tips " + tips);
    Json log = log_of(doc);
    std::string root = log[log.size() - 1]["id"].s;
    CADACLYSM_TRY_VOID(doc.branch_new("early", root));
    list = branch_list(doc);
    check(list["branches"]["early"].is(root) && list["branch"].is("main"), "branch_new at the root: " + written(list));

    // test_document_log_order_and_messages
    {
        CADACLYSM_TRY(d, Document::make());
        CADACLYSM_TRY(a, d.apply(add_op(R"J({"id": "r1", "kind": "profile.rect", "w": 1, "h": 1})J"), std::string("first")));
        CADACLYSM_TRY(b, d.apply(add_op(R"J({"id": "r2", "kind": "profile.rect", "w": 2, "h": 2})J")));
        CADACLYSM_TRY(c, d.apply(add_op(R"J({"id": "r3", "kind": "profile.rect", "w": 3, "h": 3})J"), std::string("third")));
        (void)a;
        (void)b;
        (void)c;
        Json l = log_of(d);
        check(l.size() == 4 && l[0]["message"].is("third") && !l[1].has("message") && l[2]["message"].is("first") &&
                  !l[3].has("message"),
              "the log's messages: " + written(l));
        std::vector<std::string> added;
        for (std::size_t i = 0; i < 3 && i < l.size(); ++i) added.push_back(first_op(l[i])["node"]["id"].s);
        check(added == std::vector<std::string>{"r3", "r2", "r1"}, "the log's ops add the wrong nodes");
        check(l[0]["id"].s == head_id(d) && strings(l[0]["parents"]) == std::vector<std::string>{l[1]["id"].s} &&
                  l[3]["parents"].kind == Json::Kind::array && l[3]["parents"].size() == 0,
              "the log's parents: " + written(l));
    }
    // test_document_switch_by_name_and_by_commit_id
    {
        CADACLYSM_TRY(d, plate_document());
        std::string first = log_of(d)[1]["id"].s;
        CADACLYSM_TRY_VOID(d.branch_new("side"));
        CADACLYSM_TRY(c1, d.apply(add_op(R"J({"id": "c1", "kind": "profile.circle", "r": 2})J")));
        (void)c1;
        check(branch_list(d)["branch"].is("side") && kind_of(d, "c1") != "none", "c1 on side");
        CADACLYSM_TRY_VOID(d.switch_to("main"));
        check(branch_list(d)["branch"].is("main") && kind_of(d, "c1") == "none" && kind_of(d, "x1") != "none", "back on main");
        CADACLYSM_TRY_VOID(d.switch_to("side"));
        check(kind_of(d, "c1") != "none", "c1 back on side");
        CADACLYSM_TRY_VOID(d.switch_to(first));
        Json l = branch_list(d);
        check(l.has("branch") && l["branch"].is_null() && head_id(d) == first, "a commit id did not detach: " + written(l));
        check(kind_of(d, "r1") != "none" && kind_of(d, "x1") == "none" && kind_of(d, "c1") == "none", "the detached head's nodes");
        check(!l["branches"]["main"].is(first) && !can_redo(d), "no branch to redo along");
        CADACLYSM_TRY_VOID(d.switch_to("main"));
        check(branch_list(d)["branch"].is("main") && kind_of(d, "x1") != "none", "back on main again");
    }
    // test_document_tips_after_undo_and_an_edit
    {
        CADACLYSM_TRY(d, plate_document());
        check(json(d.tips().value_or("x")).size() == 0, "tips of a new plate");
        Json old = log_of(d)[0];
        CADACLYSM_TRY(undone, d.undo());
        check(undone, "undo");
        CADACLYSM_TRY(c1, d.apply(add_op(R"J({"id": "c1", "kind": "profile.circle", "r": 2})J"), std::string("other way")));
        (void)c1;
        Json t = json(d.tips().value_or("[]"));
        check(ids(t) == std::vector<std::string>{old["id"].s}, "tips are " + written(t));
        check(t.size() == 1 && first_op(t[0])["node"]["id"].is("x1"), "a tip is a whole commit");
        check(t.size() == 1 && strings(t[0]["parents"]) == std::vector<std::string>{log_of(d)[1]["id"].s} &&
                  strings(t[0]["parents"]) == strings(old["parents"]),
              "the tip's parents");
        Json head = log_of(d)[0];
        std::vector<std::string> tip_ids = ids(t);
        check(head["message"].is("other way") && std::find(tip_ids.begin(), tip_ids.end(), head["id"].s) == tip_ids.end(),
              "the head after the edit");
        CADACLYSM_TRY_VOID(d.switch_to(old["id"].s));
        check(kind_of(d, "x1") != "none" && kind_of(d, "c1") == "none", "the abandoned line");
        CADACLYSM_TRY_VOID(d.switch_to("main"));
        CADACLYSM_TRY_VOID(d.branch_new("kept", old["id"].s));
        check(json(d.tips().value_or("x")).size() == 0, "naming the line left it a tip");
    }
    return {};
}

// ---- 8. batch and preview -------------------------------------------------------------------------
static Result<void> batch_and_preview() {
    {
        CADACLYSM_TRY(doc, plate_document());
        std::size_t before = log_of(doc).size();
        Result<void> batched = doc.batch(std::string("slot and fillet"), [&doc]() -> Result<void> {
            CADACLYSM_TRY(a, doc.apply(add_op(R"J({"id": "c1", "kind": "profile.circle", "r": 2})J")));
            CADACLYSM_TRY(b, doc.apply(add_op(R"J({"id": "c2", "kind": "profile.circle", "r": 3})J")));
            (void)a;
            (void)b;
            check(kind_of(doc, "c2") != "none", "the ops are not live inside the batch");
            return {};
        });
        CADACLYSM_TRY_VOID(batched);
        Json log = log_of(doc);
        check(log.size() == before + 1 && log[0]["message"].is("slot and fillet") && log[0]["ops"].size() == 2,
              "the batch's commit: " + written(log[0]));
        CADACLYSM_TRY(undone, doc.undo());
        check(undone, "undo of the batch");
        check(kind_of(doc, "c1") == "none" && kind_of(doc, "c2") == "none", "undo left a batch node");
        CADACLYSM_TRY_VOID(doc.batch([]() {}));
        check(log_of(doc).size() == before, "an empty batch recorded something");
        // A body's own Result passes through a normal end.
        Result<int> answer = doc.batch([]() -> Result<int> { return 42; });
        check(answer.ok() && *answer == 42, "the body's value did not come back");
    }
    {
        CADACLYSM_TRY(doc, plate_document());
        CADACLYSM_TRY(before, doc.save());
        CADACLYSM_TRY(log, doc.log());
        Result<void> failed = doc.batch(std::string("never"), [&doc]() -> Result<void> {
            CADACLYSM_TRY(a, doc.apply(add_op(R"J({"id": "c1", "kind": "profile.circle", "r": 2})J")));
            CADACLYSM_TRY(b, doc.apply(set_op("r1", R"J({"w": 20})J")));
            (void)a;
            (void)b;
            return Error{"never", cadaclysm::Origin::kernel};
        });
        check(!failed.ok() && failed.error().message == "never", "the batch passed on " + (failed.ok() ? std::string("nothing") : failed.error().message));
        check(doc.save().value_or("") == before && doc.log().value_or("") == log, "the failed batch was not rolled back");
        check(kind_of(doc, "c1") == "none" && approx(volume_of(doc, "x1"), 1000), "the failed batch left its ops");
        Result<void> inside = doc.batch([&doc]() -> Result<void> {
            CADACLYSM_TRY(a, doc.apply(add_op(R"J({"id": "c1", "kind": "profile.circle", "r": 2})J")));
            (void)a;
            CADACLYSM_TRY(b, doc.apply(R"J({"op": "remove", "id": "r1"})J"));
            (void)b;
            return {};
        });
        refused_with(inside, "document_apply: ", "the refusal inside the batch");
        check(doc.save().value_or("") == before, "the refused batch was not rolled back");
        Result<void> again = doc.batch(std::string("again"), [&doc]() -> Result<void> {
            return doc.apply(add_op(R"J({"id": "c1", "kind": "profile.circle", "r": 2})J")).map([](const std::string&) {});
        });
        CADACLYSM_TRY_VOID(again);
        check(log_of(doc)[0]["message"].is("again"), "a batch after a failed one");
#if DOCUMENT_TEST_EXCEPTIONS
        CADACLYSM_TRY(redone, doc.undo());
        (void)redone;
        CADACLYSM_TRY(again_before, doc.save());
        bool caught = false;
        try {
            Result<void> thrown = doc.batch([&doc]() {
                Result<std::string> a = doc.apply(add_op(R"J({"id": "c9", "kind": "profile.circle", "r": 2})J"));
                (void)a;
                throw std::runtime_error("thrown");
            });
            (void)thrown;
        } catch (const std::runtime_error& e) {
            caught = std::string(e.what()) == "thrown";
        }
        check(caught, "the body's exception did not propagate");
        check(doc.save().value_or("") == again_before && kind_of(doc, "c9") == "none", "the thrown batch was not rolled back");
#endif
        // the clean-up is refused (the document is closed inside): the body's own Error comes out
        Result<void> closed = doc.batch([&doc]() -> Result<void> {
            doc.close();  // nothing left to abort
            return Error{"/ by zero", cadaclysm::Origin::kernel};
        });
        check(!closed.ok() && closed.error().message == "/ by zero",
              "a refused clean-up replaced the body's error: " + (closed.ok() ? std::string("nothing") : closed.error().message));
    }
    {
        CADACLYSM_TRY(doc, plate_document());
        Result<void> outer = doc.batch([&doc]() { refused_with(doc.batch([]() {}), "document_batch_begin: ", "a nested batch"); });
        CADACLYSM_TRY_VOID(outer);
    }
    {
        CADACLYSM_TRY(doc, plate_document());
        CADACLYSM_TRY(before, doc.save());
        CADACLYSM_TRY(log, doc.log());
        Result<void> previewed = doc.preview([&doc]() -> Result<void> {
            CADACLYSM_TRY(a, doc.apply(set_op("r1", R"J({"w": 30})J")));
            CADACLYSM_TRY(b, doc.apply(add_op(R"J({"id": "c1", "kind": "profile.circle", "r": 2})J")));
            (void)a;
            (void)b;
            check(approx(volume_of(doc, "x1"), 30 * 10 * 10), "inside the preview x1 is " + std::to_string(volume_of(doc, "x1")));
            check(kind_of(doc, "c1") != "none", "c1 is not there inside the preview");
            return {};
        });
        CADACLYSM_TRY_VOID(previewed);
        check(doc.save().value_or("") == before && doc.log().value_or("") == log, "the preview was recorded");
        check(approx(volume_of(doc, "x1"), 1000) && kind_of(doc, "c1") == "none", "the preview was not taken back");
        Result<void> cancelled = doc.preview([&doc]() -> Result<void> {
            CADACLYSM_TRY(a, doc.apply(set_op("r1", R"J({"w": 40})J")));
            (void)a;
            return Error{"drag cancelled", cadaclysm::Origin::kernel};
        });
        check(!cancelled.ok() && cancelled.error().message == "drag cancelled", "the preview passed on the wrong error");
        check(doc.save().value_or("") == before && approx(volume_of(doc, "x1"), 1000), "the cancelled preview was not taken back");
        check(can_undo(doc), "the preview touched the history");
#if DOCUMENT_TEST_EXCEPTIONS
        bool caught = false;
        try {
            Result<void> thrown = doc.preview([&doc]() {
                Result<std::string> a = doc.apply(set_op("r1", R"J({"w": 50})J"));
                (void)a;
                throw std::invalid_argument("drag thrown");
            });
            (void)thrown;
        } catch (const std::invalid_argument& e) {
            caught = std::string(e.what()) == "drag thrown";
        }
        check(caught, "the preview's exception did not propagate");
        check(doc.save().value_or("") == before && approx(volume_of(doc, "x1"), 1000), "the thrown preview was not taken back");
#endif
        Result<void> closed = doc.preview([&doc]() -> Result<void> {
            doc.close();
            return Error{"drag cancelled", cadaclysm::Origin::kernel};
        });
        check(!closed.ok() && closed.error().message == "drag cancelled", "a refused clean-up replaced the preview's error");
    }
    {
        CADACLYSM_TRY(doc, plate_document());
        Result<void> outer = doc.preview([&doc]() { refused_with(doc.preview([]() {}), "document_preview_begin: ", "a nested preview"); });
        CADACLYSM_TRY_VOID(outer);
    }
    // the editor's drag: frames replace each other, end_preview takes the drag back
    {
        CADACLYSM_TRY(doc, plate_document());
        CADACLYSM_TRY(before, doc.save());
        CADACLYSM_TRY(log, doc.log());
        CADACLYSM_TRY(f1, doc.preview_frame(set_op("r1", R"J({"w": 30})J")));
        (void)f1;
        check(approx(volume_of(doc, "x1"), 3000), "the first frame gives " + std::to_string(volume_of(doc, "x1")));
        CADACLYSM_TRY(f2, doc.preview_frame(set_op("r1", R"J({"w": 40})J")));
        (void)f2;
        check(approx(volume_of(doc, "x1"), 4000), "the second frame gives " + std::to_string(volume_of(doc, "x1")) + " (frames stack?)");
        CADACLYSM_TRY(ended, doc.end_preview());
        (void)ended;
        check(approx(volume_of(doc, "x1"), 1000), "end_preview left " + std::to_string(volume_of(doc, "x1")));
        check(doc.save().value_or("") == before && doc.log().value_or("") == log, "the drag was recorded");
    }
    return {};
}

// ---- 9. result types (test_document_result_types) -------------------------------------------------
static Result<void> result_types() {
    CADACLYSM_TRY(doc, Document::make());
    const char* const nodes[] = {
        R"J({"id": "r", "kind": "profile.rect", "w": 40, "h": 30})J",
        R"J({"id": "c", "kind": "profile.circle", "r": 5})J",
        R"J({"id": "m", "kind": "profile.translate", "profile": "c", "by": [20, 0]})J",
        R"J({"id": "pieces", "kind": "profile.pieces", "profile": "r", "cutters": ["m"]})J",
        R"J({"id": "k", "kind": "curve.nurbs", "points": [[0, 0, 0], [10, 5, 0], [20, -5, 0], [30, 0, 0]]})J",
        R"J({"id": "cage", "kind": "subd.cuboid", "size": [20, 10, 5], "segments": [2, 1, 1]})J",
        R"J({"id": "e", "kind": "solid.extrude", "profile": "r", "frame": "xy", "distance": 2})J",
        R"J({"id": "mass", "kind": "measure.mass", "solid": "e"})J",
    };
    for (const char* node : nodes) {
        CADACLYSM_TRY(added, doc.apply(add_op(node)));
        (void)added;
    }
    CADACLYSM_TRY(status, doc.evaluate());
    std::vector<std::string> st = states(status);
    check(std::count(st.begin(), st.end(), std::string("ok")) == 8, "not 8 nodes ok: " + status);
    check(kind_of(doc, "r") == "profile", "r is a " + kind_of(doc, "r"));
    check(kind_of(doc, "pieces") == "profiles", "pieces is a " + kind_of(doc, "pieces"));
    CADACLYSM_TRY(pieces, doc.result_profiles("pieces"));
    check(pieces.size() >= 2, "pieces gave " + std::to_string(pieces.size()) + " profiles");
    check(kind_of(doc, "k") == "nurbs", "k is a " + kind_of(doc, "k"));
    CADACLYSM_TRY(curve, doc.result_nurbs_curve("k"));
    check(curve.degree() == 3, "k has degree " + std::to_string(curve.degree()));
    check(kind_of(doc, "cage") == "subd", "cage is a " + kind_of(doc, "cage"));
    CADACLYSM_TRY(cage, doc.result_subd("cage"));
    const std::array<double, 3> size{20, 10, 5};
    const std::array<std::uint32_t, 3> segments{2, 1, 1};
    CADACLYSM_TRY(want, bs::Subd::cuboid(size, segments));
    check(cage.faces().size() == want.faces().size(), "cage has " + std::to_string(cage.faces().size()) + " faces");
    CADACLYSM_TRY(outline, doc.apply(add_op(R"J({"id": "outline", "kind": "curve.polyline", "points": [[0, 0], [10, 0], [10, 5], [3, 9]], "closed": true})J")));
    (void)outline;
    check(kind_of(doc, "outline") == "curve", "outline is a " + kind_of(doc, "outline"));
    CADACLYSM_TRY(ov, doc.value("outline"));
    Json o = json(ov);
    check(o.size() == 2 && o["type"].is("curve") && o["closed"].kind == Json::Kind::boolean && o["closed"].b, "outline's value is " + ov);
    CADACLYSM_TRY(mv, doc.value("mass"));
    check(kind_of(doc, "mass") == "value" && json(mv).kind == Json::Kind::object, "mass is a " + kind_of(doc, "mass"));
    check(kind_of(doc, "missing") == "none", "a missing node is a " + kind_of(doc, "missing"));
    refused_with(doc.result_profiles("e"), "document_result_profile_count: ", "profiles of a solid");
    refused_with(doc.result_nurbs_curve("cage"), "document_result_nurbs_curve: ", "a curve of a cage");
    refused_with(doc.result_subd("k"), "document_result_subd: ", "a cage of a curve");
    return {};
}

// ---- 10. held geometry ------------------------------------------------------------------------------
static Result<void> held_geometry() {
    {
        const bs::Vec2 origin{0, 0};
        CADACLYSM_TRY(cylinder, bs::Solid::cylinder(5, 60));
        CADACLYSM_TRY(cutter, cylinder.translate(0, 0, -20));
        CADACLYSM_TRY(block, bs::Solid::cuboid(40, 30, 20));
        CADACLYSM_TRY(part, block.cut(cutter));
        CADACLYSM_TRY(hole, bs::Profile::circle(2));
        CADACLYSM_TRY(slot0, bs::Profile::slot(origin, 30, 5));
        CADACLYSM_TRY(slot, slot0.with_hole(hole));
        CADACLYSM_TRY(doc, Document::make());
        CADACLYSM_TRY(held, doc.add_solid(part));
        CADACLYSM_TRY(outline, doc.add_profile(slot));
        CADACLYSM_TRY(a, doc.apply(add_op("{\"id\": \"x\", \"kind\": \"solid.extrude\", \"profile\": \"" + outline + "\", \"distance\": 4}")));
        CADACLYSM_TRY(b, doc.apply(add_op("{\"id\": \"c\", \"kind\": \"solid.cut\", \"target\": \"" + held + "\", \"tool\": \"x\"}")));
        (void)a;
        (void)b;
        CADACLYSM_TRY(errors, doc.errors());
        check(json(errors).size() == 0, "the held document has errors " + errors);
        check(kind_of(doc, held) == "solid", "the held solid is a " + kind_of(doc, held));
        CADACLYSM_TRY(got, doc.result_solid(held));
        CADACLYSM_TRY(got_body, got.document_body());
        CADACLYSM_TRY(part_body, part.document_body());
        check(got_body == part_body, "the held body is not the very body");
        check(volume(got) == volume(part), "the held volume is not the part's to the bit");
        CADACLYSM_TRY(path, slot.document_path());
        Json p = json(path);
        std::size_t arcs = 0;
        for (const Json& s : p["segments"].items) arcs += s["type"].is("arc") ? 1 : 0;
        check(arcs == 2 && p["holes"].size() == 1, "the slot's path: " + path);
        CADACLYSM_TRY(held_profile, doc.result_profile(outline));
        check(held_profile.document_path().value_or("") == path, "the held path is not the slot's");
        CADACLYSM_TRY(xy, bs::Frame::xy());
        CADACLYSM_TRY(want, bs::Solid::extrude(slot, xy, 4));
        double x = volume_of(doc, "x");
        check(std::fabs(x - volume(want)) <= 1e-9 * volume(want), "the extruded slot reads " + std::to_string(x));
        check(volume_of(doc, "c") < volume(part), "the cut is not smaller");
        CADACLYSM_TRY(text, doc.save());
        {
            CADACLYSM_TRY(back, Document::load(text));
            check(back.save().value_or("") == text, "the held document does not round-trip");
            CADACLYSM_TRY(again, back.result_solid(held));
            check(again.faces() == part.faces(), "the loaded held solid's faces");
        }
        CADACLYSM_TRY(square, bs::Profile::rect(10, 10));
        CADACLYSM_TRY(face, bs::Solid::face(square, xy));
        CADACLYSM_TRY(sheet, doc.add_solid(face, true));
        check(doc.save().value_or("").find("sheet.body") != std::string::npos, "no sheet.body in the save");
        CADACLYSM_TRY(sheet_solid, doc.result_solid(sheet));
        check(kind_of(doc, sheet) == "sheet" && sheet_solid.faces() == 1, "the sheet is a " + kind_of(doc, sheet));
        std::string said = refusal(doc.apply(add_op(R"J({"kind": "solid.body", "body": "not a body"})J")), "a bad body");
        check(said.find("must be a body") != std::string::npos, "a bad body said " + said);
    }
    // test_document_keeps_held_colours_through_save_and_load
    {
        const bs::Vec2 origin{0, 0};
        const Vec3 red{1, 0, 0}, green{0, 0.5, 0}, blue{0, 0, 1}, yellow{1, 1, 0}, grey{0.25, 0.5, 0.75};
        CADACLYSM_TRY(cube, bs::Solid::cuboid(1, 1, 1));
        CADACLYSM_TRY(c1, cube.coloured(red));
        CADACLYSM_TRY(c2, c1.coloured(green, 2u));
        CADACLYSM_TRY(c3, c2.edges_coloured(blue));
        CADACLYSM_TRY(part, c3.edges_coloured(yellow, std::vector<std::uint32_t>{3}));
        CADACLYSM_TRY(slot0, bs::Profile::slot(origin, 30, 5));
        CADACLYSM_TRY(slot, slot0.coloured(grey));
        CADACLYSM_TRY(plain_rect, bs::Profile::rect(2, 1));
        CADACLYSM_TRY(doc, Document::make());
        CADACLYSM_TRY(held, doc.add_solid(part));
        CADACLYSM_TRY(outline, doc.add_profile(slot));
        CADACLYSM_TRY(plain, doc.add_profile(plain_rect));
        CADACLYSM_TRY(saved, doc.save());
        CADACLYSM_TRY(back, Document::load(saved));
        CADACLYSM_TRY(got, back.result_solid(held));
        CADACLYSM_TRY(colour, got.colour());
        check(same_floats(colour, red), "the held colour");
        CADACLYSM_TRY(f2, got.face_colour(2));
        CADACLYSM_TRY(f0, got.face_colour(0));
        check(same_floats(f2, green) && same_floats(f0, red), "the held face colours");
        CADACLYSM_TRY(e3, got.edge_colour(3));
        CADACLYSM_TRY(e0, got.edge_colour(0));
        check(same_floats(e3, yellow) && same_floats(e0, blue), "the held edge colours");
        CADACLYSM_TRY(got_body, got.document_body());
        CADACLYSM_TRY(part_body, part.document_body());
        check(got_body == part_body, "the coloured body is not the very body");
        CADACLYSM_TRY(held_slot, back.result_profile(outline));
        CADACLYSM_TRY(slot_colour, held_slot.colour());
        check(same_floats(slot_colour, grey), "the held profile's colour");
        CADACLYSM_TRY(held_plain, back.result_profile(plain));
        CADACLYSM_TRY(plain_colour, held_plain.colour());
        check(!plain_colour, "an uncoloured profile came back coloured");
        Json bare = json(part_body);
        for (const char* k : {"colour", "face_colours", "edges_colour", "edge_colours"}) bare.erase(k);
        CADACLYSM_TRY(added, back.apply(add_op("{\"kind\": \"solid.body\", \"body\": " + written(bare) + "}")));
        std::string bare_id = json(added)["added"][0].s;
        CADACLYSM_TRY(bare_solid, back.result_solid(bare_id));
        CADACLYSM_TRY(bare_colour, bare_solid.colour());
        check(!bare_colour, "a body written without colours is coloured");
    }
    return {};
}

// ---- 11. building documents ------------------------------------------------------------------------
static Result<Document> bim_wall_document() {
    CADACLYSM_TRY(doc, Document::new_bim("mm"));
    CADACLYSM_TRY(added, doc.apply(R"J({"op": "batch", "ops": [)J"
                                   R"J({"op": "add", "node": {"id": "l0", "kind": "bim.level", "name": "Ground"}},)J"
                                   R"J({"op": "add", "node": {"id": "part", "kind": "bim.wall_type", "name": "Partition",)J"
                                   R"J( "layers": [{"material": "block", "thickness": 100, "function": "structure"}]}},)J"
                                   R"J({"op": "add", "node": {"id": "w1", "kind": "bim.wall", "level": "l0", "type": "part",)J"
                                   R"J( "a": [0, 0], "b": [4000, 0]}}]})J"));
    (void)added;
    return doc;
}

static std::string project_guid(const Document& doc) {
    Json saved = json(doc.save().value_or("{}"));
    for (const Json& node : saved["nodes"].items) {
        if (node["kind"].is("bim.project")) return node["guid"].s;
    }
    check(false, "a new building document holds no bim.project");
    return "";
}

static Result<void> building_documents() {
    const std::string ifc2x3 = R"J({"schema": "IFC2X3", "timestamp": 0})J";
    const std::string prefix = "bim_document_export_ifc: ";
    {
        CADACLYSM_TRY(doc, bim_wall_document());
        CADACLYSM_TRY(text, doc.export_ifc(ifc2x3));
        check(text.find("IFCWALLSTANDARDCASE(") != std::string::npos, "the IFC2X3 export has no IFCWALLSTANDARDCASE");
        CADACLYSM_TRY(saved, doc.save());
        const std::string file = "cadaclysm-document-test-wall.json";
        {
            std::ofstream out(file, std::ios::binary);
            out << saved;
        }
        Result<Document> opened = Document::open_bim(file);
        std::remove(file.c_str());
        check(opened.ok() && opened->export_ifc(ifc2x3).value_or("") == text, "open_bim exports another file");
        CADACLYSM_TRY(loaded, Document::load_bim(saved));
        check(loaded.export_ifc(ifc2x3).value_or("") == text, "load_bim exports another file");
        CADACLYSM_TRY(exact, doc.export_ifc(std::string(R"J({"geometry": "exact", "timestamp": 0, "name": "Wall"})J")));
        check(exact.find("IFCPROJECT(") != std::string::npos && exact.find("'Wall'") != std::string::npos && exact != text,
              "the exact export");
        CADACLYSM_TRY(t, doc.apply(add_op(R"J({"id": "d900", "kind": "bim.door_type", "width": 900, "height": 2100})J")));
        CADACLYSM_TRY(o, doc.apply(add_op(R"J({"id": "o1", "kind": "bim.door", "host": "w1", "type": "d900", "joins": [], "offset": 3900})J")));
        (void)t;
        (void)o;
        std::string said = refusal(doc.export_ifc(std::string(R"J({"timestamp": 0})J")), "a door outside its wall");
        check(said.compare(0, prefix.size(), prefix) == 0, "the door's refusal said " + said);
        check(said.find(R"J("node": "o1")J") != std::string::npos || said.find(R"J("node":"o1")J") != std::string::npos,
              "the door's refusal does not name o1: " + said);
        if (said.size() > prefix.size()) {
            check(json(said.substr(prefix.size()))["refusals"][0]["node"].is("o1"), "the door's refusal names another node: " + said);
        }
        std::string ifc5 = refusal(doc.export_ifc(std::string(R"J({"schema": "IFC5"})J")), "schema IFC5");
        check(ifc5.find("IFC4 or IFC2X3") != std::string::npos, "IFC5 said " + ifc5);
    }
    {
        CADACLYSM_TRY(plain, Document::make());
        std::string said = refusal(plain.export_ifc(), "a plain document's export");
        check(said.find("not a BIM document") != std::string::npos, "a plain document's export said " + said);
        if (said.size() > prefix.size()) {
            check(json(said.substr(prefix.size()))["refusals"][0]["node"].is_null(), "a plain document's refusal names a node: " + said);
        }
    }
    CADACLYSM_TRY(kinds, Document::bim_kinds());
    std::set<std::string> names;
    for (const Json& r : json(kinds).items) names.insert(r["name"].s);
    check(names.count("bim.project") && names.count("bim.wall") && names.count("solid.extrude"), "bim_kinds lacks a kind");
    CADACLYSM_TRY(a, Document::new_bim());
    CADACLYSM_TRY(b, Document::new_bim());
    std::string ga = project_guid(a), gb = project_guid(b);
    check(ga.size() == 36 && ga[14] == '4' && ga != gb, "the project guids are " + ga + " and " + gb);
    return {};
}

// ---- 12. lifetime ----------------------------------------------------------------------------------
static Result<void> lifetime() {
    CADACLYSM_TRY(doc, plate_document());
    CADACLYSM_TRY(k, doc.apply(add_op(R"J({"id": "k", "kind": "curve.nurbs", "points": [[0, 0, 0], [10, 5, 0], [20, -5, 0], [30, 0, 0]]})J")));
    CADACLYSM_TRY(c, doc.apply(add_op(R"J({"id": "cage", "kind": "subd.cuboid", "size": [20, 10, 5], "segments": [2, 1, 1]})J")));
    (void)k;
    (void)c;
    CADACLYSM_TRY(solid, doc.result_solid("x1"));
    CADACLYSM_TRY(profile, doc.result_profile("r1"));
    CADACLYSM_TRY(curve, doc.result_nurbs_curve("k"));
    CADACLYSM_TRY(cage, doc.result_subd("cage"));
    doc.close();
    check(doc.closed() && doc.handle() == nullptr, "a closed document is not closed");
    check(solid.faces() == 6 && approx(volume(solid), 1000), "the solid died with its document");
    check(profile.document_path().value_or("").find("segments") != std::string::npos, "the profile died with its document");
    check(curve.degree() == 3, "the curve died with its document");
    check(!cage.faces().empty(), "the cage died with its document");
    check(refusal(doc.save(), "save on a closed document").find("closed") != std::string::npos, "a closed document did not say closed");
    check(refusal(doc.apply("{}"), "apply on a closed document") == "document: closed", "a closed apply");
    check(refusal(doc.result_solid("x1"), "a result of a closed document") == "document: closed", "a closed result");
    check(refusal(doc.batch([]() {}), "a batch on a closed document") == "document: closed", "a closed batch");
    doc.close();  // twice is fine
    // A moved-from document is closed too.
    CADACLYSM_TRY(other, plate_document());
    Document moved = std::move(other);
    check(other.closed() && !moved.closed(), "a move did not take the handle");  // NOLINT(bugprone-use-after-move)
    check(refusal(other.save(), "save on a moved-from document") == "document: closed", "a moved-from document");
    return {};
}

int main(int argc, char** argv) {
    if (argc > 1) {
        Result<void> loaded = bs::license(argv[1]);
        if (!loaded) {
            std::fprintf(stderr, "FAIL: license: %s\n", loaded.error().message.c_str());
            return 1;
        }
    }
    struct Test {
        const char* name;
        Result<void> (*run)();
    };
    const Test tests[] = {
        {"evaluate_and_results", evaluate_and_results},
        {"evaluate_with_progress", evaluate_with_progress},
        {"save_load_open_and_refusals", save_load_open_and_refusals},
        {"undo_and_redo", undo_and_redo},
        {"a_refusal_leaves_the_document_unchanged", a_refusal_leaves_the_document_unchanged},
        {"values_lists_and_kinds", values_lists_and_kinds},
        {"params", params},
        {"branches_and_the_log", branches_and_the_log},
        {"batch_and_preview", batch_and_preview},
        {"result_types", result_types},
        {"held_geometry", held_geometry},
        {"building_documents", building_documents},
        {"lifetime", lifetime},
    };
    for (const Test& t : tests) {
        int before = failures;
        Result<void> outcome = t.run();
        if (!outcome) {
            std::fprintf(stderr, "FAIL: %s: %s\n", t.name, outcome.error().message.c_str());
            ++failures;
        }
        std::printf("%s %s\n", failures == before ? "ok  " : "FAIL", t.name);
    }
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::printf("document: ok\n");
    return 0;
}
