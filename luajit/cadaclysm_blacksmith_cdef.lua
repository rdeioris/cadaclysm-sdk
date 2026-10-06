-- Generated from crates/cadaclysm-blacksmith-capi/include/cadaclysm_blacksmith.h by gen_cdef.py. Do not edit; rerun the script.
return [[
static const uint32_t CADACLYSM_BLACKSMITH_NONE = 0xffffffff;

static const uint32_t CADACLYSM_BLACKSMITH_SVG_TRANSPARENT = 0xffffffff;

static const uint32_t CADACLYSM_BLACKSMITH_SVG_EDGES = 1;

static const uint32_t CADACLYSM_BLACKSMITH_SVG_CURVES = 2;

static const uint32_t CADACLYSM_BLACKSMITH_SVG_ISOCURVES = 4;

static const uint32_t CADACLYSM_BLACKSMITH_SVG_POLYLINES = 8;

static const uint32_t CADACLYSM_BLACKSMITH_SVG_SILHOUETTES = 16;

typedef struct CadaclysmBlacksmithAssembly CadaclysmBlacksmithAssembly;

typedef struct CadaclysmBlacksmithCollider CadaclysmBlacksmithCollider;

typedef struct CadaclysmBlacksmithCollisions CadaclysmBlacksmithCollisions;

typedef struct CadaclysmBlacksmithFemMesh CadaclysmBlacksmithFemMesh;

typedef struct CadaclysmBlacksmithHits CadaclysmBlacksmithHits;

typedef struct CadaclysmBlacksmithIntersection CadaclysmBlacksmithIntersection;

typedef struct CadaclysmBlacksmithJob CadaclysmBlacksmithJob;

typedef struct CadaclysmBlacksmithOperations CadaclysmBlacksmithOperations;

typedef struct CadaclysmBlacksmithPath CadaclysmBlacksmithPath;

typedef struct CadaclysmBlacksmithProfile CadaclysmBlacksmithProfile;

typedef struct CadaclysmBlacksmithProfileList CadaclysmBlacksmithProfileList;

typedef struct CadaclysmBlacksmithPrograms CadaclysmBlacksmithPrograms;

typedef struct CadaclysmBlacksmithReport CadaclysmBlacksmithReport;

typedef struct CadaclysmBlacksmithSolid CadaclysmBlacksmithSolid;

typedef struct CadaclysmBlacksmithStock CadaclysmBlacksmithStock;

typedef struct CadaclysmBlacksmithSweepPath CadaclysmBlacksmithSweepPath;

typedef struct CadaclysmBlacksmithTessellation CadaclysmBlacksmithTessellation;

typedef struct CadaclysmBlacksmithTool CadaclysmBlacksmithTool;

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

const char *cadaclysm_blacksmith_last_error(void);

const char *cadaclysm_blacksmith_version(void);

bool cadaclysm_blacksmith_parse_colour(const char *text, double *out);

void cadaclysm_blacksmith_solid_free(struct CadaclysmBlacksmithSolid *solid);

void cadaclysm_blacksmith_profile_free(struct CadaclysmBlacksmithProfile *profile);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_named(const struct CadaclysmBlacksmithSolid *solid,
                                                            const char *name);

const char *cadaclysm_blacksmith_solid_name(const struct CadaclysmBlacksmithSolid *solid);

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

uint32_t cadaclysm_blacksmith_report_count(const struct CadaclysmBlacksmithReport *r);

const char *cadaclysm_blacksmith_report_kind(const struct CadaclysmBlacksmithReport *r, uint32_t i);

bool cadaclysm_blacksmith_report_at(const struct CadaclysmBlacksmithReport *r,
                                    uint32_t i,
                                    double *out);

double cadaclysm_blacksmith_report_size(const struct CadaclysmBlacksmithReport *r, uint32_t i);

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

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_translate(const struct CadaclysmBlacksmithSolid *solid,
                                                                double dx,
                                                                double dy,
                                                                double dz);

struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_scaled(const struct CadaclysmBlacksmithSolid *solid,
                                                             double factor);

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
]]
