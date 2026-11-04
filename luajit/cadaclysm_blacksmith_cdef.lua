-- Generated from crates/cadaclysm-blacksmith-capi/include/cadaclysm_blacksmith.h by gen_cdef.py. Do not edit; rerun the script.
return [[
static const uint32_t CADACLYSM_BLACKSMITH_NONE = 0xffffffff;

static const uint32_t CADACLYSM_BLACKSMITH_OUTSIDE = 0;

static const uint32_t CADACLYSM_BLACKSMITH_INSIDE = 1;

static const uint32_t CADACLYSM_BLACKSMITH_ON = 2;

static const uint32_t CADACLYSM_BLACKSMITH_INTERPOLATE_NEAREST = 0;

static const uint32_t CADACLYSM_BLACKSMITH_INTERPOLATE_LINEAR = 1;

static const uint32_t CADACLYSM_BLACKSMITH_INTERPOLATE_COSINE = 2;

static const uint32_t CADACLYSM_BLACKSMITH_INTERPOLATE_CUBIC = 3;

static const uint32_t CADACLYSM_BLACKSMITH_INTERPOLATE_CATMULL_ROM = 4;

static const uint32_t CADACLYSM_BLACKSMITH_SVG_TRANSPARENT = 0xffffffff;

static const uint32_t CADACLYSM_BLACKSMITH_SVG_EDGES = 1;

static const uint32_t CADACLYSM_BLACKSMITH_SVG_CURVES = 2;

static const uint32_t CADACLYSM_BLACKSMITH_SVG_ISOCURVES = 4;

static const uint32_t CADACLYSM_BLACKSMITH_SVG_POLYLINES = 8;

static const uint32_t CADACLYSM_BLACKSMITH_SVG_SILHOUETTES = 16;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_ENTITY_POINT = 0;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_ENTITY_LINE = 1;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_ENTITY_CIRCLE = 2;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_ENTITY_ARC = 3;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_ENTITY_FREE_CURVE = 4;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_COINCIDENT = 0;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_POINT_ON_LINE = 1;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_POINT_ON_CIRCLE = 2;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_HORIZONTAL = 3;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_VERTICAL = 4;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_PARALLEL = 5;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_PERPENDICULAR = 6;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_COLLINEAR = 7;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_TANGENT = 8;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_TANGENT_AT_END = 9;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_CONCENTRIC = 10;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_EQUAL_LENGTH = 11;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_EQUAL_RADIUS = 12;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_MIDPOINT = 13;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_SYMMETRIC = 14;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_FIX = 15;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_DISTANCE = 16;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_POINT_LINE_DISTANCE = 17;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_LINE_DISTANCE = 18;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_CIRCLE_LINE_DISTANCE = 19;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_CIRCLE_DISTANCE = 20;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_HORIZONTAL_DISTANCE = 21;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_VERTICAL_DISTANCE = 22;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_LENGTH = 23;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_ANGLE = 24;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_RADIUS = 25;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_DIAMETER = 26;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_SENSE_AUTO = 0;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_SENSE_POSITIVE = 1;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_SENSE_NEGATIVE = 2;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_END_START = 0;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_END_END = 1;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_STATUS_CONVERGED = 0;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_STATUS_CONFLICTING = 1;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_STATUS_DIVERGED = 2;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_STATE_UNDER = 0;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_STATE_FULL = 1;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_STATE_OVER = 2;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_DOF_REDUNDANT = 0;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_DOF_CONFLICTING = 1;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_DOF_FREE_ENTITIES = 2;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_PART_CONSTRAINTS = 0;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_PART_REDUNDANT = 1;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_PART_CONFLICTING = 2;

static const uint32_t CADACLYSM_BLACKSMITH_SKETCH_PART_FREE_ENTITIES = 3;

static const uint32_t CADACLYSM_BLACKSMITH_NURBS_PROCEDURAL = 0;

static const uint32_t CADACLYSM_BLACKSMITH_NURBS_ANALYTIC = 1;

static const uint32_t CADACLYSM_BLACKSMITH_NURBS_ALL = 2;

static const uint32_t CADACLYSM_BLACKSMITH_VALUE_LINE = 0;

static const uint32_t CADACLYSM_BLACKSMITH_VALUE_CIRCLE = 1;

static const uint32_t CADACLYSM_BLACKSMITH_VALUE_ARC = 2;

static const uint32_t CADACLYSM_BLACKSMITH_VALUE_ELLIPSE = 3;

static const uint32_t CADACLYSM_BLACKSMITH_VALUE_SPHERE = 4;

static const uint32_t CADACLYSM_BLACKSMITH_VALUE_CYLINDER = 5;

static const uint32_t CADACLYSM_BLACKSMITH_VALUE_CONE = 6;

static const uint32_t CADACLYSM_BLACKSMITH_VALUE_TORUS = 7;

static const uint32_t CADACLYSM_BLACKSMITH_VALUE_CUBOID = 8;

typedef struct CadaclysmBlacksmithAssembly CadaclysmBlacksmithAssembly;

typedef struct CadaclysmBlacksmithClashes CadaclysmBlacksmithClashes;

typedef struct CadaclysmBlacksmithClassifier CadaclysmBlacksmithClassifier;

typedef struct CadaclysmBlacksmithCollider CadaclysmBlacksmithCollider;

typedef struct CadaclysmBlacksmithCollisions CadaclysmBlacksmithCollisions;

typedef struct CadaclysmBlacksmithDocument CadaclysmBlacksmithDocument;

typedef struct CadaclysmBlacksmithFemMesh CadaclysmBlacksmithFemMesh;

typedef struct CadaclysmBlacksmithHeal CadaclysmBlacksmithHeal;

typedef struct CadaclysmBlacksmithHealth CadaclysmBlacksmithHealth;

typedef struct CadaclysmBlacksmithHits CadaclysmBlacksmithHits;

typedef struct CadaclysmBlacksmithInterpolator CadaclysmBlacksmithInterpolator;

typedef struct CadaclysmBlacksmithIntersection CadaclysmBlacksmithIntersection;

typedef struct CadaclysmBlacksmithJob CadaclysmBlacksmithJob;

typedef struct CadaclysmBlacksmithMeshThicknesses CadaclysmBlacksmithMeshThicknesses;

typedef struct CadaclysmBlacksmithNurbsCurve CadaclysmBlacksmithNurbsCurve;

typedef struct CadaclysmBlacksmithOperations CadaclysmBlacksmithOperations;

typedef struct CadaclysmBlacksmithPath CadaclysmBlacksmithPath;

typedef struct CadaclysmBlacksmithProfile CadaclysmBlacksmithProfile;

typedef struct CadaclysmBlacksmithProfileList CadaclysmBlacksmithProfileList;

typedef struct CadaclysmBlacksmithPrograms CadaclysmBlacksmithPrograms;

typedef struct CadaclysmBlacksmithRTree CadaclysmBlacksmithRTree;

typedef struct CadaclysmBlacksmithRTreeHits CadaclysmBlacksmithRTreeHits;

typedef struct CadaclysmBlacksmithRTreePairs CadaclysmBlacksmithRTreePairs;

typedef struct CadaclysmBlacksmithRegions CadaclysmBlacksmithRegions;

typedef struct CadaclysmBlacksmithReport CadaclysmBlacksmithReport;

typedef struct CadaclysmBlacksmithSamples CadaclysmBlacksmithSamples;

typedef struct CadaclysmBlacksmithSketch CadaclysmBlacksmithSketch;

typedef struct CadaclysmBlacksmithSolid CadaclysmBlacksmithSolid;

typedef struct CadaclysmBlacksmithStock CadaclysmBlacksmithStock;

typedef struct CadaclysmBlacksmithSubd CadaclysmBlacksmithSubd;

typedef struct CadaclysmBlacksmithSweepPath CadaclysmBlacksmithSweepPath;

typedef struct CadaclysmBlacksmithSweptClashes CadaclysmBlacksmithSweptClashes;

typedef struct CadaclysmBlacksmithTessellation CadaclysmBlacksmithTessellation;

typedef struct CadaclysmBlacksmithThicknessGauge CadaclysmBlacksmithThicknessGauge;

typedef struct CadaclysmBlacksmithThicknesses CadaclysmBlacksmithThicknesses;

typedef struct CadaclysmBlacksmithTool CadaclysmBlacksmithTool;

typedef struct CadaclysmBlacksmithAt {
  double point[3];
  double tangent[3];
  double parameter;
  uint32_t segment;
  double error;
  int32_t from_polyline;
} CadaclysmBlacksmithAt;

typedef struct CadaclysmBlacksmithClash {
  uint32_t a;
  uint32_t b;
  const char *kind;
  double distance;
  double on_a[3];
  double on_b[3];
  const char *kind_a;
  uint32_t index_a;
  uint32_t edge_a;
  const char *kind_b;
  uint32_t index_b;
  uint32_t edge_b;
  int32_t refined;
  double depth;
  const char *text;
} CadaclysmBlacksmithClash;

typedef struct CadaclysmBlacksmithSweptClash {
  uint32_t a;
  uint32_t b;
  double first_time;
  uint32_t interval_count;
} CadaclysmBlacksmithSweptClash;

typedef struct CadaclysmBlacksmithBox {
  double lo[3];
  double hi[3];
} CadaclysmBlacksmithBox;

typedef struct CadaclysmBlacksmithColliderStats {
  uint32_t considered;
  uint32_t world_boxes;
  uint32_t oriented_boxes;
  uint32_t skipped_share;
  uint32_t cached;
  uint32_t closed_form;
  uint32_t meshed;
  uint32_t refused;
  uint32_t confirmed;
} CadaclysmBlacksmithColliderStats;

typedef struct CadaclysmBlacksmithCollisionHit {
  uint32_t a;
  uint32_t b;
  bool overlap;
  double depth;
  const double *positions;
  const double *normals;
  const uint32_t *indices;
  uint32_t vertex_count;
  uint32_t index_count;
  const char *text;
} CadaclysmBlacksmithCollisionHit;

typedef struct CadaclysmBlacksmithFemOptions {

  size_t size;

  double tolerance;

  double max_size;
} CadaclysmBlacksmithFemOptions;

typedef void (*CadaclysmBlacksmithProgress)(const char *phase, size_t done, size_t total, void *user);

typedef struct CadaclysmBlacksmithFemMeshView {

  const double *nodes;
  uint32_t node_count;

  const uint32_t *triangles;
  uint32_t triangle_count;

  const uint32_t *triangle_face;

  const uint32_t *node_kind;

  const uint32_t *node_entity;

  uint32_t face_count;

  uint32_t edge_count;

  uint32_t vertex_count;

  uint32_t open_edge_count;

  uint32_t folded_edge_count;

  bool watertight;

  bool from_mesh;

  double min_angle;

  uint32_t worst_triangle;

  double longest_edge;
} CadaclysmBlacksmithFemMeshView;

typedef struct CadaclysmBlacksmithFemEdge {

  uint32_t id;

  const uint32_t *nodes;
  uint32_t node_count;

  const uint32_t *runs;
  uint32_t run_count;

  uint32_t face_a;

  uint32_t face_b;

  uint32_t end_a;

  uint32_t end_b;

  bool closed;

  bool seam;
} CadaclysmBlacksmithFemEdge;

typedef struct CadaclysmBlacksmithFemVertex {

  uint32_t node;

  double point[3];

  bool has_position;
} CadaclysmBlacksmithFemVertex;

typedef struct CadaclysmBlacksmithPoint {
  double x;
  double y;
  double z;
} CadaclysmBlacksmithPoint;

typedef struct CadaclysmBlacksmithSpot {
  uint32_t loop_index;
  uint32_t segment;
  double t;
  uint32_t face;
  double u;
  double v;
} CadaclysmBlacksmithSpot;

typedef struct CadaclysmBlacksmithHit {
  bool run;
  bool touch;
  struct CadaclysmBlacksmithPoint start;
  struct CadaclysmBlacksmithPoint end;
  struct CadaclysmBlacksmithSpot a_start;
  struct CadaclysmBlacksmithSpot a_end;
  struct CadaclysmBlacksmithSpot b_start;
  struct CadaclysmBlacksmithSpot b_end;
} CadaclysmBlacksmithHit;

typedef struct CadaclysmBlacksmithChain {
  const double *points;
  uint32_t point_count;
  uint32_t face_a;
  uint32_t face_b;
  bool closed;
  bool tangent;
  bool has_curve;
} CadaclysmBlacksmithChain;

typedef struct CadaclysmBlacksmithCurve {

  const char *kind;
  struct CadaclysmBlacksmithPoint origin;
  struct CadaclysmBlacksmithPoint x;
  struct CadaclysmBlacksmithPoint y;
  struct CadaclysmBlacksmithPoint z;
  double radius;
  double radius2;
  double t0;
  double t1;
  uint32_t degree;

  const double *knots;
  uint32_t knot_count;

  const double *poles;
  uint32_t pole_count;

  const double *weights;
} CadaclysmBlacksmithCurve;

typedef struct CadaclysmBlacksmithOverlap {
  uint32_t face_a;
  uint32_t face_b;
  const double *points;
  const uint32_t *loop_offsets;
  uint32_t point_count;
  uint32_t loop_count;
} CadaclysmBlacksmithOverlap;

typedef struct CadaclysmBlacksmithMassProperties {
  int32_t closed;
  int32_t inverted;
  int32_t accuracy_met;
  int32_t from_mesh;
  double area;
  double area_error;
  double volume;
  double volume_error;
  double centroid[3];
  double centroid_error;
  double inertia[9];
  double inertia_error;
  double principal_moments[3];
  double principal_axes[9];
} CadaclysmBlacksmithMassProperties;

typedef struct CadaclysmBlacksmithOrientedBox {
  double centre[3];
  double axes[9];
  double half[3];
} CadaclysmBlacksmithOrientedBox;

typedef struct CadaclysmBlacksmithLength {
  double length;
  double error;
  int32_t accuracy_met;
  int32_t from_polyline;
} CadaclysmBlacksmithLength;

typedef struct CadaclysmBlacksmithClosest {
  double distance;
  double on_a[3];
  double on_b[3];
  const char *kind_a;
  uint32_t index_a;
  uint32_t edge_a;
  const char *kind_b;
  uint32_t index_b;
  uint32_t edge_b;
  int32_t refined;
} CadaclysmBlacksmithClosest;

typedef struct CadaclysmBlacksmithRegion {
  int32_t finite;
  double min[3];
  double max[3];
  uint32_t sides;
  uint32_t shells;
} CadaclysmBlacksmithRegion;

typedef struct CadaclysmBlacksmithFaceSide {
  uint32_t face;
  int32_t sense;
} CadaclysmBlacksmithFaceSide;

typedef struct CadaclysmBlacksmithCurvature {
  double kappa;
  double tangent[3];
  double normal[3];
  double binormal[3];
  double centre[3];
  int32_t has_centre;
} CadaclysmBlacksmithCurvature;

typedef struct CadaclysmBlacksmithContinuity {
  double gap;
  double gap_at[3];
  double angle;
  double angle_at[3];
  double curvature;
  double curvature_at[3];
  uint32_t samples;
} CadaclysmBlacksmithContinuity;

typedef struct CadaclysmBlacksmithJoinReport {
  uint32_t sewn;
  uint32_t naked_before;
  uint32_t naked_after;
  uint32_t refused;
  uint32_t turned;
  double worst_gap;
  int32_t closed;
} CadaclysmBlacksmithJoinReport;

typedef struct CadaclysmBlacksmithMesh {

  const float *positions;

  const float *normals;

  const uint32_t *indices;
  uint32_t vertex_count;
  uint32_t index_count;
} CadaclysmBlacksmithMesh;

typedef struct CadaclysmBlacksmithMesh64 {
  const double *positions;
  const double *normals;
  const uint32_t *indices;
  uint32_t vertex_count;
  uint32_t index_count;
} CadaclysmBlacksmithMesh64;

typedef struct CadaclysmBlacksmithFaceTriangles {

  const uint32_t *counts;
  uint32_t face_count;
} CadaclysmBlacksmithFaceTriangles;

typedef struct CadaclysmBlacksmithPolylines {
  const float *points;

  const uint32_t *offsets;
  uint32_t point_count;
  uint32_t polyline_count;
} CadaclysmBlacksmithPolylines;

typedef struct CadaclysmBlacksmithColours {
  const double *rgb;
  uint32_t count;
} CadaclysmBlacksmithColours;

typedef struct CadaclysmBlacksmithSvgOptions {
  uint32_t size;

  uint32_t up;

  double azimuth;

  double elevation;

  double fov;

  double width;
  double height;

  double margin;

  double tolerance;

  double stroke_width;

  uint32_t stroke;

  uint32_t background;

  uint32_t flags;
} CadaclysmBlacksmithSvgOptions;

typedef struct CadaclysmBlacksmithGpuFace {
  uint32_t kind;
  uint32_t reversed;
  uint32_t transposed;
  uint32_t reserved;
  float origin[4];
  float ax[4];
  float ay[4];
  float az[4];
  float domain[4];
  float scalars[4];
  uint32_t loop_start;
  uint32_t loop_count;
  uint32_t profile_start;
  uint32_t profile_count;
  uint32_t profile2_start;
  uint32_t profile2_count;
  uint32_t nurbs_start;
  uint32_t nurbs_count;
} CadaclysmBlacksmithGpuFace;

typedef struct CadaclysmBlacksmithGpuSurfaces {
  const struct CadaclysmBlacksmithGpuFace *faces;
  uint32_t face_count;
  uint32_t surface_count;
  const uint32_t *loops;
  uint32_t loops_len;
  const float *points;
  uint32_t points_len;
  const float *profiles;
  uint32_t profiles_len;
  const float *nurbs;
  uint32_t nurbs_len;
  const uint32_t *shared;
  uint32_t shared_len;
  const uint32_t *tiles;
  uint32_t tiles_len;
  const float *tile_domains;
  uint32_t tile_domains_len;
  const float *tile_samples;
  uint32_t tile_samples_len;
  const float *tile_boxes;
  uint32_t tile_boxes_len;
  const float *edges;
  uint32_t edges_len;
  double bounds[6];
  double about[3];
} CadaclysmBlacksmithGpuSurfaces;

typedef struct CadaclysmBlacksmithEdge {

  const char *kind;

  const uint32_t *faces;
  uint32_t face_count;

  const double *segments;
  uint32_t segment_count;
} CadaclysmBlacksmithEdge;

typedef struct CadaclysmBlacksmithRTreeHit {
  uint32_t id;
  double distance;
} CadaclysmBlacksmithRTreeHit;

typedef struct CadaclysmBlacksmithRTreePair {
  uint32_t a;
  uint32_t b;
} CadaclysmBlacksmithRTreePair;

typedef struct CadaclysmBlacksmithSubdParts {
  const double *positions;
  uint32_t vertex_count;
  const uint32_t *face_sizes;
  uint32_t face_count;
  const uint32_t *face_indices;
  uint32_t index_count;
  const uint32_t *creases;
  uint32_t crease_count;
  const uint32_t *pins;
  uint32_t pin_count;
  int32_t symmetry_axis;
  double symmetry_tolerance;
  uint32_t selection_kind;
  const uint32_t *selection;
  uint32_t selection_count;
} CadaclysmBlacksmithSubdParts;

typedef struct CadaclysmBlacksmithSubdMesh {
  const double *positions;
  uint32_t vertex_count;
  const double *normals;
  const uint32_t *indices;
  uint32_t index_count;
  const uint32_t *triangle_face;
} CadaclysmBlacksmithSubdMesh;

typedef struct CadaclysmBlacksmithSubdReport {
  uint32_t regular;
  uint32_t refined;
  uint32_t steps;
  uint32_t levels;
  double deviation;
  double g1_angle_deg;
  double deviation_at[3];
  double g1_at[3];
} CadaclysmBlacksmithSubdReport;

typedef struct CadaclysmBlacksmithThicknessMesh {
  const double *positions;
  const double *normals;
  const uint32_t *indices;
  const uint32_t *faces;
  uint32_t vertex_count;
  uint32_t triangle_count;
} CadaclysmBlacksmithThicknessMesh;

typedef struct CadaclysmBlacksmithFaceThickness {
  bool found;
  double thickness;
  double min;
  double max;
  bool uniform;
} CadaclysmBlacksmithFaceThickness;

typedef struct CadaclysmBlacksmithThickness {
  uint32_t body;
  uint32_t vertex;
  uint32_t face;
  double point[3];
  double thickness;
  double opposite[3];
  uint32_t opposite_body;
  uint32_t opposite_face;
  bool knife;
  double exact_thickness;
  double exact_opposite[3];
  double sphere;
} CadaclysmBlacksmithThickness;

typedef struct CadaclysmBlacksmithMeshThickness {
  uint32_t mesh;
  uint32_t vertex;
  double thickness;
  double point[3];
  double opposite[3];
  uint32_t opposite_mesh;
  uint32_t opposite_triangle;
  bool knife;
} CadaclysmBlacksmithMeshThickness;

const char *cadaclysm_blacksmith_last_error(void);

const char *cadaclysm_blacksmith_version(void);

bool cadaclysm_blacksmith_parse_colour(const char *text, double *out);

bool cadaclysm_blacksmith_option_set(const char *name, double value);

bool cadaclysm_blacksmith_option_get(const char *name, double *out);

void cadaclysm_blacksmith_solid_free(struct CadaclysmBlacksmithSolid *solid);

void cadaclysm_blacksmith_profile_free(struct CadaclysmBlacksmithProfile *profile);

bool cadaclysm_blacksmith_edge_point_at_length(const struct CadaclysmBlacksmithSolid *solid,
                                               uint32_t edge,
                                               double s,
                                               double accuracy,
                                               struct CadaclysmBlacksmithAt *out);

struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_edge_divide_by_count(const struct CadaclysmBlacksmithSolid *solid,
                                                                             uint32_t edge,
                                                                             uint32_t n,
                                                                             double accuracy);

struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_edge_divide_by_length(const struct CadaclysmBlacksmithSolid *solid,
                                                                              uint32_t edge,
                                                                              double step,
                                                                              double accuracy);

bool cadaclysm_blacksmith_profile_point_at_length(const struct CadaclysmBlacksmithProfile *profile,
                                                  double s,
                                                  double accuracy,
                                                  struct CadaclysmBlacksmithAt *out);

struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_profile_divide_by_count(const struct CadaclysmBlacksmithProfile *profile,
                                                                                uint32_t n,
                                                                                double accuracy);

struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_profile_divide_by_length(const struct CadaclysmBlacksmithProfile *profile,
                                                                                 double step,
                                                                                 double accuracy);

uint32_t cadaclysm_blacksmith_samples_count(const struct CadaclysmBlacksmithSamples *samples);

bool cadaclysm_blacksmith_samples_at(const struct CadaclysmBlacksmithSamples *samples,
                                     uint32_t i,
                                     struct CadaclysmBlacksmithAt *out);

void cadaclysm_blacksmith_samples_free(struct CadaclysmBlacksmithSamples *samples);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_named(const struct CadaclysmBlacksmithSolid *solid,
                                                            const char *name);

const char *cadaclysm_blacksmith_solid_name(const struct CadaclysmBlacksmithSolid *solid);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_with_material(const struct CadaclysmBlacksmithSolid *solid,
                                                                    const char *material);

const char *cadaclysm_blacksmith_solid_material(const struct CadaclysmBlacksmithSolid *solid);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_styled(const struct CadaclysmBlacksmithSolid *solid,
                                                             const char *location,
                                                             const char *identification);

const char *cadaclysm_blacksmith_solid_style_location(const struct CadaclysmBlacksmithSolid *solid);

const char *cadaclysm_blacksmith_solid_style_identification(const struct CadaclysmBlacksmithSolid *solid);

struct CadaclysmBlacksmithAssembly *cadaclysm_blacksmith_assembly_new(const char *name);

void cadaclysm_blacksmith_assembly_free(struct CadaclysmBlacksmithAssembly *assembly);

const char *cadaclysm_blacksmith_assembly_name(const struct CadaclysmBlacksmithAssembly *assembly);

char *cadaclysm_blacksmith_assembly_place_solid(struct CadaclysmBlacksmithAssembly *assembly,
                                                const struct CadaclysmBlacksmithSolid *solid,
                                                const double *frame,
                                                const char *name);

char *cadaclysm_blacksmith_assembly_place_assembly(struct CadaclysmBlacksmithAssembly *assembly,
                                                   const struct CadaclysmBlacksmithAssembly *placed,
                                                   const double *frame,
                                                   const char *name);

char *cadaclysm_blacksmith_assembly_step(const struct CadaclysmBlacksmithAssembly *assembly,
                                         const char *schema,
                                         uint32_t unit);

bool cadaclysm_blacksmith_assembly_link(struct CadaclysmBlacksmithAssembly *assembly,
                                        const char *name,
                                        const char *const *placements,
                                        size_t placement_count);

bool cadaclysm_blacksmith_assembly_joint(struct CadaclysmBlacksmithAssembly *assembly,
                                         const char *name,
                                         const char *start,
                                         const char *end);

bool cadaclysm_blacksmith_assembly_pair(struct CadaclysmBlacksmithAssembly *assembly,
                                        const char *joint,
                                        const char *kind,
                                        const double *frame,
                                        const double *end_frame,
                                        const double *lower,
                                        const double *upper,
                                        const bool *has_lower,
                                        const bool *has_upper,
                                        size_t freedom_count,
                                        double pitch);

bool cadaclysm_blacksmith_assembly_pair_with(struct CadaclysmBlacksmithAssembly *assembly,
                                             const char *joint,
                                             const char *kind,
                                             const double *frame,
                                             const double *end_frame,
                                             const double *lower,
                                             const double *upper,
                                             const bool *has_lower,
                                             const bool *has_upper,
                                             size_t freedom_count,
                                             const double *params,
                                             size_t param_count);

bool cadaclysm_blacksmith_assembly_state(struct CadaclysmBlacksmithAssembly *assembly,
                                         const char *name,
                                         const char *const *joints,
                                         const uint32_t *counts,
                                         const double *values,
                                         size_t row_count);

bool cadaclysm_blacksmith_assembly_sequence(struct CadaclysmBlacksmithAssembly *assembly,
                                            const char *name,
                                            const char *const *states,
                                            const double *ts,
                                            const char *const *interpolations,
                                            size_t count,
                                            bool seconds);

bool cadaclysm_blacksmith_assembly_base(struct CadaclysmBlacksmithAssembly *assembly,
                                        const char *link);

struct CadaclysmBlacksmithAssembly *cadaclysm_blacksmith_assembly_posed(const struct CadaclysmBlacksmithAssembly *assembly,
                                                                        const char *const *joints,
                                                                        const uint32_t *counts,
                                                                        const double *values,
                                                                        size_t row_count,
                                                                        const char *state,
                                                                        const char *ground);

uint32_t cadaclysm_blacksmith_assembly_part_count(const struct CadaclysmBlacksmithAssembly *assembly);

char *cadaclysm_blacksmith_assembly_part_path(const struct CadaclysmBlacksmithAssembly *assembly,
                                              uint32_t i);

struct CadaclysmBlacksmithSweptClashes *cadaclysm_blacksmith_assembly_swept_clash(const struct CadaclysmBlacksmithAssembly *assembly,
                                                                                  const char *const *joints,
                                                                                  const uint32_t *counts,
                                                                                  size_t joint_count,
                                                                                  const double *values,
                                                                                  uint32_t key_count,
                                                                                  const char *ground,
                                                                                  double tolerance,
                                                                                  double clearance,
                                                                                  double resolution,
                                                                                  uint32_t max_steps,
                                                                                  const uint32_t *allowed,
                                                                                  uint32_t allowed_count,
                                                                                  bool joined);

uint32_t cadaclysm_blacksmith_pair_freedom_count(const char *kind);

struct CadaclysmBlacksmithTool *cadaclysm_blacksmith_tool_flat(uint32_t number,
                                                               double diameter,
                                                               double flute_length,
                                                               double feed,
                                                               double plunge,
                                                               double rpm);

struct CadaclysmBlacksmithTool *cadaclysm_blacksmith_tool_ball(uint32_t number,
                                                               double diameter,
                                                               double flute_length,
                                                               double feed,
                                                               double plunge,
                                                               double rpm);

struct CadaclysmBlacksmithTool *cadaclysm_blacksmith_tool_drill(uint32_t number,
                                                                double diameter,
                                                                double flute_length,
                                                                double feed,
                                                                double rpm);

struct CadaclysmBlacksmithTool *cadaclysm_blacksmith_tool_with_ramp_angle(const struct CadaclysmBlacksmithTool *t,
                                                                          double degrees);

void cadaclysm_blacksmith_tool_free(struct CadaclysmBlacksmithTool *t);

uint32_t cadaclysm_blacksmith_tool_number(const struct CadaclysmBlacksmithTool *t);

const char *cadaclysm_blacksmith_tool_shape(const struct CadaclysmBlacksmithTool *t);

double cadaclysm_blacksmith_tool_diameter(const struct CadaclysmBlacksmithTool *t);

double cadaclysm_blacksmith_tool_flute_length(const struct CadaclysmBlacksmithTool *t);

double cadaclysm_blacksmith_tool_angle(const struct CadaclysmBlacksmithTool *t);

double cadaclysm_blacksmith_tool_corner_radius(const struct CadaclysmBlacksmithTool *t);

bool cadaclysm_blacksmith_job_stock(const struct CadaclysmBlacksmithJob *j,
                                    double *min,
                                    double *max);

struct CadaclysmBlacksmithStock *cadaclysm_blacksmith_stock_box(double min_x,
                                                                double min_y,
                                                                double min_z,
                                                                double max_x,
                                                                double max_y,
                                                                double max_z);

struct CadaclysmBlacksmithStock *cadaclysm_blacksmith_stock_around(const struct CadaclysmBlacksmithSolid *s,
                                                                   double margin);

void cadaclysm_blacksmith_stock_free(struct CadaclysmBlacksmithStock *s);

struct CadaclysmBlacksmithJob *cadaclysm_blacksmith_job_new(const struct CadaclysmBlacksmithStock *stock,
                                                            double safe_z);

bool cadaclysm_blacksmith_job_set_clearance(struct CadaclysmBlacksmithJob *j, double clearance);

bool cadaclysm_blacksmith_job_set_tolerance(struct CadaclysmBlacksmithJob *j, double tolerance);

bool cadaclysm_blacksmith_job_set_spindle_dwell(struct CadaclysmBlacksmithJob *j, double seconds);

bool cadaclysm_blacksmith_job_set_name(struct CadaclysmBlacksmithJob *j, const char *name);

bool cadaclysm_blacksmith_job_set_resolution(struct CadaclysmBlacksmithJob *j, double resolution);

bool cadaclysm_blacksmith_job_face(struct CadaclysmBlacksmithJob *j,
                                   const struct CadaclysmBlacksmithTool *t,
                                   double z,
                                   double stepover,
                                   double stepdown);

bool cadaclysm_blacksmith_job_contour(struct CadaclysmBlacksmithJob *j,
                                      const struct CadaclysmBlacksmithTool *t,
                                      const struct CadaclysmBlacksmithProfile *p,
                                      double top,
                                      double bottom,
                                      uint32_t side,
                                      double stepdown,
                                      bool climb,
                                      bool open);

bool cadaclysm_blacksmith_job_pocket(struct CadaclysmBlacksmithJob *j,
                                     const struct CadaclysmBlacksmithTool *t,
                                     const struct CadaclysmBlacksmithProfile *p,
                                     double top,
                                     double bottom,
                                     double stepover,
                                     double stepdown);

bool cadaclysm_blacksmith_job_drill(struct CadaclysmBlacksmithJob *j,
                                    const struct CadaclysmBlacksmithTool *t,
                                    const double *xy,
                                    size_t count,
                                    double top,
                                    double bottom,
                                    double peck);

struct CadaclysmBlacksmithPrograms *cadaclysm_blacksmith_job_gcode(const struct CadaclysmBlacksmithJob *j);

struct CadaclysmBlacksmithPrograms *cadaclysm_blacksmith_job_camotics(const struct CadaclysmBlacksmithJob *j,
                                                                      const char *stem);

void cadaclysm_blacksmith_job_free(struct CadaclysmBlacksmithJob *j);

uint32_t cadaclysm_blacksmith_programs_count(const struct CadaclysmBlacksmithPrograms *l);

uint32_t cadaclysm_blacksmith_programs_tool(const struct CadaclysmBlacksmithPrograms *l,
                                            uint32_t i);

const char *cadaclysm_blacksmith_programs_name(const struct CadaclysmBlacksmithPrograms *l,
                                               uint32_t i);

const char *cadaclysm_blacksmith_programs_text(const struct CadaclysmBlacksmithPrograms *l,
                                               uint32_t i);

void cadaclysm_blacksmith_programs_free(struct CadaclysmBlacksmithPrograms *l);

struct CadaclysmBlacksmithReport *cadaclysm_blacksmith_job_machine(struct CadaclysmBlacksmithJob *j,
                                                                   const struct CadaclysmBlacksmithSolid *part,
                                                                   const struct CadaclysmBlacksmithTool *end_mill,
                                                                   const struct CadaclysmBlacksmithTool *const *drills,
                                                                   size_t drill_count,
                                                                   double stepover,
                                                                   double stepdown,
                                                                   double skin,
                                                                   double peck);

struct CadaclysmBlacksmithReport *cadaclysm_blacksmith_job_machine_with(struct CadaclysmBlacksmithJob *j,
                                                                        const struct CadaclysmBlacksmithSolid *part,
                                                                        const struct CadaclysmBlacksmithTool *const *end_mills,
                                                                        size_t end_mill_count,
                                                                        const struct CadaclysmBlacksmithTool *const *drills,
                                                                        size_t drill_count,
                                                                        double stepover,
                                                                        double stepdown,
                                                                        double skin,
                                                                        double peck);

uint32_t cadaclysm_blacksmith_report_count(const struct CadaclysmBlacksmithReport *r);

const char *cadaclysm_blacksmith_report_kind(const struct CadaclysmBlacksmithReport *r, uint32_t i);

bool cadaclysm_blacksmith_report_at(const struct CadaclysmBlacksmithReport *r,
                                    uint32_t i,
                                    double *out);

double cadaclysm_blacksmith_report_size(const struct CadaclysmBlacksmithReport *r, uint32_t i);

double cadaclysm_blacksmith_report_top(const struct CadaclysmBlacksmithReport *r, uint32_t i);

double cadaclysm_blacksmith_report_bottom(const struct CadaclysmBlacksmithReport *r, uint32_t i);

const char *cadaclysm_blacksmith_report_reason(const struct CadaclysmBlacksmithReport *r,
                                               uint32_t i);

struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_report_region(const struct CadaclysmBlacksmithReport *r,
                                                                          uint32_t i);

const char *cadaclysm_blacksmith_report_text(const struct CadaclysmBlacksmithReport *r);

void cadaclysm_blacksmith_report_free(struct CadaclysmBlacksmithReport *r);

struct CadaclysmBlacksmithOperations *cadaclysm_blacksmith_job_operations(const struct CadaclysmBlacksmithJob *j);

uint32_t cadaclysm_blacksmith_operations_count(const struct CadaclysmBlacksmithOperations *l);

const char *cadaclysm_blacksmith_operations_kind(const struct CadaclysmBlacksmithOperations *l,
                                                 uint32_t i);

uint32_t cadaclysm_blacksmith_operations_tool(const struct CadaclysmBlacksmithOperations *l,
                                              uint32_t i);

uint32_t cadaclysm_blacksmith_operations_param_count(const struct CadaclysmBlacksmithOperations *l,
                                                     uint32_t i);

const char *cadaclysm_blacksmith_operations_param_name(const struct CadaclysmBlacksmithOperations *l,
                                                       uint32_t i,
                                                       uint32_t k);

double cadaclysm_blacksmith_operations_param_value(const struct CadaclysmBlacksmithOperations *l,
                                                   uint32_t i,
                                                   uint32_t k);

void cadaclysm_blacksmith_operations_free(struct CadaclysmBlacksmithOperations *l);

struct CadaclysmBlacksmithClashes *cadaclysm_blacksmith_collider_clash(struct CadaclysmBlacksmithCollider *collider,
                                                                       const double *frames,
                                                                       uint32_t frame_count,
                                                                       double clearance,
                                                                       uint32_t share_k,
                                                                       uint32_t share_n);

struct CadaclysmBlacksmithClashes *cadaclysm_blacksmith_clash(const struct CadaclysmBlacksmithSolid *const *a,
                                                              uint32_t a_count,
                                                              const struct CadaclysmBlacksmithSolid *const *b,
                                                              uint32_t b_count,
                                                              double tolerance,
                                                              double clearance,
                                                              const uint32_t *allowed,
                                                              uint32_t allowed_count);

void cadaclysm_blacksmith_clashes_free(struct CadaclysmBlacksmithClashes *clashes);

uint32_t cadaclysm_blacksmith_clashes_count(const struct CadaclysmBlacksmithClashes *clashes);

bool cadaclysm_blacksmith_clashes_at(const struct CadaclysmBlacksmithClashes *clashes,
                                     uint32_t i,
                                     struct CadaclysmBlacksmithClash *out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_clashes_solid(const struct CadaclysmBlacksmithClashes *clashes,
                                                                    uint32_t i);

struct CadaclysmBlacksmithIntersection *cadaclysm_blacksmith_clashes_intersect(const struct CadaclysmBlacksmithClashes *clashes,
                                                                               uint32_t i);

struct CadaclysmBlacksmithSweptClashes *cadaclysm_blacksmith_collider_swept_clash(struct CadaclysmBlacksmithCollider *collider,
                                                                                  const double *poses,
                                                                                  uint32_t pose_count,
                                                                                  uint32_t frame_count,
                                                                                  double clearance,
                                                                                  double resolution,
                                                                                  uint32_t max_steps,
                                                                                  uint32_t share_k,
                                                                                  uint32_t share_n);

struct CadaclysmBlacksmithSweptClashes *cadaclysm_blacksmith_swept_clash(const struct CadaclysmBlacksmithSolid *const *a,
                                                                         uint32_t a_count,
                                                                         const double *poses_a,
                                                                         const struct CadaclysmBlacksmithSolid *const *b,
                                                                         uint32_t b_count,
                                                                         const double *poses_b,
                                                                         uint32_t pose_count,
                                                                         double tolerance,
                                                                         double clearance,
                                                                         double resolution,
                                                                         uint32_t max_steps,
                                                                         const uint32_t *allowed,
                                                                         uint32_t allowed_count);

void cadaclysm_blacksmith_swept_clashes_free(struct CadaclysmBlacksmithSweptClashes *swept);

uint32_t cadaclysm_blacksmith_swept_clashes_count(const struct CadaclysmBlacksmithSweptClashes *swept);

bool cadaclysm_blacksmith_swept_clashes_at(const struct CadaclysmBlacksmithSweptClashes *swept,
                                           uint32_t i,
                                           struct CadaclysmBlacksmithSweptClash *out);

bool cadaclysm_blacksmith_swept_clashes_interval(const struct CadaclysmBlacksmithSweptClashes *swept,
                                                 uint32_t i,
                                                 uint32_t k,
                                                 double *out);

struct CadaclysmBlacksmithClashes *cadaclysm_blacksmith_swept_clashes_firsts(const struct CadaclysmBlacksmithSweptClashes *swept);

struct CadaclysmBlacksmithClassifier *cadaclysm_blacksmith_classifier_new(const struct CadaclysmBlacksmithSolid *solid,
                                                                          double tolerance);

bool cadaclysm_blacksmith_classifier_contains(const struct CadaclysmBlacksmithClassifier *classifier,
                                              const double *point,
                                              uint32_t *out);

void cadaclysm_blacksmith_classifier_free(struct CadaclysmBlacksmithClassifier *classifier);

bool cadaclysm_blacksmith_contains(const struct CadaclysmBlacksmithSolid *solid,
                                   const double *point,
                                   double tolerance,
                                   uint32_t *out);

bool cadaclysm_blacksmith_solid_bounds_box(const struct CadaclysmBlacksmithSolid *solid,
                                           double tolerance,
                                           struct CadaclysmBlacksmithBox *out);

bool cadaclysm_blacksmith_box_moved(const struct CadaclysmBlacksmithBox *box_,
                                    const double *frame,
                                    struct CadaclysmBlacksmithBox *out);

bool cadaclysm_blacksmith_box_overlaps(const struct CadaclysmBlacksmithBox *a,
                                       const struct CadaclysmBlacksmithBox *b);

bool cadaclysm_blacksmith_boxes_apart(const struct CadaclysmBlacksmithBox *a,
                                      const double *frame_a,
                                      const struct CadaclysmBlacksmithBox *b,
                                      const double *frame_b,
                                      bool *apart);

struct CadaclysmBlacksmithCollider *cadaclysm_blacksmith_collider_new(const struct CadaclysmBlacksmithSolid *const *solids,
                                                                      uint32_t count,
                                                                      double tolerance,
                                                                      const uint32_t *groups,
                                                                      const uint32_t *allowed,
                                                                      uint32_t allowed_count);

void cadaclysm_blacksmith_collider_free(struct CadaclysmBlacksmithCollider *collider);

uint32_t cadaclysm_blacksmith_collider_group_count(const struct CadaclysmBlacksmithCollider *collider);

bool cadaclysm_blacksmith_collider_stats(const struct CadaclysmBlacksmithCollider *collider,
                                         struct CadaclysmBlacksmithColliderStats *out);

struct CadaclysmBlacksmithCollisions *cadaclysm_blacksmith_collider_check(struct CadaclysmBlacksmithCollider *collider,
                                                                          const double *frames,
                                                                          uint32_t frame_count,
                                                                          uint32_t share_k,
                                                                          uint32_t share_n);

void cadaclysm_blacksmith_collisions_free(struct CadaclysmBlacksmithCollisions *collisions);

uint32_t cadaclysm_blacksmith_collisions_count(const struct CadaclysmBlacksmithCollisions *collisions);

bool cadaclysm_blacksmith_collisions_hit(const struct CadaclysmBlacksmithCollisions *collisions,
                                         uint32_t i,
                                         struct CadaclysmBlacksmithCollisionHit *out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_collisions_solid(const struct CadaclysmBlacksmithCollisions *collisions,
                                                                       uint32_t i);

struct CadaclysmBlacksmithDocument *cadaclysm_blacksmith_document_new(const char *units);

struct CadaclysmBlacksmithDocument *cadaclysm_blacksmith_document_load(const char *text);

char *cadaclysm_blacksmith_document_save(const struct CadaclysmBlacksmithDocument *doc);

char *cadaclysm_blacksmith_document_apply(struct CadaclysmBlacksmithDocument *doc,
                                          const char *op,
                                          const char *message);

char *cadaclysm_blacksmith_document_preview(struct CadaclysmBlacksmithDocument *doc,
                                            const char *op);

bool cadaclysm_blacksmith_document_preview_begin(struct CadaclysmBlacksmithDocument *doc);

char *cadaclysm_blacksmith_document_end_preview(struct CadaclysmBlacksmithDocument *doc);

bool cadaclysm_blacksmith_document_batch_begin(struct CadaclysmBlacksmithDocument *doc,
                                               const char *message);

char *cadaclysm_blacksmith_document_batch_end(struct CadaclysmBlacksmithDocument *doc);

char *cadaclysm_blacksmith_document_batch_abort(struct CadaclysmBlacksmithDocument *doc);

char *cadaclysm_blacksmith_document_undo(struct CadaclysmBlacksmithDocument *doc);

char *cadaclysm_blacksmith_document_redo(struct CadaclysmBlacksmithDocument *doc);

char *cadaclysm_blacksmith_document_params(const struct CadaclysmBlacksmithDocument *doc);

char *cadaclysm_blacksmith_document_evaluate(struct CadaclysmBlacksmithDocument *doc,
                                             bool cheap_only);

char *cadaclysm_blacksmith_document_result_kind(const struct CadaclysmBlacksmithDocument *doc,
                                                const char *id);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_document_result_solid(const struct CadaclysmBlacksmithDocument *doc,
                                                                            const char *id);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_document_result_profile(const struct CadaclysmBlacksmithDocument *doc,
                                                                                const char *id);

uint32_t cadaclysm_blacksmith_document_result_profile_count(const struct CadaclysmBlacksmithDocument *doc,
                                                            const char *id);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_document_result_profile_at(const struct CadaclysmBlacksmithDocument *doc,
                                                                                   const char *id,
                                                                                   uint32_t i);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_document_result_nurbs_curve(const struct CadaclysmBlacksmithDocument *doc,
                                                                                       const char *id);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_document_result_subd(const struct CadaclysmBlacksmithDocument *doc,
                                                                          const char *id);

char *cadaclysm_blacksmith_document_value(const struct CadaclysmBlacksmithDocument *doc,
                                          const char *id);

char *cadaclysm_blacksmith_document_errors(const struct CadaclysmBlacksmithDocument *doc);

char *cadaclysm_blacksmith_document_kinds(void);

char *cadaclysm_blacksmith_document_solid_body(const struct CadaclysmBlacksmithSolid *solid);

char *cadaclysm_blacksmith_document_profile_path(const struct CadaclysmBlacksmithProfile *profile);

char *cadaclysm_blacksmith_document_branch_new(struct CadaclysmBlacksmithDocument *doc,
                                               const char *name,
                                               const char *at);

char *cadaclysm_blacksmith_document_branch_switch(struct CadaclysmBlacksmithDocument *doc,
                                                  const char *name_or_commit_id);

char *cadaclysm_blacksmith_document_tips(const struct CadaclysmBlacksmithDocument *doc);

bool cadaclysm_blacksmith_document_branch_rename(struct CadaclysmBlacksmithDocument *doc,
                                                 const char *old,
                                                 const char *new_);

bool cadaclysm_blacksmith_document_branch_delete(struct CadaclysmBlacksmithDocument *doc,
                                                 const char *name);

char *cadaclysm_blacksmith_document_branch_list(const struct CadaclysmBlacksmithDocument *doc);

char *cadaclysm_blacksmith_document_log(const struct CadaclysmBlacksmithDocument *doc,
                                        const char *branch);

void cadaclysm_blacksmith_document_free(struct CadaclysmBlacksmithDocument *doc);

struct CadaclysmBlacksmithDocument *cadaclysm_bim_document_new(const char *units);

struct CadaclysmBlacksmithDocument *cadaclysm_bim_document_load(const char *text);

char *cadaclysm_bim_kinds(void);

char *cadaclysm_bim_document_export_ifc(struct CadaclysmBlacksmithDocument *doc,
                                        const char *options_json);

bool cadaclysm_parts_catalog_load(const char *dir);

struct CadaclysmBlacksmithDocument *cadaclysm_parts_document_new(void);

struct CadaclysmBlacksmithDocument *cadaclysm_parts_document_load(const char *text);

char *cadaclysm_parts_kinds(void);

void cadaclysm_blacksmith_fem_options_init(struct CadaclysmBlacksmithFemOptions *options);

struct CadaclysmBlacksmithFemMesh *cadaclysm_blacksmith_fem_mesh(const struct CadaclysmBlacksmithSolid *solid,
                                                                 const double *placement,
                                                                 const struct CadaclysmBlacksmithFemOptions *options,
                                                                 CadaclysmBlacksmithProgress progress,
                                                                 void *user);

void cadaclysm_blacksmith_fem_mesh_free(struct CadaclysmBlacksmithFemMesh *m);

bool cadaclysm_blacksmith_fem_mesh_view(const struct CadaclysmBlacksmithFemMesh *m,
                                        struct CadaclysmBlacksmithFemMeshView *out);

bool cadaclysm_blacksmith_fem_mesh_edge(const struct CadaclysmBlacksmithFemMesh *m,
                                        uint32_t i,
                                        struct CadaclysmBlacksmithFemEdge *out);

bool cadaclysm_blacksmith_fem_mesh_vertex(const struct CadaclysmBlacksmithFemMesh *m,
                                          uint32_t i,
                                          struct CadaclysmBlacksmithFemVertex *out);

bool cadaclysm_blacksmith_fem_mesh_open_edge(const struct CadaclysmBlacksmithFemMesh *m,
                                             uint32_t i,
                                             uint32_t *a,
                                             uint32_t *b,
                                             uint32_t *brep_edge);

bool cadaclysm_blacksmith_fem_mesh_folded_edge(const struct CadaclysmBlacksmithFemMesh *m,
                                               uint32_t i,
                                               uint32_t *a,
                                               uint32_t *b,
                                               uint32_t *brep_edge);

uint32_t cadaclysm_blacksmith_fem_mesh_crossing_count(const struct CadaclysmBlacksmithFemMesh *m);

bool cadaclysm_blacksmith_fem_mesh_crossing(const struct CadaclysmBlacksmithFemMesh *m,
                                            uint32_t i,
                                            uint32_t *a,
                                            uint32_t *b);

char *cadaclysm_blacksmith_fem_mesh_msh_text(const struct CadaclysmBlacksmithFemMesh *m);

bool cadaclysm_blacksmith_fem_mesh_save_msh(const struct CadaclysmBlacksmithFemMesh *m,
                                            const char *path);

struct CadaclysmBlacksmithHeal *cadaclysm_blacksmith_healed(const struct CadaclysmBlacksmithSolid *solid,
                                                            double tolerance,
                                                            uint32_t flags);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_heal_body(const struct CadaclysmBlacksmithHeal *h);

void cadaclysm_blacksmith_heal_free(struct CadaclysmBlacksmithHeal *h);

bool cadaclysm_blacksmith_heal_summary(const struct CadaclysmBlacksmithHeal *h,
                                       uint32_t *counts,
                                       double *sizes);

uint32_t cadaclysm_blacksmith_heal_fixes(const struct CadaclysmBlacksmithHeal *h,
                                         uint32_t *items,
                                         double *sizes);

uint32_t cadaclysm_blacksmith_heal_refused(const struct CadaclysmBlacksmithHeal *h,
                                           uint32_t *items,
                                           double *sizes);

double cadaclysm_blacksmith_edge_tolerance(const struct CadaclysmBlacksmithSolid *solid,
                                           uint32_t edge);

struct CadaclysmBlacksmithHealth *cadaclysm_blacksmith_health(const struct CadaclysmBlacksmithSolid *solid,
                                                              double tolerance,
                                                              bool mesh);

void cadaclysm_blacksmith_health_free(struct CadaclysmBlacksmithHealth *health);

bool cadaclysm_blacksmith_health_summary(const struct CadaclysmBlacksmithHealth *health,
                                         uint32_t *counts,
                                         double *sizes);

uint32_t cadaclysm_blacksmith_health_free_edges(const struct CadaclysmBlacksmithHealth *health,
                                                uint32_t *ids,
                                                double *sizes);

uint32_t cadaclysm_blacksmith_health_wires(const struct CadaclysmBlacksmithHealth *health,
                                           uint32_t *runs,
                                           double *sizes);

uint32_t cadaclysm_blacksmith_health_small(const struct CadaclysmBlacksmithHealth *health,
                                           uint32_t *items,
                                           double *sizes);

uint32_t cadaclysm_blacksmith_health_crack_edges(const struct CadaclysmBlacksmithHealth *health,
                                                 uint32_t *ids);

struct CadaclysmBlacksmithHits *cadaclysm_blacksmith_profile_hits(const struct CadaclysmBlacksmithProfile *a,
                                                                  const struct CadaclysmBlacksmithProfile *b,
                                                                  double tolerance);

void cadaclysm_blacksmith_hits_free(struct CadaclysmBlacksmithHits *hits);

uint32_t cadaclysm_blacksmith_hit_count(const struct CadaclysmBlacksmithHits *hits);

bool cadaclysm_blacksmith_hit(const struct CadaclysmBlacksmithHits *hits,
                              uint32_t i,
                              struct CadaclysmBlacksmithHit *out);

struct CadaclysmBlacksmithHits *cadaclysm_blacksmith_solid_profile_hits(const struct CadaclysmBlacksmithSolid *solid,
                                                                        const struct CadaclysmBlacksmithProfile *profile,
                                                                        const double *frame,
                                                                        double tolerance,
                                                                        CadaclysmBlacksmithProgress progress,
                                                                        void *user);

uint32_t cadaclysm_blacksmith_hits_piece_count(const struct CadaclysmBlacksmithHits *hits);

bool cadaclysm_blacksmith_hits_piece(const struct CadaclysmBlacksmithHits *hits,
                                     uint32_t i,
                                     bool *inside,
                                     struct CadaclysmBlacksmithSpot *start,
                                     struct CadaclysmBlacksmithSpot *end);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_hits_piece_profile(const struct CadaclysmBlacksmithHits *hits,
                                                                           uint32_t i);

const char *cadaclysm_blacksmith_brep_layout_id(void);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_from_brep(const void *brep,
                                                                const char *layout_id);

struct CadaclysmBlacksmithInterpolator *cadaclysm_blacksmith_interpolator_new(const double *samples,
                                                                              uint32_t count,
                                                                              uint32_t dimension,
                                                                              bool cyclic);

uint32_t cadaclysm_blacksmith_interpolator_count(const struct CadaclysmBlacksmithInterpolator *interpolator);

uint32_t cadaclysm_blacksmith_interpolator_dimension(const struct CadaclysmBlacksmithInterpolator *interpolator);

bool cadaclysm_blacksmith_interpolator_cyclic(const struct CadaclysmBlacksmithInterpolator *interpolator);

bool cadaclysm_blacksmith_interpolator_at(const struct CadaclysmBlacksmithInterpolator *interpolator,
                                          double t,
                                          uint32_t mode,
                                          double *out,
                                          uint32_t out_len);

bool cadaclysm_blacksmith_interpolator_sample(const struct CadaclysmBlacksmithInterpolator *interpolator,
                                              const double *ts,
                                              uint32_t n,
                                              uint32_t mode,
                                              double *out,
                                              uint32_t out_len);

void cadaclysm_blacksmith_interpolator_free(struct CadaclysmBlacksmithInterpolator *interpolator);

struct CadaclysmBlacksmithIntersection *cadaclysm_blacksmith_intersect(const struct CadaclysmBlacksmithSolid *a,
                                                                       const struct CadaclysmBlacksmithSolid *b,
                                                                       double tolerance,
                                                                       CadaclysmBlacksmithProgress progress,
                                                                       void *user);

void cadaclysm_blacksmith_intersection_free(struct CadaclysmBlacksmithIntersection *intersection);

uint32_t cadaclysm_blacksmith_intersection_chain_count(const struct CadaclysmBlacksmithIntersection *intersection);

bool cadaclysm_blacksmith_intersection_chain(const struct CadaclysmBlacksmithIntersection *intersection,
                                             uint32_t i,
                                             struct CadaclysmBlacksmithChain *out);

bool cadaclysm_blacksmith_intersection_curve(const struct CadaclysmBlacksmithIntersection *intersection,
                                             uint32_t i,
                                             struct CadaclysmBlacksmithCurve *out);

uint32_t cadaclysm_blacksmith_intersection_overlap_count(const struct CadaclysmBlacksmithIntersection *intersection);

bool cadaclysm_blacksmith_intersection_overlap(const struct CadaclysmBlacksmithIntersection *intersection,
                                               uint32_t i,
                                               struct CadaclysmBlacksmithOverlap *out);

bool cadaclysm_blacksmith_mass_properties(const struct CadaclysmBlacksmithSolid *solid,
                                          double accuracy,
                                          struct CadaclysmBlacksmithMassProperties *out);

bool cadaclysm_blacksmith_oriented_box(const struct CadaclysmBlacksmithSolid *solid,
                                       double accuracy,
                                       struct CadaclysmBlacksmithOrientedBox *out);

bool cadaclysm_blacksmith_edge_length(const struct CadaclysmBlacksmithSolid *solid,
                                      uint32_t edge,
                                      double accuracy,
                                      struct CadaclysmBlacksmithLength *out);

bool cadaclysm_blacksmith_profile_length(const struct CadaclysmBlacksmithProfile *profile,
                                         double accuracy,
                                         struct CadaclysmBlacksmithLength *out);

bool cadaclysm_blacksmith_closest(const struct CadaclysmBlacksmithSolid *a,
                                  const struct CadaclysmBlacksmithSolid *b,
                                  double tolerance,
                                  CadaclysmBlacksmithProgress progress,
                                  void *user,
                                  struct CadaclysmBlacksmithClosest *out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_merge(const struct CadaclysmBlacksmithSolid *a,
                                                            const struct CadaclysmBlacksmithSolid *b,
                                                            double tolerance,
                                                            CadaclysmBlacksmithProgress progress,
                                                            void *user);

struct CadaclysmBlacksmithRegions *cadaclysm_blacksmith_regions(const struct CadaclysmBlacksmithSolid *solid);

uint32_t cadaclysm_blacksmith_regions_count(const struct CadaclysmBlacksmithRegions *regions);

bool cadaclysm_blacksmith_regions_at(const struct CadaclysmBlacksmithRegions *regions,
                                     uint32_t i,
                                     struct CadaclysmBlacksmithRegion *out);

bool cadaclysm_blacksmith_regions_side_at(const struct CadaclysmBlacksmithRegions *regions,
                                          uint32_t i,
                                          uint32_t k,
                                          struct CadaclysmBlacksmithFaceSide *out);

void cadaclysm_blacksmith_regions_free(struct CadaclysmBlacksmithRegions *regions);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_region_solid(const struct CadaclysmBlacksmithSolid *solid,
                                                                   uint32_t region);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_new(const double *xyz,
                                                                           size_t count,
                                                                           const double *weights,
                                                                           uint32_t degree,
                                                                           const double *knots,
                                                                           size_t knot_count);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_through(const double *xyz,
                                                                               size_t count,
                                                                               uint32_t degree,
                                                                               bool closed,
                                                                               const double *start,
                                                                               const double *end);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_fit(const double *xyz,
                                                                           size_t count,
                                                                           uint32_t degree,
                                                                           double tolerance,
                                                                           double *error_out);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_from_edge(const struct CadaclysmBlacksmithSolid *solid,
                                                                                 uint32_t edge);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_from_face_isocurve(const struct CadaclysmBlacksmithSolid *solid,
                                                                                          uint32_t face,
                                                                                          bool along_u,
                                                                                          double at);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_blend(const struct CadaclysmBlacksmithNurbsCurve *a,
                                                                             bool a_end,
                                                                             const struct CadaclysmBlacksmithNurbsCurve *b,
                                                                             bool b_end,
                                                                             uint32_t continuity,
                                                                             double bulge);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_projected_to_plane(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                          const double *origin,
                                                                                          const double *normal,
                                                                                          const double *direction);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_projected_to_face(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                         const struct CadaclysmBlacksmithSolid *solid,
                                                                                         uint32_t face,
                                                                                         const double *direction,
                                                                                         double tolerance,
                                                                                         double *error_out);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_pulled_to_face(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                      const struct CadaclysmBlacksmithSolid *solid,
                                                                                      uint32_t face,
                                                                                      double tolerance,
                                                                                      double *error_out);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_reversed(const struct CadaclysmBlacksmithNurbsCurve *curve);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_trimmed(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                               double t0,
                                                                               double t1);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_extended(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                bool at_start,
                                                                                double length);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_elevated(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                uint32_t by);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_transformed(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                   const double *matrix);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_clone(const struct CadaclysmBlacksmithNurbsCurve *curve);

void cadaclysm_blacksmith_nurbs_curve_free(struct CadaclysmBlacksmithNurbsCurve *curve);

uint32_t cadaclysm_blacksmith_nurbs_curve_degree(const struct CadaclysmBlacksmithNurbsCurve *curve);

uint32_t cadaclysm_blacksmith_nurbs_curve_control_count(const struct CadaclysmBlacksmithNurbsCurve *curve);

uint32_t cadaclysm_blacksmith_nurbs_curve_knot_count(const struct CadaclysmBlacksmithNurbsCurve *curve);

bool cadaclysm_blacksmith_nurbs_curve_control_points(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                     double *xyz);

bool cadaclysm_blacksmith_nurbs_curve_weights(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                              double *w);

bool cadaclysm_blacksmith_nurbs_curve_knots(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                            double *k);

bool cadaclysm_blacksmith_nurbs_curve_is_rational(const struct CadaclysmBlacksmithNurbsCurve *curve);

bool cadaclysm_blacksmith_nurbs_curve_is_closed(const struct CadaclysmBlacksmithNurbsCurve *curve);

bool cadaclysm_blacksmith_nurbs_curve_domain(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                             double *out);

bool cadaclysm_blacksmith_nurbs_curve_point(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                            double t,
                                            double *out);

bool cadaclysm_blacksmith_nurbs_curve_derivatives(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                  double t,
                                                  uint32_t order,
                                                  double *out);

bool cadaclysm_blacksmith_nurbs_curve_curvature(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                double t,
                                                struct CadaclysmBlacksmithCurvature *out);

bool cadaclysm_blacksmith_nurbs_curve_length(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                             double accuracy,
                                             struct CadaclysmBlacksmithLength *out);

bool cadaclysm_blacksmith_nurbs_curve_point_at_length(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                      double s,
                                                      double accuracy,
                                                      struct CadaclysmBlacksmithAt *out);

struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_divide_by_count(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                    uint32_t n,
                                                                                    double accuracy);

struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_divide_by_length(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                     double step,
                                                                                     double accuracy);

struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_plane_hits(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                               const double *origin,
                                                                               const double *normal);

struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_face_hits(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                              const struct CadaclysmBlacksmithSolid *solid,
                                                                              uint32_t face,
                                                                              double tolerance);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft_curves(const struct CadaclysmBlacksmithNurbsCurve *const *sections,
                                                                  size_t count,
                                                                  uint32_t degree,
                                                                  bool loose,
                                                                  bool closed);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep_rail(const struct CadaclysmBlacksmithNurbsCurve *rail,
                                                                 const struct CadaclysmBlacksmithNurbsCurve *const *sections,
                                                                 size_t count,
                                                                 uint32_t frame,
                                                                 const double *up,
                                                                 double tolerance,
                                                                 double *error_out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep_two_rails(const struct CadaclysmBlacksmithNurbsCurve *rail_a,
                                                                      const struct CadaclysmBlacksmithNurbsCurve *rail_b,
                                                                      const struct CadaclysmBlacksmithNurbsCurve *const *sections,
                                                                      size_t count,
                                                                      double tolerance,
                                                                      double *error_out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_edge_surface(const struct CadaclysmBlacksmithNurbsCurve *const *curves,
                                                                   size_t count,
                                                                   double tolerance,
                                                                   double *error_out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_network_surface(const struct CadaclysmBlacksmithNurbsCurve *const *u_curves,
                                                                      size_t u_count,
                                                                      const struct CadaclysmBlacksmithNurbsCurve *const *v_curves,
                                                                      size_t v_count,
                                                                      double tolerance,
                                                                      double *error_out);

bool cadaclysm_blacksmith_continuity(const struct CadaclysmBlacksmithSolid *a,
                                     uint32_t face_a,
                                     uint32_t side_a,
                                     const struct CadaclysmBlacksmithSolid *b,
                                     uint32_t face_b,
                                     uint32_t side_b,
                                     uint32_t samples,
                                     struct CadaclysmBlacksmithContinuity *out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_match_side(const struct CadaclysmBlacksmithSolid *a,
                                                                 uint32_t face_a,
                                                                 uint32_t side_a,
                                                                 const struct CadaclysmBlacksmithSolid *b,
                                                                 uint32_t face_b,
                                                                 uint32_t side_b,
                                                                 uint32_t level);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_blend_sides(const struct CadaclysmBlacksmithSolid *a,
                                                                  uint32_t face_a,
                                                                  uint32_t side_a,
                                                                  const struct CadaclysmBlacksmithSolid *b,
                                                                  uint32_t face_b,
                                                                  uint32_t side_b,
                                                                  uint32_t level,
                                                                  double bulge);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet_surfaces(const struct CadaclysmBlacksmithSolid *a,
                                                                      uint32_t face_a,
                                                                      const struct CadaclysmBlacksmithSolid *b,
                                                                      uint32_t face_b,
                                                                      double radius_start,
                                                                      double radius_end,
                                                                      bool flip_a,
                                                                      bool flip_b,
                                                                      double tolerance,
                                                                      struct CadaclysmBlacksmithNurbsCurve **rail_a,
                                                                      struct CadaclysmBlacksmithNurbsCurve **rail_b,
                                                                      double *error_out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_by_curve(const struct CadaclysmBlacksmithSolid *sheet,
                                                                     const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                     const double *direction,
                                                                     double tolerance);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_trim_by_curve(const struct CadaclysmBlacksmithSolid *sheet,
                                                                    const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                    const double *direction,
                                                                    bool keep_inside,
                                                                    double tolerance);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_join_sheets(const struct CadaclysmBlacksmithSolid *const *sheets,
                                                                  size_t count,
                                                                  double tolerance,
                                                                  struct CadaclysmBlacksmithJoinReport *report);

bool cadaclysm_blacksmith_license_set(const char *text_or_path);

const char *cadaclysm_blacksmith_license_info(void);

uint64_t cadaclysm_blacksmith_license_notice_count(void);

const char *cadaclysm_blacksmith_build_date(void);

struct CadaclysmBlacksmithMesh cadaclysm_blacksmith_mesh(const struct CadaclysmBlacksmithSolid *solid,
                                                         double tolerance);

struct CadaclysmBlacksmithMesh64 cadaclysm_blacksmith_mesh64(const struct CadaclysmBlacksmithSolid *solid,
                                                             double tolerance);

struct CadaclysmBlacksmithFaceTriangles cadaclysm_blacksmith_mesh_face_triangles(const struct CadaclysmBlacksmithSolid *solid,
                                                                                 double tolerance);

struct CadaclysmBlacksmithPolylines cadaclysm_blacksmith_edge_polylines(const struct CadaclysmBlacksmithSolid *solid,
                                                                        double tolerance);

struct CadaclysmBlacksmithTessellation *cadaclysm_blacksmith_tessellation(const struct CadaclysmBlacksmithSolid *solid,
                                                                          double tolerance);

void cadaclysm_blacksmith_tessellation_free(struct CadaclysmBlacksmithTessellation *tessellation);

struct CadaclysmBlacksmithMesh cadaclysm_blacksmith_tessellation_mesh(const struct CadaclysmBlacksmithTessellation *tessellation);

struct CadaclysmBlacksmithMesh64 cadaclysm_blacksmith_tessellation_mesh64(const struct CadaclysmBlacksmithTessellation *tessellation);

struct CadaclysmBlacksmithFaceTriangles cadaclysm_blacksmith_tessellation_face_triangles(const struct CadaclysmBlacksmithTessellation *tessellation);

struct CadaclysmBlacksmithPolylines cadaclysm_blacksmith_tessellation_edge_polylines(const struct CadaclysmBlacksmithTessellation *tessellation);

struct CadaclysmBlacksmithColours cadaclysm_blacksmith_edge_polyline_colours(const struct CadaclysmBlacksmithSolid *solid,
                                                                             double tolerance);

struct CadaclysmBlacksmithPolylines cadaclysm_blacksmith_profile_polylines(const struct CadaclysmBlacksmithProfile *profile,
                                                                           double tolerance);

bool cadaclysm_blacksmith_bounds(const struct CadaclysmBlacksmithSolid *solid,
                                 double tolerance,
                                 double *min,
                                 double *max);

bool cadaclysm_blacksmith_bounds64(const struct CadaclysmBlacksmithSolid *solid,
                                   double tolerance,
                                   double *min,
                                   double *max);

bool cadaclysm_blacksmith_box(const struct CadaclysmBlacksmithSolid *solid,
                              double *min,
                              double *max);

char *cadaclysm_blacksmith_step(const struct CadaclysmBlacksmithSolid *const *solids,
                                size_t count,
                                const char *schema,
                                uint32_t unit);

char *cadaclysm_blacksmith_step_assembly(const struct CadaclysmBlacksmithSolid *const *solids,
                                         const char *const *names,
                                         size_t part_count,
                                         const uint32_t *parts_of,
                                         const double *frames,
                                         size_t placement_count,
                                         const char *schema,
                                         uint32_t unit);

char *cadaclysm_blacksmith_sat_text(const struct CadaclysmBlacksmithSolid *const *solids,
                                    size_t count,
                                    uint32_t unit);

bool cadaclysm_blacksmith_sat(const struct CadaclysmBlacksmithSolid *const *solids,
                              size_t count,
                              const char *path,
                              uint32_t unit);

char *cadaclysm_blacksmith_brep_text(const struct CadaclysmBlacksmithSolid *const *solids,
                                     size_t count);

void cadaclysm_blacksmith_svg_options_init(struct CadaclysmBlacksmithSvgOptions *options);

char *cadaclysm_blacksmith_svg_text(const struct CadaclysmBlacksmithSolid *const *solids,
                                    size_t count,
                                    const struct CadaclysmBlacksmithSvgOptions *options);

bool cadaclysm_blacksmith_brep(const struct CadaclysmBlacksmithSolid *const *solids,
                               size_t count,
                               const char *path);

bool cadaclysm_blacksmith_svg(const struct CadaclysmBlacksmithSolid *const *solids,
                              size_t count,
                              const char *path,
                              const struct CadaclysmBlacksmithSvgOptions *options);

char *cadaclysm_blacksmith_drawing_svg_text(const struct CadaclysmBlacksmithSolid *const *solids,
                                            size_t solid_count,
                                            const struct CadaclysmBlacksmithProfile *const *profiles,
                                            size_t profile_count,
                                            const struct CadaclysmBlacksmithSvgOptions *options);

bool cadaclysm_blacksmith_drawing_svg(const struct CadaclysmBlacksmithSolid *const *solids,
                                      size_t solid_count,
                                      const struct CadaclysmBlacksmithProfile *const *profiles,
                                      size_t profile_count,
                                      const char *path,
                                      const struct CadaclysmBlacksmithSvgOptions *options);

double *cadaclysm_blacksmith_silhouette_beziers(const struct CadaclysmBlacksmithSolid *solid,
                                                const struct CadaclysmBlacksmithSvgOptions *options,
                                                uint32_t *count);

void cadaclysm_blacksmith_silhouette_beziers_free(double *data, uint32_t count);

struct CadaclysmBlacksmithGpuSurfaces *cadaclysm_blacksmith_gpu_surfaces(const struct CadaclysmBlacksmithSolid *solid,
                                                                         double tolerance);

void cadaclysm_blacksmith_gpu_surfaces_free(struct CadaclysmBlacksmithGpuSurfaces *surfaces);

void cadaclysm_blacksmith_string_free(char *s);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_rect(double w, double h);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_circle(double r);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_slot(double cx,
                                                                     double cy,
                                                                     double length,
                                                                     double r);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_polygon(const double *xy,
                                                                        size_t count);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_regular_polygon(double cx,
                                                                                double cy,
                                                                                double radius,
                                                                                uint32_t sides,
                                                                                double angle);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_circumscribed_polygon(double cx,
                                                                                      double cy,
                                                                                      double radius,
                                                                                      uint32_t sides,
                                                                                      double angle);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_star(double cx,
                                                                     double cy,
                                                                     double outer,
                                                                     double inner,
                                                                     uint32_t points,
                                                                     double angle);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_spline(const double *xy,
                                                                       size_t count,
                                                                       uint32_t degree,
                                                                       const double *weights,
                                                                       bool closed);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_round(const struct CadaclysmBlacksmithProfile *profile,
                                                                      double radius,
                                                                      const uint32_t *corners,
                                                                      size_t count,
                                                                      bool open);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_chain(const struct CadaclysmBlacksmithProfile *const *pieces,
                                                                      size_t count,
                                                                      double tolerance);

uint32_t cadaclysm_blacksmith_profile_piece_count(const struct CadaclysmBlacksmithProfile *profile,
                                                  const struct CadaclysmBlacksmithProfile *const *cutters,
                                                  size_t count,
                                                  double tolerance);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_piece(const struct CadaclysmBlacksmithProfile *profile,
                                                                      const struct CadaclysmBlacksmithProfile *const *cutters,
                                                                      size_t count,
                                                                      uint32_t index,
                                                                      double tolerance);

uint32_t cadaclysm_blacksmith_profile_trim_count(const struct CadaclysmBlacksmithProfile *profile,
                                                 const struct CadaclysmBlacksmithProfile *const *cutters,
                                                 size_t count,
                                                 uint32_t piece,
                                                 double tolerance);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_trim_chain(const struct CadaclysmBlacksmithProfile *profile,
                                                                           const struct CadaclysmBlacksmithProfile *const *cutters,
                                                                           size_t count,
                                                                           uint32_t piece,
                                                                           uint32_t index,
                                                                           double tolerance);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_from_loops(const struct CadaclysmBlacksmithProfile *const *loops,
                                                                           size_t count);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_close_loop(const struct CadaclysmBlacksmithProfile *profile);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_coloured(const struct CadaclysmBlacksmithProfile *profile,
                                                                         double r,
                                                                         double g,
                                                                         double b);

bool cadaclysm_blacksmith_profile_colour(const struct CadaclysmBlacksmithProfile *profile,
                                         double *out);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_with_hole(const struct CadaclysmBlacksmithProfile *outer,
                                                                          const struct CadaclysmBlacksmithProfile *hole);

struct CadaclysmBlacksmithPath *cadaclysm_blacksmith_path_begin(double x, double y);

bool cadaclysm_blacksmith_path_line_to(struct CadaclysmBlacksmithPath *p, double x, double y);

bool cadaclysm_blacksmith_path_arc_to(struct CadaclysmBlacksmithPath *p,
                                      double x,
                                      double y,
                                      double cx,
                                      double cy,
                                      bool ccw);

bool cadaclysm_blacksmith_path_bezier_to(struct CadaclysmBlacksmithPath *p,
                                         double c1x,
                                         double c1y,
                                         double c2x,
                                         double c2y,
                                         double x,
                                         double y);

bool cadaclysm_blacksmith_path_conic_to(struct CadaclysmBlacksmithPath *p,
                                        double x,
                                        double y,
                                        double cx,
                                        double cy,
                                        double weight);

bool cadaclysm_blacksmith_path_parabola_by_vertex(struct CadaclysmBlacksmithPath *p,
                                                  double x,
                                                  double y,
                                                  double vx,
                                                  double vy);

bool cadaclysm_blacksmith_path_parabola_by_focus(struct CadaclysmBlacksmithPath *p,
                                                 double x,
                                                 double y,
                                                 double fx,
                                                 double fy);

struct CadaclysmBlacksmithPath *cadaclysm_blacksmith_path_parabola(double vx,
                                                                   double vy,
                                                                   double ax,
                                                                   double ay,
                                                                   double focal,
                                                                   double from,
                                                                   double to);

bool cadaclysm_blacksmith_path_nurbs_to(struct CadaclysmBlacksmithPath *p,
                                        const double *control_xy,
                                        size_t control_count,
                                        const double *weights,
                                        const double *knots,
                                        size_t knot_count,
                                        uint32_t degree);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_path_end(struct CadaclysmBlacksmithPath *p);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_path_end_open(struct CadaclysmBlacksmithPath *p);

void cadaclysm_blacksmith_path_free(struct CadaclysmBlacksmithPath *p);

struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_text(const char *text,
                                                                         double size,
                                                                         const char *font,
                                                                         const uint8_t *font_bytes,
                                                                         size_t font_len,
                                                                         const char *halign,
                                                                         const char *valign,
                                                                         double spacing,
                                                                         const char *direction);

struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_common(const struct CadaclysmBlacksmithProfile *a,
                                                                           const struct CadaclysmBlacksmithProfile *b,
                                                                           double tolerance);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_to_arcs(const struct CadaclysmBlacksmithProfile *p,
                                                                        double tolerance);

struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_offset(const struct CadaclysmBlacksmithProfile *p,
                                                                           double distance,
                                                                           double tolerance);

struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_solid_section(const struct CadaclysmBlacksmithSolid *s,
                                                                          double z,
                                                                          double tolerance);

uint32_t cadaclysm_blacksmith_profile_list_count(const struct CadaclysmBlacksmithProfileList *list);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_list_get(const struct CadaclysmBlacksmithProfileList *list,
                                                                         uint32_t i);

void cadaclysm_blacksmith_profile_list_free(struct CadaclysmBlacksmithProfileList *list);

uint32_t cadaclysm_blacksmith_face_count(const struct CadaclysmBlacksmithSolid *solid);

uint32_t cadaclysm_blacksmith_select_face(const struct CadaclysmBlacksmithSolid *solid,
                                          uint32_t kind,
                                          const double *v,
                                          uint32_t index);

bool cadaclysm_blacksmith_face_frame(const struct CadaclysmBlacksmithSolid *solid,
                                     uint32_t face,
                                     double *out);

bool cadaclysm_blacksmith_face_ref(const struct CadaclysmBlacksmithSolid *solid,
                                   uint32_t face,
                                   double *out);

int32_t cadaclysm_blacksmith_find_face(const struct CadaclysmBlacksmithSolid *solid,
                                       const double *face_ref,
                                       int32_t hint,
                                       double tolerance);

bool cadaclysm_blacksmith_colour(const struct CadaclysmBlacksmithSolid *solid,
                                 uint32_t face,
                                 double *out);

bool cadaclysm_blacksmith_edge_colour(const struct CadaclysmBlacksmithSolid *solid,
                                      uint32_t edge,
                                      double *out);

const char *cadaclysm_blacksmith_face_kind(const struct CadaclysmBlacksmithSolid *solid,
                                           uint32_t face);

uint32_t cadaclysm_blacksmith_edge_count(const struct CadaclysmBlacksmithSolid *solid);

bool cadaclysm_blacksmith_edge(const struct CadaclysmBlacksmithSolid *solid,
                               uint32_t i,
                               struct CadaclysmBlacksmithEdge *out);

bool cadaclysm_blacksmith_edge_curve(const struct CadaclysmBlacksmithSolid *solid,
                                     uint32_t i,
                                     struct CadaclysmBlacksmithCurve *out);

uint32_t cadaclysm_blacksmith_leaked_edges(const struct CadaclysmBlacksmithSolid *solid,
                                           double tolerance);

uint32_t cadaclysm_blacksmith_unpaired_edges(const struct CadaclysmBlacksmithSolid *solid,
                                             double tolerance);

bool cadaclysm_blacksmith_manifold(const struct CadaclysmBlacksmithSolid *solid, uint32_t *out);

struct CadaclysmBlacksmithRTree *cadaclysm_blacksmith_rtree_new(void);

struct CadaclysmBlacksmithRTree *cadaclysm_blacksmith_rtree_from_boxes(const uint32_t *ids,
                                                                       const double *boxes,
                                                                       uint32_t n);

struct CadaclysmBlacksmithRTree *cadaclysm_blacksmith_rtree_from_points(const double *xyz,
                                                                        uint32_t n);

struct CadaclysmBlacksmithRTree *cadaclysm_blacksmith_rtree_from_triangles(const double *xyz,
                                                                           uint32_t n_points,
                                                                           const uint32_t *indices,
                                                                           uint32_t n_triangles);

struct CadaclysmBlacksmithRTree *cadaclysm_blacksmith_solid_face_tree(const struct CadaclysmBlacksmithSolid *solid);

bool cadaclysm_blacksmith_rtree_insert(struct CadaclysmBlacksmithRTree *tree,
                                       uint32_t id,
                                       const double *box_);

bool cadaclysm_blacksmith_rtree_insert_point(struct CadaclysmBlacksmithRTree *tree,
                                             uint32_t id,
                                             const double *p);

bool cadaclysm_blacksmith_rtree_remove(struct CadaclysmBlacksmithRTree *tree,
                                       uint32_t id,
                                       const double *box_);

uint32_t cadaclysm_blacksmith_rtree_count(const struct CadaclysmBlacksmithRTree *tree);

bool cadaclysm_blacksmith_rtree_bounds(const struct CadaclysmBlacksmithRTree *tree, double *out);

void cadaclysm_blacksmith_rtree_free(struct CadaclysmBlacksmithRTree *tree);

struct CadaclysmBlacksmithRTreeHits *cadaclysm_blacksmith_rtree_search(const struct CadaclysmBlacksmithRTree *tree,
                                                                       const double *box_);

struct CadaclysmBlacksmithRTreeHits *cadaclysm_blacksmith_rtree_within(const struct CadaclysmBlacksmithRTree *tree,
                                                                       const double *p,
                                                                       double r);

struct CadaclysmBlacksmithRTreeHits *cadaclysm_blacksmith_rtree_nearest(const struct CadaclysmBlacksmithRTree *tree,
                                                                        const double *p,
                                                                        uint32_t k);

struct CadaclysmBlacksmithRTreeHits *cadaclysm_blacksmith_rtree_ray(const struct CadaclysmBlacksmithRTree *tree,
                                                                    const double *origin,
                                                                    const double *direction,
                                                                    double max_t);

uint32_t cadaclysm_blacksmith_rtree_hits_count(const struct CadaclysmBlacksmithRTreeHits *hits);

bool cadaclysm_blacksmith_rtree_hits_at(const struct CadaclysmBlacksmithRTreeHits *hits,
                                        uint32_t i,
                                        struct CadaclysmBlacksmithRTreeHit *out);

void cadaclysm_blacksmith_rtree_hits_free(struct CadaclysmBlacksmithRTreeHits *hits);

struct CadaclysmBlacksmithRTreePairs *cadaclysm_blacksmith_rtree_overlaps(const struct CadaclysmBlacksmithRTree *a,
                                                                          const struct CadaclysmBlacksmithRTree *b,
                                                                          double slack);

struct CadaclysmBlacksmithRTreePairs *cadaclysm_blacksmith_rtree_self_overlaps(const struct CadaclysmBlacksmithRTree *tree,
                                                                               double slack);

uint32_t cadaclysm_blacksmith_rtree_pairs_count(const struct CadaclysmBlacksmithRTreePairs *pairs);

bool cadaclysm_blacksmith_rtree_pairs_at(const struct CadaclysmBlacksmithRTreePairs *pairs,
                                         uint32_t i,
                                         struct CadaclysmBlacksmithRTreePair *out);

void cadaclysm_blacksmith_rtree_pairs_free(struct CadaclysmBlacksmithRTreePairs *pairs);

struct CadaclysmBlacksmithSketch *cadaclysm_blacksmith_sketch_new(void);

void cadaclysm_blacksmith_sketch_free(struct CadaclysmBlacksmithSketch *s);

struct CadaclysmBlacksmithSketch *cadaclysm_blacksmith_sketch_from_profile(const struct CadaclysmBlacksmithProfile *profile,
                                                                           bool infer,
                                                                           double tolerance);

uint32_t cadaclysm_blacksmith_sketch_add_point(struct CadaclysmBlacksmithSketch *s,
                                               double x,
                                               double y);

uint32_t cadaclysm_blacksmith_sketch_add_line(struct CadaclysmBlacksmithSketch *s,
                                              uint32_t a,
                                              uint32_t b);

uint32_t cadaclysm_blacksmith_sketch_add_circle(struct CadaclysmBlacksmithSketch *s,
                                                uint32_t centre,
                                                double r);

uint32_t cadaclysm_blacksmith_sketch_add_arc(struct CadaclysmBlacksmithSketch *s,
                                             uint32_t centre,
                                             uint32_t start,
                                             uint32_t end);

uint32_t cadaclysm_blacksmith_sketch_add_bezier(struct CadaclysmBlacksmithSketch *s,
                                                uint32_t start,
                                                double c1x,
                                                double c1y,
                                                double c2x,
                                                double c2y,
                                                double x,
                                                double y);

uint32_t cadaclysm_blacksmith_sketch_add_conic(struct CadaclysmBlacksmithSketch *s,
                                               uint32_t start,
                                               double cx,
                                               double cy,
                                               double x,
                                               double y,
                                               double weight);

uint32_t cadaclysm_blacksmith_sketch_add_nurbs(struct CadaclysmBlacksmithSketch *s,
                                               uint32_t start,
                                               uint32_t degree,
                                               const double *xy,
                                               size_t count,
                                               const double *weights,
                                               const double *knots,
                                               size_t knot_count);

const uint32_t *cadaclysm_blacksmith_sketch_add_rect(struct CadaclysmBlacksmithSketch *s,
                                                     double x0,
                                                     double y0,
                                                     double x1,
                                                     double y1,
                                                     size_t *count);

uint32_t cadaclysm_blacksmith_sketch_kind(const struct CadaclysmBlacksmithSketch *s,
                                          uint32_t id);

const uint32_t *cadaclysm_blacksmith_sketch_entities(struct CadaclysmBlacksmithSketch *s,
                                                     size_t *count);

bool cadaclysm_blacksmith_sketch_point(const struct CadaclysmBlacksmithSketch *s,
                                       uint32_t id,
                                       double *out);

bool cadaclysm_blacksmith_sketch_set_point(struct CadaclysmBlacksmithSketch *s,
                                           uint32_t id,
                                           double x,
                                           double y);

double cadaclysm_blacksmith_sketch_radius(const struct CadaclysmBlacksmithSketch *s, uint32_t id);

bool cadaclysm_blacksmith_sketch_set_radius(struct CadaclysmBlacksmithSketch *s,
                                            uint32_t id,
                                            double r);

uint32_t cadaclysm_blacksmith_sketch_centre(const struct CadaclysmBlacksmithSketch *s, uint32_t id);

const uint32_t *cadaclysm_blacksmith_sketch_ends(struct CadaclysmBlacksmithSketch *s,
                                                 uint32_t id,
                                                 size_t *count);

bool cadaclysm_blacksmith_sketch_set_construction(struct CadaclysmBlacksmithSketch *s,
                                                  uint32_t id,
                                                  bool on);

bool cadaclysm_blacksmith_sketch_is_construction(const struct CadaclysmBlacksmithSketch *s,
                                                 uint32_t id);

bool cadaclysm_blacksmith_sketch_is_reference(const struct CadaclysmBlacksmithSketch *s,
                                              uint32_t id);

const uint32_t *cadaclysm_blacksmith_sketch_remove_entity(struct CadaclysmBlacksmithSketch *s,
                                                          uint32_t id,
                                                          size_t *count);

uint32_t cadaclysm_blacksmith_sketch_reference(struct CadaclysmBlacksmithSketch *s,
                                               const struct CadaclysmBlacksmithSketch *other,
                                               uint32_t entity);

bool cadaclysm_blacksmith_sketch_update_reference(struct CadaclysmBlacksmithSketch *s,
                                                  uint32_t id,
                                                  const struct CadaclysmBlacksmithSketch *other,
                                                  double *report);

uint32_t cadaclysm_blacksmith_sketch_constrain(struct CadaclysmBlacksmithSketch *s,
                                               uint32_t kind,
                                               const uint32_t *refs,
                                               size_t ref_count,
                                               double value,
                                               bool driving,
                                               uint32_t sense,
                                               uint32_t end);

const uint32_t *cadaclysm_blacksmith_sketch_constraints(struct CadaclysmBlacksmithSketch *s,
                                                        size_t *count);

uint32_t cadaclysm_blacksmith_sketch_constraint_kind(const struct CadaclysmBlacksmithSketch *s,
                                                     uint32_t id);

const uint32_t *cadaclysm_blacksmith_sketch_constraint_refs(struct CadaclysmBlacksmithSketch *s,
                                                            uint32_t id,
                                                            size_t *count);

double cadaclysm_blacksmith_sketch_constraint_value(const struct CadaclysmBlacksmithSketch *s,
                                                    uint32_t id);

bool cadaclysm_blacksmith_sketch_constraint_driving(const struct CadaclysmBlacksmithSketch *s,
                                                    uint32_t id);

uint32_t cadaclysm_blacksmith_sketch_constraint_sense(const struct CadaclysmBlacksmithSketch *s,
                                                      uint32_t id);

uint32_t cadaclysm_blacksmith_sketch_constraint_end(const struct CadaclysmBlacksmithSketch *s,
                                                    uint32_t id);

bool cadaclysm_blacksmith_sketch_is_joint_tangent(const struct CadaclysmBlacksmithSketch *s,
                                                  uint32_t id);

bool cadaclysm_blacksmith_sketch_remove(struct CadaclysmBlacksmithSketch *s, uint32_t id);

bool cadaclysm_blacksmith_sketch_set_value(struct CadaclysmBlacksmithSketch *s,
                                           uint32_t id,
                                           double value,
                                           double *report);

bool cadaclysm_blacksmith_sketch_set_driving(struct CadaclysmBlacksmithSketch *s,
                                             uint32_t id,
                                             bool driving,
                                             double *report);

double cadaclysm_blacksmith_sketch_measure(const struct CadaclysmBlacksmithSketch *s, uint32_t id);

bool cadaclysm_blacksmith_sketch_solve(struct CadaclysmBlacksmithSketch *s, double *report);

bool cadaclysm_blacksmith_sketch_drag(struct CadaclysmBlacksmithSketch *s,
                                      const uint32_t *points,
                                      const double *xy,
                                      size_t count,
                                      double *report);

const uint32_t *cadaclysm_blacksmith_sketch_report_ids(const struct CadaclysmBlacksmithSketch *s,
                                                       size_t *count);

bool cadaclysm_blacksmith_sketch_diagnose(struct CadaclysmBlacksmithSketch *s, double *out);

const uint32_t *cadaclysm_blacksmith_sketch_dof_list(struct CadaclysmBlacksmithSketch *s,
                                                     uint32_t which,
                                                     size_t *count);

bool cadaclysm_blacksmith_sketch_dof_part(const struct CadaclysmBlacksmithSketch *s,
                                          uint32_t part,
                                          double *out);

const uint32_t *cadaclysm_blacksmith_sketch_dof_part_list(struct CadaclysmBlacksmithSketch *s,
                                                          uint32_t part,
                                                          uint32_t which,
                                                          size_t *count);

struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_sketch_profiles(const struct CadaclysmBlacksmithSketch *s,
                                                                            double tolerance);

struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_sketch_open_chains(const struct CadaclysmBlacksmithSketch *s,
                                                                               double tolerance);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cuboid(double x, double y, double z);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cylinder(double r, double h);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cone(double r, double h);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sphere(double r);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_torus(double major, double minor);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_wedge(double x,
                                                            double y,
                                                            double z,
                                                            double top_x);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_pyramid(uint32_t sides, double r, double h);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude(const struct CadaclysmBlacksmithProfile *profile,
                                                              const double *frame,
                                                              double height);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_open(const struct CadaclysmBlacksmithProfile *profile,
                                                                   const double *frame,
                                                                   double height);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_between(const struct CadaclysmBlacksmithProfile *profile,
                                                                      const double *frame,
                                                                      const double *bottom,
                                                                      const double *top);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_open_between(const struct CadaclysmBlacksmithProfile *profile,
                                                                           const double *frame,
                                                                           const double *bottom,
                                                                           const double *top);

bool cadaclysm_blacksmith_frame_midplane(const double *a, const double *b, double *out);

bool cadaclysm_blacksmith_frame_through(const double *p,
                                        const double *q,
                                        const double *r,
                                        double *out);

bool cadaclysm_blacksmith_slant_of_plane(const double *frame,
                                         const double *point,
                                         const double *normal,
                                         double *out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_tapered(const struct CadaclysmBlacksmithProfile *profile,
                                                                      const double *frame,
                                                                      double height,
                                                                      double taper);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_open_tapered(const struct CadaclysmBlacksmithProfile *profile,
                                                                           const double *frame,
                                                                           double height,
                                                                           double taper);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft(const struct CadaclysmBlacksmithProfile *a,
                                                           const double *frame_a,
                                                           const struct CadaclysmBlacksmithProfile *b,
                                                           const double *frame_b);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft_open(const struct CadaclysmBlacksmithProfile *a,
                                                                const double *frame_a,
                                                                const struct CadaclysmBlacksmithProfile *b,
                                                                const double *frame_b);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft_through(const struct CadaclysmBlacksmithProfile *const *profiles,
                                                                   const double *frames,
                                                                   size_t count);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft_through_open(const struct CadaclysmBlacksmithProfile *const *profiles,
                                                                        const double *frames,
                                                                        size_t count);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve(const struct CadaclysmBlacksmithProfile *profile,
                                                              const double *axis,
                                                              double angle);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_coil(const struct CadaclysmBlacksmithProfile *profile,
                                                           const double *axis,
                                                           double pitch,
                                                           double turns);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve_open(const struct CadaclysmBlacksmithProfile *profile,
                                                                   const double *axis,
                                                                   double angle);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve_in_plane(const struct CadaclysmBlacksmithProfile *profile,
                                                                       const double *frame,
                                                                       const double *axis,
                                                                       double angle);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve_open_in_plane(const struct CadaclysmBlacksmithProfile *profile,
                                                                            const double *frame,
                                                                            const double *axis,
                                                                            double angle);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_faces(const struct CadaclysmBlacksmithSolid *sheet,
                                                                    double height);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_face(const struct CadaclysmBlacksmithProfile *profile,
                                                           const double *frame);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_face_sheet(const struct CadaclysmBlacksmithSolid *solid,
                                                                 uint32_t face);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_drop_faces(const struct CadaclysmBlacksmithSolid *solid,
                                                                 const uint32_t *faces,
                                                                 size_t count);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_place(const struct CadaclysmBlacksmithSolid *solid,
                                                            const double *frame);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_translate_profile(const struct CadaclysmBlacksmithProfile *profile,
                                                                          double dx,
                                                                          double dy);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_rotate(const struct CadaclysmBlacksmithProfile *profile,
                                                                       double cx,
                                                                       double cy,
                                                                       double radians);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_scale(const struct CadaclysmBlacksmithProfile *profile,
                                                                      double cx,
                                                                      double cy,
                                                                      double sx,
                                                                      double sy);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_mirror(const struct CadaclysmBlacksmithProfile *profile,
                                                                       double px,
                                                                       double py,
                                                                       double dx,
                                                                       double dy);

struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_transform2d(const struct CadaclysmBlacksmithProfile *profile,
                                                                            const double *m);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_translate(const struct CadaclysmBlacksmithSolid *solid,
                                                                double dx,
                                                                double dy,
                                                                double dz);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_scaled(const struct CadaclysmBlacksmithSolid *solid,
                                                             double factor);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_transform(const struct CadaclysmBlacksmithSolid *solid,
                                                                      const double *matrix,
                                                                      uint32_t *inexact_out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_convert_to_nurbs(const struct CadaclysmBlacksmithSolid *solid,
                                                                             uint32_t level,
                                                                             uint32_t *inexact_out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rotate(const struct CadaclysmBlacksmithSolid *solid,
                                                             const double *axis,
                                                             double radians);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_mirror(const struct CadaclysmBlacksmithSolid *solid,
                                                             const double *plane);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_coloured(const struct CadaclysmBlacksmithSolid *solid,
                                                               uint32_t face,
                                                               double r,
                                                               double g,
                                                               double b);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_edges_coloured(const struct CadaclysmBlacksmithSolid *solid,
                                                                     const uint32_t *edges,
                                                                     size_t count,
                                                                     double r,
                                                                     double g,
                                                                     double b);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_join(const struct CadaclysmBlacksmithSolid *a,
                                                           const struct CadaclysmBlacksmithSolid *b,
                                                           double tolerance,
                                                           CadaclysmBlacksmithProgress progress,
                                                           void *user);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cut(const struct CadaclysmBlacksmithSolid *a,
                                                          const struct CadaclysmBlacksmithSolid *b,
                                                          double tolerance,
                                                          CadaclysmBlacksmithProgress progress,
                                                          void *user);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_common(const struct CadaclysmBlacksmithSolid *a,
                                                             const struct CadaclysmBlacksmithSolid *b,
                                                             double tolerance,
                                                             CadaclysmBlacksmithProgress progress,
                                                             void *user);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_sheet(const struct CadaclysmBlacksmithSolid *sheet,
                                                                  const struct CadaclysmBlacksmithSolid *tool,
                                                                  double tolerance,
                                                                  CadaclysmBlacksmithProgress progress,
                                                                  void *user);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_trim(const struct CadaclysmBlacksmithSolid *sheet,
                                                           const struct CadaclysmBlacksmithSolid *tool,
                                                           bool keep_inside,
                                                           double tolerance,
                                                           CadaclysmBlacksmithProgress progress,
                                                           void *user);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet(const struct CadaclysmBlacksmithSolid *solid,
                                                             const uint32_t *edges,
                                                             size_t count,
                                                             double radius,
                                                             double tolerance,
                                                             CadaclysmBlacksmithProgress progress,
                                                             void *user);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet_varying(const struct CadaclysmBlacksmithSolid *solid,
                                                                     const uint32_t *edges,
                                                                     size_t count,
                                                                     double radius_start,
                                                                     double radius_end,
                                                                     double tolerance);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_chamfer(const struct CadaclysmBlacksmithSolid *solid,
                                                              const uint32_t *edges,
                                                              size_t count,
                                                              double distance,
                                                              double tolerance);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_refillet(const struct CadaclysmBlacksmithSolid *solid,
                                                               uint32_t face,
                                                               double radius,
                                                               double tolerance);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_unfillet(const struct CadaclysmBlacksmithSolid *solid,
                                                               uint32_t face);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rechamfer(const struct CadaclysmBlacksmithSolid *solid,
                                                                uint32_t face,
                                                                double distance,
                                                                double tolerance);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_unchamfer(const struct CadaclysmBlacksmithSolid *solid,
                                                                uint32_t face);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_push_pull(const struct CadaclysmBlacksmithSolid *solid,
                                                                uint32_t face,
                                                                double distance,
                                                                double tolerance,
                                                                CadaclysmBlacksmithProgress progress,
                                                                void *user);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_push_pull_faces(const struct CadaclysmBlacksmithSolid *solid,
                                                                      const uint32_t *faces,
                                                                      size_t count,
                                                                      double distance,
                                                                      double tolerance,
                                                                      CadaclysmBlacksmithProgress progress,
                                                                      void *user);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split(const struct CadaclysmBlacksmithSolid *solid,
                                                            const struct CadaclysmBlacksmithSolid *tool,
                                                            double tolerance,
                                                            CadaclysmBlacksmithProgress progress,
                                                            void *user);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_by_plane(const struct CadaclysmBlacksmithSolid *solid,
                                                                     const double *plane,
                                                                     double tolerance,
                                                                     CadaclysmBlacksmithProgress progress,
                                                                     void *user);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_by_profile(const struct CadaclysmBlacksmithSolid *solid,
                                                                       const struct CadaclysmBlacksmithProfile *profile,
                                                                       const double *frame,
                                                                       double tolerance,
                                                                       CadaclysmBlacksmithProgress progress,
                                                                       void *user);

uint32_t cadaclysm_blacksmith_lump_count(const struct CadaclysmBlacksmithSolid *solid);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_lump(const struct CadaclysmBlacksmithSolid *solid,
                                                           uint32_t index);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_merge_flush(const struct CadaclysmBlacksmithSolid *solid);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_shell(const struct CadaclysmBlacksmithSolid *solid,
                                                            double thickness,
                                                            const uint32_t *open_faces,
                                                            size_t count,
                                                            double tolerance,
                                                            CadaclysmBlacksmithProgress progress,
                                                            void *user);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_thicken(const struct CadaclysmBlacksmithSolid *solid,
                                                              double thickness,
                                                              double tolerance,
                                                              CadaclysmBlacksmithProgress progress,
                                                              void *user);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_cuboid(double sx,
                                                                 double sy,
                                                                 double sz,
                                                                 uint32_t nx,
                                                                 uint32_t ny,
                                                                 uint32_t nz);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_cylinder(double radius,
                                                                   double height,
                                                                   uint32_t sides,
                                                                   uint32_t rings,
                                                                   bool creased_rims);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_sphere(double radius, uint32_t segments);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_torus(double major,
                                                                double minor,
                                                                uint32_t around,
                                                                uint32_t tube);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_from_parts(const double *positions,
                                                                     uint32_t vertex_count,
                                                                     const uint32_t *face_sizes,
                                                                     uint32_t face_count,
                                                                     const uint32_t *face_indices,
                                                                     uint32_t index_count,
                                                                     const uint32_t *creases,
                                                                     uint32_t crease_count,
                                                                     const uint32_t *pins,
                                                                     uint32_t pin_count,
                                                                     int32_t symmetry_axis,
                                                                     double symmetry_tolerance);

bool cadaclysm_blacksmith_subd_parts(const struct CadaclysmBlacksmithSubd *subd,
                                     struct CadaclysmBlacksmithSubdParts *out);

void cadaclysm_blacksmith_subd_free(struct CadaclysmBlacksmithSubd *subd);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_transform(const struct CadaclysmBlacksmithSubd *subd,
                                                                    uint32_t kind,
                                                                    const uint32_t *ids,
                                                                    uint32_t id_count,
                                                                    const double *matrix);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_set_crease(const struct CadaclysmBlacksmithSubd *subd,
                                                                     const uint32_t *edges,
                                                                     uint32_t edge_count,
                                                                     bool on);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_set_pin(const struct CadaclysmBlacksmithSubd *subd,
                                                                  const uint32_t *vertices,
                                                                  uint32_t vertex_count,
                                                                  bool on);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_extrude(const struct CadaclysmBlacksmithSubd *subd,
                                                                  const uint32_t *faces,
                                                                  uint32_t face_count,
                                                                  double distance);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_inset(const struct CadaclysmBlacksmithSubd *subd,
                                                                const uint32_t *faces,
                                                                uint32_t face_count,
                                                                double amount,
                                                                bool individual);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_subdivide(const struct CadaclysmBlacksmithSubd *subd,
                                                                    const uint32_t *faces,
                                                                    uint32_t face_count);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_insert_loop(const struct CadaclysmBlacksmithSubd *subd,
                                                                      uint32_t a,
                                                                      uint32_t b,
                                                                      double at);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_mirror_on(const struct CadaclysmBlacksmithSubd *subd,
                                                                    uint32_t axis);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_mirror_off(const struct CadaclysmBlacksmithSubd *subd);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_full(const struct CadaclysmBlacksmithSubd *subd);

struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_edge_loop(const struct CadaclysmBlacksmithSubd *subd,
                                                                    uint32_t a,
                                                                    uint32_t b);

bool cadaclysm_blacksmith_subd_smooth_mesh(const struct CadaclysmBlacksmithSubd *subd,
                                           uint32_t levels,
                                           struct CadaclysmBlacksmithSubdMesh *out);

bool cadaclysm_blacksmith_subd_pick(const struct CadaclysmBlacksmithSubd *subd,
                                    const double *point,
                                    uint32_t kind,
                                    uint32_t *out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_subd_to_solid(const struct CadaclysmBlacksmithSubd *subd,
                                                                    double tolerance,
                                                                    double g1_angle_deg,
                                                                    uint32_t max_levels,
                                                                    struct CadaclysmBlacksmithSubdReport *report);

struct CadaclysmBlacksmithSweepPath *cadaclysm_blacksmith_sweep_path_begin(double x,
                                                                           double y,
                                                                           double z);

bool cadaclysm_blacksmith_sweep_path_line_to(struct CadaclysmBlacksmithSweepPath *p,
                                             double x,
                                             double y,
                                             double z);

bool cadaclysm_blacksmith_sweep_path_arc(struct CadaclysmBlacksmithSweepPath *p,
                                         double cx,
                                         double cy,
                                         double cz,
                                         double ax,
                                         double ay,
                                         double az,
                                         double angle);

struct CadaclysmBlacksmithSweepPath *cadaclysm_blacksmith_sweep_path_along(const struct CadaclysmBlacksmithProfile *curve,
                                                                           const double *frame,
                                                                           double tolerance,
                                                                           bool open);

void cadaclysm_blacksmith_sweep_path_free(struct CadaclysmBlacksmithSweepPath *p);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep(const struct CadaclysmBlacksmithProfile *profile,
                                                            const double *frame,
                                                            const struct CadaclysmBlacksmithSweepPath *path);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_pipe(const struct CadaclysmBlacksmithSweepPath *path,
                                                           double radius,
                                                           double thickness);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep_open(const struct CadaclysmBlacksmithProfile *profile,
                                                                 const double *frame,
                                                                 const struct CadaclysmBlacksmithSweepPath *path);

struct CadaclysmBlacksmithThicknessGauge *cadaclysm_blacksmith_thickness_gauge_new(const struct CadaclysmBlacksmithSolid *const *solids,
                                                                                   uint32_t count,
                                                                                   double tolerance);

void cadaclysm_blacksmith_thickness_gauge_free(struct CadaclysmBlacksmithThicknessGauge *gauge);

uint32_t cadaclysm_blacksmith_thickness_gauge_body_count(const struct CadaclysmBlacksmithThicknessGauge *gauge);

double cadaclysm_blacksmith_thickness_gauge_tolerance(const struct CadaclysmBlacksmithThicknessGauge *gauge);

bool cadaclysm_blacksmith_thickness_gauge_mesh(const struct CadaclysmBlacksmithThicknessGauge *gauge,
                                               uint32_t body,
                                               struct CadaclysmBlacksmithThicknessMesh *out);

struct CadaclysmBlacksmithThicknesses *cadaclysm_blacksmith_thickness_gauge_measure(const struct CadaclysmBlacksmithThicknessGauge *gauge,
                                                                                    double maximum,
                                                                                    double sharp_angle);

struct CadaclysmBlacksmithThicknesses *cadaclysm_blacksmith_thickness_gauge_at(const struct CadaclysmBlacksmithThicknessGauge *gauge,
                                                                               uint32_t body,
                                                                               uint32_t face,
                                                                               const double *point,
                                                                               double maximum,
                                                                               double sharp_angle);

bool cadaclysm_blacksmith_thickness_gauge_face(const struct CadaclysmBlacksmithThicknessGauge *gauge,
                                               uint32_t body,
                                               uint32_t face,
                                               const double *at,
                                               double maximum,
                                               struct CadaclysmBlacksmithFaceThickness *out);

void cadaclysm_blacksmith_thicknesses_free(struct CadaclysmBlacksmithThicknesses *list);

uint32_t cadaclysm_blacksmith_thicknesses_count(const struct CadaclysmBlacksmithThicknesses *list);

bool cadaclysm_blacksmith_thicknesses_at(const struct CadaclysmBlacksmithThicknesses *list,
                                         uint32_t i,
                                         struct CadaclysmBlacksmithThickness *out);

struct CadaclysmBlacksmithMeshThicknesses *cadaclysm_blacksmith_mesh_thickness(const double *positions,
                                                                               const uint32_t *vertex_counts,
                                                                               const uint32_t *indices,
                                                                               const uint32_t *triangle_counts,
                                                                               uint32_t mesh_count,
                                                                               double maximum,
                                                                               double sharp_angle);

void cadaclysm_blacksmith_mesh_thicknesses_free(struct CadaclysmBlacksmithMeshThicknesses *list);

uint32_t cadaclysm_blacksmith_mesh_thicknesses_count(const struct CadaclysmBlacksmithMeshThicknesses *list);

bool cadaclysm_blacksmith_mesh_thicknesses_at(const struct CadaclysmBlacksmithMeshThicknesses *list,
                                              uint32_t i,
                                              struct CadaclysmBlacksmithMeshThickness *out);

bool cadaclysm_blacksmith_transform_translation(const double *v, double *out);

bool cadaclysm_blacksmith_transform_rotation(const double *axis, double radians, double *out);

bool cadaclysm_blacksmith_transform_mirror(const double *plane,
                                           double *out);

bool cadaclysm_blacksmith_transform_scale(const double *centre, double k, double *out);

bool cadaclysm_blacksmith_transform_scale_xyz(const double *frame,
                                              double sx,
                                              double sy,
                                              double sz,
                                              double *out);

bool cadaclysm_blacksmith_transform_shear(const double *plane,
                                          const double *dir,
                                          double factor,
                                          double *out);

bool cadaclysm_blacksmith_transform_plane_to_plane(const double *a,
                                                   const double *b,
                                                   double *out);

bool cadaclysm_blacksmith_transform_change_basis(const double *from,
                                                 const double *to,
                                                 double *out);

bool cadaclysm_blacksmith_transform_planar_projection(const double *plane,
                                                      double *out);

bool cadaclysm_blacksmith_transform_project_along(const double *plane,
                                                  const double *dir,
                                                  double *out);

bool cadaclysm_blacksmith_transform_compose(const double *a, const double *b, double *out);

bool cadaclysm_blacksmith_transform_inverse(const double *m, double *out);

uint32_t cadaclysm_blacksmith_transform_is_rigid(const double *m, double tolerance);

double cadaclysm_blacksmith_transform_is_similarity(const double *m, double tolerance);

bool cadaclysm_blacksmith_transform_decompose_rigid(const double *m, double tolerance, double *out);

bool cadaclysm_blacksmith_transform_decompose_similarity(const double *m,
                                                         double tolerance,
                                                         double *out);

bool cadaclysm_blacksmith_transform_decompose_affine(const double *m, double *out);

bool cadaclysm_blacksmith_quaternion_from_axis_angle(const double *dir,
                                                     double radians,
                                                     double *out);

bool cadaclysm_blacksmith_quaternion_from_transform(const double *m, double *out);

bool cadaclysm_blacksmith_quaternion_to_transform(const double *q,
                                                  const double *centre,
                                                  double *out);

bool cadaclysm_blacksmith_quaternion_slerp(const double *a,
                                           const double *b,
                                           double s,
                                           double *out);

uint32_t cadaclysm_blacksmith_value_size(uint32_t kind);

bool cadaclysm_blacksmith_value_check(uint32_t kind, const double *value, double *out);

bool cadaclysm_blacksmith_value_bounds(uint32_t kind, const double *value, double *out);

bool cadaclysm_blacksmith_value_transform(uint32_t kind,
                                          const double *value,
                                          const double *matrix,
                                          double *out);

bool cadaclysm_blacksmith_curve_value_point_at(uint32_t kind,
                                               const double *value,
                                               double t,
                                               double *out);

bool cadaclysm_blacksmith_curve_value_tangent_at(uint32_t kind,
                                                 const double *value,
                                                 double t,
                                                 double *out);

bool cadaclysm_blacksmith_curve_value_length(uint32_t kind, const double *value, double *out);

bool cadaclysm_blacksmith_curve_value_closest_point(uint32_t kind,
                                                    const double *value,
                                                    const double *point,
                                                    double *out);

struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_curve_value_to_nurbs(uint32_t kind,
                                                                                const double *value);

bool cadaclysm_blacksmith_circle_through(const double *a,
                                         const double *b,
                                         const double *c,
                                         double *out);

bool cadaclysm_blacksmith_arc_through(const double *a,
                                      const double *b,
                                      const double *c,
                                      double *out);

bool cadaclysm_blacksmith_arc_from_start_tangent_end(const double *a,
                                                     const double *tangent,
                                                     const double *c,
                                                     double *out);

bool cadaclysm_blacksmith_ellipse_from_circle(const double *value, double *out);

bool cadaclysm_blacksmith_surface_value_point_at(uint32_t kind,
                                                 const double *value,
                                                 double u,
                                                 double v,
                                                 double *out);

bool cadaclysm_blacksmith_surface_value_normal_at(uint32_t kind,
                                                  const double *value,
                                                  double u,
                                                  double v,
                                                  double *out);

bool cadaclysm_blacksmith_surface_value_closest_point(uint32_t kind,
                                                      const double *value,
                                                      const double *point,
                                                      double *out);

bool cadaclysm_blacksmith_surface_value_domain(uint32_t kind, const double *value, double *out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_surface_value_nurbs_sheet(uint32_t kind,
                                                                                const double *value);

uint32_t cadaclysm_blacksmith_solid_value_contains(uint32_t kind,
                                                   const double *value,
                                                   const double *point,
                                                   double tolerance);

bool cadaclysm_blacksmith_solid_value_area(uint32_t kind, const double *value, double *out);

bool cadaclysm_blacksmith_solid_value_volume(uint32_t kind, const double *value, double *out);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_value_to_solid(uint32_t kind,
                                                                           const double *value);

bool cadaclysm_blacksmith_cuboid_from_bounds(const double *min, const double *max, double *out);

bool cadaclysm_blacksmith_cuboid_around(const double *frame,
                                        const double *xyz,
                                        size_t count,
                                        double *out);

bool cadaclysm_blacksmith_cuboid_corners(const double *value, double *out);

bool cadaclysm_blacksmith_cuboid_point_at(const double *value,
                                          double sx,
                                          double sy,
                                          double sz,
                                          double *out);

bool cadaclysm_blacksmith_cuboid_closest_point(const double *value,
                                               const double *point,
                                               double *out);

bool cadaclysm_blacksmith_frame_fit(const double *xyz,
                                    size_t count,
                                    double *out,
                                    double *deviation_out);
]]
