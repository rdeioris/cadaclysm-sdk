// The forge's general kernel calls -- Document::revision/nodes/inputs/readers/probe/
// result_beziers/meta and Profile::from_pieces/pieces_json/fillet_corner/bounds/reversed --
// at parity with the Python reference's tests in test_cadaclysm_blacksmith.py
// (holed_document, test_document_revision_moves_with_the_state_only ..
// test_profile_fillet_corner_cuts_back_to_the_tangent_points). The calls answer JSON text,
// read here by the small reader below (the header reads none). Needs the kernel library and a
// license; the exit code is the verdict.
//
//     cadaclysm_forge_kernel_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Document;
using bs::Profile;

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

static bool contains(const std::string& text, const std::string& part) { return text.find(part) != std::string::npos; }

static bool near(double a, double b, double tolerance = 1e-9) { return std::fabs(a - b) <= tolerance; }

// ---- a just-enough JSON reader -------------------------------------------------------------

struct Json {
    enum class Kind { null, boolean, number, string, array, object };
    Kind kind = Kind::null;
    bool b = false;
    double n = 0.0;
    std::string s;
    std::vector<Json> items;        // an array's items, or an object's values
    std::vector<std::string> keys;  // an object's keys, beside its values

    std::size_t size() const { return items.size(); }
    const Json& operator[](std::size_t i) const {
        static const Json missing;
        return i < items.size() ? items[i] : missing;
    }
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

