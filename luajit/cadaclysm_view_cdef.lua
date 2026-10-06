-- Generated from crates/cadaclysm-view-capi/include/cadaclysm_view.h by gen_cdef.py. Do not edit; rerun the script.
return [[

static const uint32_t CADACLYSM_VIEW_ABI_MAJOR = 1;

static const uint32_t CADACLYSM_VIEW_ABI_MINOR = 4;

static const uint32_t CADACLYSM_VIEW_WINDOW_WIN32 = 1;

static const uint32_t CADACLYSM_VIEW_WINDOW_XLIB = 2;

static const uint32_t CADACLYSM_VIEW_WINDOW_XCB = 3;

static const uint32_t CADACLYSM_VIEW_WINDOW_WAYLAND = 4;

static const uint32_t CADACLYSM_VIEW_WINDOW_APPKIT = 5;

static const uint32_t CADACLYSM_VIEW_SURFACES_EXACT = 0;

static const uint32_t CADACLYSM_VIEW_SURFACES_TRIANGLES = 1;

static const uint32_t CADACLYSM_VIEW_BACKEND_ANY = 0;

static const uint32_t CADACLYSM_VIEW_BACKEND_VULKAN = 1;

static const uint32_t CADACLYSM_VIEW_BACKEND_D3D12 = 2;

static const uint32_t CADACLYSM_VIEW_BACKEND_METAL = 3;

static const uint32_t CADACLYSM_VIEW_STANDARD_TOP = 0;

static const uint32_t CADACLYSM_VIEW_STANDARD_FRONT = 1;

static const uint32_t CADACLYSM_VIEW_STANDARD_RIGHT = 2;

static const uint32_t CADACLYSM_VIEW_STANDARD_ISO = 3;

static const uint32_t CADACLYSM_VIEW_LAYER_SURFACES = 0;

static const uint32_t CADACLYSM_VIEW_LAYER_EDGES = 1;

static const uint32_t CADACLYSM_VIEW_LAYER_CURVES = 2;

static const uint32_t CADACLYSM_VIEW_LAYER_ISOCURVES = 3;

static const uint32_t CADACLYSM_VIEW_LAYER_GRID = 4;

static const uint32_t CADACLYSM_VIEW_GRID_NONE = 0;

static const uint32_t CADACLYSM_VIEW_GRID_TOP = 1;

static const uint32_t CADACLYSM_VIEW_GRID_FRONT = 2;

static const uint32_t CADACLYSM_VIEW_GRID_RIGHT = 3;

static const uint32_t CADACLYSM_VIEW_EVENT_DOWN = 1;

static const uint32_t CADACLYSM_VIEW_EVENT_MOVE = 2;

static const uint32_t CADACLYSM_VIEW_EVENT_UP = 3;

static const uint32_t CADACLYSM_VIEW_EVENT_CANCEL = 4;

static const uint32_t CADACLYSM_VIEW_EVENT_WHEEL = 5;

static const uint32_t CADACLYSM_VIEW_EVENT_KEY = 6;

static const uint32_t CADACLYSM_VIEW_POINTER_MOUSE = 0;

static const uint32_t CADACLYSM_VIEW_POINTER_TOUCH = 1;

static const uint32_t CADACLYSM_VIEW_POINTER_PEN = 2;

static const uint32_t CADACLYSM_VIEW_BUTTON_LEFT = 0;

static const uint32_t CADACLYSM_VIEW_BUTTON_MIDDLE = 1;

static const uint32_t CADACLYSM_VIEW_BUTTON_RIGHT = 2;

static const uint32_t CADACLYSM_VIEW_INPUT_CLOSE = 1;

static const uint32_t CADACLYSM_VIEW_INPUT_PICKED = 2;

static const uint32_t CADACLYSM_VIEW_OPEN = 1;

static const uint32_t CADACLYSM_VIEW_CLOSED = 2;

static const uint32_t CADACLYSM_VIEW_LOD_DETAILED = 0;

static const uint32_t CADACLYSM_VIEW_LOD_SMOOTH = 1;

typedef struct CadaclysmView CadaclysmView;

typedef struct CadaclysmViewWindow {

  uint32_t size;

  uint32_t kind;

  void *window;

  uint64_t window_id;

  void *display;

  uint32_t width;
  uint32_t height;
} CadaclysmViewWindow;

typedef struct CadaclysmViewOptions {

  uint32_t size;

  uint32_t surfaces;

  uint32_t backend;

  uint32_t y_up;

  const char *title;

  uint32_t width;
  uint32_t height;

  uint32_t offscreen;
} CadaclysmViewOptions;

typedef struct CadaclysmViewCamera {

  uint32_t size;
  float eye[3];
  float target[3];
  float up[3];

  uint32_t orthographic;
} CadaclysmViewCamera;

typedef struct CadaclysmViewPick {

  uint32_t size;

  uint32_t item;

  uint32_t node;

  uint32_t face;
} CadaclysmViewPick;

typedef struct CadaclysmViewLod {

  uint32_t size;

  uint32_t min_triangles;

  uint32_t motion;
} CadaclysmViewLod;

typedef struct CadaclysmViewViewport {

  uint32_t size;

  uint32_t rect[4];

  float view[16];

  float projection[16];
  float eye[3];

  uint32_t grid;
} CadaclysmViewViewport;

typedef struct CadaclysmViewEvent {

  uint32_t size;

  uint32_t kind;
  uint32_t pointer_id;

  uint32_t pointer;

  uint32_t button;

  uint32_t shift;

  float x;
  float y;

  float wheel_y;

  const char *key;

  uint32_t key_down;

  double time_ms;
} CadaclysmViewEvent;

typedef struct CadaclysmViewMesh {

  uint32_t size;

  const float *positions;
  uint32_t vertex_count;

  const float *normals;

  const uint32_t *indices;
  uint32_t index_count;

  const float *edges;
  uint32_t edge_count;

  const float *rgb;
} CadaclysmViewMesh;

typedef struct CadaclysmViewImage {

  uint32_t size;

  float corners[12];

  const uint8_t *rgba;
  uint32_t width;
  uint32_t height;

  float opacity;
  uint32_t flip_x;
  uint32_t flip_y;
} CadaclysmViewImage;

uint32_t cadaclysm_view_abi_version(void);

const char *cadaclysm_view_last_error(void);

const char *cadaclysm_view_name(void);

struct CadaclysmView *cadaclysm_view_create(const struct CadaclysmViewWindow *window,
                                            const struct CadaclysmViewOptions *options);

void cadaclysm_view_destroy(struct CadaclysmView *view);

uint32_t cadaclysm_view_pump(struct CadaclysmView *view, uint32_t timeout_ms);

bool cadaclysm_view_run(struct CadaclysmView *view,
                        struct CadaclysmViewCamera *camera_out,
                        struct CadaclysmViewPick *pick_out);

bool cadaclysm_view_resize(struct CadaclysmView *view, uint32_t width, uint32_t height);

bool cadaclysm_view_needs_draw(const struct CadaclysmView *view);

bool cadaclysm_view_draw(struct CadaclysmView *view);

bool cadaclysm_view_size(struct CadaclysmView *view, uint32_t *width, uint32_t *height);

bool cadaclysm_view_image(struct CadaclysmView *view, uint8_t *rgba, size_t capacity);

uint32_t cadaclysm_view_show(struct CadaclysmView *view, const void *scene);

bool cadaclysm_view_remove(struct CadaclysmView *view, uint32_t item);

bool cadaclysm_view_set_surfaces(struct CadaclysmView *view, uint32_t surfaces);

uint32_t cadaclysm_view_surfaces(const struct CadaclysmView *view);

void cadaclysm_view_orbit(struct CadaclysmView *view, float dx, float dy);

void cadaclysm_view_pan(struct CadaclysmView *view, float dx, float dy);

void cadaclysm_view_zoom(struct CadaclysmView *view, float steps);

bool cadaclysm_view_frame(struct CadaclysmView *view, uint32_t item);

bool cadaclysm_view_standard(struct CadaclysmView *view, uint32_t which);

void cadaclysm_view_set_orthographic(struct CadaclysmView *view, bool on);

bool cadaclysm_view_set_layer(struct CadaclysmView *view, uint32_t layer, bool on);

void cadaclysm_view_set_background(struct CadaclysmView *view, const float *rgb);

bool cadaclysm_view_set_lod(struct CadaclysmView *view, const struct CadaclysmViewLod *lod);

uint32_t cadaclysm_view_wake_ms(const struct CadaclysmView *view);

bool cadaclysm_view_set_node_visible(struct CadaclysmView *view,
                                     uint32_t item,
                                     uint32_t node,
                                     bool visible);

bool cadaclysm_view_set_node_color(struct CadaclysmView *view,
                                   uint32_t item,
                                   uint32_t node,
                                   const float *rgba);

bool cadaclysm_view_set_node_highlight(struct CadaclysmView *view,
                                       uint32_t item,
                                       uint32_t node,
                                       const float *rgba);

bool cadaclysm_view_set_viewports(struct CadaclysmView *view,
                                  const struct CadaclysmViewViewport *viewports,
                                  uint32_t count);

void cadaclysm_view_request_pick(struct CadaclysmView *view,
                                 uint32_t x,
                                 uint32_t y);

void cadaclysm_view_request_pick_in(struct CadaclysmView *view,
                                    uint32_t viewport,
                                    uint32_t x,
                                    uint32_t y);

bool cadaclysm_view_pick_result(struct CadaclysmView *view, struct CadaclysmViewPick *out);

bool cadaclysm_view_frame_node(struct CadaclysmView *view, uint32_t item, uint32_t node);

void cadaclysm_view_look(struct CadaclysmView *view, float dx, float dy);

void cadaclysm_view_dolly(struct CadaclysmView *view, float ratio);

uint32_t cadaclysm_view_input(struct CadaclysmView *view, const struct CadaclysmViewEvent *event);

uint32_t cadaclysm_view_show_mesh(struct CadaclysmView *view, const struct CadaclysmViewMesh *mesh);

uint32_t cadaclysm_view_show_lines(struct CadaclysmView *view,
                                   const float *segments,
                                   uint32_t segment_count,
                                   const float *rgb);

uint32_t cadaclysm_view_show_curves(struct CadaclysmView *view,
                                    const float *beziers,
                                    uint32_t curve_count,
                                    const float *rgb);

uint32_t cadaclysm_view_show_image(struct CadaclysmView *view,
                                   const struct CadaclysmViewImage *image);

bool cadaclysm_view_set_colour(struct CadaclysmView *view, uint32_t item, const float *rgb);

bool cadaclysm_view_set_xray(struct CadaclysmView *view, uint32_t item, bool on);

bool cadaclysm_view_set_face_colours(struct CadaclysmView *view,
                                     uint32_t item,
                                     const uint32_t *faces,
                                     const float *rgba,
                                     uint32_t count);

bool cadaclysm_view_set_placement(struct CadaclysmView *view, uint32_t item, const double *matrix);

bool cadaclysm_view_set_node_transforms(struct CadaclysmView *view,
                                        uint32_t item,
                                        const double *transforms,
                                        uint32_t count);

uint32_t cadaclysm_view_show_solid(struct CadaclysmView *view,
                                   const void *solid,
                                   double tolerance,
                                   const float *rgb);
]]
