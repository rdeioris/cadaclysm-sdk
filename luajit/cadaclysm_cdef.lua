-- Generated from crates/cadaclysm-capi/include/cadaclysm.h by gen_cdef.py. Do not edit; rerun the script.
return [[
static const uint32_t CADACLYSM_NONE = 0xffffffff;

static const uint32_t CADACLYSM_UNITY_HULL_LIMIT = 255;

static const uint32_t CADACLYSM_LOD_LEVELS = 3;

static const uint32_t CADACLYSM_WINDOW_NONE = 0;

static const uint32_t CADACLYSM_WINDOW_X11 = 1;

static const uint32_t CADACLYSM_WINDOW_WAYLAND = 2;

static const uint32_t CADACLYSM_WINDOW_WIN32 = 3;

static const uint32_t CADACLYSM_WINDOW_APPKIT = 4;

static const uint32_t CADACLYSM_SVG_TRANSPARENT = 0xffffffff;

static const uint32_t CADACLYSM_SVG_EDGES = 1;

static const uint32_t CADACLYSM_SVG_CURVES = 2;

static const uint32_t CADACLYSM_SVG_ISOCURVES = 4;

static const uint32_t CADACLYSM_SVG_POLYLINES = 8;

typedef enum CadaclysmAxis {
  CADACLYSM_AXIS_X = 0,
  CADACLYSM_AXIS_Y = 1,
  CADACLYSM_AXIS_Z = 2,
  CADACLYSM_AXIS_NEG_X = 3,
  CADACLYSM_AXIS_NEG_Y = 4,
  CADACLYSM_AXIS_NEG_Z = 5,
} CadaclysmAxis;

typedef enum CadaclysmWinding {

  CADACLYSM_WINDING_COUNTER_CLOCKWISE = 0,

  CADACLYSM_WINDING_CLOCKWISE = 1,
} CadaclysmWinding;

typedef enum CadaclysmValueKind {

  CadaclysmValueNone = 0,
  CadaclysmValueText = 1,
  CadaclysmValueInteger = 2,
  CadaclysmValueReal = 3,
  CadaclysmValueBoolean = 4,

  CadaclysmValueList = 5,

  CadaclysmValueReference = 6,
} CadaclysmValueKind;

typedef enum CadaclysmConvention {
  CADACLYSM_NATIVE = 0,
  CADACLYSM_UNREAL = 1,
  CADACLYSM_UNITY = 2,
  CADACLYSM_Y_UP = 3,
  CADACLYSM_BLENDER = 4,
} CadaclysmConvention;

typedef enum CadaclysmMeshUvs {
  CADACLYSM_UV_NONE = 0,

  CADACLYSM_UV_WORLD_SCALE = 1,
} CadaclysmMeshUvs;

typedef enum CadaclysmMeshColors {
  CADACLYSM_COLORS_NONE = 0,
  CADACLYSM_COLORS_PER_FACE = 1,
} CadaclysmMeshColors;

typedef struct CadaclysmBrep CadaclysmBrep;

typedef struct CadaclysmFemMesh CadaclysmFemMesh;

typedef struct CadaclysmMeshlets CadaclysmMeshlets;

typedef struct CadaclysmScene CadaclysmScene;

typedef struct CadaclysmConventionSpec {
  enum CadaclysmAxis x;
  enum CadaclysmAxis y;
  enum CadaclysmAxis z;

  double units_per_metre;

  bool file_units;
  enum CadaclysmWinding winding;
} CadaclysmConventionSpec;

typedef struct CadaclysmCandidate {

  const char *name;

  const char *format;

  size_t depth;
} CadaclysmCandidate;

typedef size_t (*CadaclysmPick)(const struct CadaclysmCandidate *candidates,
                                size_t count,
                                void *user);

typedef struct CadaclysmOpenOptions {

  size_t size;

  uint32_t convention;

  const struct CadaclysmConventionSpec *spec;

  bool file_units;

  uint32_t uvs;

  uint32_t colors;

  double source_meters_per_unit;

  const char *const *schemas;
  size_t schema_count;

  const uint8_t *schema_text;
  size_t schema_length;

  CadaclysmPick pick;

  void *pick_user;
} CadaclysmOpenOptions;

typedef struct CadaclysmBounds {
  float min[3];
  float max[3];
} CadaclysmBounds;

typedef struct CadaclysmBounds64 {
  double min[3];
  double max[3];
} CadaclysmBounds64;

typedef struct CadaclysmAttribute {
  const char *name;
  enum CadaclysmValueKind kind;
  const char *text;
  int64_t integer;
  double real;
  bool boolean;
} CadaclysmAttribute;

typedef struct CadaclysmMesh {
  const float *positions;
  const float *normals;
  const float *uvs;

  const float *colors;
  const uint32_t *indices;
  uint32_t vertex_count;
  uint32_t index_count;
} CadaclysmMesh;

typedef struct CadaclysmMesh64 {
  const double *positions;
  const double *normals;
  const double *uvs;
  const float *colors;
  const uint32_t *indices;
  uint32_t vertex_count;
  uint32_t index_count;
} CadaclysmMesh64;

typedef struct CadaclysmCollision {

  uint32_t size;

  uint32_t shape;

  uint32_t confidence;

  uint32_t axis;

  double frame[16];
  double half_extent[3];
  double radius;

  double height;

  double error;
  uint32_t hull_vertex_count;
  uint32_t hull_index_count;
} CadaclysmCollision;

typedef struct CadaclysmCollisionHull {

  const float *positions;

  const uint32_t *indices;
  uint32_t vertex_count;
  uint32_t index_count;
} CadaclysmCollisionHull;

typedef struct CadaclysmPolylines {
  const float *positions;
  const uint32_t *counts;
  uint32_t polyline_count;
  uint32_t vertex_count;
} CadaclysmPolylines;

typedef struct CadaclysmBeziers {
  const float *points;
  const float *weights;
  uint32_t count;
} CadaclysmBeziers;

typedef struct CadaclysmBeziers64 {
  const double *points;
  const double *weights;
  uint32_t count;
} CadaclysmBeziers64;

typedef struct CadaclysmFace {
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
} CadaclysmFace;

typedef struct CadaclysmSurfaces {
  const struct CadaclysmFace *faces;
  uint32_t face_count;

  const uint32_t *loops;
  uint32_t loop_count;

  const float *points;
  uint32_t point_count;

  const float *profiles;
  uint32_t profile_count;

  const float *nurbs;
  uint32_t nurbs_count;
} CadaclysmSurfaces;

typedef struct CadaclysmWindow {
  uint32_t kind;
  void *handle;
  void *display;
} CadaclysmWindow;

typedef struct CadaclysmSvgOptions {
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
} CadaclysmSvgOptions;

typedef struct CadaclysmFemOptions {

  size_t size;

  double tolerance;

  double max_size;
} CadaclysmFemOptions;

typedef struct CadaclysmFemMeshView {

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
} CadaclysmFemMeshView;

typedef struct CadaclysmFemEdge {

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
} CadaclysmFemEdge;

typedef struct CadaclysmFemVertex {

  uint32_t node;

  double point[3];

  bool has_position;
} CadaclysmFemVertex;

const char *cadaclysm_last_error(void);

const char *cadaclysm_version(void);

struct CadaclysmScene *cadaclysm_open(const char *path, const struct CadaclysmOpenOptions *options);

struct CadaclysmScene *cadaclysm_open_memory(const uint8_t *bytes,
                                             size_t length,
                                             const char *format,
                                             const struct CadaclysmOpenOptions *options);

void cadaclysm_open_options_init(struct CadaclysmOpenOptions *options);

void cadaclysm_close(struct CadaclysmScene *scene);

const char *cadaclysm_source_name(const struct CadaclysmScene *scene);

uint32_t cadaclysm_node_count(const struct CadaclysmScene *scene);

uint32_t cadaclysm_root_count(const struct CadaclysmScene *scene);

uint32_t cadaclysm_root(const struct CadaclysmScene *scene, uint32_t index);

const char *cadaclysm_schema(const struct CadaclysmScene *scene);

const char *cadaclysm_schema_read(const struct CadaclysmScene *scene);

double cadaclysm_metres_per_unit(const struct CadaclysmScene *scene);

struct CadaclysmBounds cadaclysm_bounds(const struct CadaclysmScene *scene);

struct CadaclysmBounds64 cadaclysm_bounds64(const struct CadaclysmScene *scene);

uint32_t cadaclysm_node_parent(const struct CadaclysmScene *scene, uint32_t node);

uint32_t cadaclysm_node_child_count(const struct CadaclysmScene *scene, uint32_t node);

uint32_t cadaclysm_node_child(const struct CadaclysmScene *scene, uint32_t node, uint32_t index);

uint32_t cadaclysm_node_depth(const struct CadaclysmScene *scene, uint32_t node);

const char *cadaclysm_node_name(const struct CadaclysmScene *scene, uint32_t node);

const char *cadaclysm_node_kind(const struct CadaclysmScene *scene, uint32_t node);

const char *cadaclysm_node_id(const struct CadaclysmScene *scene, uint32_t node);

bool cadaclysm_node_color(const struct CadaclysmScene *scene, uint32_t node, float *rgba);

void cadaclysm_node_transform(const struct CadaclysmScene *scene, uint32_t node, double *out);

uint32_t cadaclysm_placement_count(const struct CadaclysmScene *scene);

uint32_t cadaclysm_placement_geometry(const struct CadaclysmScene *scene, uint32_t placement);

uint32_t cadaclysm_placement_select(const struct CadaclysmScene *scene, uint32_t placement);

void cadaclysm_placement_transform(const struct CadaclysmScene *scene,
                                   uint32_t placement,
                                   double *out);

uint32_t cadaclysm_node_attribute_count(const struct CadaclysmScene *scene, uint32_t node);

struct CadaclysmAttribute cadaclysm_node_attribute(const struct CadaclysmScene *scene,
                                                   uint32_t node,
                                                   uint32_t index);

uint32_t cadaclysm_query(const struct CadaclysmScene *scene,
                         const char *filter,
                         uint32_t *out,
                         uint32_t capacity);

bool cadaclysm_node_can_mesh(const struct CadaclysmScene *scene, uint32_t node);

bool cadaclysm_node_visible(const struct CadaclysmScene *scene, uint32_t node);

struct CadaclysmMesh cadaclysm_node_mesh(const struct CadaclysmScene *scene, uint32_t node);

struct CadaclysmMesh64 cadaclysm_node_mesh64(const struct CadaclysmScene *scene, uint32_t node);

int64_t cadaclysm_node_triangle_estimate(const struct CadaclysmScene *scene, uint32_t node);

struct CadaclysmMesh cadaclysm_node_surface_proxy_mesh(const struct CadaclysmScene *scene,
                                                       uint32_t node,
                                                       uint32_t cells);

struct CadaclysmBounds cadaclysm_node_bounds(const struct CadaclysmScene *scene, uint32_t node);

struct CadaclysmBounds64 cadaclysm_node_bounds64(const struct CadaclysmScene *scene, uint32_t node);

struct CadaclysmBounds cadaclysm_node_bounds_placed(const struct CadaclysmScene *scene,
                                                    uint32_t node,
                                                    const double *placement);

struct CadaclysmBounds64 cadaclysm_node_bounds_placed64(const struct CadaclysmScene *scene,
                                                        uint32_t node,
                                                        const double *placement);

bool cadaclysm_node_collision(const struct CadaclysmScene *scene,
                              uint32_t node,
                              uint32_t hull_budget,
                              struct CadaclysmCollision *out);

struct CadaclysmCollisionHull cadaclysm_node_collision_hull(const struct CadaclysmScene *scene,
                                                            uint32_t node,
                                                            uint32_t hull_budget);

uint32_t cadaclysm_node_instance_of(const struct CadaclysmScene *scene, uint32_t node);

uint32_t cadaclysm_node_select_as(const struct CadaclysmScene *scene, uint32_t node);

const char *cadaclysm_node_generator(const struct CadaclysmScene *scene, uint32_t node);

uint32_t cadaclysm_lod_levels(void);

struct CadaclysmMesh cadaclysm_node_mesh_lod(const struct CadaclysmScene *scene,
                                             uint32_t node,
                                             uint32_t level);

float cadaclysm_node_lod_error(const struct CadaclysmScene *scene, uint32_t node, uint32_t level);

uint32_t cadaclysm_diagnostic_count(const struct CadaclysmScene *scene);

const char *cadaclysm_diagnostic(const struct CadaclysmScene *scene, uint32_t index);

uint32_t cadaclysm_geometry_diagnostic_count(const struct CadaclysmScene *scene);

const char *cadaclysm_geometry_diagnostic(const struct CadaclysmScene *scene, uint32_t index);

struct CadaclysmPolylines cadaclysm_node_edges(const struct CadaclysmScene *scene, uint32_t node);

struct CadaclysmPolylines cadaclysm_node_surface_edges(const struct CadaclysmScene *scene,
                                                       uint32_t node);

struct CadaclysmPolylines cadaclysm_node_surface_isocurves(const struct CadaclysmScene *scene,
                                                           uint32_t node);

struct CadaclysmBeziers cadaclysm_node_edge_beziers(const struct CadaclysmScene *scene,
                                                    uint32_t node);

struct CadaclysmBeziers64 cadaclysm_node_edge_beziers64(const struct CadaclysmScene *scene,
                                                        uint32_t node);

struct CadaclysmSurfaces cadaclysm_node_surfaces(const struct CadaclysmScene *scene, uint32_t node);

bool cadaclysm_node_surface_pick(const struct CadaclysmScene *scene,
                                 uint32_t node,
                                 const double *from,
                                 const double *to,
                                 double *out_point);

void cadaclysm_surface_matrix(const struct CadaclysmScene *scene, float *out);

struct CadaclysmBeziers cadaclysm_node_curve_beziers(const struct CadaclysmScene *scene,
                                                     uint32_t node);

struct CadaclysmBeziers64 cadaclysm_node_curve_beziers64(const struct CadaclysmScene *scene,
                                                         uint32_t node);

struct CadaclysmBeziers cadaclysm_node_isocurve_beziers(const struct CadaclysmScene *scene,
                                                        uint32_t node);

struct CadaclysmBeziers64 cadaclysm_node_isocurve_beziers64(const struct CadaclysmScene *scene,
                                                            uint32_t node);

struct CadaclysmPolylines cadaclysm_node_curves(const struct CadaclysmScene *scene, uint32_t node);

struct CadaclysmPolylines cadaclysm_node_isocurves(const struct CadaclysmScene *scene,
                                                   uint32_t node);

void cadaclysm_forget_meshes(struct CadaclysmScene *scene);

uint32_t cadaclysm_realize_all(const struct CadaclysmScene *scene);

uint32_t cadaclysm_realize_meshes(const struct CadaclysmScene *scene, uint32_t skip_surfaced);

bool cadaclysm_node_is_meshed(const struct CadaclysmScene *scene, uint32_t node);

uint32_t cadaclysm_realized(const struct CadaclysmScene *scene);

uint32_t cadaclysm_realize_total(const struct CadaclysmScene *scene);

void cadaclysm_cancel(const struct CadaclysmScene *scene);

bool cadaclysm_scene_save(const struct CadaclysmScene *scene, const char *path, const char *format);

uint32_t cadaclysm_mesh_format_count(void);

const char *cadaclysm_mesh_format(uint32_t index);

const char *cadaclysm_mesh_format_extension(uint32_t index);

const char *cadaclysm_mesh_format_label(uint32_t index);

uint32_t cadaclysm_format_count(void);

const char *cadaclysm_format_name(uint32_t index);

const char *cadaclysm_format_extensions(uint32_t index);

bool cadaclysm_node_save_mesh(const struct CadaclysmScene *scene,
                              uint32_t node,
                              const char *path,
                              const char *format);

const char *cadaclysm_pick_file(const struct CadaclysmWindow *parent);

const char *cadaclysm_pick_save(const struct CadaclysmWindow *parent, const char *suggested_name);

bool cadaclysm_license_set(const char *text_or_path);

const char *cadaclysm_license_info(void);

uint64_t cadaclysm_license_notice_count(void);

const char *cadaclysm_build_date(void);

const char *cadaclysm_brep_layout_id(void);

const struct CadaclysmBrep *cadaclysm_node_brep(const struct CadaclysmScene *scene, uint32_t node);

void cadaclysm_brep_release(const struct CadaclysmBrep *brep);

bool cadaclysm_brep_manifold(const struct CadaclysmBrep *brep, uint32_t *out);

void cadaclysm_svg_options_init(struct CadaclysmSvgOptions *options);

const char *cadaclysm_scene_svg_text(const struct CadaclysmScene *scene,
                                     const struct CadaclysmSvgOptions *options);

bool cadaclysm_scene_svg(const struct CadaclysmScene *scene,
                         const char *path,
                         const struct CadaclysmSvgOptions *options);

const char *cadaclysm_node_svg_text(const struct CadaclysmScene *scene,
                                    uint32_t node,
                                    const struct CadaclysmSvgOptions *options);

bool cadaclysm_node_svg(const struct CadaclysmScene *scene,
                        uint32_t node,
                        const char *path,
                        const struct CadaclysmSvgOptions *options);

struct CadaclysmMeshlets *cadaclysm_meshlets_build(const float *positions,
                                                   const float *normals,
                                                   size_t vertex_count,
                                                   const uint32_t *indices,
                                                   size_t index_count,
                                                   uint32_t max_triangles,
                                                   uint32_t max_vertices,
                                                   int32_t levels);

uint32_t cadaclysm_meshlets_count(const struct CadaclysmMeshlets *handle);

uint32_t cadaclysm_meshlet_triangle_count(const struct CadaclysmMeshlets *handle, uint32_t index);

uint32_t cadaclysm_meshlet_vertex_count(const struct CadaclysmMeshlets *handle, uint32_t index);

uint32_t cadaclysm_meshlet_level(const struct CadaclysmMeshlets *handle, uint32_t index);

uint32_t cadaclysm_meshlet_group(const struct CadaclysmMeshlets *handle, uint32_t index);

float cadaclysm_meshlet_error(const struct CadaclysmMeshlets *handle, uint32_t index);

uint32_t cadaclysm_meshlet_child_count(const struct CadaclysmMeshlets *handle, uint32_t index);

void cadaclysm_meshlet_positions(const struct CadaclysmMeshlets *handle,
                                 uint32_t index,
                                 float *out);

void cadaclysm_meshlet_normals(const struct CadaclysmMeshlets *handle, uint32_t index, float *out);

void cadaclysm_meshlet_indices(const struct CadaclysmMeshlets *handle,
                               uint32_t index,
                               uint32_t *out);

void cadaclysm_meshlet_children(const struct CadaclysmMeshlets *handle,
                                uint32_t index,
                                uint32_t *out);

void cadaclysm_meshlets_free(struct CadaclysmMeshlets *handle);

void cadaclysm_fem_options_init(struct CadaclysmFemOptions *options);

struct CadaclysmFemMesh *cadaclysm_node_fem_mesh(const struct CadaclysmScene *scene,
                                                 uint32_t node,
                                                 const double *placement,
                                                 const struct CadaclysmFemOptions *options);

bool cadaclysm_fem_mesh_view(const struct CadaclysmFemMesh *m, struct CadaclysmFemMeshView *out);

bool cadaclysm_fem_mesh_edge(const struct CadaclysmFemMesh *m,
                             uint32_t i,
                             struct CadaclysmFemEdge *out);

bool cadaclysm_fem_mesh_vertex(const struct CadaclysmFemMesh *m,
                               uint32_t i,
                               struct CadaclysmFemVertex *out);

bool cadaclysm_fem_mesh_open_edge(const struct CadaclysmFemMesh *m,
                                  uint32_t i,
                                  uint32_t *a,
                                  uint32_t *b,
                                  uint32_t *brep_edge);

bool cadaclysm_fem_mesh_folded_edge(const struct CadaclysmFemMesh *m,
                                    uint32_t i,
                                    uint32_t *a,
                                    uint32_t *b,
                                    uint32_t *brep_edge);

bool cadaclysm_fem_mesh_save_msh(const struct CadaclysmFemMesh *m, const char *path);

const char *cadaclysm_fem_mesh_msh_text(const struct CadaclysmFemMesh *m);

void cadaclysm_fem_mesh_free(struct CadaclysmFemMesh *m);
]]