    Json value() {
        space();
        Json v;
        if (i_ >= s_.size()) return v;
        char c = s_[i_];
        if (c == '{' || c == '[') {
            const char close = c == '{' ? '}' : ']';
            v.kind = c == '{' ? Json::Kind::object : Json::Kind::array;
            ++i_;
            space();
            if (i_ < s_.size() && s_[i_] == close) {
                ++i_;
                return v;
            }
            while (i_ < s_.size()) {
                if (v.kind == Json::Kind::object) {
                    space();
                    v.keys.push_back(string());
                    space();
                    ++i_;  // ':'
                }
                v.items.push_back(value());
                space();
                if (i_ >= s_.size() || s_[i_++] == close) return v;
            }
            return v;
        }
        if (c == '"') {
            v.kind = Json::Kind::string;
            v.s = string();
            return v;
        }
        if (s_.compare(i_, 4, "true") == 0 || s_.compare(i_, 5, "false") == 0) {
            v.kind = Json::Kind::boolean;
            v.b = s_[i_] == 't';
            i_ += v.b ? 4 : 5;
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

    // Ids and kinds only: an escape keeps the character after the backslash.
    std::string string() {
        std::string out;
        ++i_;  // '"'
        while (i_ < s_.size()) {
            char c = s_[i_++];
            if (c == '"') return out;
            if (c == '\\' && i_ < s_.size()) c = s_[i_++];
            out.push_back(c);
        }
        return out;
    }

    const std::string& s_;
    std::size_t i_ = 0;
};

static Json json(const std::string& text) { return JsonReader::parse(text); }

static std::vector<std::string> strings(const Json& v) {
    std::vector<std::string> out;
    for (const Json& item : v.items) out.push_back(item.kind == Json::Kind::string ? item.s : std::string("<?>"));
    return out;
}

using Ids = std::vector<std::string>;

static std::string text_of(const Result<std::string>& r, const std::string& what) {
    if (!r) {
        check(false, what + ": " + r.error().message);
        return "null";
    }
    return *r;
}

// ---- the documents -------------------------------------------------------------------------

static std::string add_op(const std::string& node) { return "{\"op\": \"add\", \"node\": " + node + "}"; }

static std::string set_op(const std::string& id, const std::string& fields) {
    return "{\"op\": \"set\", \"id\": \"" + id + "\", \"fields\": " + fields + "}";
}

// Python's plate_document: a 10 x 10 rectangle r1 and its 10 mm extrusion x1.
static Result<Document> plate_document() {
    CADACLYSM_TRY(doc, Document::make("mm"));
    CADACLYSM_TRY(a, doc.apply(add_op(R"J({"id": "r1", "kind": "profile.rect", "w": 10, "h": 10})J")));
    CADACLYSM_TRY(b, doc.apply(add_op(R"J({"id": "x1", "kind": "solid.extrude", "profile": "r1", "frame": "xy", "distance": 10})J")));
    (void)a;
    (void)b;
    return doc;
}

// Python's holed_document: a 10 mm box and a 2 mm pin cut through it -- the box's six faces
// and the hole's wall.
static Result<Document> holed_document() {
    CADACLYSM_TRY(doc, Document::make("mm"));
    CADACLYSM_TRY(a, doc.apply(add_op(R"J({"id": "box", "kind": "solid.cuboid", "x": 10, "y": 10, "z": 10})J")));
    CADACLYSM_TRY(b, doc.apply(add_op(R"J({"id": "pin", "kind": "solid.cylinder", "r": 2, "h": 30, "at": [0, 0, -15]})J")));
    CADACLYSM_TRY(c, doc.apply(add_op(R"J({"id": "cut", "kind": "solid.cut", "target": "box", "tool": "pin"})J")));
    CADACLYSM_TRY(status, doc.evaluate());
    (void)a;
    (void)b;
    (void)c;
    (void)status;
    return doc;
}

static std::uint32_t faces_of(Document& doc, const std::string& id) {
    Result<bs::Solid> s = doc.result_solid(id);
    if (!s) {
        check(false, "result_solid(" + id + "): " + s.error().message);
        return 0;
    }
    return s->faces();
}

// ---- the tests -----------------------------------------------------------------------------

static Result<void> document_revision_moves_with_the_state_only() {
    CADACLYSM_TRY(doc, plate_document());
    CADACLYSM_TRY(r0, doc.revision());
    check(r0 >= 1, "a revision below 1: " + std::to_string(r0));
    CADACLYSM_TRY(status, doc.evaluate());
    CADACLYSM_TRY(saved, doc.save());
    CADACLYSM_TRY(nodes, doc.nodes());
    (void)status;
    (void)nodes;
    CADACLYSM_TRY(r1, doc.revision());
    check(r1 == r0, "an evaluation, a save or a read moved the revision");
    CADACLYSM_TRY(undone, doc.undo());
    check(undone, "nothing to undo");
    CADACLYSM_TRY(r2, doc.revision());
    check(r2 == r0 + 1, "an undo moved the revision by " + std::to_string(r2 - r0));
    CADACLYSM_TRY(changed, doc.apply(set_op("r1", R"({"w": 12})")));
    (void)changed;
    CADACLYSM_TRY(r3, doc.revision());
    check(r3 == r0 + 2, "a set moved the revision by " + std::to_string(r3 - r2));
    CADACLYSM_TRY(again, doc.save());
    CADACLYSM_TRY(loaded, Document::load(again));
    CADACLYSM_TRY(r4, loaded.revision());
    check(r4 == 1, "a loaded document starts at " + std::to_string(r4));
    (void)saved;
    return {};
}

static Result<void> document_nodes_all_or_by_id() {
    CADACLYSM_TRY(doc, plate_document());
    CADACLYSM_TRY(all, doc.nodes());
    Json nodes = json(all);
    check(nodes.size() == 2 && nodes[0]["id"].s == "r1" && nodes[1]["id"].s == "x1", "nodes(): " + all);
    check(nodes[0]["kind"].s == "profile.rect" && nodes[0]["w"].n == 10, "r1's record: " + all);
    CADACLYSM_TRY(some, doc.nodes({"x1", "r1"}));
    Json asked = json(some);
    check(asked.size() == 2 && asked[0]["id"].s == "x1" && asked[1]["id"].s == "r1", "nodes in the order asked: " + some);
    check(contains(refusal(doc.nodes({"ghost"}), "nodes of a ghost"), "ghost"), "an unknown id is not named");
    return {};
}

static Result<void> document_inputs_and_readers_direct_and_transitive() {
    CADACLYSM_TRY(doc, holed_document());
    CADACLYSM_TRY(added, doc.apply(add_op(R"J({"id": "m", "kind": "measure.mass", "solid": "cut"})J")));
    (void)added;
    check(strings(json(text_of(doc.inputs("cut"), "inputs(cut)"))) == Ids{"box", "pin"}, "inputs(cut)");
    check(strings(json(text_of(doc.inputs("m"), "inputs(m)"))) == Ids{"cut"}, "inputs(m)");
    check(strings(json(text_of(doc.inputs("m", true), "inputs(m, transitive)"))) == Ids{"box", "pin", "cut"},
          "inputs(m, transitive)");
    check(strings(json(text_of(doc.readers("box"), "readers(box)"))) == Ids{"cut"}, "readers(box)");
    check(strings(json(text_of(doc.readers("box", true), "readers(box, transitive)"))) == Ids{"cut", "m"},
          "readers(box, transitive)");
    check(json(text_of(doc.inputs("box"), "inputs(box)")).size() == 0, "inputs(box) is not empty");
    check(json(text_of(doc.readers("m"), "readers(m)")).size() == 0, "readers(m) is not empty");
    check(contains(refusal(doc.inputs("ghost"), "inputs of a ghost"), "ghost"), "an unknown id is not named");
    return {};
}

static Result<void> document_probe_reads_through_results_and_leaves_the_document() {
    CADACLYSM_TRY(doc, holed_document());
    check(faces_of(doc, "cut") == 7, "the holed cut");
    CADACLYSM_TRY(saved, doc.save());
    CADACLYSM_TRY(revision, doc.revision());
    Result<void> probed = doc.probe(set_op("pin", R"({"at": [50, 0, -15]})"), {"cut"}, [&](const std::string& statuses) {
        bool cut_ok = false;
        for (const Json& row : json(statuses).items) {
            if (row["id"].s == "cut") cut_ok = row["state"].s == "ok";
        }
        check(cut_ok, "the probe's cut is not ok: " + statuses);
        check(faces_of(doc, "cut") == 6, "the probe's cut: the pin moved clear");
        check(contains(refusal(doc.apply(R"({"op": "remove", "id": "cut"})"), "an apply inside a probe"), "a probe is open"),
              "an apply inside a probe was not refused for it");
    });
    check(probed.ok(), "probe: " + (probed.ok() ? std::string() : probed.error().message));
    check(faces_of(doc, "cut") == 7, "the document's cut again");
    CADACLYSM_TRY(after, doc.save());
    CADACLYSM_TRY(revision_after, doc.revision());
    check(after == saved && revision_after == revision, "the probe changed the document");
    // A body's own Error ends the probe and is passed on.
    Result<int> failed = doc.probe(set_op("pin", R"({"r": 1})"), {"cut"},
                                   [](const std::string&) -> Result<int> { return cadaclysm::Error{"dropped", cadaclysm::Origin::kernel}; });
    check(!failed.ok() && failed.error().message == "dropped", "the body's error was not passed on");
    CADACLYSM_TRY(set, doc.apply(set_op("pin", R"({"r": 1})")));  // not refused: no probe is open
    (void)set;
    Result<void> ghost = doc.probe(set_op("pin", R"({"r": 2})"), {"ghost"}, [](const std::string&) {});
    check(contains(refusal(ghost, "a probe of a ghost"), "no node `ghost`"), "a probe of a ghost: " + refusal(ghost, ""));
    return {};
}

static Result<void> document_result_beziers_of_a_curve_node() {
    CADACLYSM_TRY(doc, Document::make("mm"));
    CADACLYSM_TRY(a, doc.apply(add_op(R"J({"id": "l", "kind": "curve.line", "x0": 0, "y0": 0, "x1": 10, "y1": 5})J")));
    CADACLYSM_TRY(b, doc.apply(add_op(R"J({"id": "s", "kind": "solid.cuboid", "x": 1, "y": 1, "z": 1})J")));
    (void)a;
    (void)b;
    CADACLYSM_TRY(flat, doc.result_beziers("l"));
    check(flat.size() == 16, "a line is one Bezier: " + std::to_string(flat.size()) + " numbers");
    if (flat.size() == 16) {
        check(flat[0] == 0 && flat[1] == 0 && flat[2] == 0 && flat[3] == 1, "the line's start");
        check(flat[12] == 10 && flat[13] == 5 && flat[14] == 0 && flat[15] == 1, "the line's end");
    }
    const std::array<double, 12> up{0, 0, 10, 1, 0, 0, 0, 1, 0, 0, 0, 1};
    CADACLYSM_TRY(lifted, doc.result_beziers("l", bs::FrameLike(up)));
    check(lifted.size() == 16 && lifted[0] == 0 && lifted[1] == 0 && lifted[2] == 10 && lifted[3] == 1, "the lifted start");
    check(lifted.size() == 16 && lifted[12] == 10 && lifted[13] == 5 && lifted[14] == 10 && lifted[15] == 1, "the lifted end");
    check(contains(refusal(doc.result_beziers("s"), "a solid's Beziers"), "is a solid"), "a solid's Beziers not refused for it");
    return {};
}

static Result<void> document_meta_is_per_app_undone_and_saved() {
    CADACLYSM_TRY(doc, plate_document());
    CADACLYSM_TRY(none, doc.meta("forge"));
    check(!none, "meta before any was set: " + none.value_or(""));
    CADACLYSM_TRY(changed, doc.apply(R"({"op": "meta", "app": "forge", "value": {"grid": 5}})"));
    check(strings(json(changed)["meta"]) == Ids{"forge"}, "the changed set's meta: " + changed);
    CADACLYSM_TRY(forge, doc.meta("forge"));
    check(forge && json(*forge)["grid"].n == 5 && json(*forge).size() == 1, "meta(forge): " + forge.value_or("nullopt"));
    CADACLYSM_TRY(other, doc.meta("other"));
    check(!other, "another app's meta");
    CADACLYSM_TRY(saved, doc.save());
    CADACLYSM_TRY(loaded, Document::load(saved));
    CADACLYSM_TRY(kept, loaded.meta("forge"));
    check(kept && json(*kept)["grid"].n == 5, "meta did not survive a save and load");
    CADACLYSM_TRY(undone, doc.undo());
    (void)undone;
    CADACLYSM_TRY(gone, doc.meta("forge"));
    check(!gone, "an undo left the meta");
    return {};
}

static const char* const ARC_PIECES = R"([
    {"kind": "line", "x0": 0, "y0": 0, "x1": 10, "y1": 0},
    {"kind": "arc", "x0": 10, "y0": 0, "xm": 15, "ym": 5, "x1": 10, "y1": 10},
    {"kind": "line", "x0": 10, "y0": 10, "x1": 0, "y1": 10}
])";

static Result<void> profile_from_pieces_round_trips_its_pieces() {
    CADACLYSM_TRY(closed, Profile::from_pieces(ARC_PIECES, true));
    CADACLYSM_TRY(text, closed.pieces_json());
    Json back = json(text);
    check(back.size() == 4, "three pieces and the closing side: " + text);
    std::vector<bool> arcs;
    for (const Json& q : back.items) arcs.push_back(q.has("xm"));
    check(arcs == std::vector<bool>{false, true, false, false}, "the arc is not second: " + text);
    CADACLYSM_TRY(again, Profile::from_pieces(text));
    CADACLYSM_TRY(round, again.pieces_json());
    check(json(round).size() == 4, "read back: " + round);
    check(contains(refusal(Profile::from_pieces(R"([{"kind": "nope"}])"), "an unknown piece"), "0"),
          "an unknown piece is not named by index");
    return {};
}

static Result<void> profile_bounds_are_the_curves_own_extremes() {
    CADACLYSM_TRY(circle, Profile::circle(5));
    CADACLYSM_TRY(box, circle.bounds());
    check(near(box[0], -5, 1e-12) && near(box[1], -5, 1e-12) && near(box[2], 5, 1e-12) && near(box[3], 5, 1e-12),
          "the circle's bounds");
    CADACLYSM_TRY(rect, Profile::rect(4, 2));
    CADACLYSM_TRY(rbox, rect.bounds());
    check(near(rbox[0], -2, 1e-12) && near(rbox[1], -1, 1e-12) && near(rbox[2], 2, 1e-12) && near(rbox[3], 1, 1e-12),
          "the rectangle's bounds");
    return {};
}

static std::vector<double> ends(const std::string& text) {
    std::vector<double> out;
    for (const Json& q : json(text).items) {
        for (const char* key : {"x0", "y0", "x1", "y1"}) out.push_back(std::round(q[key].n * 1e9) / 1e9);
    }
    return out;
}

static Result<void> profile_reversed_twice_is_the_profile() {
    CADACLYSM_TRY(open, Profile::from_pieces(R"([{"kind": "line", "x0": 0, "y0": 0, "x1": 10, "y1": 0},
                                                 {"kind": "line", "x0": 10, "y0": 0, "x1": 10, "y1": 5}])"));
    CADACLYSM_TRY(turned, open.reversed());
    CADACLYSM_TRY(text, turned.pieces_json());
    Json first = json(text)[0];
    check(near(first["x0"].n, 10) && near(first["y0"].n, 5), "the reversed profile starts at " + text);
    CADACLYSM_TRY(twice, turned.reversed());
    CADACLYSM_TRY(a, twice.pieces_json());
    CADACLYSM_TRY(b, open.pieces_json());
    check(ends(a) == ends(b), "reversed twice is not the profile: " + a + " vs " + b);
    return {};
}

static Result<void> profile_fillet_corner_cuts_back_to_the_tangent_points() {
    CADACLYSM_TRY(a, Profile::from_pieces(R"([{"kind": "line", "x0": 0, "y0": 0, "x1": 10, "y1": 0}])"));
    CADACLYSM_TRY(b, Profile::from_pieces(R"([{"kind": "line", "x0": 10, "y0": 0, "x1": 10, "y1": 10}])"));
    CADACLYSM_TRY(text, Profile::fillet_corner(a, b, 2));
    Json got = json(text);
    check(got.keys == std::vector<std::string>{"a", "b", "arc"}, "the fillet's keys: " + text);
    const Json& cut_a = got["a"];
    check(cut_a.size() > 0 && near(cut_a[cut_a.size() - 1]["x1"].n, 8), "a's last x1: " + text);
    check(near(got["b"][0]["y0"].n, 2), "b's first y0: " + text);
    const Json& arc = got["arc"];
    check(near(arc["x0"].n, 8) && near(arc["y0"].n, 0) && near(arc["x1"].n, 10) && near(arc["y1"].n, 2), "the arc's ends: " + text);
    check(!refusal(Profile::fillet_corner(a, b, 50), "a radius that does not fit").empty(), "radius 50 refused with no reason");
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
        {"document_revision_moves_with_the_state_only", document_revision_moves_with_the_state_only},
        {"document_nodes_all_or_by_id", document_nodes_all_or_by_id},
        {"document_inputs_and_readers_direct_and_transitive", document_inputs_and_readers_direct_and_transitive},
        {"document_probe_reads_through_results_and_leaves_the_document",
         document_probe_reads_through_results_and_leaves_the_document},
        {"document_result_beziers_of_a_curve_node", document_result_beziers_of_a_curve_node},
        {"document_meta_is_per_app_undone_and_saved", document_meta_is_per_app_undone_and_saved},
        {"profile_from_pieces_round_trips_its_pieces", profile_from_pieces_round_trips_its_pieces},
        {"profile_bounds_are_the_curves_own_extremes", profile_bounds_are_the_curves_own_extremes},
        {"profile_reversed_twice_is_the_profile", profile_reversed_twice_is_the_profile},
        {"profile_fillet_corner_cuts_back_to_the_tangent_points", profile_fillet_corner_cuts_back_to_the_tangent_points},
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
    std::printf("forge_kernel: ok\n");
    return 0;
}
