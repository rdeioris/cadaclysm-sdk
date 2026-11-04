# Cadaclysm blacksmith: a modelling guide for language models

**For cadaclysm 0.12.0.** The API below is this release's: use it with the wrappers and libraries of 0.12.0.

> This file teaches a language model (ChatGPT, Gemini, Claude or any other) to write Python
> that builds exact solid CAD parts with the cadaclysm modelling kernel, the *blacksmith*,
> and turns parts into G-code with its CAM calls.
> Give it to the model whole, as a file or pasted text, then ask for parts in plain language.
> It is generated from the Python wrapper's own source and the cadaclysm documentation, so
> every class, method and argument named here exists. The latest copy is always at
> https://cadaclysm.blitter.studio/llms-full.txt; each release attaches the copy for that version.

## Instructions for the model

You are an expert with `cadaclysm_blacksmith`, and this guide is your reference. The user may
ask for anything it covers: designing a part, changing one, machining it, explaining how the
kernel works, reviewing a script, comparing ways to build something. Answer as an experienced
CAD engineer would, in the form the question calls for. Whenever your answer includes code,
these rules hold; where the user asks for a different form (a fragment, other units, no STEP
file), their request wins over rules 1 and 6:

1. Write **complete, runnable scripts**: the imports, then every dimension as a named
   variable at the top (in millimetres unless the user says otherwise), then the
   construction, then `part.step("<name>.stp")` to write the result. The notebook the user
   may run it in also shows the value of the last line, so a script may end on the solid.
   For machining, end instead by writing the job's programs (see *Machining*).
2. Use **only** the classes, methods and arguments listed in the API reference below. Do not
   borrow names from CadQuery, build123d, OpenSCAD, FreeCAD or OCCT: they are different APIs.
3. Build the part the way a designer would: a base solid, then features added (`join`) and
   removed (`cut`), then edge finishing (`fillet`, `chamfer`) and hollowing (`shell`) last.
4. Pick faces and edges by their geometry (a `Selector`, or filtering `Solid.edges` by kind,
   direction, radius or position), never by a hard-coded index.
5. Say in a sentence or two how the part is built and which choices you made where the
   request left something open. Ask first only when the choice would change what the part
   is. If the user reports an error, read the kernel's message — it names what was refused --
   and fix that step.
6. When asked for a change, answer with the whole updated script, not a fragment, so it can
   be run as it stands.
7. When the user runs scripts in the browser notebook, end each on the finished solid, which
   the notebook draws, and do not use `Job.machine` there (see *Machining*).

## Running it

- **In the browser, nothing installed:** the Python notebook at https://cadaclysm.blitter.studio/notebook/ runs this
  same module over WebAssembly. Paste the script into a cell and run it; the solid on the last
  line is drawn, and `show(a, b, ...)` draws several.
- **On a machine:** `pip install cadaclysm`, then `python part.py`. The module is
  `cadaclysm.blacksmith`; `import cadaclysm_blacksmith` is the same module under its SDK name,
  which this guide uses. Without a licence file it runs fully and prints a one-line notice.
- Open the STEP it writes in any CAD program, or in the viewer at https://cadaclysm.blitter.studio/mobile_demo/.

## How the kernel thinks

- A **`Profile`** is a closed 2D outline with holes, drawn in its own sketch x/y: a
  rectangle, circle, slot, polygon, text, or a `Path` of lines, arcs, Beziers and NURBS.
- A **frame** places a sketch in space: an origin and three axes. The sketch is drawn in the
  frame's x/y and extruded along its z. `Frame.xy()`, `Frame.xz()`, `Frame.yz()` are the world
  planes (optionally through another origin), `Frame.at(point, normal)` any plane, and
  `solid.face_frame(face)` the plane of a face with z its outward normal.
- A **`Solid`** is an exact boundary representation: planes, cylinders, cones, spheres, tori
  and NURBS, never triangles. It comes from a primitive (`Solid.cuboid`, `Solid.cylinder`, ...)
  or from a profile on a frame (`Solid.extrude`, `revolve`, `loft`, `loft_through`, `sweep`,
  `pipe`, `coil`). Solids are **immutable**: every operation returns a new solid, so write
  `part = part.cut(hole)`.
- **Booleans** are explicit: `a.join(b)`, `a.cut(b)`, `a.common(b)`.
- **Finishing** works on edges and faces of the finished shape: `solid.edges` lists `Edge`
  records to filter and hand to `fillet(edges, r)` or `chamfer(edges, d)`; `shell(t, open=[face])`
  hollows; `push_pull(face, d)` moves a face.
- The **`Workplane`** chain is an optional sketch-and-extrude shorthand: start on a plane,
  build, pick a face with a `Selector`, move onto it, build the next feature there. Each build
  step *replaces* the chain's solid, so take `.solid()` and `join` the pieces yourself.
- A failure raises **`BuildError`** at the call that failed, with the kernel's reason:
  a profile that crosses itself, a fillet too large for its faces, a boolean with nothing left.

## Conventions

| What | Rule |
| --- | --- |
| Units | Plain numbers. Treat them as millimetres: `step()` writes `unit="mm"` unless told `"m"` or `"in"`. |
| Axes | Right-handed, Z up. `Frame.xy()`: sketch x = X, sketch y = Y, extrude along +Z. `Frame.xz()`: x = X, y = Z, extrude along **-Y**. `Frame.yz()`: x = Y, y = Z, extrude along +X. |
| Angles | **Radians** everywhere in modelling (`revolve`, `rotate`, `extrude_tapered`, `arc`, `regular_polygon`). Use `math.radians(deg)`, `math.pi`, `math.tau`. The one exception is a CAM `Tool`'s `ramp_angle`, in degrees. |
| An axis | A point and a direction: `((0, 0, 0), (0, 0, 1))` is the Z axis. |
| `Solid.cuboid(x, y, z)` | **Centred on the origin** in all three directions: it spans z from `-z/2` to `z/2`. |
| `Solid.cylinder(r, h)`, `Solid.cone(r, h)` | Centred on the Z axis, standing on z = 0, up to z = `h`. |
| `Solid.sphere(r)`, `Solid.torus(R, r)` | Centred on the origin; the torus goes round the Z axis. |
| `Solid.extrude(profile, frame, h)` | From the frame's plane `h` along its z. The profile sits where it was drawn in the sketch. |
| `Profile.rect(w, h)`, `Profile.circle(r)` | Centred on the sketch origin; `.translate(dx, dy)` moves them. |
| `Solid.revolve(profile, axis, angle)` | The sketch x is the distance from the axis and the sketch y the height along it, so the profile must keep x >= 0. |
| `Workplane.cuboid` | Centred on the workplane origin, so on a face you picked it sinks half into the solid. `Workplane.cylinder` and `Workplane.extrude` stand on the face. |
| Face frames | `face_frame` and `Workplane.workplane()` put the origin at the face's centre, z along the outward normal. |
| Lists | `fillet`, `chamfer`, `shell(open=...)` and `drop_faces` take a **list**, even of one edge or face. |

## Mistakes to avoid

- Degrees passed where radians are expected. `rotate(axis, 90)` turns 90 *radians* (the part
  ends up about 117 degrees round, with no error); `revolve(p, axis, 360)` is refused as more
  than a full turn. Write `math.radians(90)`, `math.pi / 2`, `math.tau`.
- Forgetting that `Solid.cuboid` is centred: a 10 mm tall box on a plate at z = 0 needs
  `.translate(0, 0, 5)` to sit on it (or extrude a `Profile.rect` from the plate's top instead).
- A cutting tool exactly flush with the material it should pass through. Make through-holes
  longer than the part and start them outside it (`Solid.cylinder(r, t + 2).translate(x, y, -1)`).
- Discarding a result: `part.cut(hole)` returns the cut part and leaves `part` unchanged.
- Hard-coding face or edge numbers. They change with every operation; select by geometry
  after the operation that made them.
- A fillet or chamfer larger than the faces beside the edge allow, which is refused. Keep it
  smaller than the thinnest wall or face it touches.
- Profiles that cross or touch themselves, holes that touch the outline, or a revolve profile
  that crosses its axis: all refused, the message naming the loop.
- `Solid.loft` between profiles with different numbers of sides; it rules side to side.
  `loft_through` fits a smooth skin through any number of sections.
- Inventing an API. There is no `box()`, `hole()`, `union()`, `difference()` or `sketch()`:
  use `Solid.cuboid`, `cut` with a cylinder, `join`, `cut`, and `Profile` + `Solid.extrude`.

## Machining (CAM): from a part to G-code

The same module plans 2.5D milling for a 3-axis machine and writes **Grbl 1.1** G-code.

- **`Tool`**: `Tool.flat` (a flat end mill), `Tool.ball` (a ball end mill) and `Tool.drill`.
  Each takes its Grbl tool number (1..255, the `T` word), then diameter and flute length in mm,
  feed and plunge in **mm/min**, and spindle speed in rpm (a drill has no plunge). A mill ramps
  into its cuts at `ramp_angle` **degrees** (3 by default).
- **`Stock`**: the block of material, an axis-aligned box. `Stock.box(min, max)` takes two
  corners; `Stock.around(part, margin)` wraps a solid, its bottom at the part's lowest Z.
- **`Job(stock, safe_z, ...)`**: the operations, in the order you add them. `safe_z` is the
  absolute Z of every rapid move and must be above the stock's top. The job changes in place:
  `job.face(...)`, `job.pocket(...)` and the rest return nothing.
- **Operations**, all in world coordinates, Z up. A `Profile` is read in world X/Y, as drawn
  in its sketch, and `top` and `bottom` are absolute Z values.
  - `face(tool, z, stepover, stepdown)` skims the stock's top down to `z`.
  - `pocket(tool, profile, top, bottom, stepover, stepdown)` clears inside a profile, leaving
    its holes standing as islands. `stepover` is at most the tool's radius.
  - `contour(tool, profile, top, bottom, side="outside" | "inside" | "on", stepdown)` follows an
    outline: a profile cut out of the stock, or the wall of a pocket.
  - `drill(drill_tool, [(x, y), ...], top, bottom, peck=None)` drills holes, pecking if asked.
- **Automatic**: `job.machine(part, end_mill, drills=[...])` reads a solid lying inside the
  stock by slicing it at each Z level, then adds the face, pockets and drillings that make it.
  It returns a `Report` of what the tools cannot reach: corners too tight for the end mill,
  holes no drill matches, slopes cut as steps, undercuts. It never emits a cut that would
  gouge the part. `print(report)` gives one line per item, or "nothing left uncut". It leaves a
  `skin` (0.3 mm by default) at the bottom so the part stays attached to the stock.
- **Output**: `job.gcode()` returns one `Program` per run of operations sharing a tool (T1,
  T2, T1 gives three programs). Write each `program.text` to `program.name + ".nc"`.
  `job.write_camotics("part.camotics")` writes the programs plus a CAMotics project for
  simulating the cut.
- **In the browser notebook**, `Job.machine`, `Job.operations` and `Report` are not available
  yet (they need a newer WebAssembly build); run those on a machine. The manual operations and
  `gcode()` work in both.

Machining mistakes to avoid:

- Order: drill and pocket before the final outside `contour`. Once the contour cuts through, the
  part is loose.
- Depths are absolute Z, not depths below the top. With the stock top at z = 0, a pocket 4 deep
  is `top=0, bottom=-4`.
- A `pocket` stepover larger than the tool's radius, a `face` stepover larger than its diameter,
  or a pocket narrower than the tool are all refused. So is a `safe_z` at or below the stock's
  top, and a drill passed where a mill is expected (or the reverse).
- Feeds and speeds are the user's machine's business. When the request gives none, pick
  conservative values, give them names at the top of the script, and say so.

## Worked examples: from a request to a script

Each opens with the request as a user would word it.

### An L-bracket

*Request:* A wall bracket: an L of 4 mm plate, 60 mm wide, a 40 mm leg on the floor and a 30 mm leg up the wall, the inside of the bend rounded 3 mm, and two 5 mm holes through each leg.

```python
import math
from cadaclysm_blacksmith import Frame, Profile, Solid

# Dimensions, in mm.
width = 60        # along X
base = 40         # the horizontal leg, along +Y
height = 30       # the upright leg, up +Z
t = 4             # plate thickness
bend = 3          # inside corner radius
hole_r = 2.5      # 5 mm holes

# The L as a side view on the YZ plane (sketch x = world Y, sketch y = world Z), its
# inside corner rounded in the sketch: corner k is where segment k ends, and the
# inside corner is where segment 2, (base, t) -> (t, t), ends.
section = Profile.polygon([(0, 0), (base, 0), (base, t), (t, t), (t, height), (0, height)])
section = section.round(bend, corners=[2])
bracket = Solid.extrude(section, Frame.yz(), width)       # from x = 0 to x = width

# Two holes down through the base, two through the upright (drilled along +Y).
for x in (width / 4, 3 * width / 4):
    down = Solid.cylinder(hole_r, t + 2).translate(x, (base + t) / 2, -1)
    across = Solid.extrude(Profile.circle(hole_r), Frame.at((x, -1, (height + t) / 2), (0, 1, 0)), t + 2)
    bracket = bracket.cut(down).cut(across)

bracket.step("bracket.stp")
```

### A flanged hub

*Request:* A flanged hub: a 90 mm disc 10 mm thick with a 50 mm hub rising to 30 mm overall, a 30 mm bore through both, the hub-to-disc joint rounded 3 mm, and six 8 mm bolt holes on a 70 mm circle.

```python
import math
from cadaclysm_blacksmith import Profile, Solid

# Dimensions, in mm.
flange_r, flange_t = 45, 10     # the disc
hub_r, hub_h = 25, 30           # the hub standing on it, overall height hub_h
bore_r = 15
bolts, bolt_circle_r, bolt_r = 6, 35, 4
joint_r = 3                     # round where the hub meets the disc

# Half-section as (radius, height), revolved a full turn about Z.
section = Profile.polygon([(bore_r, 0), (flange_r, 0), (flange_r, flange_t),
                           (hub_r, flange_t), (hub_r, hub_h), (bore_r, hub_h)])
part = Solid.revolve(section, ((0, 0, 0), (0, 0, 1)), 2 * math.pi)

# The hub-to-disc joint: circular edges of the hub's radius, lying at the disc's top.
joint = [e for e in part.edges
         if e.kind == "circle" and abs(e.curve.radius - hub_r) < 1e-6
         and abs(e.curve.origin[2] - flange_t) < 1e-6]
part = part.fillet(joint, joint_r)

# The bolt circle: one cylinder cut per hole, a little longer than the disc is thick.
for i in range(bolts):
    a = 2 * math.pi * i / bolts
    hole = Solid.cylinder(bolt_r, flange_t + 2).translate(
        bolt_circle_r * math.cos(a), bolt_circle_r * math.sin(a), -1)
    part = part.cut(hole)

part.step("flange.stp")
```

### A plate, machined operation by operation

*Request:* G-code for an 80 x 50 plate 12 mm thick with 5 mm corner radii, cut from a slightly larger block: face the top, a 40 x 20 pocket 4 mm deep in the middle, four 5 mm holes through at (±30, ±15), then cut the outline free. 6 mm end mill, 5 mm drill.

```python
from cadaclysm_blacksmith import Job, Profile, Stock, Tool

# Dimensions in mm, feeds in mm/min. The finished top is z = 0, so depths are negative.
plate_x, plate_y, plate_t, plate_corner = 80, 50, 12, 5
pocket_x, pocket_y, pocket_depth, pocket_corner = 40, 20, 4, 3
hole_centres = [(-30, -15), (30, -15), (30, 15), (-30, 15)]

# The block: 5 mm spare round the plate, 1 mm over its top and under its bottom.
stock = Stock.box((-45, -30, -plate_t - 1), (45, 30, 1))
job = Job(stock, safe_z=10, name="plate")

mill = Tool.flat(1, 6, 20, feed=800, plunge=200, rpm=12000)    # number, diameter, flute length
drill = Tool.drill(2, 5, 30, feed=150, rpm=3000)

job.face(mill, 0, stepover=4, stepdown=1)                             # the top, down to z = 0
job.pocket(mill, Profile.rect(pocket_x, pocket_y).round(pocket_corner), 0, -pocket_depth,
           stepover=2.5, stepdown=1.5)
job.drill(drill, hole_centres, 0, -plate_t - 0.5, peck=3)             # through, 0.5 into the spare
job.contour(mill, Profile.rect(plate_x, plate_y).round(plate_corner), 0, -plate_t - 0.5,
            side="outside", stepdown=2)                               # last: this cuts it free

# One Grbl program per run of a tool: T1, then T2, then T1 again.
for program in job.gcode():
    with open(program.name + ".nc", "w") as f:
        f.write(program.text)
```

### A block, machined from its model

*Request:* Model a 60 x 40 x 15 block with a 30 x 16 pocket 6 mm deep in its top (4 mm corners) and two 6 mm holes through, 44 mm apart, then let the kernel plan the machining from 3 mm oversize stock with a 6 mm end mill and a 6 mm drill.

```python
from cadaclysm_blacksmith import Frame, Job, Profile, Solid, Stock, Tool

# Dimensions in mm, feeds in mm/min.
length, width, height = 60, 40, 15
pocket_l, pocket_w, pocket_depth, pocket_corner = 30, 16, 6, 4
hole_r, hole_x = 3, 22
margin = 3                                     # stock round the part and over its top

part = Solid.extrude(Profile.rect(length, width), Frame.xy(), height)
pocket = Solid.extrude(Profile.rect(pocket_l, pocket_w).round(pocket_corner),
                       Frame.xy((0, 0, height - pocket_depth)), pocket_depth + 1)
part = part.cut(pocket)
for x in (-hole_x, hole_x):
    part = part.cut(Solid.cylinder(hole_r, height + 2).translate(x, 0, -1))

stock = Stock.around(part, margin)
job = Job(stock, safe_z=height + margin + 10, name="block")
end_mill = Tool.flat(1, 6, 25, feed=900, plunge=250, rpm=12000)
drill = Tool.drill(2, 2 * hole_r, 30, feed=150, rpm=3000)

# The kernel finds the face, the pocket levels and the holes; the report lists what it could
# not cut (a corner tighter than the end mill, a hole no drill matches), or nothing.
report = job.machine(part, end_mill, drills=[drill], peck=3)
print(report)
job.write_camotics("block.camotics")          # the programs, and a project to simulate them
```

## More examples

The parts on https://cadaclysm.blitter.studio/examples.html, each a whole program that writes a STEP file.

### Plate with a boss: Join, cut, fillet

A 120 × 80 × 14 plate, a boss joined on its top face, an 11 mm bore cut through both, the four vertical corners rounded at 12. Every face is a plane or a cylinder, the corner fillets included; the STEP says so.

```python
from cadaclysm_blacksmith import Axis, Profile, Selector, Workplane

plate = Workplane.xy().extrude(Profile.rect(120, 80), 14).solid()
boss = (Workplane.from_solid(plate)
        .faces(Selector.max(Axis.Z)).workplane()
        .extrude(Profile.circle(22), 26).solid())
part = plate.join(boss)

bore = Workplane.xy().extrude(Profile.circle(11), 60).solid().translate(0, 0, -10)
part = part.cut(bore)

# The plate's four vertical corners: the lines along Z between two planes
# (the boss has vertical seams too, but those lie on its cylinder).
corners = [e for e in part.edges
           if e.is_line and abs(e.direction[2]) > 0.99
           and all(part.face_kind(f) == "plane" for f in e.faces)]
part = part.fillet(corners, 12)
part.step("plate.stp")
```

### Rounded box: Fillet every edge

A 20 mm cube with its twelve edges rounded at 2 in one call, which is the whole of the program. The twelve bands are cylinders and the eight corners where three of them meet are patches of a sphere.

```python
from cadaclysm_blacksmith import Solid

box = Solid.cuboid(20, 20, 20)
part = box.fillet(box.edges, 2)
part.step("box-fillet-all.stp")
```

### Bevelled box: Chamfer every edge

The same cube with every edge cut back 2 along both its faces. Twelve bevels and eight triangular corners, twenty-six faces in all and every one of them a plane.

```python
from cadaclysm_blacksmith import Solid

box = Solid.cuboid(20, 20, 20)
part = box.chamfer(box.edges, 2)
part.step("box-chamfer-all.stp")
```

### Perforated plate: Cut, twenty-four times

A 60 × 40 × 4 plate with a grid of six by four holes, each a short cylinder cut in its turn from an ordinary Python loop. The solid stays closed through every cut, and the STEP carries each hole as two half-cylinders between the plate's faces.

```python
from cadaclysm_blacksmith import Profile, Solid, Workplane

plate = Solid.cuboid(60, 40, 4).translate(30, 20, 2)

# Six by four holes of radius 2.5, each a short cylinder cut through the plate.
for i in range(6):
    for j in range(4):
        hole = Workplane.xy().extrude(Profile.circle(2.5), 6).solid()
        plate = plate.cut(hole.translate(7 + 9.2 * i, 7 + 8.7 * j, -1))

plate.step("plate-holes.stp")
```

### Hollow box: Shell, then cut

A 30 mm cube shelled to 3 mm walls, which leaves a closed void inside, and a window cut through the front wall to open it. The inner faces are the outer ones offset inwards; the window's four faces run between the two.

```python
from cadaclysm_blacksmith import Solid

box = Solid.cuboid(30, 30, 30)
hollow = box.shell(3)

# A window through the front wall, to see the void the shell left.
window = Solid.cuboid(10, 8, 10).translate(0, -15, 0)
part = hollow.cut(window)
part.step("hollow-box-window.stp")
```

### Bottle: Revolve a spline

A bottle's side drawn as one degree-3 spline in the x/z half-plane, closed to the axis with three lines, and turned a full circle about Z. The side is one surface of revolution and the two caps are discs.

```python
import math
from cadaclysm_blacksmith import Profile, Solid

# The bottle's side, a degree-3 spline in the x/z half-plane (x the radius),
# closed along the axis so the ends are capped flat.
side = [(7.238, 1.498), (9.221, 3.368), (10.868, 15.965), (7.306, 22.771),
        (1.909, 24.951), (3.059, 33.424), (3.591, 33.377), (4.0, 34.0)]
knots = [0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 6, 6, 6]
profile = (Profile.path((6, 0)).nurbs_to(side, knots, 3)
           .line_to(0, 34).line_to(0, 0).line_to(6, 0).end())

bottle = Solid.revolve(profile, ((0, 0, 0), (0, 0, 1)), 2 * math.pi)
bottle.step("revolve-bottle.stp")
```

### Spline prism: Extrude a spline

A closed degree-3 spline drawn on the XY plane and pulled up 15. Three faces: the spline's wall, exact in the STEP as the surface it is, and the two flat caps.

```python
from cadaclysm_blacksmith import Profile, Workplane

# A closed degree-3 spline: the control points after the start, the start last.
points = [(3.427, -2.292), (12.491, -5.040), (23.139, 3.080), (14.951, 16.721),
          (1.057, 14.037), (-0.434, 4.100), (0, 0)]
knots = [0, 0, 0, 0, 1, 2, 3, 4, 5, 5, 5, 5]
profile = Profile.path((0, 0)).nurbs_to(points, knots, 3).end()

prism = Workplane.xy().extrude(profile, 15).solid()
prism.step("spline-prism.stp")
```

### Swept ring: Sweep along an arc

A circle of radius 2 carried once round a circle of radius 10, the profile held normal to the path all the way. A torus, in other words, but arrived at by a sweep, whose path may equally be lines and arcs joined end to end.

```python
import math
from cadaclysm_blacksmith import Profile, Solid, SweepPath

# A full turn about Z, starting on the x axis at radius 10.
path = SweepPath.at((10, 0, 0)).arc((0, 0, 0), (0, 0, 1), 2 * math.pi)

# The profile sits at the path's start, its plane normal to the path (along +Y).
start = ((10, 0, 0), (0, 0, 1), (1, 0, 0), (0, 1, 0))
ring = Solid.sweep(Profile.circle(2), start, path)
ring.step("sweep-ring.stp")
```

### Pillar on a base: Join, then fillet the joint

A round pillar raised from the top face of a 30 × 30 × 5 base and joined to it, then the circle where they meet rounded at 2. The fillet is a torus band, tangent to the base's plane on one side and to the pillar's cylinder on the other.

```python
from cadaclysm_blacksmith import Axis, Profile, Selector, Solid, Workplane

base = Solid.cuboid(30, 30, 5)
pillar = (Workplane.from_solid(base)
          .faces(Selector.max(Axis.Z)).workplane()
          .extrude(Profile.circle(6), 12).solid())
part = base.join(pillar)

# The joint: the one round edge at the top of the base.
top = base.bounds[1][2]
joint = [e for e in part.edges
         if not e.is_line and abs(e.segments[0][0][2] - top) < 1e-6]
part = part.fillet(joint, 2)
part.step("pillar-fillet.stp")
```

## Notebook examples

The example notebooks of https://cadaclysm.blitter.studio/notebook/, cell by cell. `show(a, b, ...)` is the notebook's own call, drawing several shapes at once; a cell ending in a solid draws it.

### A plate, a boss and a bore

Extrude, join, cut, fillet — and the colours the cuts keep.

```python
from cadaclysm_blacksmith import Axis, Profile, Selector, Workplane

plate = Workplane.xy().extrude(Profile.rect(120, 80), 14).solid()
print("faces:", plate.faces, "bounds:", plate.bounds)
plate
```

```python
boss = (Workplane.from_solid(plate)
        .faces(Selector.max(Axis.Z)).workplane()
        .extrude(Profile.circle(22), 26).solid()
        .coloured("#c8a060"))           # a brass boss: the join keeps its faces brass
part = plate.join(boss)
part
```

```python
bore = (Workplane.xy().extrude(Profile.circle(11), 60).solid()
        .translate(0, 0, -10).coloured("#378add"))
part = part.cut(bore)                   # the hole's wall takes the tool's blue
show(part, bore.translate(150, 0, 0))   # the part, and the tool beside it
```

```python
corners = [e for e in part.edges
           if e.is_line and abs(e.direction[2]) > 0.99
           and all(part.face_kind(f) == "plane" for f in e.faces)]
rounded = part.fillet(corners, 12.0)
print(rounded.step_text()[:120])
rounded
```

### Outlines: paths, chains and splines

A profile drawn in pieces, closed, or through control points.

```python
from cadaclysm_blacksmith import Profile, Workplane

# An outline drawn in pieces, shuffled, the sides drawn against the arc: Profile.chain
# joins them in any order and either way round, and closes the loop.
top = Profile.path((-30, 40)).arc_to(30, 40, centre=(0, 40), ccw=False).end_open()
left = Profile.path((-30, 40)).line_to(-30, 0).end_open()
base = Profile.path((-30, 0)).line_to(30, 0).end_open()
right = Profile.path((30, 0)).line_to(30, 40).end_open()
arch = Profile.chain([top, base, left, right])
tile = Workplane.xy().extrude(arch, 6).solid()
show(arch, tile.translate(90, 0, 0))    # the outline, and the tile it extrudes to
```

```python
# An open outline closed: a hook drawn as a path ended open, and close_loop() adds the
# straight side from its end back to its start -- the open hook, the closed profile, and
# the solid that closed profile extrudes to.
hook = (Profile.path((0, 0)).line_to(40, 0).arc_to(60, 20, centre=(40, 20), ccw=True)
        .line_to(60, 40).end_open())
shut = hook.close_loop()
show(hook, shut.translate(80, 0), Workplane.xy().extrude(shut, 5).solid().translate(160, 0, 0))
```

```python
# A hexagon, a closed spline through four control points, and a rectangle with a hole in
# it: each drawn as its outline, and beside it the solid it extrudes to.
hexagon = Profile.regular_polygon((0, 0), 30, 6)
blob = Profile.spline([(-30, -20), (30, -20), (30, 20), (-30, 20)], closed=True)
washer = Profile.rect(60, 40).with_hole(Profile.circle(12))
show(hexagon, blob.translate(0, 70), washer.translate(0, 140),
     Workplane.xy().extrude(hexagon, 8).solid().translate(90, 0, 0),
     Workplane.xy().extrude(blob, 8).solid().translate(90, 70, 0),
     Workplane.xy().extrude(washer, 8).solid().translate(90, 140, 0))
```

### Press-pull, re-round, re-chamfer

Faces pushed and pulled, rounds and bevels made again.

```python
from cadaclysm_blacksmith import Axis, Profile, Selector, Workplane

# The plate of the first example in one go: a brass boss joined, a blue bore cut, the
# four upright corners rounded.
plate = Workplane.xy().extrude(Profile.rect(120, 80), 14).solid()
boss = (Workplane.from_solid(plate).faces(Selector.max(Axis.Z)).workplane()
        .extrude(Profile.circle(22), 26).solid().coloured("#c8a060"))
bore = Workplane.xy().extrude(Profile.circle(11), 60).solid().translate(0, 0, -10).coloured("#378add")
part = plate.join(boss).cut(bore)
corners = [e for e in part.edges
           if e.is_line and abs(e.direction[2]) > 0.99
           and all(part.face_kind(f) == "plane" for f in e.faces)]
rounded = part.fillet(corners, 12.0)
rounded
```

```python
# A face of a solid pushed out, as a face extrude does it: the plate's flat right
# side raised 20 along its normal into a tab, its top and bottom merged with the plate's.
# A negative distance pulls the face in instead.
side = rounded.select_face(Selector.max(Axis.X))
rounded.push_pull(side, 20)
```

```python
# A curved face pushed, as a press-pull does it: a cylinder's (or a cone's) face
# moves out along its normal, and the flat faces beside it follow -- the brass boss's wall
# pushed out 6 is a boss 12 wider, and the blue bore's pushed out 4, into the hole, a bore
# 8 narrower. Each wall's two halves move, and come back, as one.
def wall(solid, colour):
    """The face of `solid` on a cylinder, painted `colour`."""
    return next(f for f in range(solid.faces)
                if solid.face_kind(f) == "cylinder" and solid.face_colour(f) == colour)

fatter = rounded.push_pull(wall(rounded, boss.colour), 6)
fatter.push_pull(wall(fatter, bore.colour), 4)
```

```python
# A round made again, as a press-pull on a fillet face does it: one of the plate's
# rounded corners taken from 12 to 4 -- taken back to its sharp corner, rounded again --
# and, beside it, another taken off altogether, square again.
corners = [f for f in range(rounded.faces)
           if rounded.face_kind(f) == "cylinder" and rounded.face_colour(f) is None]
show(rounded.refillet(corners[0], 4), rounded.unfillet(corners[1]).translate(150, 0, 0))
```

```python
# A chamfer cut again, and one taken off, as a press-pull and a delete do it on a
# chamfer's face: the part's upright corners bevelled 8 -- one bevel cut again at 3, and
# beside it another taken off, its corner square again.
uprights = [e for e in part.edges
            if e.is_line and abs(e.direction[2]) > 0.99
            and all(part.face_kind(f) == "plane" for f in e.faces)]
bevelled = part.chamfer(uprights, 8)
bevels = [f for f in range(bevelled.faces)
          if bevelled.face_kind(f) == "plane" and all(abs(n) > 0.1 for n in bevelled.face_frame(f)[9:11])]
show(bevelled.rechamfer(bevels[0], 3), bevelled.unchamfer(bevels[1]).translate(150, 0, 0))
```

### Sweeps, pipes and coils

A profile carried along a path in space, a spring.

```python
import math
from cadaclysm_blacksmith import Frame, Profile, Solid, SweepPath

# A square carried up 40 and bent to run 30 along X -- a mitred L, every wall exact --
# and a circle carried round a quarter arc: an exact surface of revolution.
bend = SweepPath.at((0, 0, 0)).line_to((0, 0, 40)).line_to((30, 0, 40))
arc = SweepPath.at((0, 0, 0)).arc(centre=(25, 0, 0), axis=(0, 1, 0), angle=math.pi / 2)
show(Solid.sweep(Profile.rect(10, 10), Frame.xy(), bend),
     Solid.sweep(Profile.circle(5), Frame.xy(), arc).translate(70, 0, 0))
```

```python
# A path drawn as a 2D chain -- a line, an arc, a Bezier fitted with tangent arcs -- laid
# on the XY plane, and a pipe run along it: a rod, and above it a tube with walls 1.5.
route = (Profile.path((0, 0)).line_to(40, 0).arc_to(60, 20, centre=(40, 20), ccw=True)
         .bezier_to((60, 50), (100, 50), (100, 80)).end_open())
path = SweepPath.along(route, Frame.xy())
show(Solid.pipe(path, 4), Solid.pipe(path, 4, thickness=1.5).translate(0, 0, 30))
```

```python
# A circle coiled about Z: a spring of four turns, climbing 12 a turn. The profile is read
# as (distance from the axis, height along it), so the circle is drawn at x = 20.
Solid.coil(Profile.circle(3).translate(20, 0), ((0, 0, 0), (0, 0, 1)), 12, 4)
```

### Revolves, lofts and drafts

A section turned about an axis, walls between sections, a taper.

```python
import math
from cadaclysm_blacksmith import Frame, Profile, Solid

# A vase: its half-section drawn as (radius, height) and turned a full circle about Z --
# and the same section turned a quarter, drawn with its axis as a sketch draws them.
section = (Profile.path((0, 0)).line_to(24, 0).line_to(28, 30)
           .arc_to(28, 60, centre=(44, 45), ccw=False)      # a waist, bowing in
           .line_to(16, 70).line_to(0, 70).line_to(0, 0).end())
show(Solid.revolve(section, ((0, 0, 0), (0, 0, 1)), math.tau),
     Solid.revolve_in_plane(section, Frame.xy(), (0, 0), (0, 1), math.pi / 2).translate(90, 0, 0))
```

```python
# A loft between two rectangles is a frustum; through three circles -- wide, narrow,
# wide -- it runs smooth: a waist, round at every height.
frustum = Solid.loft(Profile.rect(40, 40), Frame.xy(), Profile.rect(16, 16), Frame.xy((0, 0, 30)))
waist = Solid.loft_through([(Profile.circle(r), Frame.xy((0, 0, z))) for r, z in ((20, 0), (10, 25), (20, 50))])
show(frustum, waist.translate(80, 0, 0))
```

```python
# An extrusion with a draft: the walls lean out 10 degrees as they rise, each one exact --
# a plane off a line, a cone off an arc.
Solid.extrude_tapered(Profile.slot((0, 0), 40, 10), Frame.xy(), 25, math.radians(10))
```

### Shells, sheets and thickening

A hollow box, a sheet punched and thickened, open walls given thickness.

```python
from cadaclysm_blacksmith import Axis, Frame, Profile, Selector, Solid

# A block shelled into an open box: walls 2 thick, its top face taken off so the hollow shows.
block = Solid.cuboid(40, 40, 30)
block.shell(2, open=[block.select_face(Selector.max(Axis.Z))])
```

```python
# A flat sheet -- one face, the outline's exact curves on its edges -- a hole punched
# through it by a cylinder, and the punched sheet thickened into a plate 3 thick.
sheet = Solid.face(Profile.rect(80, 50), Frame.xy())
punched = sheet.trim(Solid.cylinder(10, 20).translate(15, 0, -10), keep="outside")
show(sheet, punched.translate(0, 70, 0), punched.thicken(3).translate(0, 140, 0))
```

```python
# Open walls -- a rectangle extruded without caps -- thickened outward and inward, the
# corners on their mitres; and a tube from a circle's wall.
walls = Solid.extrude_open(Profile.rect(40, 24), Frame.xy(), 16)
show(walls, walls.thicken(2).translate(60, 0, 0), walls.thicken(-2).translate(120, 0, 0),
     Solid.extrude_open(Profile.circle(12), Frame.xy(), 30).thicken(1.5).translate(190, 0, 0))
```

### Booleans, splits and symmetry

What two solids share, a part split into bodies, mirrored and turned.

```python
import math
from cadaclysm_blacksmith import Frame, Profile, Solid

# A rod and a thinner one crossing it at right angles: what the two share, the two as one,
# and the rod with the thinner one cut through it.
rod = Solid.cylinder(20, 80).translate(0, 0, -40)
cross = Solid.cylinder(14, 80).translate(0, 0, -40).rotate(((0, 0, 0), (1, 0, 0)), math.pi / 2)
show(rod.common(cross), rod.join(cross).translate(100, 0, 0), rod.cut(cross).translate(200, 0, 0))
```

```python
# A part split by a plane into bodies -- a flat sheet splits by the whole plane it lies
# on -- each body a solid of its own, shown moved apart.
knob = Solid.sphere(25).join(Solid.cylinder(8, 50).translate(0, 0, 20))
halves = knob.split(Solid.face(Profile.rect(200, 200), Frame.xy((0, 0, 10))))
show(*[h.translate(0, 70 * i, 0) for i, h in enumerate(halves)])
```

```python
# A lug drawn on one side of the XZ plane and mirrored in it, the two joined into one
# symmetric part; then the part turned 30 degrees about Z, raised beside it.
lug = (Solid.extrude(Profile.rect(60, 30), Frame.xy(), 12).translate(0, 10, 0)
       .join(Solid.cylinder(8, 12).translate(30, 18, 0)))
whole = lug.join(lug.mirror(Frame.xz()))
show(whole, whole.rotate(((0, 0, 0), (0, 0, 1)), math.radians(30)).translate(0, 0, 30))
```

### Frames and faces

A sketch on any plane or face, a face as a sheet.

```python
import math
from cadaclysm_blacksmith import Axis, Frame, Profile, Selector, Solid, Workplane

# A frame is where a sketch lives: Frame.at is the plane through a point square to a
# normal, and a solid's face has a frame of its own. A peg grows out of the block's front
# face along that face's normal; a plate sits on a frame leaning 20 degrees off the top.
block = Workplane.xy().extrude(Profile.rect(60, 40), 30).solid()
front = block.select_face(Selector.min(Axis.Y))
peg = Solid.extrude(Profile.circle(6), block.face_frame(front), 15)
lean = Frame.at((0, 0, 30), (math.sin(math.radians(20)), 0, math.cos(math.radians(20))))
show(block.join(peg), Solid.extrude(Profile.rect(24, 24), lean, 6).translate(100, 0, 0))
```

```python
# A face on its own: the block's top as a sheet -- its surface, its edges' exact curves
# -- and the prism over it, the sheet raised 10 along its normal.
top = block.select_face(Selector.max(Axis.Z))
cap = block.face_sheet(top)
show(block, cap.translate(80, 0, 0), cap.extrude_faces(10).translate(160, 0, 0))
```

### SubD: a cage fired into a solid

A control cage pushed, pulled, creased and mirrored, then converted to exact NURBS.

```python
from cadaclysm_blacksmith import Solid, Subd

# A SubD cage: a box of 3 x 2 x 1 quads, whose smooth Catmull-Clark surface to_solid
# turns into an exact solid -- one NURBS face per patch, measured against the limit
# surface it stands for.
cage = Subd.cuboid((40, 30, 16), (3, 2, 1))
pebble, report = cage.to_solid()
print("cage faces:", len(cage.faces), "solid faces:", pebble.faces)
print(f"patches: {report.regular} exact, {report.refined} refined, deviation {report.deviation:.1e} of the diagonal")
pebble
```

```python
# A little fighter, built on its right half: mirror_on keeps the cage symmetric in X,
# every later edit landing on both sides. Faces are picked by where their centres sit.
def where(cage, test):
    p = cage.positions
    return [i for i, f in enumerate(cage.faces) if test(*p[f].mean(axis=0))]

def scale(sx, sy, sz, dx=0, dy=0, dz=0):
    return [[sx, 0, 0, dx], [0, sy, 0, dy], [0, 0, sz, dz], [0, 0, 0, 1]]

def moved(cage, m):
    return cage.transform(cage.selection, m)

def rim(cage, faces):
    loops = cage.faces
    return [(loops[i][k], loops[i][(k + 1) % len(loops[i])]) for i in faces for k in range(len(loops[i]))]

# The hull: a box cage subdivided once -- four quads for each, the smooth surface unchanged.
ship = Subd.cuboid((16, 48, 10), (2, 2, 1)).mirror_on("x").subdivide()
# The nose: the front faces drawn out and pinched.
ship = ship.transform(("faces", where(ship, lambda x, y, z: y < -18)), scale(0.45, 1, 0.55, 0, -12, -0.5))
# The wings: the lower side faces behind the middle pulled out 24, the tips thinned and
# swept back; each tip inset, and the inner face pushed out 2 into a wingtip pod.
ship = moved(ship.extrude(where(ship, lambda x, y, z: x > 6.5 and y > 0 and z < 0), 24), scale(1, 0.6, 0.45, 0, 10, -1))
ship = moved(ship.inset(ship.selection[1], 0.3), scale(1, 1, 1, 2, 0, 0))
# Twin fins: the outer deck faces at the tail pulled up 8 and raked back, the tips'
# outline creased to a sharp edge.
ship = moved(ship.extrude(where(ship, lambda x, y, z: x > 4.5 and y > 12 and z > 3), 8), scale(0.75, 0.8, 1, 1.5, 6, 0))
ship = ship.crease(rim(ship, ship.selection[1]))
# The canopy: the deck ahead of the wings raised 2.5, a smooth bubble.
ship = ship.transform(("faces", where(ship, lambda x, y, z: x < 3 and -12 < y < 0 and z > 3)), scale(1, 1, 1, 0, 0, 2.5))
fighter, fired = ship.to_solid()
print("half cage faces:", len(ship.faces), "solid faces:", fighter.faces, "refined patches:", fired.refined)
fighter
```

```python
# The converted fighter is an ordinary solid: a vent cut through each wing, the walls
# taking the tools' orange -- one cut, the two tools joined first.
vents = (Solid.cylinder(2.5, 20).translate(-19, 13, -10)
         .join(Solid.cylinder(2.5, 20).translate(19, 13, -10)).coloured("#ff7a2e"))
show(fighter.cut(vents), fighter.translate(80, 0, 0))
```

### A drone motor

A base, a bell with windows, a shaft and a nut; then the parts as an assembly with a joint.

```python
import math
from cadaclysm_blacksmith import Frame, Profile, Solid

# A drone motor: an orange base, a blue anodised bell with six windows, a shaft and a nut.
base = Solid.cylinder(15, 3).coloured("#ff6b0d")
bell = Solid.cylinder(15, 12).translate(0, 0, 3)
for k in range(6):
    a = k * math.pi / 3
    bell = bell.cut(Solid.cylinder(4, 10).translate(8.5 * math.cos(a), 8.5 * math.sin(a), 7))
bell = bell.coloured("#2f6fd6")
shaft = Solid.cylinder(2.5, 24).coloured("#9ea3ad")
nut = Solid.extrude(Profile.regular_polygon((0, 0), 4.6, 6), Frame.xy((0, 0, 15)), 4).coloured("#d6d8dc")

show(base, bell, shaft, nut)
```

```python
from cadaclysm_blacksmith import Assembly

# The same parts as an assembly: the bell turns on the base, a joint about Z.
motor = Assembly("motor")
motor.link("base", [motor.place(base, Frame.xy())])
motor.link("bell", [motor.place(p, Frame.xy()) for p in (bell, shaft, nut)])
motor.joint("bearing", "base", "bell")
motor.pair("bearing", "revolute", Frame.xy())
print(motor.step_text().count("REVOLUTE_PAIR"), "revolute pair")
```

```python
# A joint's value turns the mechanism: posed() returns a NEW assembly with the bell turned.
# (A joint inside a sub-assembly is named by its path.)
show(motor.posed({"bearing": 0.5}))
```

### SPARKY-01, a combat robot

A wedge hull, saw damage as cuts, a hollow shell and its mass; wheels, a spinner on a joint.

```python
import math
from cadaclysm_blacksmith import Frame, Mass, Profile, Solid

# SPARKY-01, in millimetres. The hull: a wedge side profile, extruded across the width.
W = 260.0
side = Profile.polygon([(-190, 18), (238, 18), (238, 34), (110, 112), (-190, 112)])
hull = Solid.extrude(side, Frame.at((0, W / 2, 0), (0, -1, 0), (1, 0, 0)), W)

# The top rear edge rounded, a slot through the nose for the weapon, four wheel wells.
rear = [e for e in hull.edges
        if e.is_line and abs(e.direction[1]) > 0.99 and e.segments[0][0][0] < -189
        and e.segments[0][0][2] > 100]
hull = hull.fillet(rear, 14.0)
hull = hull.cut(Solid.cuboid(190, 44, 260).translate(160, 0, 100))
# Every strip the wells leave -- behind the rear pair, above all four -- stays thicker
# than the two 6 mm walls the shell below gives it, or the hollow hull would cross itself.
for x in (-105, 105):
    for side_y in (-1, 1):
        hull = hull.cut(Solid.cuboid(132, 50, 100).translate(x, side_y * (W / 2 - 18), 40))
hull = hull.coloured("#ff7a2e")
hull
```

```python
# Battle damage: a horizontal spinner bit the flank twice. Each bite is a plain cut,
# a thin tilted disc overlapping the side -- the hole is real geometry. Both land on the
# full-height flank between the wheel wells, clear of them, the floor and the deck.
hurt = hull
for z, tilt in ((45, 0.12), (82, -0.10)):
    blade = Solid.cylinder(26, 10).rotate(((0, 0, 0), (1, 0, 0)), tilt)
    hurt = hurt.cut(blade.translate(0, W / 2 + 26 - 16, z - 5))

# Hollowed to 6 mm walls; the mass comes from the geometry (aluminium, kg per mm^3),
# measured to 0.1 % -- plenty for kilograms, and far quicker than the default.
ALU, STEEL, RUBBER = 2.7e-6, 7.85e-6, 1.2e-6
def kg(solid, density):
    return Mass.of(solid, 1e-3).mass(density)

shell = hurt.shell(6.0)
print(f"hull: solid {kg(hurt, ALU):.2f} kg, hollow {kg(shell, ALU):.2f} kg")
shell
```

```python
# Many holes at once: join the tools, then cut once -- one boolean instead of one per hole.
def cut_all(solid, tools):
    tools = list(tools)
    for t in tools[1:]:
        tools[0] = tools[0].join(t)
    return solid.cut(tools[0])

def around(n, r, z, tool, turn=0.0):
    """n copies of tool, on a circle of radius r at height z, each turned to face out."""
    for k in range(n):
        a = 2 * math.pi * k / n + turn
        yield tool.rotate(((0, 0, 0), (0, 0, 1)), a).translate(r * math.cos(a), r * math.sin(a), z)

# The running gear: one wheel -- a tyre with tread grooves, a recessed hub -- placed four times.
tyre = cut_all(Solid.cylinder(52, 36), [*around(14, 52, 18, Solid.cuboid(10, 6, 60)),
                                        Solid.cylinder(30, 10).translate(0, 0, 30)])
tyre = tyre.coloured("#1c1c1e")
hub = cut_all(Solid.cylinder(30, 6).translate(0, 0, 30),
              [Solid.cylinder(9, 20).translate(0, 0, 25), *around(5, 19, 25, Solid.cylinder(5, 20))])
hub = hub.coloured("#9aa0a6")
wheels = []                             # tyre, hub, tyre, hub, ...
for x in (-105, 105):
    for side_y in (-1, 1):
        out = ((0, 0, 0), (1, 0, 0)), -side_y * math.pi / 2    # the wheel's +Z turned to face out
        wheels += [p.rotate(*out).translate(x, side_y * W / 2, 52) for p in (tyre, hub)]

# The weapon: a three-tooth disc with lightening holes, on its axle in the nose slot.
disc = Solid.extrude(Profile.star((0, 0), 86, 58, 3).round(6.0), Frame.xy((0, 0, -11)), 22)
disc = cut_all(disc, [Solid.cylinder(12, 40).translate(0, 0, -20),
                      *around(3, 40, -20, Solid.cylinder(13, 40), turn=0.5)])
upright = ((0, 0, 0), (1, 0, 0)), -math.pi / 2                  # Z onto Y
disc = disc.rotate(*upright).translate(165, 0, 84).coloured("#cfd4da")
axle = Solid.cylinder(11, 120).rotate(*upright).translate(165, -60, 84).coloured("#6b7178")

# A bolted top plate, and the brain's sensor bar: two lenses and an antenna.
spots = [(px, py) for px in (-170, -60, 50) for py in (-100, 100)]
plate = cut_all(Solid.cuboid(250, 236, 6).translate(-60, 0, 116),
                [Solid.cylinder(6, 20).translate(px, py, 105) for px, py in spots])
plate = plate.coloured("#3e444c")
bolts = [Solid.cylinder(4.5, 9).translate(px, py, 113).coloured("#b8bec6") for px, py in spots]
head = Solid.cuboid(40, 110, 34).translate(-150, 0, 136)
forward = ((0, 0, 0), (0, 1, 0)), math.pi / 2                  # Z onto X
lenses = []
for py in (-28, 28):
    head = head.cut(Solid.cylinder(13, 10).rotate(*forward).translate(-133, py, 138))
    lenses.append(Solid.cylinder(11, 10).rotate(*forward).translate(-132, py, 138).coloured("#38d9ea"))
head = head.coloured("#2b3036")
antenna = Solid.cylinder(2.5, 90).translate(-160, 40, 153).join(Solid.sphere(6).translate(-160, 40, 245))
antenna = antenna.coloured("#ff3b30")

body = [shell, plate, head, antenna, *bolts, *lenses]
show(*body, *wheels, disc, axle)
```

```python
from cadaclysm_blacksmith import Assembly

# The robot as an assembly: the body, four wheels and the weapon, each a link; the
# spinner on a revolute joint about its axle (the pair frame's z, along Y).
robot = Assembly("sparky-01")
robot.link("body", [robot.place(p, Frame.xy()) for p in body])
robot.link("weapon", [robot.place(p, Frame.xy()) for p in (disc, axle)])
robot.joint("spinner", "body", "weapon")
robot.pair("spinner", "revolute", Frame.at((165, 0, 84), (0, 1, 0)))
for i in range(4):
    robot.link(f"wheel {i + 1}", [robot.place(p, Frame.xy()) for p in wheels[2 * i:2 * i + 2]])

# Its mass, material by material, straight from the geometry.
total = (sum(kg(p, ALU) for p in [shell, head, antenna, *lenses, *wheels[1::2]])
         + sum(kg(p, STEEL) for p in [plate, disc, axle, *bolts])
         + sum(kg(p, RUBBER) for p in wheels[0::2]))
print(f"SPARKY-01: {total:.2f} kg")

# A joint's value turns the weapon: posed() returns a new assembly, the disc spun 50 degrees.
show(robot.posed({"spinner": math.radians(50)}))
```

### Machining a plate

A part, a job that works out its own toolpaths, and the stock cut on the timeline.

```python
from cadaclysm_blacksmith import Frame, Job, Profile, Solid, Stock, Tool

# An 80 x 50 x 12 plate: rounded corners, a pocket round a boss, four through holes.
part = Solid.extrude(Profile.rect(80, 50).round(6), Frame.xy(), 12)
pocket = Profile.rect(40, 24).round(4).with_hole(Profile.circle(5))
part = part.cut(Solid.extrude(pocket, Frame.xy((0, 0, 7)), 5))
for x in (-32, 32):
    for y in (-17, 17):
        part = part.cut(Solid.cylinder(3, 12).translate(x, y, 0))
part
```

```python
# A job on a block 3 mm bigger all round: machine() works out the facing, the pockets
# and the drilling, and reports anything it could not cut.
end_mill = Tool.flat(1, 6, 20, 800, 200, 12000)
drill = Tool.drill(2, 6, 30, 150, 3000)
job = Job(Stock.around(part, 3), safe_z=25, name="plate")
print(job.machine(part, end_mill, drills=[drill]))
print([p.name for p in job.gcode()])
```

```python
# Play it under the view; Deviation in the colour menu shows how close each cell is to the part.
show(job, part=part)
```

## API reference (Python)

Every class and call a part needs, as the wrapper declares it. `Solid.name(...)` is called on the class, `solid.name(...)` on an instance; the other classes likewise. Frames and axes: pass a `Frame`, twelve numbers or four `(x, y, z)` triples for a frame, and six numbers or two triples for an axis.

### Module functions

The kernel's own library, licence, STEP and `.brep` writers. It is a separate shared library (`cadaclysm_blacksmith`) from the reader, with its own licence call; one licence file serves both.

```python
write_step(path: FilePath, solids: Sequence[Solid], schema: Schema = None, unit: Unit = 'mm') -> None
```
Write several solids as one STEP file, each its own body. `unit` is `mm`, `m` or `in`. `schema` is left out for AP203 (built in — no file needed; AP242 when any solid, face or edge is coloured, since AP203 has no colour entities), the name of another built-in schema such as AP242's `AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF` (AP214's `AUTOMOTIVE_DESIGN` cannot carry the writer's `mechanical_context`), or a custom EXPRESS schema: a path to its `.exp` or its text. Colours from `coloured` and `edges_coloured` are written as STEP styling wherever the schema has it, a solid's read back as the node's colour; a named schema without it writes the solids bare.

```python
write_step_assembly(path: FilePath, parts: Mapping[str, Solid], placements: Iterable[tuple[str, FrameLike]], schema: Schema = None, unit: Unit = 'mm') -> None
```
Write an assembly as one STEP file: `parts` names each solid, in its own coordinates, and each is written once as its own product; `placements` lists `(name, frame)` pairs, each an occurrence of that part at that frame (right-handed and orthonormal), all under one root product. A reader tessellates a part once however many times it is placed, and shows each placement under its part's name. `schema` and `unit` as `write_step`.

```python
write_brep(path: FilePath, solids: Sequence[Solid]) -> None
```
Write several solids as one OCCT `.brep` file, each its own solid under one compound (a single solid is the file's root): the exact surfaces and curves, with a curve in each face's own parameters for every edge, so Open CASCADE's `BRepTools::Read` gives a shape its `BRepCheck_Analyzer` finds valid. No unit is declared — a `.brep` carries none — so the numbers written are the numbers held. The library writes the file itself.

```python
write_sat(path: FilePath, solids: Sequence[Solid], unit: Unit = 'mm') -> None
```
Write several solids as one ACIS SAT file, each its own body: planes, cylinders, cones, spheres and tori as their own records, splines and swept surfaces as exact NURBS, in the layout Rhino's own exporter writes. `unit` is `mm`, `m` or `in` and goes into the header as millimetres per unit. The library writes the file itself, so a refusal names it.

```python
svg(things: Sequence[Solid | Profile], path: FilePath | None = None) -> str | None
```
Several solids and profiles' wireframe as one SVG, any mix and any order: a `<g id="solid-<i>">` per solid then a `<g id="profile-<i>">` per profile, each stroked in its own colour where it carries one — a solid's edge colour first, then its body colour (a face colour says nothing about a wireframe) — and the keywords' `stroke=` otherwise. The keywords are `Scene.svg`'s own: `view=` (front, back, left, right, top, bottom, iso), `az=`/`el=` over it, `up=` (default `z`: neither a solid nor a profile carries a convention of its own to default it from), `fov=` (0, the default, is orthographic), `size=`, `margin=`, `tolerance=`, `stroke=` and `background=` (`"#rgb"`, `"#rrggbb"` or a CSS colour name in every language, beside that language's own numeric form; `background=` `None` for transparent), `width=` (the stroke's, in page units), `edges=`, `curves=`, `isocurves=`, `polylines=` (which line sets are drawn; edges by default), and `silhouettes=` (also draw where each solid's surfaces turn away from the eye — the outline a sphere has no edge for, on by default: a sphere's and a torus's only curves are the seams where their one face meets itself, which are not edges of the body and are never drawn, so without it those two draw a blank page. A line set in its own right, so `silhouettes=` with `edges=` off draws the outline alone).

A list of solids alone draws exactly as it always did. The SVG is the drawing itself: with `path`, writes it to the file and returns `None`; without, returns the SVG text. Both lists empty raises `BuildError`; so does anything in them that is neither a solid nor a profile, a refused option, or a failed write.

```python
version() -> str
```
The version of the kernel library actually loaded.

```python
pair_freedom_count(kind: str) -> int
```
How many freedoms a pair kind has, so a caller can size `Assembly.pair()`'s `ranges`. 0 for an unknown name, and for `fully_constrained`, which has none.

```python
set_option(name: str, value: float) -> None
```
Set a kernel option, by its name, for the whole process from the next call on — every thread, every solid. The options are numbers under stable names, one call for all of them, so an option added later needs no new function:

`boolean.mesh_budget` (default 500000): the most triangles a boolean (join, cut, common, split) builds its trees from, its two solids' meshes together. Past it the boolean refuses with a tolerance error rather than running for minutes or hours. A whole number, at least 1, or infinity for no limit.

`boolean.finest_tolerance` (default 1e-8): the finest tolerance a boolean takes, as a share of how far its two solids reach; under it the boolean refuses before meshing anything. From 0 (no floor) to below 1.

`profile_boolean.point_budget` (default 8000000): the most points a profile boolean follows its two profiles' arcs and splines with. Past it the boolean refuses with a tolerance error; 8 million is about 128 MB. A whole number, at least 1, or infinity for no limit.

`measure.default_accuracy` (default 1e-7): the relative accuracy `Solid.mass()`, `Solid.edge_length()`, `Profile.length()` and the arc-length samples (`Solid.edge_point_at_length()`, `Profile.point_at_length()` and their divides) refine to when they are asked for 0, the default. Above 0 and below 1. `Solid.oriented_box()` has its own default, 1e-5, and does not read it.

A name that is not an option, or a value the option does not take, raises `BuildError` and changes nothing, saying which and what it takes.

```python
option(name: str) -> float
```
A kernel option's value, by its name: what `set_option` last set, else its default (see `set_option` for the names). A name that is not an option raises `BuildError`, listing the ones there are.

```python
boxes_apart(a: Box, frame_a: FrameLike, b: Box, frame_b: FrameLike) -> bool
```
True only if box `a` at `frame_a` and box `b` at `frame_b` cannot touch — a separating axis among the boxes' face normals and edge-direction crosses; touching is not apart. Sharper than moving each box (`Box.moved()`) and asking `Box.overlaps()`, which boxes the *result* on the world axes again and so can call two oriented boxes overlapping when they are not (two unit boxes, the second turned 45 degrees about z and moved 2.3 along x: their world boxes overlap, but the boxes themselves do not touch). `frame_a` or `frame_b` not twelve finite numbers or not rigid raises `BuildError`.

```python
clash(parts: Iterable[Solid], others: Iterable[Solid] | None = None, clearance: float = 0.0, tolerance: float = 0.05, allowed: Iterable[tuple[int, int]] = ()) -> list[Clash]
```
Every pair of `parts` — or, with `others`, every part of `parts` against every part of `others` — that penetrates, touches or lies within `clearance` of the other, as `Clash` rows, the solids as they stand. It is the question `Solid.closest()` and `Collider.check()` leave open: not how far apart two parts are, nor only whether they overlap, but which pairs are in trouble and how. A row's `kind` is decided in this order: `"penetrating"` where the volumes overlap; `"touching"` where the boundaries are within `tolerance` of each other; `"too_close"` where they are apart by more than `tolerance` but less than `clearance`; `"refused"` where the pair could not be decided. A pair further apart than `clearance` gives no row, and with `clearance` 0 there are no `"too_close"` rows. `tolerance` is the meshing tolerance, absolute, in model units (0.05 by default); a distance is exact to within it. In a row `a` indexes `parts` and `b` indexes `others` (or `parts` again, when there are no `others`; then `a < b`). Rows come in pair order. `allowed` is pairs of part indices never tested — designed contacts — each exactly two integers; with `others` a pair is (index in `parts`, index in `others`). A negative or non-finite `clearance`, a `tolerance` not positive and finite, an `allowed` pair that is not two indices or one out of range, an empty `others`, or a part that is not a closed solid raises `BuildError`; the kernel's own words are prefixed `clash:`. For the same parts moved pose after pose, build a `Collider` and ask `Collider.clash()`. Whether the parts meet on the way from one pose to the next is `swept_clash`'s question.

```python
swept_clash(parts: Iterable[Solid], poses: Iterable[Iterable[FrameLike]], others: Iterable[Solid] | None = None, other_poses: Iterable[Iterable[FrameLike]] | None = None, clearance: float = 0.0, tolerance: float = 0.05, resolution: float = 0.001, max_steps: int = 100000, allowed: Iterable[tuple[int, int]] = ()) -> list[SweptClash]
```
Every pair of `parts` — or, with `others`, every part of `parts` against every part of `others` — that penetrates, touches or comes within `clearance` of the other anywhere on a path, as `SweptClash` rows: `clash`'s question asked of the motion, not only of the poses. Each part is its own group: pose `k` of `poses` is one `Frame` (or twelve numbers) per part of `parts`, and pose `k` of `other_poses` one per part of `others`; `others` and `other_poses` go together, and the two have as many poses. The motion between poses, the guarantee, `resolution` and `max_steps` are `Collider.swept_clash()`'s; `clearance`, `tolerance` (the meshing tolerance, absolute, 0.05 by default) and `allowed` are `clash`'s, and a row's `a` indexes `parts`, its `b` `others` (or `parts` again; then `a < b`). Rows come in pair order. `others` without `other_poses` or the other way round, a different number of poses in the two, a pose with the wrong number of frames, an empty set, fewer than two poses, an `allowed` pair that is not two indices or one out of range, a part that is not a closed solid, or a bad frame, tolerance, `clearance`, `resolution` or `max_steps` raises `BuildError`; the kernel's own words are prefixed `swept_clash:`.

```python
thickness(solids: Iterable[Solid], maximum: float, sharp_angle: float = 0.0, tolerance: float = 0.01) -> list[Thickness]
```
Every wall-thickness reading within `maximum` on `solids`, measured against each other, as `Thickness` rows by body then vertex: a `ThicknessGauge` built at `tolerance` (0.01 by default), asked `ThicknessGauge.thickness()` once and freed. Build the gauge yourself to ask more than once. `maximum` not positive and finite, `sharp_angle` negative or not finite, or a `tolerance` not positive and finite raises `BuildError`, with the gauge call's own prefix (`thickness_gauge_new:`, `thickness_gauge_measure:`).

```python
mesh_thickness(meshes: Iterable[tuple[Sequence[Point3], Sequence[Sequence[int]]]], maximum: float, sharp_angle: float = 0.0) -> list[MeshThickness]
```
The wall-thickness rule on plain meshes, measured against each other, as `MeshThickness` rows by mesh then vertex. Each of `meshes` is a pair: its points, `(x, y, z)` each, and its triangles, three indices into its own points each. From a vertex P the thickness is the distance to the nearest triangle that opposes one of P's own triangles (their normals more than 89 degrees apart) with P on or behind its plane — not a ray cast along the normal. A triangle with a vertex exactly at P is skipped; if one of those meets P's own at an interior angle under `sharp_angle` radians, P is a knife edge and reads 0. A vertex with no such triangle, or one further than `maximum`, gives no row: readings are dropped, not clamped. At the sharp rims of faceted holes it can read the wall far too thin (the distance to a neighbouring facet), an open finding. A mesh that is not such a pair, a position not finite, a triangle naming a point past its mesh, `maximum` not positive and finite, or `sharp_angle` negative or not finite raises `BuildError`.

```python
closest_points(hay: 'Iterable[Point3] | numpy.ndarray', needles: 'Iterable[Point3] | numpy.ndarray', limit: float) -> list[list[int]]
```
For each of `needles`, the indices of the `hay` points within `limit` of it, nearest first and equal distances by index — one `RTree` over `hay` answers every needle. A point within exactly `limit` counts. A `limit` negative or NaN, then the first `hay` point and the first needle with a NaN or infinite coordinate, by index, raises `BuildError`.

```python
k_neighbors(hay: 'Iterable[Point3] | numpy.ndarray', needles: 'Iterable[Point3] | numpy.ndarray', k: int) -> list[list[int]]
```
For each of `needles`, the indices of the `k` nearest `hay` points, nearest first and equal distances by index (the smaller indices win a tie at the `k`-th place); every `hay` point when `k` is over their count. The first `hay` point and the first needle with a NaN or infinite coordinate, by index, or a `k` above 1,000,000, raises `BuildError`.

### Profile

```python
class Profile
```

A closed outline with holes, in its own x/y — what gets extruded, revolved, lofted or swept. Immutable: every method returns a new one.

Its loops must be simple: an outline that crosses or touches itself (a figure-eight, a vertex landing on another side), a hole that runs into the boundary, or two holes that overlap are refused by every call that builds a face or a closed solid, naming the loops — `extrude: hole 0 crosses the boundary`. The open calls (`extrude_open`, `revolve_open`, `sweep_open`, `loft_open`) build sheets, and take such a profile as it is.

```python
Profile.rect(w: float, h: float) -> Profile
```
A `w` × `h` rectangle centred on the origin.

```python
Profile.circle(r: float) -> Profile
```
A circle of radius `r` about the origin.

```python
Profile.slot(centre: Point2, length: float, r: float) -> Profile
```
A slot (stadium) `length` long overall, with end radius `r`, centred on `centre` and running along x. `length` must exceed `2 * r`.

```python
Profile.polygon(points: Iterable[Point2]) -> Profile
```
A closed polygon through the points, in order, its side back to the first point a segment of its own. At least three points.

```python
Profile.regular_polygon(centre: Point2, radius: float, sides: int, angle: float = 0.0) -> Profile
```
A regular polygon of `sides` sides (at least 3) on the circle of `radius` about `centre`, its first corner at `angle` radians from the sketch's x axis (0 by default), the rest counter-clockwise. More than a million sides raises `BuildError`.

```python
Profile.circumscribed_polygon(centre: Point2, radius: float, sides: int, angle: float = 0.0) -> Profile
```
A regular polygon of `sides` sides (at least 3) whose sides touch the circle of `radius` about `centre` — the polygon across flats, as a nut's hex is specified: its corners on the circle of `radius / cos(pi / sides)`, each side's midpoint on the circle of `radius`. The first corner is at `angle` radians from the sketch's x axis (0 by default), the rest counter-clockwise, **on the same rays as `Profile.regular_polygon()`'s corners** for the same `angle`, so the inscribed and circumscribed polygons of one circle nest corner to corner. More than a million sides raises `BuildError`.

```python
Profile.star(centre: Point2, outer: float, inner: float, points: int, angle: float = 0.0) -> Profile
```
A star of `points` tips (at least 3) on the circle of `outer` about `centre`, its inner corners on the circle of `inner` (positive, under `outer`), alternating: the first tip at `angle` radians from the sketch's x axis (0 by default), the rest counter-clockwise, each inner corner half a step on from the tip before it. `2 * points` straight sides; an `inner` not under `outer`, or more than a million points, raises `BuildError`.

```python
Profile.text(text: str, size: float = 10.0, font: str | os.PathLike[str] = '', halign: Literal['left', 'center', 'right'] = 'left', valign: Literal['baseline', 'bottom', 'center', 'top'] = 'baseline', spacing: float = 1.0, direction: Literal['ltr', 'rtl'] = 'ltr', font_bytes: bytes | None = None) -> list[Profile]
```
`text` set in a font, one profile per closed shape — a letter with its counters as holes (`o` one, `8` two; `i` is two profiles) — on the sketch plane, the baseline along x from the origin, each outline counter-clockwise and its holes clockwise, a curved side the font's own cubic Bezier kept exactly: an extruded `O` has curved walls, and writes to STEP as splines. `size` (10 by default) is roughly the height of a capital. `font` is a family, optionally with a style (`"Liberation Sans:style=Bold"`), a font file's path, or empty for the bundled Liberation Sans Regular — which also serves when the family is not found, so text never comes back empty; `font_bytes` a font file's bytes, used instead of `font` when given (a page or a phone fetches its own font). `halign` is `left` (default), `center` or `right`; `valign` `baseline` (default), `bottom`, `center` or `top`; `spacing` (1 by default) multiplies the gap between glyphs; `direction` `ltr` (default) or `rtl`. Glyphs are laid out one after another by their advance widths — no shaping, so Latin sets as expected and scripts that need ligatures or reordering do not. Empty text is an empty list. A size or spacing not positive and finite, an alignment or direction not one of those words, or font bytes that are not a font raises `BuildError`.

```python
Profile.spline(points: Iterable[Point2], degree: int = 3, weights: Iterable[float] | None = None, closed: bool = False) -> Profile
```
A spline of `degree` (3 by default) through the control polygon `points`, `weights` one per point or `None`. Open, it starts on the first point and ends on the last: an open chain, for `Solid.extrude_open()` or `Profile.chain()`. Closed, it is periodic — smooth through its own start, no corner there — and a closed profile. The degree is lowered to fit the points; a degree of zero, too few points (two open, three closed) or a weight not positive raises `BuildError`.

```python
Profile.path(start: Point2) -> Path
```
Start drawing an outline segment by segment at `start`; see `Path`.

```python
Profile.parabola(vertex: Point2, axis: Point2, focal: float, from_: float, to: float) -> Path
```
Start drawing on the arc of the parabola with `vertex`, axis direction `axis` and focal length `focal`, over the across-axis coordinates `from`..`to`: the path begins at the arc's first point and holds the arc as one conic segment — a reflector from rim to rim; `parabola((0, 0), (0, 1), 20, -50, 50)` is a dish 100 wide opening up. A zero axis, a focal length not positive and finite, or `from` not under `to` raises `BuildError`.

```python
Profile.chain(pieces: Iterable[Profile], tolerance: float = 1e-06) -> Profile
```
Open profiles — paths ended open — joined end to end into one: the forge's merge. They may come in any order and either way round: each next piece is the first of the rest with an end within `tolerance` (1e-6 by default) of either end of the chain so far, reversed where that makes it meet. Every segment is kept exactly — a line a line, an arc an arc, a spline the same spline. Closed where the chain's two ends meet, otherwise an open chain. A piece that is empty, has holes, is closed on its own or meets none of the others raises `BuildError` naming it by its index.

```python
Profile.from_loops(loops: Iterable[Profile]) -> Profile
```
Closed loops, in any order, as one profile: the loop enclosing the most area is the boundary and every other a hole in it, in the order given — a sketch's rectangle and the circles drawn inside it. Each loop is a closed profile with no holes of its own, wound either way; one that closes within rounding is closed exactly. A loop that is open, empty or encloses no area, loops that cross or touch, a hole outside the boundary, or one inside another hole (an island) raises `BuildError`, naming the loops by their index.

```python
profile.close_loop() -> Profile
```
This profile closed — the forge's sketch "close": where its last segment stops short of its start (a path ended open), a straight segment back to it; where it already comes back within 1e-9 of its extent, its last segment made to land on the start exactly. A closed profile comes back as it is, and holes are closed the same way.

```python
profile.pieces(cutters: Iterable[Profile], tolerance: float = 1e-06) -> list[Profile]
```
This curve cut where the `cutters` cross, touch or run along it — the sketch trim's pieces: in order along the curve from its start, each an open profile of portions of this one's own segments (a line's stretch a line, an arc's an arc, a spline's the same spline over part of its domain, nothing refitted). One piece, this curve, where nothing cuts it; a closed curve's piece round its start is one piece. Cuts closer than `tolerance` to each other fold onto one. A curve with no segments raises `BuildError`.

```python
profile.trim(cutters: Iterable[Profile], piece: int, tolerance: float = 1e-06) -> list[Profile]
```
This curve with piece `piece` of `Profile.pieces()` taken away — the sketch trim, the forge's: what is left, as open profiles. One for a closed curve (its other pieces run together from where the removed one ended), the stretches before and after for an open one, none where the piece was the whole curve. A piece the curve does not have raises `BuildError`.

```python
profile.with_hole(hole: 'Profile') -> Profile
```
This outline with `hole` cut out of it.

```python
profile.common(other: Profile, tolerance: float = 1e-06) -> list[Profile]
```
The region this outline and `other` share, both read in one plane, as a list of zero or more profiles — each boundary counter-clockwise, each hole clockwise, arcs and splines kept exact. An arc kept from an input can still come out split at that input's own seam point (two circles' lens is four arcs, one pair per circle) — exact, not an approximation. Two loops of a result may touch at a point (two holes whose corners meet, one from each input): a right point set that the verbs needing simple loops — `Solid.extrude()`, a boolean taking it as an input — refuse. Both must be closed and simple; no shared area is an empty list. A `tolerance` not positive and finite, an outline open or crossing itself, a `tolerance` too fine for these outlines (following their arcs and splines to a tenth of it would take more than 8 million points, about 128 MB), and, as a defect rather than an outcome, a result that fails to close, raises `BuildError`.

```python
profile.translate(dx: float, dy: float) -> Profile
```
This outline moved by (`dx`, `dy`).

```python
profile.rotate(centre: Point2, radians: float) -> Profile
```
This outline turned `radians` (counter-clockwise) about `centre`.

```python
profile.scale(centre: Point2, sx: float, sy: float) -> Profile
```
This outline scaled by `sx`, `sy` about `centre`. An arc stays an arc where the two are equal in size, and becomes exact conics (rational quadratics) otherwise; a negative factor mirrors across that axis, and a zero one raises `BuildError`.

```python
profile.mirror(point: Point2, direction: Point2) -> Profile
```
This outline reflected across the line through `point` along `direction`; each arc's sense turns. A zero `direction` raises `BuildError`.

```python
profile.transform2d(m: 'Sequence[float]') -> Profile
```
This outline under the 2D affine map `m`, six numbers row-major (2×3): `x' = m0·x + m1·y + m2`, `y' = m3·x + m4·y + m5`. Lines, Béziers, conics and NURBS map by their points, exactly; a singular map raises `BuildError`.

```python
profile.coloured(colour: Colour) -> Profile
```
A new outline coloured (r, g, b), each 0..1, `"#rgb"`, `"#rrggbb"` or a CSS colour name (`"tomato"`, `"RebeccaPurple"`): how it is drawn. The verbs that make a profile from one carry it (`translate`, `round`, `with_hole` keeps the outer's, `chain` and `from_loops` the first's); a solid made from it takes nothing — colour a solid with `Solid.coloured()`.

```python
profile.colour: tuple[float, float, float] | None  (property)
```
The outline's colour as (r, g, b), or none.

```python
profile.round(radius: float, corners: Iterable[int] | None = None, open: bool = False) -> Profile
```
This outline with its corners rounded by `radius`: where two straight segments meet, both are cut back and an exact arc tangent to both goes between them; a corner next to an arc or a spline is left as it is. With no `corners` every such corner is rounded, the holes' too; a list picks corners of the outline — corner `k` is where segment `k` ends. `open` reads the profile as an open chain whose two ends stay square. A radius that does not fit raises `BuildError` naming the corner.

```python
profile.to_arcs(tolerance: float = 0.01) -> Profile
```
This profile with every free-form side (a Bezier, a conic, a NURBS) replaced by lines and arcs within `tolerance` of it — what a G-code writer can say. Lines and arcs pass through as they are, every loop closes on itself exactly, holes are converted the same way. `tolerance` (0.01 by default) not positive and finite, or a spline that does not evaluate, raises `BuildError`.

```python
profile.offset(distance: float, tolerance: float = 0.01) -> list[Profile]
```
This profile grown by `distance` (shrunk where it is negative), as zero or more profiles, all lines and arcs: outward corners rounded by `|distance|`, holes moving against the boundary (a hole shrinks as the profile grows). Free-form sides are fitted to `tolerance` first (`Profile.to_arcs()`). A shrink that eats the whole profile is an empty list. A `distance` not finite, a `tolerance` (0.01 by default) not positive and finite, a loop with no sides, or loops that cross or touch, raises `BuildError`.

```python
profile.document_path() -> dict[str, Any]
```
This profile as its exact segments, as a `Document`'s `profile.path` node holds it: a record of its `start`, its `segments` (each a `line`, `arc`, `bezier`, `conic` or `nurbs` with its points, weights and knots, never flattened) and its `holes`. What `Document.add_profile()` puts in a document.

```python
profile.polylines(tolerance: float = 0.05) -> list[numpy.ndarray]
```
The outline, then each hole, as polylines at z = 0 within `tolerance` of its arcs and splines — what a viewer draws it with. A closed loop repeats its first point at the end; an open chain (a profile ended open) stays open. Views, like `Solid.mesh()` — copies in Node, Godot and Python.

```python
profile.show(tolerance: float = 0.05) -> None
```
Draw the outline and holes with the viewer in use, from the top by default. Keywords as `Solid.show()`; `edges=` is ignored, the lines being the whole picture. With the GPU library (`import cadaclysm.view.wgpu`) the drawing replaces what one shared window shows and stays live — at the REPL, in IPython and in Jupyter by themselves, in a script until it exits; `cadaclysm.view.View` draws several items or several windows.

```python
profile.svg(path: FilePath | None = None, *, view='top') -> str | None
```
This profile's own loops as SVG: a line a line, an arc an arc, a spline the NURBS' own Béziers — exact curves, nothing flattened to the polyline `Profile.polylines()` samples. The keywords are `svg`'s own, except `view=` defaults to `top` here rather than `iso`: a profile lies in z = 0, so its own plane is already the page and it reads flat and true. In the languages whose options are a struct (view already `iso`, not nullable), that default holds only when no options value is passed at all — pass one for anything else and its own `view` applies. With `path`, writes the file and returns `None`; without, returns the SVG text. raises `BuildError` on a refused option or a failed write.

```python
profile.length(accuracy: float = 0.0) -> Length
```
The perimeter of the outer loop — holes are not counted — as a `Length`: its exact curves measured to the relative `accuracy`, 0 asking for `measure.default_accuracy` (see `set_option`). An accuracy of NaN, infinite or 1 or more raises `BuildError`.

```python
profile.point_at_length(s: float, accuracy: float = 0.0) -> At
```
The point at arc length `s` along the outer loop, as an `At`: `s` is absolute, measured from the loop's start, and lies in `[0, length]` (see `Profile.length()`) — past either end by no more than the length's own error is that end, further raises `BuildError`. The sample names its side in `segment`, and `parameter` is that side's own: a line's 0 to 1, an arc's angle about its centre (a clockwise arc's angle decreasing along it), a spline's parameter. `accuracy` is relative, 0 or less asking for `measure.default_accuracy`; NaN, infinite or 1 or more raises `BuildError`.

```python
profile.divide_by_count(n: int, accuracy: float = 0.0) -> list[At]
```
The outer loop in `n` pieces of equal arc length, as a list of `At`: a profile is closed, so `n` samples from its start, never the start again. `n` is 1 to 1,000,000; `accuracy` as `Profile.point_at_length()`.

```python
profile.divide_by_length(step: float, accuracy: float = 0.0) -> list[At]
```
Samples of the outer loop every `step` of arc length from its start, as a list of `At`: the last piece is whatever is left over, kept short, and the start is never repeated. `step` is positive and finite and may give at most 999,999 steps; `accuracy` as `Profile.point_at_length()`.

### Path

```python
class Path
```

An outline drawn a segment at a time — lines, arcs, Béziers, NURBS — then closed into a `Profile`. Ending it consumes the builder.

```python
path.line_to(x: float, y: float) -> Path
```
A straight segment to (`x`, `y`).

```python
path.arc_to(x: float, y: float, centre: Point2, ccw: bool = True) -> Path
```
A circular arc to (`x`, `y`) about `centre`, counter-clockwise unless `ccw` is `False`.

```python
path.bezier_to(c1: Point2, c2: Point2, to: Point2) -> Path
```
A cubic Bézier through control points `c1`, `c2` to `to`.

```python
path.conic_to(x: float, y: float, control: Point2, weight: float) -> Path
```
A conic arc to (`x`, `y`) through the control point `control` with middle `weight`: under 1 an elliptical arc, 1 a parabola, over 1 a hyperbola — the rational quadratic Bézier, kept exact. A weight not positive and finite, an end on the current point, or a control point on the chord raises `BuildError`.

```python
path.parabola_to(x: float, y: float, control: Point2) -> Path
```
A parabolic arc to (`x`, `y`) whose end tangents meet at `control`: `Path.conic_to()` with weight 1.

```python
path.hyperbola_to(x: float, y: float, control: Point2, weight: float) -> Path
```
A hyperbolic arc to (`x`, `y`) through `control` with middle `weight` over 1; a weight of 1 or under raises `BuildError`.

```python
path.parabola_by_vertex(x: float, y: float, vertex: Point2) -> Path
```
The parabolic arc to (`x`, `y`) whose vertex is `vertex`: the axis and focal length are solved from the two ends. A vertex on the chord, or one no parabola through both ends has (the vertex must be the arc's extreme point), raises `BuildError`.

```python
path.parabola_by_focus(x: float, y: float, focus: Point2) -> Path
```
The parabolic arc to (`x`, `y`) whose focus is `focus`: of the two parabolas through the ends with that focus, the one whose vertex lies between the ends' projections, then the one whose arc cups the focus (the focus between the arc and its chord), then the more symmetric; with the focus beyond the chord that is the arch over the ends, not the shallow dish — draw that one with `Profile.parabola()`. A focus on the chord raises `BuildError`.

```python
path.nurbs_to(control: Iterable[Point2], knots: Sequence[float], degree: int, weights: Iterable[float] | None = None) -> Path
```
A NURBS segment: `control` is every control point after the current one, the endpoint last; `knots` the full knot vector; `weights` one per control point including the current one, or `None` for a non-rational curve.

```python
path.end() -> Profile
```
Close the outline back to its start and return the `Profile`.

```python
path.end_open() -> Profile
```
The path as it stands, not closed: an open chain for `Solid.extrude_open()`, `Solid.sweep_open()` or `Solid.loft_open()`.

### SweepPath

```python
class SweepPath
```

The 3D path a profile is carried along by `Solid.sweep()`: lines and circular arcs. Sweeping only borrows it, so one path can be swept many times; close it when done.

```python
SweepPath.at(point: Point3) -> SweepPath
```
Start a path at a 3D point.

```python
SweepPath.along(curve: Profile, frame: FrameLike, tolerance: float = 0.05, open: bool = True) -> SweepPath
```
The path a 2D chain (usually from `Path.end_open()`) draws on `frame`: a line a straight piece, an arc a circular one, a Bézier or spline fitted with biarcs — arcs tangent to each other and to the curve — within `tolerance`, so the path is tangent throughout and the sweep exact along it. `open` false closes the path back to its start.

```python
sweepPath.line_to(point: Point3) -> SweepPath
```
A straight piece to a 3D point.

```python
sweepPath.arc(centre: Point3, axis: Point3, angle: float) -> SweepPath
```
Turn `angle` radians (in (0, 2π]) about the axis through `centre` along `axis`.

```python
sweepPath.close() -> None
```
Free the path.

### Slant

```python
class Slant
```

A plane a `Solid.extrude_between()` starts or ends on, read as a height over the sketch plane at each point: `at + grad · (x, y)`. Flat for an ordinary cap; sloped for a mitre.

```python
slant.at  (attribute)
```
The height at the sketch origin.

```python
slant.grad  (attribute)
```
The slope in x and y.

```python
Slant.flat(at: float) -> Slant
```
A flat plane at height `at`.

```python
Slant.of_plane(frame: FrameLike, point: Point3, normal: Point3) -> Slant
```
The plane through `point` square to `normal`, as heights over `frame`. A plane that contains the extrusion direction has no height and raises `BuildError`.

### Frame

```python
class Frame
Frame(origin: Point3, x: Point3, y: Point3, z: Point3)  # the constructor
```

A frame built for you instead of twelve numbers typed out: an origin and three unit axes, square to each other and right-handed (z = x × y). It goes wherever a `frame` does. Immutable. The constructor takes the origin and the three axes, normalises them, and raises `BuildError` when they are not square or not right-handed.

```python
Frame.xy(origin: Point3 = (0, 0, 0)) -> Frame
```
The world XY plane through `origin`: z up, as `Workplane.xy()`.

```python
Frame.xz(origin: Point3 = (0, 0, 0)) -> Frame
```
The world XZ plane through `origin`: x along X, y along Z, so z is -Y, as `Workplane.xz()`.

```python
Frame.yz(origin: Point3 = (0, 0, 0)) -> Frame
```
The world YZ plane through `origin`: x along Y, y along Z, so z is +X, as `Workplane.yz()`.

```python
Frame.at(origin: Point3, normal: Point3, x: Point3 | None = None) -> Frame
```
The plane through `origin` square to `normal`, which becomes the frame's z (it need not be unit). Its x axis is `x` laid onto that plane; with none, world X laid onto it, or world Y when the normal is within about 25° of X — the axes `Solid.face_frame()` gives a face facing `normal`. So a normal along +Z, -Y or +X gives exactly `Frame.xy()`, `Frame.xz()` or `Frame.yz()`. A zero normal, or an `x` along the normal, raises `BuildError`.

```python
Frame.of(frame: FrameLike) -> Frame
```
Twelve numbers — what `Solid.face_frame()` and `Workplane.frame` hand back — as a checked frame, to read its axes or move it.

```python
Frame.midplane(a: FrameLike, b: FrameLike) -> Frame
```
The plane midway between the planes of frames `a` and `b`: for parallel planes the one halfway between, on `a`'s axes; for planes that meet, the plane bisecting them through the line they meet on, its x along that line.

```python
Frame.through(p: Point3, q: Point3, r: Point3) -> Frame
```
The plane through the points `p`, `q` and `r`: its origin `p`, its x towards `q`, its z the normal the three turn about counter-clockwise. Three points on one line raises `BuildError`.

```python
frame.origin: tuple[float, float, float]  (property)
frame.x: tuple[float, float, float]  (property)
frame.y: tuple[float, float, float]  (property)
frame.z: tuple[float, float, float]  (property)
```
The origin and the three axes, each three numbers.

```python
frame.translate(dx: float, dy: float, dz: float) -> Frame
```
This frame moved by (`dx`, `dy`, `dz`) in world coordinates.

```python
frame.offset(distance: float) -> Frame
```
This frame moved `distance` along its own z: `Frame.xy().offset(5)` is the XY plane at z = 5.

```python
Frame.fit(points: 'Iterable[Point3]') -> tuple[Frame, float]
```
The least-squares plane through `points` (three or more, not all on one line) as a frame, and the largest distance any point lies off it: `(frame, deviation)`. Fewer points, or points on one line, raises `BuildError`.

```python
frame.flipped() -> Frame
```
The same plane facing the other way: x and y swapped, z reversed.

```python
frame.rotated(radians: float, axis: Point3) -> Frame
```
This frame turned `radians` about `axis` through its origin, right-handed.

```python
frame.to_local(p: Point3) -> tuple[float, float, float]
```
The point `p` in this frame's coordinates.

```python
frame.closest_point(p: Point3) -> tuple[float, float, float]
```
The point `p` dropped onto the frame's plane along its z.

```python
frame.distance_to(p: Point3) -> float
```
How far `p` lies above the frame's plane, along its z: negative below.

### Transform

```python
class Transform
```

An affine map of space: a 4×4 matrix, row-major, its bottom row `0 0 0 1` (a projective one raises `BuildError`). Immutable, with nothing to free; it iterates as its 16 numbers. `a @ b` is `a` after `b`. The constructors and decompositions are the library's own, so every language computes them alike. A frame argument is a `Frame` or 12 numbers: one within 1e-6 of right-handed and orthonormal is squared up, any other raises `BuildError`.

```python
Transform.from_rows(rows: 'Iterable[float]') -> Transform
```
The map 16 numbers state, row-major, or four rows of four.

```python
Transform.identity() -> Transform
```
The map that moves nothing.

```python
Transform.translation(v: Point3) -> Transform
```
`p + v`.

```python
Transform.rotation(point: Point3, direction: Point3, radians: float) -> Transform
```
A turn of `radians` about the line through `point` along `direction`, right-handed.

```python
Transform.mirror(plane: FrameLike) -> Transform
```
The reflection across `plane`, its z the normal.

```python
Transform.scale(centre: Point3, k: float) -> Transform
```
A uniform scale by `k` about `centre`.

```python
Transform.scale_xyz(frame: FrameLike, sx: float, sy: float, sz: float) -> Transform
```
A scale by `sx`, `sy`, `sz` along `frame`'s axes, about its origin.

```python
Transform.shear(plane: FrameLike, direction: Point3, factor: float) -> Transform
```
Every point slid along `direction` by `factor` times its height above `plane`. `direction` is normalised, so `factor` alone sets the slide; one off the plane raises `BuildError`.

```python
Transform.plane_to_plane(a: FrameLike, b: FrameLike) -> Transform
```
The rigid map sending frame `a` onto frame `b`.

```python
Transform.change_basis(from_: FrameLike, to: FrameLike) -> Transform
```
Coordinates in frame `from_` to coordinates in frame `to`.

```python
Transform.planar_projection(plane: FrameLike) -> Transform
```
The orthogonal projection onto `plane` (singular by design).

```python
Transform.project_along(plane: FrameLike, direction: Point3) -> Transform
```
The parallel projection onto `plane` along `direction`; a direction in the plane raises `BuildError`.

```python
transform.rows: tuple[float, ...]  (property)
```
The 16 numbers, row-major.

```python
transform.point(p: Point3) -> tuple[float, float, float]
```
Where the map takes the point `p`.

```python
transform.inverse() -> Transform
```
The map undoing this one; a singular map raises `BuildError`.

```python
transform.is_rigid(tolerance: float = _MAP_TOLERANCE) -> bool
```
Whether the linear part is orthogonal (`AᵀA = I` to `tolerance`, 1e-9 by default): a rotation or a mirror.

```python
transform.is_similarity(tolerance: float = _MAP_TOLERANCE) -> float | None
```
The scale `k` where the linear part is `k` times an orthogonal one (to `tolerance`, relative to `k²`); `None` otherwise.

```python
transform.decompose_rigid(tolerance: float = _MAP_TOLERANCE) -> tuple[tuple[float, float, float], Transform] | None
```
`(translation, orthogonal part)` for a rigid map; `None` otherwise.

```python
transform.decompose_similarity(tolerance: float = _MAP_TOLERANCE) -> tuple[tuple[float, float, float], Transform, float] | None
```
`(translation, orthogonal part, k)` for a similarity; `None` otherwise.

```python
transform.decompose_affine() -> tuple[tuple[float, float, float], Transform, Transform, tuple[float, float, float]] | None
```
`(translation, rotation, axes, stretch)` with the linear part `rotation · axes · diag(stretch) · axesᵀ`: `rotation` carries the mirror, `axes` is a proper rotation whose columns are the stretch directions, the stretches come largest first. `None` for a singular map, or one stretched past 1e7:1.

### Quaternion

```python
class Quaternion
```

A rotation as `w + xi + yj + zk`. Immutable; it iterates as `w, x, y, z`. `q` and `-q` are the same rotation; a non-unit one is normalised where it becomes a rotation, and a zero one raises `BuildError` there. `a * b` turns by `b`, then by `a`.

```python
Quaternion.from_axis_angle(direction: Point3, radians: float) -> Quaternion
```
The turn of `radians` about `direction`, right-handed.

```python
Quaternion.from_transform(t: 'Transform') -> Quaternion
```
The rotation in `t`'s linear part (its translation ignored); anything but a proper rotation raises `BuildError`.

```python
Quaternion.slerp(a: 'Quaternion', b: 'Quaternion', s: float) -> Quaternion
```
From `a` (`s = 0`) to `b` (`s = 1`) along the shorter arc.

```python
quaternion.to_transform(centre: Point3 = (0.0, 0.0, 0.0)) -> Transform
```
This rotation as a `Transform` fixing `centre`.

```python
quaternion.w: float  (property)
quaternion.x: float  (property)
quaternion.y: float  (property)
quaternion.z: float  (property)
```
The four numbers.

```python
quaternion.length: float  (property)
```
Its length; 1 for a rotation as made here.

```python
quaternion.angle: float  (property)
```
The turn, in `[0, 2π]`.

```python
quaternion.axis: tuple[float, float, float] | None  (property)
```
The turn's axis; `None` for the identity.

```python
quaternion.conjugate() -> Quaternion
```
The opposite turn.

```python
quaternion.normalized() -> Quaternion
```
This quaternion at length 1; a zero one raises `BuildError`.

### Interval

```python
class Interval
```

A parameter range `t0..t1`, in either order: `length` and `swapped` keep the order, the set operations (`grown`, `union`, `intersect`) answer increasing. Immutable and hashable; it iterates as `(t0, t1)`, so two numbers go wherever an `Interval` does. The values' angle and height ranges and the surfaces' domains are intervals.

```python
Interval.of(value: 'Interval | Iterable[float]') -> Interval
```
An `Interval`, or two numbers, as an `Interval`; any other count raises `BuildError`.

```python
interval.t0: float  (property)
interval.t1: float  (property)
```
The two ends, as given.

```python
interval.length: float  (property)
```
`t1 - t0`: negative for a decreasing interval.

```python
interval.mid: float  (property)
```
The middle, `(t0 + t1) / 2`.

```python
interval.min: float  (property)
interval.max: float  (property)
```
The smaller and the larger end.

```python
interval.is_increasing: bool  (property)
```
Whether `t0 < t1`.

```python
interval.is_singleton: bool  (property)
```
Whether `t0 == t1`.

```python
interval.swapped() -> Interval
```
The interval `t1..t0`.

```python
interval.grown(t: float) -> Interval
```
The increasing interval holding this one and `t`.

```python
interval.union(o: 'Interval | Iterable[float]') -> Interval
```
The increasing interval holding this one and `o`.

```python
interval.intersect(o: 'Interval | Iterable[float]') -> Interval | None
```
The increasing overlap with `o`; `None` where the two are apart. Two that touch give a singleton.

```python
interval.contains(t: float) -> bool
```
Whether `t` lies in the closed range, in either order.

```python
interval.parameter_at(s: float) -> float
```
`t0 + s (t1 - t0)`: the fraction `s` of the way from `t0`; outside 0..1 extrapolates.

```python
interval.normalized_parameter_at(t: float) -> float | None
```
The fraction of the way `t` lies from `t0` toward `t1`; `None` for a singleton.

### CurveFoot

```python
class CurveFoot(NamedTuple)
```

The closest point of a curve value, as a named tuple: its parameter `t`, the `point`, and `unique` — `False` where several points lie equally near and `point` is a fixed pick among them (a point on a circle's axis, one equidistant from an arc's ends).

### SurfaceFoot

```python
class SurfaceFoot(NamedTuple)
```

The closest point of a surface value, as a named tuple: its parameters `u`, `v`, the `point`, and `unique` — `False` where several points lie equally near and `point` is a fixed pick among them (a sphere's centre, a point on an axis).

### Line

```python
class Line(_CurveValue)
```

The segment from `start` to `end`, as a value: a piece of construction geometry to measure, to project onto and to map, without building a solid. Its parameter runs 0..1. Immutable, with nothing to free: equal by value, hashable, iterating as its numbers, the maths the library's own, so every language answers alike. A frame argument is a `Frame` or 12 numbers; one within 1e-6 of right-handed and orthonormal is squared up, any other raises `BuildError`, as does a size that is not positive and finite.

```python
line.start: tuple[float, float, float]  (property)
line.end: tuple[float, float, float]  (property)
```
The two ends.

```python
line.point_at(t: float) -> tuple[float, float, float]
```
The point at `t`: the fraction `t` of the way from `start` to `end` (0..1 spans the segment).

```python
line.tangent_at(t: float) -> tuple[float, float, float]
```
The unit tangent at `t`, the way `t` grows.

```python
line.length() -> float
```
The length.

```python
line.closest_point(p: Point3) -> CurveFoot
```
The `CurveFoot` nearest `p`: its parameter `t`, the `point` and `unique`. Exact for every kind, in closed form rather than by iteration. `unique` is `False` where several points lie equally near and the answer is a fixed pick among them — a point on a circle's axis, one equidistant from an arc's two ends; `True` otherwise.

```python
line.distance_to(p: Point3) -> float
```
How far `p` lies from the curve: the distance to its `closest_point`.

```python
line.to_nurbs() -> NurbsCurve
```
The curve as its exact `NurbsCurve` (a conic as a rational quadratic). Native only: the web build has no `NurbsCurve`, so there this raises `BuildError` before any call.

```python
line.bounds() -> tuple[tuple[float, float, float], tuple[float, float, float]]
```
The exact world box, `(min, max)`, from the closed form rather than from samples.

```python
line.transform(t: 'Transform | Sequence[float]')
```
This value under `t` (a `Transform`, or 16 numbers), a value of the same type. A line takes any map that keeps its ends apart and an ellipse any that keeps it an ellipse; every other value only a similarity — turn a circle into an `Ellipse` first for anything else. Any other map raises `BuildError`.

### Circle

```python
class Circle(_ConicValue)
```

The circle of `radius` about the frame's origin in its x-y plane, running counter-clockwise about its z from its x, as a value. `Curve`'s `value` gives an edge's circle. Immutable, with nothing to free: equal by value, hashable, iterating as its numbers, the maths the library's own, so every language answers alike. A frame argument is a `Frame` or 12 numbers; one within 1e-6 of right-handed and orthonormal is squared up, any other raises `BuildError`, as does a size that is not positive and finite.

```python
Circle.through(a: Point3, b: Point3, c: Point3) -> Circle
```
The circle through the points `a`, `b` and `c`: its x toward `a`, turning `a`, `b`, `c` counter-clockwise. Three points on one line raises `BuildError`.

```python
circle.radius: float  (property)
```
The radius.

```python
circle.point_at(t: float) -> tuple[float, float, float]
```
The point at `t`: `t` the angle in radians from the frame's x toward its y.

```python
circle.tangent_at(t: float) -> tuple[float, float, float]
```
The unit tangent at `t`, the way `t` grows.

```python
circle.length() -> float
```
The length.

```python
circle.closest_point(p: Point3) -> CurveFoot
```
The `CurveFoot` nearest `p`: its parameter `t`, the `point` and `unique`. Exact for every kind, in closed form rather than by iteration. `unique` is `False` where several points lie equally near and the answer is a fixed pick among them — a point on a circle's axis, one equidistant from an arc's two ends; `True` otherwise.

```python
circle.distance_to(p: Point3) -> float
```
How far `p` lies from the curve: the distance to its `closest_point`.

```python
circle.to_nurbs() -> NurbsCurve
```
The curve as its exact `NurbsCurve` (a conic as a rational quadratic). Native only: the web build has no `NurbsCurve`, so there this raises `BuildError` before any call.

```python
circle.frame: Frame  (property)
```
The `Frame` the value is placed on.

```python
circle.bounds() -> tuple[tuple[float, float, float], tuple[float, float, float]]
```
The exact world box, `(min, max)`, from the closed form rather than from samples.

```python
circle.transform(t: 'Transform | Sequence[float]')
```
This value under `t` (a `Transform`, or 16 numbers), a value of the same type. A line takes any map that keeps its ends apart and an ellipse any that keeps it an ellipse; every other value only a similarity — turn a circle into an `Ellipse` first for anything else. Any other map raises `BuildError`.

### Arc

```python
class Arc(_ConicValue)
```

The part of a circle over `angle` (an `Interval` or two numbers, increasing, by at most a full turn), as a value: the circle's frame and radius, its angles measured from the frame's x toward its y. `Curve`'s `value` gives an edge's arc. Immutable, with nothing to free: equal by value, hashable, iterating as its numbers, the maths the library's own, so every language answers alike. A frame argument is a `Frame` or 12 numbers; one within 1e-6 of right-handed and orthonormal is squared up, any other raises `BuildError`, as does a size that is not positive and finite.

```python
Arc.through(a: Point3, b: Point3, c: Point3) -> Arc
```
The arc from `a` through `b` to `c`. Three points on one line raises `BuildError`.

```python
Arc.from_start_tangent_end(a: Point3, tangent: Point3, c: Point3) -> Arc
```
The arc leaving `a` along `tangent` and ending at `c`. A zero tangent, or a `c` on the tangent's line, raises `BuildError`.

```python
arc.radius: float  (property)
```
The radius.

```python
arc.angle: Interval  (property)
```
The angle range, an `Interval`.

```python
arc.start: tuple[float, float, float]  (property)
arc.end: tuple[float, float, float]  (property)
arc.mid: tuple[float, float, float]  (property)
```
The points at the start, the end and halfway along.

```python
arc.point_at(t: float) -> tuple[float, float, float]
```
The point at `t`: `t` the angle in radians from the frame's x toward its y.

```python
arc.tangent_at(t: float) -> tuple[float, float, float]
```
The unit tangent at `t`, the way `t` grows.

```python
arc.length() -> float
```
The length.

```python
arc.closest_point(p: Point3) -> CurveFoot
```
The `CurveFoot` nearest `p`: its parameter `t`, the `point` and `unique`. Exact for every kind, in closed form rather than by iteration. `unique` is `False` where several points lie equally near and the answer is a fixed pick among them — a point on a circle's axis, one equidistant from an arc's two ends; `True` otherwise.

```python
arc.distance_to(p: Point3) -> float
```
How far `p` lies from the curve: the distance to its `closest_point`.

```python
arc.to_nurbs() -> NurbsCurve
```
The curve as its exact `NurbsCurve` (a conic as a rational quadratic). Native only: the web build has no `NurbsCurve`, so there this raises `BuildError` before any call.

```python
arc.frame: Frame  (property)
```
The `Frame` the value is placed on.

```python
arc.bounds() -> tuple[tuple[float, float, float], tuple[float, float, float]]
```
The exact world box, `(min, max)`, from the closed form rather than from samples.

```python
arc.transform(t: 'Transform | Sequence[float]')
```
This value under `t` (a `Transform`, or 16 numbers), a value of the same type. A line takes any map that keeps its ends apart and an ellipse any that keeps it an ellipse; every other value only a similarity — turn a circle into an `Ellipse` first for anything else. Any other map raises `BuildError`.

### Ellipse

```python
class Ellipse(_ConicValue)
```

The ellipse of radius `r1` along the frame's x and `r2` along its y, as a value. Unlike a circle it takes any affine map that keeps it an ellipse. `Curve`'s `value` gives an edge's whole ellipse (an elliptical arc's range stays on the `Curve`). Immutable, with nothing to free: equal by value, hashable, iterating as its numbers, the maths the library's own, so every language answers alike. A frame argument is a `Frame` or 12 numbers; one within 1e-6 of right-handed and orthonormal is squared up, any other raises `BuildError`, as does a size that is not positive and finite.

```python
Ellipse.from_circle(circle: Circle) -> Ellipse
```
`circle` as an ellipse of two equal radii, to map by a non-uniform scale or a shear.

```python
ellipse.r1: float  (property)
ellipse.r2: float  (property)
```
The radii along the frame's x and y.

```python
ellipse.point_at(t: float) -> tuple[float, float, float]
```
The point at `t`: `t` the eccentric angle in radians, from the frame's x toward its y.

```python
ellipse.tangent_at(t: float) -> tuple[float, float, float]
```
The unit tangent at `t`, the way `t` grows.

```python
ellipse.length() -> float
```
The perimeter, in closed form.

```python
ellipse.closest_point(p: Point3) -> CurveFoot
```
The `CurveFoot` nearest `p`: its parameter `t`, the `point` and `unique`. Exact for every kind, in closed form rather than by iteration. `unique` is `False` where several points lie equally near and the answer is a fixed pick among them — a point on a circle's axis, one equidistant from an arc's two ends; `True` otherwise.

```python
ellipse.distance_to(p: Point3) -> float
```
How far `p` lies from the curve: the distance to its `closest_point`.

```python
ellipse.to_nurbs() -> NurbsCurve
```
The curve as its exact `NurbsCurve` (a conic as a rational quadratic). Native only: the web build has no `NurbsCurve`, so there this raises `BuildError` before any call.

```python
ellipse.frame: Frame  (property)
```
The `Frame` the value is placed on.

```python
ellipse.bounds() -> tuple[tuple[float, float, float], tuple[float, float, float]]
```
The exact world box, `(min, max)`, from the closed form rather than from samples.

```python
ellipse.transform(t: 'Transform | Sequence[float]')
```
This value under `t` (a `Transform`, or 16 numbers), a value of the same type. A line takes any map that keeps its ends apart and an ellipse any that keeps it an ellipse; every other value only a similarity — turn a circle into an `Ellipse` first for anything else. Any other map raises `BuildError`.

### Sphere

```python
class Sphere(_SurfaceValue)
```

The sphere of `radius` about the frame's origin, as a value: `u` the longitude from the frame's x, `v` the latitude toward its z. Measure it, project onto it, test points against it, or make it a solid with `to_solid`. Immutable, with nothing to free: equal by value, hashable, iterating as its numbers, the maths the library's own, so every language answers alike. A frame argument is a `Frame` or 12 numbers; one within 1e-6 of right-handed and orthonormal is squared up, any other raises `BuildError`, as does a size that is not positive and finite.

```python
sphere.radius: float  (property)
```
The radius.

```python
sphere.point_at(u: float, v: float) -> tuple[float, float, float]
```
The point at `(u, v)`, in the ranges `domain` gives.

```python
sphere.normal_at(u: float, v: float) -> tuple[float, float, float]
```
The outward unit normal at `(u, v)`.

```python
sphere.closest_point(p: Point3) -> SurfaceFoot
```
The `SurfaceFoot` nearest `p` on the surface (a cylinder's and a cone's side, not their caps): its `u`, `v`, the `point` and `unique`. Exact for every kind, in closed form. `unique` is `False` where several points lie equally near and the answer is a fixed pick among them — a sphere's centre, a point on a cylinder's, cone's or torus's axis; `True` otherwise.

```python
sphere.distance_to(p: Point3) -> float
```
How far `p` lies from the surface: the distance to its `closest_point`.

```python
sphere.domain() -> tuple[Interval, Interval]
```
The `u` and `v` ranges, as two `Interval`s.

```python
sphere.to_nurbs_sheet() -> Solid
```
The surface alone, as an open sheet on its exact NURBS form.

```python
sphere.contains(p: Point3, tolerance: float = 1e-09) -> bool
```
Whether `p` lies inside the closed shape or within `tolerance` of it (1e-9 by default).

```python
sphere.area() -> float
```
The boundary's area, in closed form: a cylinder's and a cone's caps included.

```python
sphere.volume() -> float
```
The volume enclosed, in closed form.

```python
sphere.to_solid() -> Solid
```
The shape as a closed exact B-rep `Solid`, to join, cut and write.

```python
sphere.frame: Frame  (property)
```
The `Frame` the value is placed on.

```python
sphere.bounds() -> tuple[tuple[float, float, float], tuple[float, float, float]]
```
The exact world box, `(min, max)`, from the closed form rather than from samples.

```python
sphere.transform(t: 'Transform | Sequence[float]')
```
This value under `t` (a `Transform`, or 16 numbers), a value of the same type. A line takes any map that keeps its ends apart and an ellipse any that keeps it an ellipse; every other value only a similarity — turn a circle into an `Ellipse` first for anything else. Any other map raises `BuildError`.

### Cylinder

```python
class Cylinder(_SurfaceValue)
```

The capped cylinder of `radius` about the frame's z over `height` (an increasing `Interval` along z, or two numbers), as a value: `u` the angle from the frame's x, `v` the height. Immutable, with nothing to free: equal by value, hashable, iterating as its numbers, the maths the library's own, so every language answers alike. A frame argument is a `Frame` or 12 numbers; one within 1e-6 of right-handed and orthonormal is squared up, any other raises `BuildError`, as does a size that is not positive and finite.

```python
cylinder.radius: float  (property)
```
The radius.

```python
cylinder.height: Interval  (property)
```
The range along the frame's z, an `Interval`.

```python
cylinder.point_at(u: float, v: float) -> tuple[float, float, float]
```
The point at `(u, v)`, in the ranges `domain` gives.

```python
cylinder.normal_at(u: float, v: float) -> tuple[float, float, float]
```
The outward unit normal at `(u, v)`.

```python
cylinder.closest_point(p: Point3) -> SurfaceFoot
```
The `SurfaceFoot` nearest `p` on the surface (a cylinder's and a cone's side, not their caps): its `u`, `v`, the `point` and `unique`. Exact for every kind, in closed form. `unique` is `False` where several points lie equally near and the answer is a fixed pick among them — a sphere's centre, a point on a cylinder's, cone's or torus's axis; `True` otherwise.

```python
cylinder.distance_to(p: Point3) -> float
```
How far `p` lies from the surface: the distance to its `closest_point`.

```python
cylinder.domain() -> tuple[Interval, Interval]
```
The `u` and `v` ranges, as two `Interval`s.

```python
cylinder.to_nurbs_sheet() -> Solid
```
The surface alone, as an open sheet on its exact NURBS form.

```python
cylinder.contains(p: Point3, tolerance: float = 1e-09) -> bool
```
Whether `p` lies inside the closed shape or within `tolerance` of it (1e-9 by default).

```python
cylinder.area() -> float
```
The boundary's area, in closed form: a cylinder's and a cone's caps included.

```python
cylinder.volume() -> float
```
The volume enclosed, in closed form.

```python
cylinder.to_solid() -> Solid
```
The shape as a closed exact B-rep `Solid`, to join, cut and write.

```python
cylinder.frame: Frame  (property)
```
The `Frame` the value is placed on.

```python
cylinder.bounds() -> tuple[tuple[float, float, float], tuple[float, float, float]]
```
The exact world box, `(min, max)`, from the closed form rather than from samples.

```python
cylinder.transform(t: 'Transform | Sequence[float]')
```
This value under `t` (a `Transform`, or 16 numbers), a value of the same type. A line takes any map that keeps its ends apart and an ellipse any that keeps it an ellipse; every other value only a similarity — turn a circle into an `Ellipse` first for anything else. Any other map raises `BuildError`.

### Cone

```python
class Cone(_SurfaceValue)
```

The capped cone of base `radius` on the frame's x-y plane, its apex `height` up its z, as a value: `u` the angle from the frame's x, `v` the height. Immutable, with nothing to free: equal by value, hashable, iterating as its numbers, the maths the library's own, so every language answers alike. A frame argument is a `Frame` or 12 numbers; one within 1e-6 of right-handed and orthonormal is squared up, any other raises `BuildError`, as does a size that is not positive and finite.

```python
cone.radius: float  (property)
```
The base radius.

```python
cone.height: float  (property)
```
How far up the frame's z the apex lies.

```python
cone.point_at(u: float, v: float) -> tuple[float, float, float]
```
The point at `(u, v)`, in the ranges `domain` gives.

```python
cone.normal_at(u: float, v: float) -> tuple[float, float, float]
```
The outward unit normal at `(u, v)`.

```python
cone.closest_point(p: Point3) -> SurfaceFoot
```
The `SurfaceFoot` nearest `p` on the surface (a cylinder's and a cone's side, not their caps): its `u`, `v`, the `point` and `unique`. Exact for every kind, in closed form. `unique` is `False` where several points lie equally near and the answer is a fixed pick among them — a sphere's centre, a point on a cylinder's, cone's or torus's axis; `True` otherwise.

```python
cone.distance_to(p: Point3) -> float
```
How far `p` lies from the surface: the distance to its `closest_point`.

```python
cone.domain() -> tuple[Interval, Interval]
```
The `u` and `v` ranges, as two `Interval`s.

```python
cone.to_nurbs_sheet() -> Solid
```
The surface alone, as an open sheet on its exact NURBS form.

```python
cone.contains(p: Point3, tolerance: float = 1e-09) -> bool
```
Whether `p` lies inside the closed shape or within `tolerance` of it (1e-9 by default).

```python
cone.area() -> float
```
The boundary's area, in closed form: a cylinder's and a cone's caps included.

```python
cone.volume() -> float
```
The volume enclosed, in closed form.

```python
cone.to_solid() -> Solid
```
The shape as a closed exact B-rep `Solid`, to join, cut and write.

```python
cone.frame: Frame  (property)
```
The `Frame` the value is placed on.

```python
cone.bounds() -> tuple[tuple[float, float, float], tuple[float, float, float]]
```
The exact world box, `(min, max)`, from the closed form rather than from samples.

```python
cone.transform(t: 'Transform | Sequence[float]')
```
This value under `t` (a `Transform`, or 16 numbers), a value of the same type. A line takes any map that keeps its ends apart and an ellipse any that keeps it an ellipse; every other value only a similarity — turn a circle into an `Ellipse` first for anything else. Any other map raises `BuildError`.

### Torus

```python
class Torus(_SurfaceValue)
```

The torus of `major` radius about the frame's z and `minor` radius about that circle, as a value: `u` the angle about the z from the frame's x, `v` the angle about the tube. Immutable, with nothing to free: equal by value, hashable, iterating as its numbers, the maths the library's own, so every language answers alike. A frame argument is a `Frame` or 12 numbers; one within 1e-6 of right-handed and orthonormal is squared up, any other raises `BuildError`, as does a size that is not positive and finite.

```python
torus.major: float  (property)
torus.minor: float  (property)
```
The radius of the tube's centre circle, and the tube's own.

```python
torus.point_at(u: float, v: float) -> tuple[float, float, float]
```
The point at `(u, v)`, in the ranges `domain` gives.

```python
torus.normal_at(u: float, v: float) -> tuple[float, float, float]
```
The outward unit normal at `(u, v)`.

```python
torus.closest_point(p: Point3) -> SurfaceFoot
```
The `SurfaceFoot` nearest `p` on the surface (a cylinder's and a cone's side, not their caps): its `u`, `v`, the `point` and `unique`. Exact for every kind, in closed form. `unique` is `False` where several points lie equally near and the answer is a fixed pick among them — a sphere's centre, a point on a cylinder's, cone's or torus's axis; `True` otherwise.

```python
torus.distance_to(p: Point3) -> float
```
How far `p` lies from the surface: the distance to its `closest_point`.

```python
torus.domain() -> tuple[Interval, Interval]
```
The `u` and `v` ranges, as two `Interval`s.

```python
torus.to_nurbs_sheet() -> Solid
```
The surface alone, as an open sheet on its exact NURBS form.

```python
torus.contains(p: Point3, tolerance: float = 1e-09) -> bool
```
Whether `p` lies inside the closed shape or within `tolerance` of it (1e-9 by default).

```python
torus.area() -> float
```
The boundary's area, in closed form: a cylinder's and a cone's caps included.

```python
torus.volume() -> float
```
The volume enclosed, in closed form.

```python
torus.to_solid() -> Solid
```
The shape as a closed exact B-rep `Solid`, to join, cut and write.

```python
torus.frame: Frame  (property)
```
The `Frame` the value is placed on.

```python
torus.bounds() -> tuple[tuple[float, float, float], tuple[float, float, float]]
```
The exact world box, `(min, max)`, from the closed form rather than from samples.

```python
torus.transform(t: 'Transform | Sequence[float]')
```
This value under `t` (a `Transform`, or 16 numbers), a value of the same type. A line takes any map that keeps its ends apart and an ellipse any that keeps it an ellipse; every other value only a similarity — turn a circle into an `Ellipse` first for anything else. Any other map raises `BuildError`.

### Cuboid

```python
class Cuboid(_SolidValue)
```

The box over `x`, `y`, `z` (increasing `Interval`s, or pairs) along its frame's axes, as a value: an oriented bounding box, a region to test points against, a block to make a solid of. Immutable, with nothing to free: equal by value, hashable, iterating as its numbers, the maths the library's own, so every language answers alike. A frame argument is a `Frame` or 12 numbers; one within 1e-6 of right-handed and orthonormal is squared up, any other raises `BuildError`, as does a size that is not positive and finite.

```python
Cuboid.from_bounds(min: Point3, max: Point3) -> Cuboid
```
The world-aligned box from `min` to `max`; an empty or flat one raises `BuildError`.

```python
Cuboid.around(frame: FrameLike, points: 'Iterable[Point3]') -> Cuboid
```
The tightest box holding `points`, aligned to `frame`. No points, or points flat along one of the frame's axes (a sheet, not a box), raises `BuildError`.

```python
cuboid.x: Interval  (property)
cuboid.y: Interval  (property)
cuboid.z: Interval  (property)
```
The three ranges along the frame's axes, as `Interval`s.

```python
cuboid.corners() -> list[tuple[float, float, float]]
```
The eight corners: the `z0` face counter-clockwise about the frame's z from `(x0, y0)`, then the `z1` face in the same order.

```python
cuboid.point_at(sx: float, sy: float, sz: float) -> tuple[float, float, float]
```
The point the fractions `sx`, `sy`, `sz` of the way along each range.

```python
cuboid.closest_point(p: Point3) -> tuple[float, float, float]
```
The closest point of the solid box to `p`: `p` itself where it lies inside.

```python
cuboid.contains(p: Point3, tolerance: float = 1e-09) -> bool
```
Whether `p` lies inside the closed shape or within `tolerance` of it (1e-9 by default).

```python
cuboid.area() -> float
```
The boundary's area, in closed form: a cylinder's and a cone's caps included.

```python
cuboid.volume() -> float
```
The volume enclosed, in closed form.

```python
cuboid.to_solid() -> Solid
```
The shape as a closed exact B-rep `Solid`, to join, cut and write.

```python
cuboid.frame: Frame  (property)
```
The `Frame` the value is placed on.

```python
cuboid.bounds() -> tuple[tuple[float, float, float], tuple[float, float, float]]
```
The exact world box, `(min, max)`, from the closed form rather than from samples.

```python
cuboid.transform(t: 'Transform | Sequence[float]')
```
This value under `t` (a `Transform`, or 16 numbers), a value of the same type. A line takes any map that keeps its ends apart and an ellipse any that keeps it an ellipse; every other value only a similarity — turn a circle into an `Ellipse` first for anything else. Any other map raises `BuildError`.

### Workplane

```python
class Workplane
```

The fluent chain: a frame, the solid built so far, and the face last picked. A build step **replaces** the solid rather than adding to it — combine solids explicitly with `Solid.join()`. Every step raises `BuildError` at once rather than holding the error for later.

```python
Workplane.xy() -> Workplane
```
Start on the XY plane at the origin (Z up). `Workplane.xz()` and `Workplane.yz()` start on the other two.

```python
Workplane.xz() -> Workplane
```
Start on the XZ plane.

```python
Workplane.yz() -> Workplane
```
Start on the YZ plane.

```python
Workplane.on(frame: FrameLike) -> Workplane
```
Start on any frame (see Frames).

```python
Workplane.from_solid(solid: Solid) -> Workplane
```
Start from an existing solid, on the XY plane — the usual way to pick one of its faces and build on it.

```python
workplane.frame  (attribute)
```
The current frame, 12 numbers.

```python
workplane.cuboid(x: float, y: float, z: float) -> Workplane
```
A box `x` × `y` × `z` centred on the current frame's origin and aligned to its axes — on a picked face, half of it below the face; replaces the solid.

```python
workplane.cylinder(r: float, h: float) -> Workplane
```
A cylinder of radius `r` and height `h` standing on the current frame; replaces the solid.

```python
workplane.face(profile: Profile) -> Workplane
```
The planar sheet the profile bounds on this frame — see `Solid.face()`; replaces the solid.

```python
workplane.extrude(profile: Profile, height: float) -> Workplane
```
The profile extruded `height` along the frame's z; replaces the solid.

```python
workplane.revolve(profile: Profile, angle: float) -> Workplane
```
The profile revolved `angle` radians about the frame's y axis; replaces the solid.

```python
workplane.translate(dx: float, dy: float, dz: float) -> Workplane
```
Slide the current solid. Keeps the face selection — a rigid move keeps every face's index.

```python
workplane.faces(selector: Selector) -> Workplane
```
Pick a face of the current solid with a `Selector`.

```python
workplane.workplane() -> Workplane
```
Move the frame onto the face last picked (outward normal as z), so the next step builds on it.

```python
workplane.solid() -> Solid
```
The solid built so far. On an empty chain it raises `BuildError`.

### Selector

```python
class Selector
```

Which face to pick: the one furthest along an axis, furthest against it, the one facing a direction, or by index. Used by `Workplane.faces()` and `Solid.select_face()`.

```python
Selector.max(axis: Axis) -> Selector
```
The face furthest along `axis`.

```python
Selector.min(axis: Axis) -> Selector
```
The face furthest against `axis`.

```python
Selector.normal(direction: Point3) -> Selector
```
The face whose outward normal is nearest `direction` (need not be unit).

```python
Selector.index(i: int) -> Selector
```
The face with this index.

```python
Axis.X = 0
Axis.Y = 1
Axis.Z = 2
```
`X`, `Y`, `Z`: the axes `Selector.max()` and `Selector.min()` take.

### Solid

```python
class Solid
```

An exact B-rep solid (or an open sheet): planes, cylinders, cones, spheres, tori and NURBS, trimmed and joined, never approximated by triangles. Immutable — every operation returns a new one. Close it when done, or let the language's scope do it; see Lifetimes.

#### Primitives

```python
Solid.cuboid(x: float, y: float, z: float) -> Solid
```
A box `x` × `y` × `z`, centred on the origin.

```python
Solid.cylinder(r: float, h: float) -> Solid
```
A cylinder of radius `r`, from z = 0 to `h`.

```python
Solid.cone(r: float, h: float) -> Solid
```
A cone of base radius `r` and height `h`, apex up.

```python
Solid.sphere(r: float) -> Solid
```
A sphere of radius `r` about the origin.

```python
Solid.torus(major: float, minor: float) -> Solid
```
A torus about the z axis: `major` to the tube's centre, `minor` the tube's radius. A tube wider than its ring (`minor > major`, a spindle) builds the solid it sweeps, the outer sheet with a pole at each end on the axis; `minor == major` is refused.

```python
Solid.wedge(x: float, y: float, z: float, top_x: float) -> Solid
```
A box whose top face is `top_x` long instead of `x`: a ramp.

```python
Solid.pyramid(sides: int, r: float, h: float) -> Solid
```
A pyramid of `sides` sides (at least 3): its base the regular polygon of radius `r` on z = 0 (`r` to a corner, the first on +x), its tip at height `h`.

#### From a profile

```python
Solid.extrude(profile: Profile, frame: FrameLike, height: float) -> Solid
```
The profile on `frame`, extruded `height` along the frame's z.

```python
Solid.extrude_open(profile: Profile, frame: FrameLike, height: float) -> Solid
```
The walls only, no caps: an open sheet. Takes an open `Path.end_open()` chain as well as a closed profile.

```python
Solid.extrude_tapered(profile: Profile, frame: FrameLike, height: float, taper: float) -> Solid
```
Extrude with a draft: the walls lean out by `taper` radians as they rise (in, when negative). Every wall stays exact — a plane off a line, a cone off an arc.

```python
Solid.extrude_open_tapered(profile: Profile, frame: FrameLike, height: float, taper: float) -> Solid
```
The tapered walls without caps.

```python
Solid.extrude_between(profile: Profile, frame: FrameLike, bottom: Slant | float, top: Slant | float) -> Solid
```
Extrude between two planes rather than two heights: `bottom` and `top` are each a `Slant` (a bare number is a flat one). With both flat this is `Solid.extrude()`; with a slope it is the mitred end of a frame member. A top that comes down to or through the bottom raises `BuildError`.

```python
Solid.extrude_open_between(profile: Profile, frame: FrameLike, bottom: Slant | float, top: Slant | float) -> Solid
```
`Solid.extrude_between()` without the caps.

```python
Solid.revolve(profile: Profile, axis: AxisLike, angle: float) -> Solid
```
The profile swung `angle` radians about `axis` (a point and a direction — see Frames). The profile's x is read as the radius and its y as the height along the axis, so it must lie to one side of it.

```python
Solid.revolve_open(profile: Profile, axis: AxisLike, angle: float) -> Solid
```
The revolved surface of an open profile: a sheet.

```python
Solid.revolve_in_plane(profile: Profile, frame: FrameLike, a: Point2, b: Point2, angle: float) -> Solid
```
The profile on `frame` swung `angle` radians about the axis through the sketch points `a` and `b` (each `(x, y)` on the frame) — the profile and its axis drawn together, as a sketch draws them, where `Solid.revolve()` reads the profile as (radius, height). The profile may lie on either side of the axis and touch it (a half-disc with its diameter on the axis turns into a ball), but not cross it. The sweep starts where the profile is drawn and turns right-handed about `b - a`, so a partial turn leaves one end of the solid over the profile itself.

```python
Solid.revolve_open_in_plane(profile: Profile, frame: FrameLike, a: Point2, b: Point2, angle: float) -> Solid
```
`Solid.revolve_in_plane()` for a curve: its segments swung into a sheet, no caps.

```python
Solid.coil(profile: Profile, axis: AxisLike, pitch: float, turns: float) -> Solid
```
The profile coiled about `axis` (a point and a direction): read as `Solid.revolve()` reads it — x the distance from the axis, y along it — and turned `turns` times while climbing `pitch` along the axis each turn: a spring, a thread. The walls follow the helix to a few millionths of the radius (a helix is not a NURBS curve, so they are a close fit, exact at both ends); the two ends are the profile itself, flat. A profile reaching the axis, one with holes, or — from a full turn up — a pitch no taller than the profile raises `BuildError`.

```python
Solid.loft(a: Profile, frame_a: FrameLike, b: Profile, frame_b: FrameLike) -> Solid
```
The solid between profile `a` on one frame and `b` on another: ruled walls between matching sides (both profiles need the same number of sides, and no holes), capped by the two.

```python
Solid.loft_open(a: Profile, frame_a: FrameLike, b: Profile, frame_b: FrameLike) -> Solid
```
The ruled walls without the caps.

```python
Solid.loft_through(sections: Iterable[tuple[Profile, FrameLike]]) -> Solid
```
The solid smooth through every section — a profile on its frame, in order: each wall interpolates its side across all the profiles (cubic through four or more, quadratic through three, `Solid.loft()` through two), capped by the first and the last. Every section of the result is its profile exactly, arcs and all. The profiles must have the same number of sides and no holes; otherwise raises `BuildError`.

```python
Solid.loft_through_open(sections: Iterable[tuple[Profile, FrameLike]]) -> Solid
```
The walls through the curves without the caps: an open sheet.

```python
Solid.sweep(profile: Profile, frame: FrameLike, path: SweepPath) -> Solid
```
The profile on `frame`, carried along a `SweepPath`. A straight piece is an extrusion and an arc a revolution about the arc's axis, so nothing is approximated — a circle along an arc is an exact torus wall.

```python
Solid.sweep_open(profile: Profile, frame: FrameLike, path: SweepPath) -> Solid
```
The swept walls without caps: an open sheet.

```python
Solid.pipe(path: SweepPath, radius: float, thickness: float = 0.0) -> Solid
```
A circle of `radius` carried along a `SweepPath`, square to where it starts: a solid rod, or with a positive `thickness` a tube whose walls are that thick. The path is only borrowed, as by `Solid.sweep()`, and refused the same way.

```python
solid.extrude_faces(height: float) -> Solid
```
Every face of a sheet pushed `height` along its own normal, walled and closed: the sheet as a solid of that thickness.

```python
Solid.face(profile: Profile, frame: FrameLike) -> Solid
```
The flat sheet a profile bounds on `frame`: one planar face, each hole a hole through it, its normal the frame's z however the profile winds, every edge the exact line, arc or spline its segment is. An open sheet — raise it with `Solid.extrude_faces()`, cut it with `Solid.trim()`.

#### Placing

```python
solid.place(frame: FrameLike) -> Solid
```
A solid built about the origin moved onto `frame`: its origin to the frame's origin, its axes to the frame's (see Frames).

```python
solid.translate(dx: float, dy: float, dz: float) -> Solid
```
Moved by (`dx`, `dy`, `dz`).

```python
solid.scaled(factor: float) -> Solid
```
Scaled by `factor` about the origin: every length times `factor`, exactly. `factor` must be positive and finite.

```python
solid.rotate(axis: AxisLike, radians: float) -> Solid
```
Turned `radians` about `axis` (a point and a direction).

```python
solid.mirror(plane: FrameLike) -> Solid
```
Reflected across `plane`: a frame whose z is the mirror plane's normal.

```python
solid.transform(t: 'Transform | Sequence[float]') -> Solid
```
Through the affine map `t` — a `Transform`, or 16 numbers row-major — exactly, colours and name kept. A rigid map or a similarity keeps every surface's kind; a map within 1e-6 of a similarity (`AᵀA` against `k²I`, relative to `k²`: a rotation written in float32 among them) is applied as the exact similarity nearest it, moving a point `p` by at most about `1e-6·|A|·|p|`. Any other map — a non-uniform scale, a shear — turns the curved surfaces into their exact NURBS and maps those. A singular map raises `BuildError`.

```python
solid.convert_to_nurbs(level: str = 'all') -> Solid
```
Every surface `level` selects rewritten as its exact NURBS: `"procedural"` the revolutions, extrusions and sums; `"analytic"` those and the cylinders, cones, spheres and tori; `"all"` everything, planes and edge curves too. Colours and name kept.

```python
solid.inexact_trims  (attribute)
```
On a solid from `Solid.transform()` or `Solid.convert_to_nurbs()`, the trims **that call** lost: face boundaries kept only as a polyline lifted through the old surface, where no exact edge curve was left. Per call — not the solid's history — and 0 for a rigid map or a similarity, and on every other solid.

#### Booleans

```python
solid.join(other: 'Solid', tolerance: float = 0.05, progress: Progress = None, merge: bool = False) -> Solid
```
The union with `other`, as an exact B-rep. `merge` (off by default, so face and edge numbers stay as they were) merges the flush faces the join leaves, as `Solid.merge_flush()` does — Go takes it as a trailing `true`, Java as an overload; `Solid.cut()` and `Solid.common()` take it too. `tolerance` (0.05 by default) is the mesh tolerance the boolean decides at: both solids are meshed at it, so a tighter one is as correct and slower. It is also the resolution: two faces on one surface to within it — a peg the size of its hole, or a hair thinner — are one surface, and the join is a fit; a gap wider than it is a gap. `progress`, where the wrapper takes one, is called with a phase name and a done/total count.

```python
solid.cut(other: 'Solid', tolerance: float = 0.05, progress: Progress = None, merge: bool = False) -> Solid
```
This solid with `other` removed.

```python
solid.common(other: 'Solid', tolerance: float = 0.05, progress: Progress = None, merge: bool = False) -> Solid
```
What this solid and `other` share.

```python
solid.section(z: float, tolerance: float = 0.05) -> list[Profile]
```
This solid cut by the plane `Z = z`: its closed outlines there, in XY, nested into profiles with holes (boundaries counter-clockwise, holes clockwise), a line or a circle crossing kept exact and any other curve as lines within `tolerance`. A plane that misses the solid is an empty list. A `z` not finite, a `tolerance` (0.05 by default) not positive and finite, a face lying in the plane (section a little above or below it), or a crossing that does not close, raises `BuildError`.

```python
solid.split_sheet(tool: 'Solid', tolerance: float = 0.05, progress: Progress = None) -> Solid
```
This solid or sheet cut along `tool`'s boundary with nothing removed: each face comes back as its pieces outside `tool` and then its pieces inside, in the original face order — the start of a surface trim. `tool` must be a closed solid. Keep the pieces you want with `Solid.drop_faces()`, or split and drop in one call with `Solid.trim()`.

#### Faces and sheets

```python
solid.face_sheet(face: int) -> Solid
```
One face alone, as an open sheet: its surface, its loops and the exact curves on its edges, the rest of the solid left behind — raised by `Solid.extrude_faces()` it is the prism over that face. Keeps the face's colour.

```python
solid.drop_faces(faces: Iterable[int]) -> Solid
```
This solid without the faces listed: the rest keep their surfaces, curves and colours in their order, so an index into the result is this one's with the dropped ones closed up. Dropping every face raises `BuildError`.

```python
solid.trim(tool: 'Solid', keep: Literal['outside', 'inside'] = 'outside', tolerance: float = 0.05, progress: Progress = None) -> Solid
```
This sheet (or solid) cut along the closed `tool`'s boundary and the pieces on one side thrown away: `keep` `"outside"` (the default) keeps what lies outside the tool — a hole punched through — and `"inside"` what lies within it. Nothing on the kept side raises `BuildError`. `tolerance` and `progress` as for `Solid.join()`.

```python
solid.split_by_curve(curve: 'NurbsCurve', direction: 'Point3 | None' = None, tolerance: float = 0.05) -> Solid
```
This sheet cut along `curve` — a `NurbsCurve` lying on it, typically projected or pulled onto it — with nothing removed: each face comes back as its pieces outside the cutter and then its pieces inside, as `Solid.split_sheet()` orders them. The cutter is the curve run along `direction` (`None`: the mean of the sheet's normals along the curve) through the whole sheet, so the cut follows the curve wherever the sheet is one layer along that direction. A closed curve's inside is the island it bounds; an open curve's is the side left of its run, seen from where `direction` points, and an open curve is run on straight past both ends, so it should reach the sheet's boundary. Where the cut lies on the curve — a curve drawn on the sheet — the rim is one edge carrying the curve's own span exactly, its ends on the curve, so another sheet built along the same curve sews to it with `Solid.join_sheets()`. A direction that is zero, or a curve running along it, raises `BuildError`. Native Python only for now.

```python
solid.trim_by_curve(curve: 'NurbsCurve', keep: Literal['outside', 'inside', 'left', 'right'] = 'outside', direction: 'Point3 | None' = None, tolerance: float = 0.05) -> Solid
```
This sheet cut along `curve` and one side thrown away (see `Solid.split_by_curve()`): `keep` `"outside"` (the default) keeps the sheet with the hole a closed curve cuts, `"inside"` the island; for an open curve `"left"` (the same as `"inside"`) keeps the side left of its run seen from where `direction` points, `"right"` the other. Nothing on the kept side raises `BuildError`. The kept pieces keep their faces' colours. Native Python only for now.

```python
Solid.join_sheets(sheets: 'Iterable[Solid]', tolerance: float = 0.0) -> tuple[Solid, JoinReport]
```
Separate sheets joined into one body, their faces in order, beside a `JoinReport` of what was done: every two naked edges whose ends and curves agree within `tolerance` (0: a rounding of the body's size) sewn into one edge — a gap closed is kept as that edge's own tolerance, nothing moves — the faces turned to agree across their edges, and a closed result turned to face out: a solid `Solid.cut()`, `Solid.mass()` and the writers take like any other. Edges that carry exact curves are compared to the tolerance however coarsely each sheet sampled them. One sheet's edge running along part of another's is not sewn and stays naked. No sheets, a negative tolerance, or faces that cannot be turned to agree (a one-sided surface) raises `BuildError`. Native Python only for now.

```python
solid.health(tolerance: 'float | None' = None, mesh: bool = False) -> HealthReport
```
What is wrong with this solid, as a `HealthReport`: the free edges and the wires they chain into, each with its nearest partner and the gap to it; the features below `tolerance`; the loose edges; and what sewing would join and leave. Nothing moves. `tolerance` is an absolute length, as Rhino's model tolerance is, by default `1e-4` times the diagonal; a NaN, infinite, zero or negative one takes the default, and the report shows what was used. A partner is the nearest free edge other than a neighbour on the wire, so a rim reads as a gap the size of the part; `shared_ends` 2 is what `Solid.join_sheets()` joins. `mesh=True` also meshes the solid and reports where the mesh cracks; an open body's crack census is empty by design (not asked), and cracks are only counted on a closed body. Loose edges are compared against the larger of the tolerance recorded and the one given. A solid that cannot be read raises `BuildError`.

```python
solid.healed(tolerance: 'float | None' = None, edges: bool = True, faces: bool = True, holes: bool = True) -> tuple[Solid, HealReport]
```
This solid with its small features removed, beside a `HealReport` of what was done and left, as a new `Solid`; this one is left as it was. It heals what `Solid.health()` lists as small at the same `tolerance`, so `health` first tells what it will do.

Each kind's fix: a short edge's two ends are merged into one vertex and the edge dropped; a collapsed edge (a trim collapsed to a point where its surface is not singular) is dropped; a sliver face's short ends are merged, then the face is dropped and its two long sides sewn into one edge; a tiny face's corners are merged into one vertex and the face is dropped with its edges; a small hole (an inner loop whose edges are all free: a pinhole in an open sheet) is dropped from its face. A hole with walls (a bore) is not a small hole, and a tiny body is listed but never removed.

Everything is a vertex merge no wider than `tolerance`: a cluster of vertices that spans more, measured by every trim end at them, is refused (`chain`), so a run of short edges cannot swallow a long one, nor a loosely written corner move an end further. No edit moves a trim further than `tolerance`: a trim end on a surface pole keeps its uv, an end sent further is left, and a curve edit that would move further is discarded and only the vertex moves. A stack of slivers whose outer faces part by more than `tolerance` is not sewn across (`neighbours_part`). Each edge that moved records how far as its `Solid.edge_tolerance()`, as sewing records a gap; an end that could not move records how far it was left from the merged vertex.

A guard compares the result's health with this solid's. If it is worse — less closed, more free or non-manifold edges, or no faces left — healing retries with the face pass off; if that is still worse, this solid comes back as it was. `guarded` is set whenever the guard refused a fix. So a lone sliver sheet comes back as a face of two trims: its short ends merged, the sliver refused.

`edges`, `faces` and `holes` switch each kind of fix; a kind switched off is refused as `toggled`. `tolerance` `None`, NaN, infinite, zero or negative takes the default, `1e-4` times the diagonal; the report shows what was used. In the browser the reader module's `Scene.healed` returns the report only: heal the body through the blacksmith module's `Solid.healed`. A solid that cannot be read raises `BuildError`.

```python
solid.edge_tolerance(edge: int) -> float | None
```
How far edge `edge` (a brep edge id, as a `HealFix` or `FreeEdge` names one) may lie off its curve: 0 for an exact edge, the distance healing or sewing moved it where that is recorded, `None` when no trim names the id (an edge healing removed). A solid that cannot be read raises `BuildError`.

```python
solid.push_pull(face: int | Iterable[int], distance: float, tolerance: float = 0.05, progress: Progress = None) -> Solid
```
Face `face` pushed out by `distance` along its outward normal — pulled in, negative — as a face extrude does it: the prism over it joined on (cut out) at `tolerance`, and the flush faces merged, so a box's top raised is one taller box of six faces rather than a box and a prism with every side wall split at the seam. A face on a cylinder, a cone, a sphere or a torus moves out along its normal instead, as a press-pull does: the surface a step out — a boss fatter, a bore or a countersink narrower, a dome fuller — with the flat faces beside it carried along in their own planes. Any other curved face is refused, as is a curved face with anything but a plane it can follow beside it, reaching a cone's apex, pushed to its axis or centre, off a plane beside it or run into another edge. A flat face keeps its own colour where it now lies.

Several faces push together, as a press-pull on a selection: each by its own rule, one after another in the order given, each found again after the pushes before it renumbered the faces — a box's top and a side pushed 5 is the box 5 taller and 5 wider, a boss's top and wall the boss taller and fatter. A face on the same curved surface as one before it, and joined to it, moved with that one and is not pushed twice. No faces, or a face an earlier push took away, raises `BuildError`.

`face` is a face index or a list of them.

```python
solid.refillet(face: int, radius: float, tolerance: float = 1e-06) -> Solid
```
The round `face` belongs to — a fillet's bands, balls and rim bands joined to that face — made again at `radius`, as a press-pull on a fillet face: taken back to the sharp edges it replaced, and those rounded again, so the round is the one `Solid.fillet()` makes at that radius. Rounds of straight edges between planes (their ends square corners, mitres, balls, or a cylinder, cone or sphere the edge runs into — a D-cut shaft's top edge, a rib's into a boss) and of circular rims between a plane and a cylinder or cone (a boss's foot, a bore's mouth, a counterbore's step); a face that is not one, or a radius that does not fit, raises `BuildError`.

```python
solid.unfillet(face: int) -> Solid
```
The round `face` belongs to taken off, the faces beside it made sharp again, meeting on the edges the round replaced — the delete of a fillet face. The same rounds as `Solid.refillet()`.

```python
solid.rechamfer(face: int, distance: float, tolerance: float = 1e-06) -> Solid
```
The chamfer `face` belongs to — its bevels (flat between two planes, cones round rims) and the corner triangles joined to that face — cut again at `distance`, as a press-pull on a chamfer face: taken back to the sharp edges it cut, and those bevelled again, so the chamfer is the one `Solid.chamfer()` cuts at that distance. A flat bevel's ends may run into a cylinder, cone or sphere, as a round's may. A face that is not a chamfer's bevel, or a distance that does not fit, raises `BuildError`.

```python
solid.unchamfer(face: int) -> Solid
```
The chamfer `face` belongs to taken off, the faces beside it made sharp again — the delete of a chamfer face. The same chamfers as `Solid.rechamfer()`.

```python
solid.merge_flush() -> Solid
```
This solid with its flush faces merged: flat faces on one plane, facing one way and meeting along their edges — the seams `Solid.join()` leaves where two parts are flush — made one face, and the vertices left mid-way along a straight edge taken out.

```python
solid.split(tool: 'Solid', tolerance: float = 0.05, progress: Progress = None) -> list[Solid]
```
This solid split by `tool` into bodies — returned as a list: a closed `tool` gives the parts outside it, then the parts inside; a flat sheet (a `Solid.face()`) splits by the whole plane it lies on. Each connected part is a body of its own, so a U cut across both arms is three. The new faces are pieces of the tool's, the colours carried over. A tool that does not cross the solid, or a curved sheet, raises `BuildError`. `tolerance` and `progress` as for `Solid.join()`.

```python
solid.split_by_plane(plane: FrameLike, tolerance: float = 0.05, progress: Progress = None) -> list[Solid]
```
This solid split by the plane through `plane`'s origin, square to its z (a frame): the bodies in front of it first, then those behind.

```python
solid.split_by_profile(profile: 'Profile', frame: FrameLike, tolerance: float = 0.05, progress: Progress = None) -> list[Solid]
```
This solid split by the closed `Profile` `profile` drawn on `frame`, pushed straight through it along the frame's z both ways — a split by a sketch profile: the bodies outside the profile first, then those inside. Where the plane lies along z does not matter, only the outline across it: a circle cores a sphere wherever it is drawn above it. The new faces are the profile's walls exactly. A profile that misses the solid, takes all of it or encloses nothing raises `BuildError`. `tolerance` and `progress` as for `Solid.join()`.

```python
solid.lumps() -> list[Solid]
```
This solid's connected bodies, each a solid of its own — faces sharing an edge are one body — in the order of their first faces. One body comes back as itself; a boolean that leaves two parts gives two.

```python
solid.merge(other: 'Solid', tolerance: float = 0.05, progress: Progress = None) -> Solid
```
This solid and `other` as one body that keeps every piece — a union that keeps the inside pieces, as Rhino's `MergeBreps`: every face of both, split where they cross, the walls they share stored once. Its `Solid.regions()` are this solid less `other`, the two together and `other` less this one, those that are not empty; one solid inside the other gives the outer one with a void and the inner one, two solids apart give both. Faces keep the colours of the faces they are pieces of.

**The body is non-manifold**: where a wall between two cells meets the outside, an edge has three or four faces. The verbs that need a manifold solid — `Solid.join()`, `Solid.cut()`, `Solid.common()`, the splits and trims, `Solid.fillet()`, `Solid.chamfer()`, `Solid.shell()`, `Solid.thicken()`, `Solid.mass()` and the STEP writer — refuse it and name the way out: take each cell with `Solid.region_solid()`.

**Built exactly, on the exact boolean route**: both solids closed, every face a plane, cylinder, cone, sphere or torus. A face of any other kind raises `BuildError`, naming it; so do walls of the two lying on one another in part (two boxes sharing part of a side, equal solids) — a case the exact route does not take yet, refused in words, with no mesh fallback. `tolerance` (0.05 by default) is the resolution the sections are found to; `progress` as for `Solid.join()`.

```python
solid.regions() -> list[Region]
```
The regions of space this solid's faces bound, as `Region` values — Rhino's `GetRegions`, computed on demand from the faces' order round every edge. **Region 0 is the infinite one**, the outside; the finite ones follow in a fixed order, so the same body gives the same list. An ordinary solid has two (the outside, in front of every face, and the inside, behind them), a `Solid.merge()` one per cell, a solid with a cavity three (the cavity is a region of its own).

Each region lists its sides as `FaceSide` values: a face and its `sense`, **+1 where the region is the side the face's normal points to, -1 the other** — a solid's own inside is behind its faces, at -1. Its shells come outer boundary first, then one per void inside it. Faces that leave an edge the same way (tangent along it, to the second order) raises `BuildError`.

```python
solid.region_solid(region: int) -> Solid
```
Finite region `region` (an index into `Solid.regions()`) as a closed solid of its own — Rhino's `BrepRegion.BoundaryBrep`: the faces bounding it, each turned to point out of it, each keeping its colour. A `Solid.merge()`'s cells come out one at a time this way, ready for `Solid.mass()` and the booleans. A closed manifold unless the region touches itself along an edge. Region 0 (the infinite region) or a region past the count raises `BuildError`.

#### Finishing

```python
solid.edges: list[Edge]  (property)
```
The solid's edges as `Edge` values — what `Solid.fillet()` and `Solid.chamfer()` take. Copied; safe to keep.

```python
solid.fillet(edges: Iterable[Edge | int], radius: float, tolerance: float = 1e-06, progress: Progress = None, radius_end: 'float | None' = None) -> Solid
```
Round the given edges (`Edge` values or their indices) with `radius`. Exact: the blend faces are cylinders, tori and NURBS, and the neighbours are trimmed back onto them. A spline edge — the crease between two faces on NURBS surfaces, running from one free edge of the shell to another, as between a fender patch and a door patch — is rounded by a ball rolled along it, the two faces cut back to where it touches them, in a call of its own (not with straight or circular edges); `tolerance` is then the fillet surface's fit. `radius_end` (spline edges only) runs the radius linearly from `radius` to it in arc length along the edge. A spline edge ending where other shared edges meet, a closed one, or a varying radius on a straight or circular edge raises `BuildError`.

```python
solid.chamfer(edges: Iterable[Edge | int], distance: float, tolerance: float = 1e-06) -> Solid
```
A flat bevel instead of a round: each edge cut back `distance` along both its faces.

```python
solid.shell(thickness: float, open: Iterable[int] = (), tolerance: float = 1e-06, progress: Progress = None) -> Solid
```
Hollow the solid to walls `thickness` thick — inward for a positive thickness, outward (the solid becoming the cavity) for a negative one. The faces listed in `open` are removed so the hollow is reachable.

```python
solid.thicken(thickness: float, tolerance: float = 1e-06, progress: Progress = None) -> Solid
```
A sheet made a solid `thickness` thick: its faces, their twins moved `thickness` along the faces' normals (against them for a negative thickness), and a wall round every open edge. Two faces of a folded sheet meet on their offsets' mitre; a closed sheet thickens to a hollow. Free-form (NURBS) faces offset by a fit held to `tolerance`. A thickness a face cannot take — a radius used up, a free-form offset folding over — raises `BuildError`.

#### Asking

```python
solid.faces: int  (property)
```
How many faces.

```python
solid.face_kind(face: int) -> str
```
A face's surface: `plane`, `cylinder`, `cone`, `sphere`, `torus`, `nurbs`, `revolution`, `extrusion` or `other`.

```python
solid.select_face(selector: 'Selector') -> int
```
The index of the face a `Selector` picks.

```python
solid.face_frame(face: int) -> tuple[float, ...]
```
The frame on a face: origin at its centre, z its outward normal, x world X laid onto the face (world Y on a face facing close to X) — `Frame.at()`'s rule, so the top of a box gets the XY plane's axes. What `Workplane.workplane()` moves onto.

```python
solid.bounds: tuple[tuple[float, float, float], tuple[float, float, float]]  (property)
```
The axis-aligned box, at the same cost whatever the solid's size: its mesh at a thousandth of its own extent, in double, so the box is inside the exact one and short of it by at most that. Worked out once per solid, apart from the tessellation `Solid.mesh()` caches. `Solid.bounds_at()` is the box of the mesh at a tolerance you name.

```python
solid.bounds_at(tolerance: float) -> tuple[tuple[float, float, float], tuple[float, float, float]]
```
The bounds over the tessellation at `tolerance` — the same cache `Solid.mesh()` fills, so asking both costs one mesh.

```python
solid.is_watertight(tolerance: float = 0.05) -> bool
```
Whether `Solid.leaked_edges()` is zero.

```python
solid.mass(accuracy: float = 0.0) -> Mass
```
What this solid measures, per unit density, as a `Mass`: area, volume, centroid, the inertia tensor about the centroid and its principal moments and axes — each figure beside a bound on its own error. Measured on the exact surfaces, refined until every error is under `accuracy` (a share of the figure) or the refinement gives up, which `Mass.accuracy_met` reports; the values are honest either way, they are simply less certain, and the errors say by how much. Volume, centroid and inertia mean something only where the body is closed — `Mass.closed` — and a body whose faces all point inward is measured as if they did not, which `Mass.inverted` says. An accuracy not positive and finite raises `BuildError`.

```python
solid.oriented_box(accuracy: float = 0.0) -> OrientedBox
```
This closed solid's box on its principal axes, as an `OrientedBox`. The axes are the inertia's, so the box is tight along a clear long direction but not the minimal box in general; where two moments are equal (a cube, a cylinder about its axis) any axes in that plane are as principal as the others, so which come back is a free choice. The half-extents are grown by the tolerance the measurement settled on, so they hold the body and may exceed its own extent by about that much. It costs as much as `Solid.mass()` at the same `accuracy`, because the axes come from the same inertia: tens of seconds at 1e-7 on a free-form body read from a file. `accuracy` is relative, and 0 or less asks for the box's own default, 1e-5 — not `measure.default_accuracy` — because a finer one buys little box: the half-extents are grown by the diagonal times the larger of `accuracy` and a sixteenth of the integration's tolerance, which starts at 5e-4 of the diagonal, so a body that settles at once (planes, cylinders, cones) is grown by about 3.1e-5 of its diagonal however fine the accuracy. A coarser `accuracy` (1e-3, say) is the fast route. An open body has no oriented box, and an accuracy that is NaN or infinite raises `BuildError`.

```python
solid.edge_length(edge: 'Edge | int', accuracy: float = 0.0) -> Length
```
The length of one edge over its own range, as a `Length`: `edge` is the index `Solid.edges` uses (Python also takes the `Edge` itself), and `accuracy` the relative accuracy, 0 asking for `measure.default_accuracy`. An edge past the end, or one with no curve to measure, raises `BuildError`. A body whose trims are 2D-only (Rhino `.3dm`, IGES entity 144) has no fillet-table edges at all, so this cannot be asked of it.

```python
solid.edge_point_at_length(edge: 'Edge | int', s: float, accuracy: float = 0.0) -> At
```
The point at arc length `s` along one edge, as an `At`: `s` is absolute, measured from the start of the edge's own range (the `t0` of its `Edge.curve`), and lies in `[0, length]` — past either end by no more than the length's own error is that end, further raises `BuildError`. `edge` is the index `Solid.edges` uses (Python also takes the `Edge` itself); `accuracy` is relative, 0 or less asking for `measure.default_accuracy`. The sample's `segment` is empty on an edge. An edge past the end or with no exact curve, or an accuracy NaN, infinite or 1 or more, raises `BuildError`.

```python
solid.edge_divide_by_count(edge: 'Edge | int', n: int, accuracy: float = 0.0) -> list[At]
```
One edge in `n` pieces of equal arc length, as a list of `At`: an open edge gives `n + 1` samples from its start to its end, a closed one (its range the curve's whole closed loop: a whole circle or ellipse, a closed spline's whole domain) `n`, never its start again. The first sample is exactly the range's start and an open edge's last exactly its end. `n` is 1 to 1,000,000; `accuracy` as `Solid.edge_point_at_length()`, and so are the refusals.

```python
solid.edge_divide_by_length(edge: 'Edge | int', step: float, accuracy: float = 0.0) -> list[At]
```
Samples of one edge every `step` of arc length from its start, as a list of `At`. The last piece is whatever is left over, kept short: an open edge's end is a sample only where a step lands on it (to within the length's error), and a closed edge never repeats its start. A step longer than the edge gives the start alone. `step` is positive and finite and may give at most 999,999 steps; `accuracy` as `Solid.edge_point_at_length()`, and so are the refusals.

```python
Solid.loft_curves(sections: 'Iterable[NurbsCurve]', degree: int = 3, loose: bool = False, closed: bool = False) -> Solid
```
A sheet lofted through `sections` (`NurbsCurve`s): one face on one NURBS surface whose `u` runs along the sections and `v` across them, `degree` across them (lowered to what the sections allow). `loose=True` shapes it by the sections instead — through the first and last only, smoother between; `closed=True` makes it periodic across them, the last section back to the first. Fewer than two sections (three closed) raises `BuildError`. Native Python only for now.

```python
Solid.sweep_rail(rail: 'NurbsCurve', sections: 'Iterable[NurbsCurve]', frame: str = 'rmf', up: 'Point3 | None' = None, tolerance: float = 0.001) -> Solid
```
A sheet of `sections` swept along `rail`: each section carried by the rail's frame from the rail point nearest its centre, the sections between blended by their place along the rail. `frame="rmf"` turns the sections no more than the rail makes them (rotation-minimising); `"fixed"` keeps `up` upright, as a sweep along a car's side does. Fitted through enough stations to lie within `tolerance` of that definition; `Solid.sheet_error` says how close it came.

```python
Solid.sweep_two_rails(rail_a: 'NurbsCurve', rail_b: 'NurbsCurve', sections: 'Iterable[NurbsCurve]', tolerance: float = 0.001) -> Solid
```
A sheet of `sections` swept between two rails: each section's first end on `rail_a` and its last on `rail_b`, carried by the rotation and uniform scale that keep them there, the rails matched by arc length (so a section spreads as the rails do). A section whose ends are not on the rails raises `BuildError`. Fitted within `tolerance` (`Solid.sheet_error`).

```python
Solid.edge_surface(curves: 'Iterable[NurbsCurve]', tolerance: float = 0.001) -> Solid
```
The Coons sheet of 2, 3 or 4 boundary curves meeting end to end within `tolerance`, given in order round the boundary (each either way round): three leave the fourth side a point, two give the ruled sheet between them. Exact for non-rational boundaries; rational ones (arcs) are fitted first, and `Solid.sheet_error` is that fit's error. Curves that do not meet raises `BuildError`.

```python
Solid.network_surface(u_curves: 'Iterable[NurbsCurve]', v_curves: 'Iterable[NurbsCurve]', tolerance: float = 0.001) -> Solid
```
The Gordon sheet of a curve network: `u_curves` in order across one way, `v_curves` across the other, every one of the first crossing every one of the second within `tolerance`. The curves are re-fitted so their crossings share parameters, then blended; `Solid.sheet_error` is the largest distance from the sheet to the curves given. A pair that does not cross raises `BuildError`, naming both.

```python
solid.continuity(side: str, other: 'Solid', other_side: str, face: int = 0, other_face: int = 0, samples: int = 64) -> Continuity
```
How well this solid's face `face` meets `other`'s face `other_face` along their sides — a side is `"u0"`, `"u1"`, `"v0"` or `"v1"`, a boundary isocurve of the face's NURBS surface — as a `Continuity`: the largest gap between the sides (G0), the largest angle between their normals (G1), the largest difference of curvature across the edge (G2), each with where it is, from `samples` points along the first side. A face that is not NURBS, or a side that is not one of the four, raises `BuildError`.

```python
solid.matched(side: str, other: 'Solid', other_side: str, level: int = 2, face: int = 0, other_face: int = 0) -> Solid
```
Face `face` as a sheet of its own, its side `side` bent to meet `other`'s `other_side` at G`level`: 0 onto the other side, 1 into its tangent plane, 2 with its curvature too. The opposite side stays where it was; the face is refined across the edge first if it has too few rows. Both faces non-rational NURBS: a rational one, or a level outside 0 to 2, raises `BuildError`.

```python
Solid.fillet_surfaces(a: 'Solid', b: 'Solid', radius: float, radius_end: 'float | None' = None, flip_a: bool = False, flip_b: bool = False, tolerance: float = 0.001, face_a: int = 0, face_b: int = 0) -> tuple[Solid, NurbsCurve, NurbsCurve]
```
The rolling-ball fillet between `a`'s face `face_a` and `b`'s face `face_b` — their whole NURBS surfaces — as `(fillet, rail_a, rail_b)`: the fillet sheet (its `Solid.sheet_error` set) and the `NurbsCurve`s the ball touches each face along, to trim the faces back with `Solid.trim_by_curve()` and join the three with `Solid.join_sheets()`. The ball sits on the side each face's normal points to (`flip_a`, `flip_b` turn it to the other side); its radius is `radius`, or runs linearly from `radius` at the fillet's first end to `radius_end` at its last. A radius not positive, or sides where the ball cannot touch both faces, raises `BuildError`.

```python
Solid.blend_sides(a: 'Solid', side_a: str, b: 'Solid', side_b: str, level: int = 2, bulge: float = 1.0, face_a: int = 0, face_b: int = 0) -> Solid
```
A sheet spanning from `a`'s side `side_a` to `b`'s side `side_b`, meeting each at G`level` (1 a cubic across, 2 a quintic, matching curvature too); `bulge` scales how far it leaves each edge along its neighbour's tangent. Both faces non-rational NURBS.

```python
solid.sheet_error  (attribute)
```
On a sheet from `Solid.sweep_rail()`, `Solid.sweep_two_rails()`, `Solid.edge_surface()` or `Solid.network_surface()`, how far it came from its definition; `None` on every other solid.

```python
solid.contains(point: Point3, tolerance: float = 0.05) -> str
```
Where `point` is relative to this closed solid: inside, outside, or on, within `tolerance` of its boundary — absolute, in model units (0.05 by default). The body is meshed on every call; for more than a few points build a `Solid.classifier()` once. An open body, a point not finite, or a tolerance not positive and finite raises `BuildError`.

```python
solid.classifier(tolerance: float = 0.05) -> Classifier
```
A `Classifier` for this closed solid at `tolerance` — absolute, in model units (0.05 by default): the body meshed once, then asked point after point. It keeps its own reference to the body, so it goes on answering after this solid is closed. An open body, or a tolerance not positive and finite, raises `BuildError`.

```python
solid.closest(other: 'Solid', tolerance: float = 0.05, progress: Progress = None) -> Closest
```
The closest points between this solid's boundary and `other`'s, to `tolerance` — absolute, in model units (0.05 by default) — as a `Closest`; this solid is side `a`. Boundaries are measured, not volumes: a solid wholly inside another is the gap between their skins, not 0, and boundaries that cross are 0 apart (ask `Solid.contains()` for containment). `progress`, where the wrapper takes one, hears "meshing", "pruning" and "refining"; in the browser it is never called. A tolerance not positive and finite, or a solid with no faces, raises `BuildError`. Whether two parts overlap, touch or lie within a clearance of each other is `clash`'s question, asked of a whole set.

```python
solid.thickness_at_face(face: int, at: Point3 | None = None, *, maximum, tolerance=0.01) -> FaceThickness | None
```
How thick this solid's walls are at face `face`, as a `FaceThickness`, on a `ThicknessGauge` of this solid alone built at `tolerance` (0.01 by default), asked `ThicknessGauge.thickness_at_face()` once and freed: at `at`'s foot on the face, or with no `at` over the face's vertices. `maximum` has no default. `None` where nothing on the face reads within `maximum`, or `at`'s foot lies off the face. A face past the end, an `at` not finite, `maximum` not positive and finite, or a `tolerance` not positive and finite raises `BuildError`.

```python
solid.bounds_box(tolerance: float = 0.05) -> Box
```
This solid's `Box` at `tolerance` (0.05 by default): its boolean mesh, padded by twice that — the broad phase's own bound, cheaper to move and to test against another than the solid itself. `Collider` builds one of these per part at construction. A tolerance not positive and finite, or a solid that meshes to nothing, raises `BuildError`.

```python
solid.face_tree() -> RTree
```
An `RTree` over this solid's faces: one entry per face, its id the face index the other face calls take, its box holding the face — the box the boolean's broad phase pairs faces by (an analytic face's exact bound, another face's boolean mesh padded), grown by a thousandth of the solid's extent. Ask it which faces a box meets, which a ray passes, or which are near a point, then test those faces themselves. A solid with no faces gives an empty tree; a face that cannot be boxed raises `BuildError`.

#### Naming

```python
solid.named(name: str) -> Solid
```
This solid, named `name`. The name rides through an operation with exactly one source solid (`place`, `translate`, `rotate`, `mirror`, `scaled`, `coloured`, `edges_coloured`, `fillet`, `chamfer`, `shell`, `thicken`, `face_sheet`, `drop_faces`, `lump`, `trim`, `split_by_plane`, `split_by_profile`, `push_pull`, and so on) and is dropped by one with two or more sources (`join`, `cut`, `common`, `split_sheet`, `split`) and by a fresh primitive or sweep. It is what `Assembly.place()` defaults a placement's own name to, and the product name a lone named solid gets written into STEP (`Solid.step()`/`Solid.step_text()` — SAT and OCCT `.brep` have no product name to set). An empty name raises `BuildError`.

```python
solid.name: str | None  (property)
```
This solid's name, or none, as `Solid.named()` set it, kept or dropped by whatever built this solid.

#### Material and outside style

```python
solid.with_material(material: str) -> Solid
```
This solid made of `material` — a name, written into STEP as the product's `MATERIAL_DESIGNATION`. Kept by every operation as the solid's colour is: a move keeps it, and a boolean's result is made of its first solid's. Writing it moves `Solid.step()`'s default schema to AP242; a named schema without the entity writes the solid without it, as it does a colour. A reader takes it back as the node's `Material` property. A blank material raises `BuildError`.

```python
solid.material: str | None  (property)
```
What this solid is made of, or none, as `Solid.with_material()` set it.

```python
solid.styled(location: 'str | None' = None, identification: 'str | None' = None) -> Solid
```
This solid drawn in a style defined outside the file: `identification` the style's name in the library at `location` — a MaterialX or MDL file and a material in it, say. Either may be left out, not both. Written into STEP as an `EXTERNALLY_DEFINED_STYLE` beside the solid's colour, which a reader without the library draws instead (AP242 or AP214: the default schema moves to AP242); a reader takes it back as the node's `ExternalStyle.Location` and `ExternalStyle.Identification` properties. Kept by operations as `Solid.with_material()`'s material is. A style naming neither raises `BuildError`.

```python
solid.style_location: str | None  (property)
```
Where this solid's outside style lives (`Solid.styled()`'s `location`), or none.

```python
solid.style_identification: str | None  (property)
```
This solid's outside style's name in its library (`Solid.styled()`'s `identification`), or none.

#### Colour

```python
solid.coloured(colour: Colour, face: int | None = None) -> Solid
```
A new solid coloured (r, g, b), each 0..1, `"#rgb"`, `"#rrggbb"` or a CSS colour name — or, given a face (Go: `ColouredFace`), just that face, whose colour then wins over the solid's. What is made from a coloured solid inherits: a move keeps every colour; a boolean, fillet, chamfer or shell gives each face the colour of the input face it lies on (a cut's bore takes the tool's), and a new face — a round, a shell's inner wall — the solid's. `Solid.step()` and `write_step` write the colours as STEP styling (AP242; a named schema that lacks styling writes the solids bare), and a solid's colour reads back as `Node.colour`.

```python
solid.colour: tuple[float, float, float] | None  (property)
```
The solid's own colour as (r, g, b), or none.

```python
solid.face_colour(face: int) -> tuple[float, float, float] | None
```
A face's colour as drawn: its own, else the solid's, else none.

```python
solid.edges_coloured(colour: Colour, edges: Iterable[Edge | int] | None = None) -> Solid
```
A new solid with its edges coloured (r, g, b), `"#rgb"`, `"#rrggbb"` or a CSS colour name: every edge, or, given `edges` (as `Solid.fillet()` takes them: `Edge` records or indices), just those, whose colour then wins over the all-edges one — an empty list colours none. Inherited as face colours are: a move keeps every edge colour; a boolean, fillet, chamfer or shell gives each edge the colour of the input edge it lies on, and a new edge (a cut's rim, a round's edges) the all-edges colour. `Solid.step()` and `write_step` write them as STEP `CURVE_STYLE` styling, which the reader reads back as `Node.edge_colours`.

```python
solid.edge_colour(edge: Edge | int) -> tuple[float, float, float] | None
```
An edge's colour as drawn: its own, else the solid's edge colour, else none.

```python
solid.brep(path: FilePath) -> None
```
Write this solid as an OCCT `.brep` file; see `write_brep`.

```python
solid.document_body() -> dict[str, Any]
```
This solid as a `Document`'s `solid.body` node holds it: the kernel's own B-rep as a record of its tables (surfaces, curves, trims, loops, faces), every number as it is, so the node gives back exactly this solid. What `Document.add_solid()` puts in a document.

#### From files

```python
Solid.open(path: FilePath, body: int | None = None) -> Solid
```
The body a CAD file holds, as a solid: STEP (AP203/214/242), ACIS `.sat`, Rhino `.3dm`, OCCT `.brep`, IGES or IFC, read where it draws, in the file's own units and axes. A file drawing several bodies needs `body` (0-based, in drawing order) or `Solid.open_all()`. What such a solid can do is what its geometry allows: fillet and chamfer want line and circle edges; booleans take any surface, but new edges traced on a free-form face are not always writable back to STEP; and every verb meshes its operands first, so its cost grows with the body's face count. Reads through the reader library, which must be from the same release.

```python
Solid.open_all(path: FilePath) -> list[Solid]
```
Every body a CAD file draws, as solids placed where it draws them: one per placement, so a part placed twice is two solids.

#### Output

```python
solid.mesh(tolerance: float = 0.05) -> tuple[numpy.ndarray, numpy.ndarray, numpy.ndarray]
```
Triangles at `tolerance`: positions, normals (three floats a vertex) and indices. **In every wrapper that lends a view, views owned by a held tessellation** — valid for as long as you keep the view, whatever happens to the solid: meshed again at any tolerance, closed. Rust borrows the solid for the view's lifetime instead; Node and Godot copy. **A raw span, slice or buffer taken out of a view does not keep the view itself reachable in a collected language**: hold the view while you read one, and copy what must outlive it. The same rule as a FEM mesh's views, for the same reason. **A view pins its whole tessellation** — positions, normals, indices, edges, face counts, in both precisions — until the view itself is freed or collected, whichever the language uses; for data that must outlive the view, `copy()` it and drop the view.

Read-only numpy views owned by a held tessellation: neither meshing again at another tolerance nor the solid's `close()` touches them (copies under Pyodide).

```python
solid.show(tolerance: float = 0.05) -> None
```
Draw the solid with the viewer in use — in a terminal, the picture is left in the scrollback. Each face keeps its own colour (`Solid.face_colour()`: a colour of its own, else the solid's). Keywords: view= (front, back, left, right, top, bottom, iso), az=, el=, zoom=, up=, edges=, width=, height=, hint=, tolerance=. With the GPU library (`import cadaclysm.view.wgpu`) the drawing replaces what one shared window shows and stays live — at the REPL, in IPython and in Jupyter by themselves, in a script until it exits; `cadaclysm.view.View` draws several items or several windows.

```python
solid.step(path: FilePath, schema: Schema = None, unit: Unit = 'mm') -> None
```
Write this solid as a STEP file (AP203, or AP242 when coloured); see `write_step` for `schema` and `unit`.

```python
solid.step_text(schema: Schema = None, unit: Unit = 'mm') -> str
```
The same STEP file as text.

```python
solid.sat(path: FilePath, unit: Unit = 'mm') -> None
```
Write this solid as an ACIS SAT file; see `write_sat` for `unit`.

```python
solid.svg(path: FilePath | None = None) -> str | None
```
This solid's wireframe as SVG, from a camera the keywords describe — `svg`'s own words, read by the library itself rather than a viewer. With `path`, writes the file and returns `None`; without, returns the SVG text. raises `BuildError` on a refused option or a failed write.

```python
solid.silhouette_beziers() -> Beziers
```
This solid's silhouette — the curves where its surfaces turn away from the eye, which no edge of it lies on, so a sphere has an outline here that its wireframe has none of — as rational cubic Béziers in double precision, from the camera the options describe: `Solid.svg()`'s own words, so the words that draw a picture ask about the same eye. `tolerance` is read as a fraction of the page's width, and nothing else in the options changes the curves; the line-set flags are not read. Exact Béziers where the surface has a closed silhouette form — sphere, cylinder, cone, extrusion — and for every other surface, a torus and a NURBS patch included, a straight-chord polyline carried as degree-1 Béziers: there is no spline fitter here, so a sphere's rim arrives as arcs and a torus's as chords.

The curves are in memory of the wrapper's own: the library's buffer is copied out and released before the call returns, so there is nothing to free and nothing that can dangle. A solid with no silhouette — one whose every face is planar, a cuboid's, since a plane has none from any eye — is an empty answer (`count` 0), not an error. The library clears its error slot as each call starts, so an empty answer leaves no message and a refusal leaves one; that is how the two are told apart, and why a failure from an earlier call cannot be mistaken for this call's empty answer. raises `BuildError` on a refusal — a refused option, say.

Takes `svg`'s keywords: `view`, `az`, `el`, `up`, `fov`, and `size` with `tolerance`, read as `tolerance / size[0]`; the line-set keywords are not read. Returns a `Beziers`: `points` of shape `(count, 4, 3)`, `weights` of shape `(count, 4)` and `count`, read-only arrays over a copy the wrapper owns, `copy()` for writable ones of your own. The empty answer is a `Beziers` that is falsey, with `count` 0 and `points` and `weights` both `None`, not empty arrays — the reader's convention for an empty Bézier answer, followed here; this is the only Bézier accessor in this module, so there is no sibling to compare it with.

```python
solid.close() -> None
```
Free the solid now. The garbage collector, or the language's scope, does it otherwise.

### Assembly

```python
class Assembly
Assembly(name: str)  # the constructor
```

A mutable tree of placements: a name, and zero or more solids or other assemblies placed in it at a frame. Unlike `Solid`, placing shares rather than copies — placing one assembly under another does not snapshot it, so a later placement on the shared one shows up wherever it already sits. Close it when done, or let the language's scope do it; see Lifetimes — closing an assembly does not free what was placed in it if that is still reachable from somewhere else.

```python
assembly.name: str  (property)
```
This assembly's own name, given when it was made.

```python
assembly.place(thing: 'Solid | Assembly', frame: FrameLike, name: 'str | None' = None) -> str
```
Place `thing` (a `Solid` or another `Assembly`) at `frame` in this assembly, called `name` — or, with `name` left out, `thing`'s own name (`Solid.name` for a solid, `"part"` for an unnamed one, or the placed assembly's own name), numbered past any already taken here (`"bolt"`, `"bolt 2"`, ...). `frame` must be right-handed and orthonormal, or the call raises `BuildError`. An explicit `name` already taken here raises `BuildError`. Placing an assembly that is this one, or anywhere above this one in the tree already, raises `BuildError` naming the cycle, since writing that out would never terminate. Returns the placement's name.

```python
assembly.link(name: str, placements: Iterable[str]) -> None
```
Declare a rigid link called `name` over `placements`: a list of names of placements of this assembly itself (not of assemblies placed in it — give those their own mechanism); in Python, Node and LuaJIT, a single name in place of the list is refused. A placed assembly in a link moves as one piece. An empty name, a name taken by another link here, no placements, a placement named twice, one this assembly does not have, or one already in another link raises `BuildError`, and the assembly is left as it was. Written as an AP242 kinematic link; a mechanism anywhere in the tree makes AP242 the default schema of `Assembly.step_text()`, and an explicit schema without the kinematic entities raises `BuildError`. A reader `Scene` reads it back as links and joints.

```python
assembly.joint(name: str, start: str, end: str) -> None
```
Connect this assembly's links `start` and `end`, kept in that order, as a joint called `name`. An empty name, a name taken by another joint here, a link this assembly does not have, a link joined to itself or a (start, end) pair already joined raises `BuildError`; the reverse pair is a different joint.

```python
assembly.pair(joint: str, kind: str, frame: FrameLike, end_frame: FrameLike | None = None, ranges: Iterable[Sequence[float | None] | None] | None = None, pitch: float | None = None) -> None
```
Give joint `joint` its pair: `kind` (one of `revolute`, `prismatic`, `cylindrical`, `screw`, `spherical`, `spherical_with_pin`, `planar`, `universal`, `homokinetic`, `fully_constrained` or `unconstrained`), the contact frame at rest, an optional `end_frame` (the frame the pair reaches at its rest values; `frame` itself, i.e. all-zero rest values, when left out), `ranges` (one entry per freedom of `kind`, each unbounded or a lower/upper pair; left out entirely for a kind that allows none), and `pitch` (required and non-zero for `screw`, refused for any other kind). An unknown or already-paired joint, an unknown kind, a bad pitch, ranges given where none are allowed or of the wrong length, a non-finite or inverted range, or an `end_frame` this kind's motion cannot reach (or reaches only outside a given range) raises `BuildError`, and the assembly is left as it was.

```python
assembly.pair_with(joint: str, kind: str, frame: FrameLike, end_frame: FrameLike | None = None, ranges: Iterable[Sequence[float | None] | None] | None = None, params: Iterable[float] = ()) -> None
```
`Assembly.pair()` with the kind's own numbers, `params`, in place of the pitch — for the coupled pairs: `kind` any kind `pair` takes, or `gear` or `rack_and_pinion`; `params` `[pitch]` for `screw`, `[pinion_radius]` for `rack_and_pinion`, `[radius_first, radius_second, ratio]` or those plus `[bevel, helical_angle]` (radians) for `gear` — the ratio the second link's rotation over the first's, signed, so two meshing external gears have a negative one — and none for any other kind. Written as AP242's `screw_pair`, `rack_and_pinion_pair` and `gear_pair` (whose `gear_ratio` is the ratio negated); a reader `Scene` gives them back as `Pair.kind_name` and `Pair.parameters`, and posing turns a coupled joint from its driver. A wrong number of parameters, a non-finite one, a zero pitch, radius or ratio, or anything `pair` refuses raises `BuildError`, and the assembly is left as it was.

```python
assembly.state(name: str, values: Mapping[str, Sequence[float]] | Iterable[tuple[str, Sequence[float]]]) -> None
```
Add a named state: the rows (Python: a mapping, or an iterable of (joint, values) pairs) set each named joint to its values, in that joint's pair's freedom order. An empty or duplicate name, no rows, an unknown joint, a joint set twice, a joint with no pair or none of its pair's freedoms, a row of the wrong length, or a non-finite or out-of-range value raises `BuildError`, and the assembly is left as it was.

```python
assembly.sequence(name: str, segments: Iterable[tuple[str, float, str]], seconds: bool = False) -> None
```
Add a named motion sequence over this assembly's states: `segments` are (state name, parameter, interpolation) rows, the interpolation one of `"undefined"`, `"discontinuous"`, `"synchronous"` or `"linear"`, and `seconds` writes the parameter's unit as the second. Closed or open is the last segment's interpolation: closed unless it is `"discontinuous"`. An empty or duplicate name, fewer than two segments, an unknown state, a non-finite or decreasing parameter, or an unknown interpolation raises `BuildError`, and the assembly is left as it was.

```python
assembly.base(link: str) -> None
```
Declare this assembly's base link. `link` naming no link of this assembly, or a base already declared, raises `BuildError` naming the link already there.

```python
assembly.posed(values: Mapping[JointKey, float | Sequence[float]] | Iterable[tuple[JointKey, float | Sequence[float]]] | None = None, state: JointKey | None = None, ground: str | None = None) -> Assembly
```
This assembly with its mechanism posed, as a new assembly; this one is left as it was. Each joint is named by its path — the placement names down the tree, then the joint's name, joined by `/` (`"drive FL/spin"`), a `/` or `\` inside a name escaped with `\` — or by its bare name, which means a joint of this assembly by that name, else the only joint of that name anywhere under it; each copy of a sub-assembly placed more than once poses on its own. Values are absolute, one per freedom of the joint's pair, radians for rotations and the assembly's units for translations. A state's path is applied first and overridden joint by joint; `ground` names one of this assembly's links to hold fixed (default: its base, else its busiest link). A sub-assembly no key reaches is shared with this one. An unknown or ambiguous key, a joint given twice, one without a pair, the wrong number of values, a value that is not finite or is outside its range, an unknown state or link, or a loop the pose leaves open raises `BuildError`. Whether the parts meet on the way from one pose to the next is `Assembly.swept_clash()`'s question.

```python
assembly.parts() -> list[str]
```
The placement path of every solid under this assembly, at any depth: depth first, placements in order, the placement names down the tree joined by `/`, a `/` or `\` inside a name escaped with `\`, as `Assembly.posed()`'s keys are (`"a\/b/x"` for part `x` of a sub-assembly placed as `a/b`). The index `Assembly.swept_clash()`'s rows use. Empty for an assembly that places no solid.

```python
assembly.swept_clash(keyframes: Iterable[Mapping[JointKey, float | Sequence[float]] | Iterable[tuple[JointKey, float | Sequence[float]]]], clearance: float = 0.0, tolerance: float = 0.05, resolution: float = 0.001, max_steps: int = 100000, allowed: Iterable[tuple[int, int]] = (), ground: str | None = None, joined: bool = False) -> list[SweptClash]
```
Every pair of this assembly's solids, indexed as `Assembly.parts()` lists them, that penetrates, touches or comes within `clearance` of the other anywhere while this assembly's own mechanism moves through `keyframes`, as `SweptClash` rows in pair order. Each keyframe maps joint keys to values as `Assembly.posed()`'s values do, and every keyframe names the same joints with the same number of values each (the first keyframe fixes their order); time runs in keyframe units, keyframe `k` at time `k`.

Between two keyframes each joint value moves linearly and each link is posed from those values, as `Assembly.posed()` poses it: a link swinging about a joint goes round its arc, not along its chord, and a coupled joint turns from its driver. Only this assembly's own joints move: a key into a sub-assembly is refused, and a sub-assembly rides the link its placement is in. `ground` names one of this assembly's links to hold fixed (default: its base, else its busiest link); solids in no link stay still too. Pairs on the two links a joint joins are not tested unless `joined`; `allowed` pairs of part indices are never tested. `tolerance` (0.05 by default) meshes the parts; the guarantee, `resolution` and `max_steps` are `Collider.swept_clash()`'s, and each row's `first` is the `Clash` at the posed frames, so its `Clash.solid()` rebuilds the contact.

Fewer than two keyframes, keyframes naming different joints or a different number of values for one, a joint given twice, a key into a sub-assembly, anything `Assembly.posed()` refuses of a key or its values, an unknown `ground`, a loop the motion leaves open, an `allowed` pair that is not two indices or one out of range, a part that is not a closed solid, or a bad tolerance, `clearance`, `resolution` or `max_steps` raises `BuildError`; the kernel's own words are prefixed `swept_clash:`.

```python
assembly.step_text(schema: Schema = None, unit: Unit = 'mm') -> str
```
This assembly, and everything placed under it, as one STEP file: this assembly the root product, each sub-assembly and each distinct part (the same solid with the same paint and name) written once, each placement an occurrence named as it was placed. `schema` and `unit` as `write_step`. An assembly reachable from this one, this one included, that places nothing raises `BuildError` — a reader would never show it.

```python
assembly.step(path: FilePath, schema: Schema = None, unit: Unit = 'mm') -> None
```
`Assembly.step_text()` written to a file.

```python
assembly.to_scene(schema: Schema = None) -> cadaclysm.Scene
```
This assembly as a reader `Scene`, through STEP in memory; see `Solid.to_scene()`.

```python
assembly.close() -> None
```
Free this handle now. The garbage collector, or the language's scope, does it otherwise.

### Edge

```python
class Edge
```

One edge of a solid as plain data, copied out of it: what `Solid.edges` lists and `Solid.fillet()` takes.

A method that takes edges — `Solid.fillet()`, `Solid.chamfer()`, `Solid.edges_coloured()` — takes a list of them, `Edge` values or their indices, and refuses a single one: one edge is a list of one. So do the face and corner lists of `Solid.drop_faces()`, `Solid.shell()` and `Profile.round()`; `Solid.push_pull()` takes one face on its own or a list.

```python
edge.index  (attribute)
```
Its index — what `Solid.fillet()` and `Solid.chamfer()` take.

```python
edge.kind  (attribute)
```
The curve: `line`, `circle`, `ellipse`, `parabola`, `hyperbola`, `nurbs` or `other`.

```python
edge.faces  (attribute)
```
The faces meeting on it, as face indices.

```python
edge.segments  (attribute)
```
The two ends of each piece of the edge.

```python
edge.curve  (attribute)
```
The edge's exact curve, as a `Curve` — `None` for an edge with no exact curve (kind `other`). Filled when the edges are listed, so the edge stays plain data.

```python
edge.is_line: bool  (property)
```
Whether the edge is straight.

```python
edge.direction: tuple[float, float, float] | None  (property)
```
The unit direction of a straight edge, or `None` for a curved one. Picking the vertical edges of a plate is a filter on this.

### Curve

```python
class Curve
```

One edge's, or one intersection chain's, exact curve as plain data, copied out: what `Edge.curve` or `Chain.curve` holds. `kind` is `line`, `circle`, `ellipse`, `parabola`, `hyperbola` or `nurbs`.

`t0..t1` is the edge's (or the chain's) parameter range on its own curve: a line's fraction (0..1 over `origin -> origin + x`, where `x` is the full `to - from`, NOT unit — so `point(t) = origin + x*t`); a circle's or ellipse's angle in radians about `origin` in the `x, y` plane (`point(t) = origin + x*radius*cos(t) + y*radius2*sin(t)`, `radius2 = radius` for a circle); a parabola's own parameter with `radius` its focal length `F` (`point(t) = origin + x*F*t*t + y*2*F*t`, `radius2` 0); a hyperbola's with `radius, radius2` its semi-axes `a, b` (`point(t) = origin + x*a*cosh(t) + y*b*sinh(t)`); a NURBS's knot parameter (`knots[degree] <= t0 < t1 <= knots[n]`). Frame vectors `x, y, z` are unit for conics; for a line `x` is the direction with length = the line's length and `y, z` are zero. Always `t0 < t1`: an edge whose segments run against its curve's own parameter reports the same range — read the direction from `Edge.segments`, not from the range. A chain's `Chain.points` always run WITH the curve's own parameter instead: `point(t0)` is the chain's first point and `point(t1)` its last for an open chain (a closed chain simply goes once round, `t0..t1` its whole domain).

For a NURBS the frame is zero and so are the radii; for a conic or a line `degree` is 0 and `knots`, `poles` are empty. Evaluating `point(t)` is left to the caller for now.

```python
curve.kind  (attribute)
```
The curve: `line`, `circle`, `ellipse`, `parabola`, `hyperbola` or `nurbs`. Never `other`: a curve of that kind is `None` instead.

```python
curve.origin  (attribute)
```
The frame's origin, three numbers: a circle's or ellipse's centre, a parabola's vertex, a hyperbola's centre, a line's start. Zero for a NURBS.

```python
curve.x  (attribute)
```
The frame's first axis: a conic's unit direction at angle 0 (a parabola's or hyperbola's axis); for a line the whole `to - from`, so `origin + x` is its far end. Zero for a NURBS.

```python
curve.y  (attribute)
```
The frame's second axis: a conic's unit direction at a quarter turn. Zero for a line or a NURBS.

```python
curve.z  (attribute)
```
The frame's normal, `x` cross `y`, unit for a conic. Zero for a line or a NURBS.

```python
curve.radius  (attribute)
```
A circle's radius, an ellipse's along `x`, a parabola's focal length, a hyperbola's semi-axis along `x`; 0 for a line or a NURBS.

```python
curve.radius2  (attribute)
```
An ellipse's radius along `y`, a hyperbola's semi-axis along `y`; equal to `radius` for a circle; 0 for a parabola, a line or a NURBS.

```python
curve.t0  (attribute)
```
Where the edge starts on the curve, in the range convention above.

```python
curve.t1  (attribute)
```
Where it ends: greater than `t0`. A whole circle is one edge, `t1 - t0` a full turn. On a conic `t1` may exceed 2pi when the arc crosses angle 0 (say `t0` 5.6, `t1` 7.0): keep the angles as reported and never normalise them into `0..2pi`, or the arc is drawn the long way round.

```python
curve.degree  (attribute)
```
A NURBS's degree; 0 for a conic or a line.

```python
curve.knots  (attribute)
```
A NURBS's knot vector, `poles + degree + 1` long; empty for a conic or a line.

```python
curve.poles  (attribute)
```
A NURBS's control points, three numbers each; empty for a conic or a line.

```python
curve.value: Line | Circle | Arc | Ellipse | None  (property)
```
This curve as a value: a line a `Line` from `origin` to `origin + x`; a circle a `Circle` over a full turn, else the `Arc` over `t0..t1`; an ellipse its whole `Ellipse` (the range stays here: there is no elliptical-arc value); any other kind `None`.

```python
curve.weights  (attribute)
```
One weight per pole for a rational NURBS; `None` for a plain (non-rational) B-spline, a conic or a line.

### Mass

```python
class Mass
```

What a body measures, per unit density: what `Solid.mass()` returns. Every figure carries a bound on its own error, because a measurement without one cannot be compared with anybody else's — including another kernel's. Measured on the exact surfaces where a face has one and on a mesh where it has not, which `Mass.from_mesh` reports.

```python
mass.closed  (attribute)
```
The body is topologically closed. Only then do the volume, the centroid and the inertia mean anything; they are not numbers at all otherwise.

```python
mass.inverted  (attribute)
```
Every face pointed inward. The figures are given as if they had not.

```python
mass.accuracy_met  (attribute)
```
Every error came under the accuracy asked for. `false` where the refinement gave up first — the values and their errors are still honest, simply less certain.

```python
mass.from_mesh  (attribute)
```
Measured on a mesh rather than on exact surfaces: exact for that mesh, and its errors are then the rounding floor rather than a statement about the surface.

```python
Mass.of(solid: 'Solid', accuracy: float = 0.0) -> Mass
```
Measure `solid` at `accuracy`, which is the same call as `Solid.mass()` written the other way round: `Mass.of(solid)` where the body reads better as the object of the sentence.

```python
mass.mass(density: float) -> float
```
`density * volume`, in whatever units the model and the density agree on. Per unit density is what everything here is, because an assembly of two materials would have to undo a density applied on its behalf — so `Mass.of(part).mass(7850)` is a steel part in kilograms where the model is in metres, and the inertia scales the same way.

```python
mass.area  (attribute)
```
The surface area.

```python
mass.area_error  (attribute)
```
A bound on `area`'s own error.

```python
mass.volume  (attribute)
```
The volume enclosed, where `Mass.closed`.

```python
mass.volume_error  (attribute)
```
A bound on `volume`'s own error.

```python
mass.centroid  (attribute)
```
The volume's centroid, where `Mass.closed`.

```python
mass.centroid_error  (attribute)
```
A bound on the distance from `centroid` to the true centroid.

```python
mass.inertia  (attribute)
```
The inertia tensor about the centroid, row-major and symmetric, products of inertia negated (`inertia[0][1]` is minus the integral of `(x - gx)(y - gy)`).

```python
mass.inertia_error  (attribute)
```
A bound on every entry of `inertia`.

```python
mass.principal_moments  (attribute)
```
The tensor's eigenvalues, ascending.

```python
mass.principal_axes  (attribute)
```
Their axes, one unit vector each, in the same order.

### OrientedBox

```python
class OrientedBox
```

What `Solid.oriented_box()` returns: a closed solid's box on its principal axes. Not the minimal box in general, and with equal moments the axes are a free choice; see `Solid.oriented_box()`.

```python
orientedBox.centre  (attribute)
```
The box's middle, not the body's centroid.

```python
orientedBox.axes  (attribute)
```
The three unit axes, one row each: orthonormal and right-handed.

```python
orientedBox.half  (attribute)
```
The half-extent along each axis, grown by the tolerance the measurement settled on.

### Length

```python
class Length
```

A measured length — what `Solid.edge_length()` and `Profile.length()` return — beside an estimate of its error. The error is an estimate of the distance from the true length, not a proof.

```python
length.length  (attribute)
```
The length.

```python
length.error  (attribute)
```
An estimate of how far `length` is from the true length.

```python
length.accuracy_met  (attribute)
```
The error came under the accuracy asked for. `false` where the refinement stopped at its depth limit first: the figure is then less certain than was asked, and `error` says by how much.

```python
length.from_polyline  (attribute)
```
The curve was a sampled polyline: exact for its points and not for whatever they were sampled from.

### NurbsCurve

```python
class NurbsCurve
```

A curve in space to model with — always a NURBS, so a line, an arc or a conic is an exact rational one. `NurbsCurve(points, degree=3, weights=None, knots=None)` builds one from its control points (degree 1 to 7; weights positive, one per point; the full knot vector, non-decreasing, or None for clamped and uniform); `NurbsCurve.through()`, `NurbsCurve.fit()`, `NurbsCurve.from_edge()`, `NurbsCurve.isocurve()` and `NurbsCurve.blend()` build the rest. Immutable: every edit returns a new curve. Not `Curve`, the plain data an edge's curve is copied out as.

**A face is its whole surface here**: projecting onto, pulling to and crossing a face ignore its trims, so a curve projected past a face's edge lands on the surface's continuation. A curve projected or pulled onto a face is a 3D curve fitted through points on the surface, within the tolerance asked (`NurbsCurve.fit_error` says how close it came), not a curve in the face's parameters. Native Python only for now: under Pyodide every builder raises `BuildError`. Every refusal names the C call, e.g. `nurbs_curve_trimmed: ...`.

```python
NurbsCurve.through(points: 'Iterable[Point3]', degree: int = 3, closed: bool = False, start_tangent: 'Point3 | None' = None, end_tangent: 'Point3 | None' = None) -> NurbsCurve
```
The curve of `degree` through `points` in order, chord-length parametrised. `closed=True` closes it back to the first point, smooth across the seam (`C^(degree-1)`); an open curve may leave along `start_tangent` and arrive along `end_tangent` (directions; their length does not matter). Too few points for the degree, a point repeating the one before it, or a closed curve given end tangents, raises `BuildError`.

```python
NurbsCurve.fit(points: 'Iterable[Point3]', degree: int = 3, tolerance: float = 0.001) -> NurbsCurve
```
A curve of `degree` within `tolerance` of every point, through the first and the last (least squares, growing its control points until the tolerance is met); its `NurbsCurve.fit_error` is the largest distance from a point to it. A tolerance not positive raises `BuildError`.

```python
NurbsCurve.from_edge(solid: 'Solid', edge: 'Edge | int') -> NurbsCurve
```
Edge `edge` of `solid` (an `Edge` or its index) as an exact NURBS over the edge's own span of its curve, running the way the edge runs. An edge with no exact curve raises `BuildError`.

```python
NurbsCurve.isocurve(solid: 'Solid', face: int, along_u: bool, at: float) -> NurbsCurve
```
The isocurve of face `face` of `solid`'s surface: along `u` at `v = at` when `along_u`, else along `v` at `u = at`. NURBS faces only: a plane or a quadric face raises `BuildError`, as does an `at` outside the surface's domain.

```python
NurbsCurve.blend(a: 'NurbsCurve', a_end: bool, b: 'NurbsCurve', b_end: bool, continuity: int = 2, bulge: float = 1.0) -> NurbsCurve
```
The curve bridging `a` (at its end when `a_end`, else its start) to `b` (at its end when `b_end`, else its start), leaving `a` and arriving at `b` along their tangents: `continuity` 1 matches position and tangent (a cubic), 2 also the curvature (a quintic). `bulge` (positive, 1 usual) scales how far the tangents reach. Two ends at the same point raises `BuildError`.

```python
nurbsCurve.projected_to_plane(origin: 'Point3', normal: 'Point3', direction: 'Point3 | None' = None) -> NurbsCurve
```
This curve projected onto the plane through `origin` with `normal`, along `direction` (None: the normal). Exact — the control points move, the weights stay. A direction lying in the plane raises `BuildError`.

```python
nurbsCurve.projected_to_face(solid: 'Solid', face: int, direction: 'Point3', tolerance: float = 0.001) -> NurbsCurve
```
This curve projected along `direction` onto face `face` of `solid` (its whole surface): sampled, each sample carried along the direction to the surface, fitted within `tolerance`. A sample whose ray misses the surface, or a result straying past the tolerance, raises `BuildError`.

```python
nurbsCurve.pulled_to_face(solid: 'Solid', face: int, tolerance: float = 0.001) -> NurbsCurve
```
This curve pulled onto face `face` of `solid` (its whole surface): each sample moved to its nearest surface point, fitted within `tolerance`.

```python
nurbsCurve.reversed() -> NurbsCurve
```
The same curve run the other way over the same domain.

```python
nurbsCurve.trimmed(t0: float, t1: float) -> NurbsCurve
```
The part from `t0` to `t1` (`t0 < t1`, both inside the domain), over `t0..t1`.

```python
nurbsCurve.extended(length: float, at_start: bool = False) -> NurbsCurve
```
This curve continued `length` past its end (or its start, `at_start=True`) along its own end polynomial: position, tangent and curvature there unchanged, and every old parameter still names its old point — the domain grows on that side only.

```python
nurbsCurve.elevated(by: int = 1) -> NurbsCurve
```
The same curve at degree `degree + by` (the result at most 12).

```python
nurbsCurve.transformed(t: 'Transform | Sequence[float]') -> NurbsCurve
```
This curve through the affine map `t` (a `Transform` or 16 numbers): its control points mapped, weights and knots kept — exact. A singular map, a projection, is allowed.

```python
nurbsCurve.degree: int  (property)
```
The curve's degree.

```python
nurbsCurve.control_points: tuple[tuple[float, float, float], ...]  (property)
```
The control points, as `(x, y, z)` triples.

```python
nurbsCurve.weights: tuple[float, ...]  (property)
```
One weight per control point; all 1 for a plain B-spline.

```python
nurbsCurve.knots: tuple[float, ...]  (property)
```
The full knot vector, `len(control_points) + degree + 1` values.

```python
nurbsCurve.domain: tuple[float, float]  (property)
```
The parameter domain `(lo, hi)`.

```python
nurbsCurve.is_rational: bool  (property)
```
Whether the weights differ: a true NURBS rather than a plain B-spline.

```python
nurbsCurve.is_closed: bool  (property)
```
Whether the curve ends where it starts (to `1e-10` of its size).

```python
nurbsCurve.point(t: float) -> tuple[float, float, float]
```
The point at parameter `t`; a `t` outside the domain raises `BuildError`.

```python
nurbsCurve.derivatives(t: float, order: int = 2) -> list[tuple[float, float, float]]
```
The point and its derivatives at `t` up to `order` (at most 8): `[C, C', C'', ...]`.

```python
nurbsCurve.curvature(t: float) -> Curvature
```
The `Curvature` and Frenet frame at `t`. A point where the curve has no tangent raises `BuildError`.

```python
nurbsCurve.length(accuracy: float = 0.0) -> Length
```
The curve's length as a `Length`, to the relative `accuracy` (0 asks for the default).

```python
nurbsCurve.point_at_length(s: float, accuracy: float = 0.0) -> At
```
The point at arc length `s` from the start, as an `At` (`segment` empty).

```python
nurbsCurve.divide_by_count(n: int, accuracy: float = 0.0) -> list[At]
```
The curve in `n` pieces of equal arc length: `n + 1` `At` samples, `n` for a closed curve (its start not repeated).

```python
nurbsCurve.divide_by_length(step: float, accuracy: float = 0.0) -> list[At]
```
Samples every `step` of arc length from the start; the last piece is whatever is left, and a closed curve never repeats its start.

```python
nurbsCurve.plane_hits(origin: 'Point3', normal: 'Point3') -> list[At]
```
Where the curve crosses the plane through `origin` with `normal`, in parameter order, each an `At` whose `error` is the point's distance from the plane. A curve lying in the plane raises `BuildError`; a touch that does not cross is not listed.

```python
nurbsCurve.face_hits(solid: 'Solid', face: int, tolerance: float = 0.001) -> list[At]
```
Where the curve crosses face `face` of `solid` (its whole surface), within `tolerance` of it, in parameter order, each an `At` whose `error` is the point's distance from the surface. A touch that does not cross is not listed.

```python
nurbsCurve.comb(n: int = 64, scale: float = 1.0) -> list[tuple[tuple[float, float, float], tuple[float, float, float]]]
```
A curvature comb to draw: at `n + 1` even parameters, the curve point and that point moved by `-scale * kappa * normal`, out of the bend. Straight stretches give zero teeth.

```python
nurbsCurve.fit_error  (attribute)
```
On a curve from `NurbsCurve.fit()`, `NurbsCurve.projected_to_face()` or `NurbsCurve.pulled_to_face()`, the largest distance found between it and what it was fitted to; `None` on any other.

### HealthReport

```python
class HealthReport
```

What is wrong with a body, as plain data: what `Solid.health()` returns. Nothing in it moves the body. It lists the free edges (the sides only one face bounds) and the wires they chain into, the features below the tolerance, the loose edges, what sewing would join and leave, and, if asked for, where the body's mesh cracks. The tolerance is an absolute length, as Rhino's model tolerance is; it is reported back as used.

```python
healthReport.tolerance  (attribute)
```
The length below which a feature is small and a gap closes, as used: by default `1e-4` times the body's diagonal. A value that is not finite and positive (NaN, infinite, zero or negative) takes the default.

```python
healthReport.rounding  (attribute)
```
The rounding the body's vertices are merged at, as used.

```python
healthReport.extent  (attribute)
```
The body's diagonal, the length the default tolerance is a fraction of.

```python
healthReport.free_edges  (attribute)
```
The free edges, as `FreeEdge` rows, each wire's edges together and in order.

```python
healthReport.wires  (attribute)
```
The chains the free edges make end to end, as `FreeWire` rows.

```python
healthReport.small  (attribute)
```
The features below the tolerance, as `SmallFeature` rows.

```python
healthReport.loose_edges  (attribute)
```
How many shared edges are loose: the two faces' sides along the edge lie further apart than the larger of the tolerance the body recorded for the edge and the one given.

```python
healthReport.worst_loose  (attribute)
```
The widest such gap; 0 when no edge is loose.

```python
healthReport.sew_pairs  (attribute)
```
How many pairs of free edges `Brep.sewed` (or `Solid.join_sheets()`) would join: those with `shared_ends` 2.

```python
healthReport.sew_refused  (attribute)
```
How many groups of free edges it would leave free.

```python
healthReport.sew_worst_gap  (attribute)
```
The widest gap it would sew.

```python
healthReport.cracks  (attribute)
```
Where the body's mesh cracks, as a `Cracks`; `None` unless the call asked for the mesh. Cracks are only counted on a closed body: for an open one the census is empty by design, so `watertight` false beside no edges means "not asked", not "nothing found".

```python
healthReport.worst_gap: float  (property)
```
The widest gap between a free edge and its partner. A rim has no true partner, so it reads as a gap the size of the part.

```python
healthReport.wire_edges(wire: int) -> tuple[FreeEdge, ...]
```
The free edges of one wire, by its number in `wires`, in order.

### FreeEdge

```python
class FreeEdge
```

One free edge: a side only one face bounds, with its nearest partner. The partner is the nearest free edge other than a neighbour on its own wire, so the rim of a sheet reads as a gap the size of the part rather than as a crack, and a real seam reads as a small gap. The partner is a row index into `free_edges`.

```python
freeEdge.trim  (attribute)
```
The face's side this is.

```python
freeEdge.edge  (attribute)
```
The edge it lies on; `None` for a side that has no edge.

```python
freeEdge.face  (attribute)
```
The face it bounds.

```python
freeEdge.wire  (attribute)
```
The free wire it is on: a row of `wires`.

```python
freeEdge.partner  (attribute)
```
The nearest free edge across the gap, as an index into `free_edges`; `None` if there is none.

```python
freeEdge.shared_ends  (attribute)
```
How many of its two ends it shares with the partner: 2 is what `Brep.sewed` joins.

```python
freeEdge.length  (attribute)
```
Its length.

```python
freeEdge.gap  (attribute)
```
The distance to the partner; infinite without one.

### FreeWire

```python
class FreeWire
```

A chain of free edges end to end.

```python
freeWire.first  (attribute)
```
The row of `free_edges` it starts at: its edges are the rows `first` to `first + count`.

```python
freeWire.count  (attribute)
```
How many free edges it holds.

```python
freeWire.closed  (attribute)
```
Whether it closes on itself.

```python
freeWire.length  (attribute)
```
Its total length.

```python
freeWire.widest_gap  (attribute)
```
The widest gap from any of its edges to a partner.

### SmallFeature

```python
class SmallFeature
```

Something below the tolerance.

```python
smallFeature.kind  (attribute)
```
What it is: `short_edge`, `collapsed_edge`, `sliver_face`, `tiny_face`, `tiny_body` or `small_hole` (an inner loop whose edges are all free, below the tolerance in area or width: a pinhole in an open sheet; a hole with walls is not one).

```python
smallFeature.index  (attribute)
```
Its edge, face or body number; a small hole's is its loop number.

```python
smallFeature.size  (attribute)
```
How small it is.

### Cracks

```python
class Cracks
```

What a mesh of the body shows, asked for with `mesh=True`: the call meshes the body. Only a closed body is counted: an open one's census is empty by design, as its rim is not a crack.

```python
cracks.watertight  (attribute)
```
Whether the mesh has no open or folded edge.

```python
cracks.open  (attribute)
```
How many mesh edges only one triangle uses.

```python
cracks.folded  (attribute)
```
How many mesh edges more than two triangles use.

```python
cracks.crossings  (attribute)
```
How many pairs of triangles pass through each other.

```python
cracks.edges  (attribute)
```
The body's edges the cracks lie along.

### HealReport

```python
class HealReport
```

What `Solid.healed()` did, as plain data: the fixes it made, the small features it left and why, and the body's health before and after at the tolerance it healed at. Indices are the input body's.

```python
healReport.tolerance  (attribute)
```
The tolerance it healed at, as used: by default `1e-4` times the body's diagonal.

```python
healReport.moved  (attribute)
```
The furthest any trim the result keeps moved, measured: the edited trims against the originals. Not the same measure as a `HealFix`'s `moved`, which is how far that fix's merged vertices moved: a curve can move further than its ends, and the trims of a dropped edge are not measured at all, so either can be the larger.

```python
healReport.guarded  (attribute)
```
Whether the guard refused a fix: the full result was worse (less closed, more free or non-manifold edges, or no faces left), so the face pass's fixes were refused and the rest kept, or, if that was still worse, every fix was refused and the body came back as it was. Refused fixes are listed as `body_guard`.

```python
healReport.fixes  (attribute)
```
What was done, as `HealFix` rows, in the order it was done. A short edge removed as part of a face is that face's fix and is not listed again.

```python
healReport.refused  (attribute)
```
What `health` listed as small and was left, as `HealRefusal` rows.

```python
healReport.small_before  (attribute)
```
How many small features `health` listed on the input.

```python
healReport.small_after  (attribute)
```
How many it lists on the result.

```python
healReport.free_before  (attribute)
```
The input's free edges (sides only one face bounds).

```python
healReport.free_after  (attribute)
```
The result's free edges.

```python
healReport.closed_before  (attribute)
```
Whether the input was closed.

```python
healReport.closed_after  (attribute)
```
Whether the result is closed.

```python
healReport.nonmanifold_before  (attribute)
```
The input's edges three or more faces share.

```python
healReport.nonmanifold_after  (attribute)
```
The result's.

### HealFix

```python
class HealFix
```

One small feature removed.

```python
healFix.kind  (attribute)
```
What it was, as `SmallFeature`'s `kind`.

```python
healFix.index  (attribute)
```
Its edge, face or loop number in the input, as `health` gave it.

```python
healFix.size  (attribute)
```
How small it was.

```python
healFix.moved  (attribute)
```
How far the vertices this fix merged moved. The report's own `moved` is a second measure, how far any surviving trim moved, measured; either can be the larger.

### HealRefusal

```python
class HealRefusal
```

One small feature left, and why.

```python
healRefusal.kind  (attribute)
```
What it is, as `SmallFeature`'s `kind`.

```python
healRefusal.index  (attribute)
```
Its edge, face or loop number in the input.

```python
healRefusal.why  (attribute)
```
`would_empty_loop` (removing the edge would leave a loop with no trims: the face pass's case), `closed` (both ends already one vertex: a tiny closed curve), `seam` (one face uses the edge twice), `chain` (the vertices to merge span more than the tolerance), `neighbours_part` (a sliver's two long sides part by more than the tolerance), `uneven` (a sliver's long edges are not two, one per side), `non_manifold` (a sliver side three or more trims share), `has_holes` (the sliver or tiny face has inner loops), `body_guard` (the guard refused the fix), `toggled` (its kind switched off) or `unsupported` (a tiny body, which healing never removes).

```python
healRefusal.figure  (attribute)
```
The width of a `chain`, the gap of `neighbours_part`; 0 otherwise.

### JoinReport

```python
class JoinReport
```

What `Solid.join_sheets()` did.

```python
joinReport.sewn  (attribute)
```
Edges sewn: each is two naked edges become one shared edge.

```python
joinReport.worst_gap  (attribute)
```
The widest gap between two sewn edges; 0 where every edge met exactly.

```python
joinReport.naked_before  (attribute)
```
Edges bordered by one face before the sewing.

```python
joinReport.naked_after  (attribute)
```
Edges bordered by one face after it: 0 for a closed result.

```python
joinReport.refused  (attribute)
```
Groups of naked edges sharing both ends that were left apart: too far apart, or three or more.

```python
joinReport.turned  (attribute)
```
Faces whose sense the join turned.

```python
joinReport.closed  (attribute)
```
Whether the result is closed — every edge bordered twice — and so a solid.

### Continuity

```python
class Continuity
```

How well two faces meet along their sides — what `Solid.continuity()` returns. The angle ignores which way each face points; the curvature is the normal curvature square to the edge, about the first face's normal.

```python
continuity.gap  (attribute)
```
The largest distance between the two sides (G0).

```python
continuity.gap_at  (attribute)
```
Where on the first side it is.

```python
continuity.angle  (attribute)
```
The largest angle between the faces' normals, in radians (G1).

```python
continuity.angle_at  (attribute)
```
Where on the first side it is.

```python
continuity.curvature  (attribute)
```
The largest difference of normal curvature across the edge (G2).

```python
continuity.curvature_at  (attribute)
```
Where on the first side it is.

```python
continuity.samples  (attribute)
```
How many points along the first side were asked.

### Curvature

```python
class Curvature
```

A curve's bending at a parameter — what `NurbsCurve.curvature()` returns.

```python
curvature.kappa  (attribute)
```
The curvature, 1 / radius; 0 on a straight piece.

```python
curvature.tangent  (attribute)
```
The unit tangent, along increasing parameter.

```python
curvature.normal  (attribute)
```
The unit normal toward the centre of curvature; zero on a straight piece.

```python
curvature.binormal  (attribute)
```
`tangent x normal`; zero on a straight piece.

```python
curvature.centre  (attribute)
```
The centre of the osculating circle, or `None` on a straight piece.

### At

```python
class At
```

A point at arc length — what `Solid.edge_point_at_length()` and `Profile.point_at_length()` return, and each sample of the divides — beside an estimate of how far its arc length can be trusted.

```python
at.point  (attribute)
```
The point.

```python
at.tangent  (attribute)
```
The unit tangent there, along the edge or loop; zero where the curve stops.

```python
at.parameter  (attribute)
```
The curve's own parameter at the point: on an edge, its curve's (a circle's angle, a line's fraction); on a profile, its side's (a line's 0 to 1, an arc's angle about its centre — a clockwise arc's decreasing along it — a spline's parameter).

```python
at.segment  (attribute)
```
On a profile, the side the point lies on: its segment's index, or the segment count for the implicit closing side. Empty on an edge (`None` in Python, `CADACLYSM_BLACKSMITH_NONE` in C).

```python
at.error  (attribute)
```
An estimate of how far the true arc length to the point is from the `s` asked for: the length's error up to it plus the inversion's own residual.

```python
at.from_polyline  (attribute)
```
The curve was a sampled polyline: exact for its points and not for whatever they were sampled from.

### Classifier

```python
class Classifier
```

A closed solid meshed once and asked where point after point lies: what `Solid.classifier()` returns. It keeps its own reference to the body. Calls on one classifier take turns (a lock inside the library), so build one per thread to classify in parallel.

```python
classifier.contains(point: Point3) -> str
```
Where `point` is: inside, outside, or on within the tolerance of the boundary. A point not finite raises `BuildError`.

```python
classifier.close() -> None
```
Free the handle. Leaving a `with` block or the garbage collector does the same.

### Closest

```python
class Closest
```

The closest points between two solids' boundaries: what `Solid.closest()` returns, side `a` the solid asked and side `b` the other. Each side names the feature its point lies on.

```python
closest.distance  (attribute)
```
The distance between the two points.

```python
closest.on_a  (attribute)
```
The point on side `a`.

```python
closest.on_b  (attribute)
```
The point on side `b`.

```python
closest.kind_a  (attribute)
```
What side `a`'s point lies on: `"face"`, `"edge"` or `"vertex"`.

```python
closest.index_a  (attribute)
```
The kernel's id for side `a`'s feature.

```python
closest.edge_a  (attribute)
```
Side `a`'s edge as the index `Solid.edges` uses; none for a face or a vertex, and for an edge the fillet table does not hold (a trim with no exact curve).

```python
closest.kind_b  (attribute)
```
What side `b`'s point lies on: `"face"`, `"edge"` or `"vertex"`.

```python
closest.index_b  (attribute)
```
The kernel's id for side `b`'s feature.

```python
closest.edge_b  (attribute)
```
Side `b`'s edge, as `edge_a`.

```python
closest.refined  (attribute)
```
A refined answer is never below the true minimum and within the tolerance of it wherever the face pair holding the minimum refines to its own nearest pair. Where a nearer candidate did not converge, or left its trims and its boundary search found nothing, the mesh's answer comes back instead with `refined` false: within `[d - 2/3 tolerance, d + tolerance]` of the true minimum `d`.

### Beziers

```python
class Beziers
```

What `Solid.silhouette_beziers()` returns: curves as cubic Béziers in double precision, four control points and four weights a curve. Unlike the reader's `Beziers`, the arrays are the wrapper's own — the kernel hands its buffer over and the wrapper releases it before the call returns — so there is nothing to outlive; they are read-only views over one copy kept alive by the arrays themselves.

```python
beziers.points  (attribute)
```
Four control points a curve, three doubles each: shape `(count, 4, 3)`.

```python
beziers.weights  (attribute)
```
A weight per control point, as doubles: shape `(count, 4)`. All ones for a polynomial curve, and the weights that make a circular arc exact for a rational one.

```python
beziers.count  (attribute)
```
How many curves. A `Beziers` is falsey when this is 0, the empty answer.

```python
beziers.copy() -> Beziers
```
The same arrays, writable and contiguous, in memory of your own.

### Box

```python
class Box
```

An axis-aligned box: `lo` and `hi`, three numbers each. The broad phase's own shape (`Solid.bounds_box()`, `Collider`'s own boxes): cheap to move and to test against another before anything is meshed.

```python
box.lo  (attribute)
```
The box's low corner.

```python
box.hi  (attribute)
```
The box's high corner.

```python
box.moved(frame: FrameLike) -> Box
```
This box moved by `frame` (rigid), boxed again on the world axes — not this box's corners individually moved, which would not in general be a box at all: the *bounding* box of the moved corners. A `frame` not twelve finite numbers or not rigid raises `BuildError`.

```python
box.overlaps(other: 'Box') -> bool
```
Whether this box and `other` share a point (touching counts).

### Region

```python
class Region
```

One region of space a solid's faces bound, as `Solid.regions()` returns it: a value, equal by value, that does not change. `Solid.region_solid()` takes a finite one as a solid of its own.

```python
region.index  (attribute)
```
Its index in `Solid.regions()`: 0 for the infinite region.

```python
region.finite  (attribute)
```
`False` for region 0, the one reaching to infinity; `True` for every other.

```python
region.box  (attribute)
```
The `Box` round the faces bounding it.

```python
region.sides  (attribute)
```
Every face side bounding it, as `FaceSide` values, ascending by face and then sense (-1 first).

```python
region.shells  (attribute)
```
How many connected boundaries it has: 1, plus one per void inside it.

### FaceSide

```python
class FaceSide
```

One side of one face, as a `Region` lists its sides: a value, equal by value.

```python
faceSide.face  (attribute)
```
The face's index in the solid.

```python
faceSide.sense  (attribute)
```
+1 for the side the face's normal points to, -1 for the other. A solid's inside is behind its faces, at -1.

### ColliderStats

```python
class ColliderStats
```

Counts of one `Collider.check()` call, as `Collider.stats` returns them (all zero before the first call): the candidate pairs `considered`, how many of them the world boxes and the oriented boxes cleared, how many the share left to another call, how the rest were answered (`cached`, `closed_form`, `meshed`), and how many were `refused`. `confirmed` is the subset of `meshed` that were thin mesh-path overlaps sent to `Solid.common()` itself for a final answer.

```python
colliderStats.considered  (attribute)
```
The candidate pairs looked at: every pair of parts in different groups, less any in `allowed` or `skipped_share`.

```python
colliderStats.world_boxes  (attribute)
```
Of those, how many two world boxes (`Box.overlaps()`) cleared at once — decided apart with no oriented test.

```python
colliderStats.oriented_boxes  (attribute)
```
Of the rest, how many `boxes_apart` cleared — decided apart on the parts' own oriented boxes.

```python
colliderStats.skipped_share  (attribute)
```
Pairs this call's `share` left to another call, not decided here at all.

```python
colliderStats.cached  (attribute)
```
Pairs answered from an earlier pose's cache rather than worked afresh.

```python
colliderStats.closed_form  (attribute)
```
Pairs decided by an exact formula (both parts a shape the kernel has one for), no mesh built.

```python
colliderStats.meshed  (attribute)
```
Pairs that needed a mesh-against-mesh test to decide.

```python
colliderStats.refused  (attribute)
```
Pairs that could not be decided at all — each a `CollisionHit` with `kind` `"refused"`.

```python
colliderStats.confirmed  (attribute)
```
Of `meshed`, how many thin mesh-path overlaps were sent on to `Solid.common()` itself for a final answer.

### CollisionHit

```python
class CollisionHit
```

One pair `Collider.check()` found overlapping (`kind` `"overlap"`), or could not decide (`kind` `"refused"`, `text` says why), as plain data. `positions`/`normals` are world xyz triples, three per triangle (unwelded); `indices` indexes them — all empty for a refused pair. `depth` is the thinnest side of the overlap's world box, 0 for a refused pair.

`CollisionHit.solid()` rebuilds the exact overlap now, from the frames `Collider.check()` found it at; this keeps the check call's own answer alive behind every hit of it until the last one is let go, freeing it only then.

```python
collisionHit.a  (attribute)
```
The first part's index, as given to `Collider`.

```python
collisionHit.b  (attribute)
```
The second part's index.

```python
collisionHit.kind  (attribute)
```
`"overlap"` or `"refused"`.

```python
collisionHit.depth  (attribute)
```
The thinnest side of the overlap's world box; 0 for a refused pair.

```python
collisionHit.text  (attribute)
```
Why a refused pair could not be decided; empty for an overlap.

```python
collisionHit.positions  (attribute)
```
The overlap solid's mesh positions, world xyz triples, three per triangle (unwelded); empty for a refused pair.

```python
collisionHit.normals  (attribute)
```
The overlap solid's mesh normals, matching `positions`; empty for a refused pair.

```python
collisionHit.indices  (attribute)
```
Indices into `positions`/`normals`; empty for a refused pair.

```python
collisionHit.solid() -> Solid
```
The exact overlap of this pair at the frames `Collider.check()` found it at, as a new `Solid`. raises `BuildError` for a refused pair (`kind` `"refused"`) or a `check` answer already closed some other way.

### Clash

```python
class Clash
```

One pair `clash` or `Collider.clash()` found, as plain data. `kind` is `"penetrating"` (the volumes overlap), `"touching"` (the boundaries are within the tolerance of each other), `"too_close"` (apart by more than the tolerance but less than the clearance) or `"refused"` (the pair could not be decided; `text` says why). The feature fields are `Closest`'s, flat: what each point lies on, by the kernel's id and the `Solid.edges` index; for a penetrating or refused pair there is no closest point, so `kind_a` and `kind_b` are `"none"` and `index_*` and `edge_*` are none.

`Clash.solid()` and `Clash.intersect()` are built on demand, from the placement the pair was found at; the answer of the call that found the rows is kept alive behind every row of it until the last one is let go, freeing it only then.

```python
clash.a  (attribute)
```
The first part's index: in the one set, or in the collider (then `a < b`); in `clash` with two sets, an index into `parts`.

```python
clash.b  (attribute)
```
The second part's index; with two sets, an index into `others`.

```python
clash.kind  (attribute)
```
`"penetrating"`, `"touching"`, `"too_close"` or `"refused"`.

```python
clash.distance  (attribute)
```
The gap between the two boundaries; 0 for a penetrating or refused pair.

```python
clash.on_a  (attribute)
```
A world point on part `a`: the closest of the pair; for a penetrating pair the centre of the overlap's world box; the origin for a refused one.

```python
clash.on_b  (attribute)
```
The matching world point on part `b`, as `on_a`.

```python
clash.kind_a  (attribute)
```
What `on_a` lies on, as `Closest.kind_a`: `"face"`, `"edge"` or `"vertex"`; `"none"` for a penetrating or refused pair.

```python
clash.index_a  (attribute)
```
The kernel's id for part `a`'s feature; none for a penetrating or refused pair.

```python
clash.edge_a  (attribute)
```
Part `a`'s edge as the index `Solid.edges` uses, as `Closest.edge_a`; none for a face, a vertex, an edge the fillet table does not hold, and a penetrating or refused pair.

```python
clash.kind_b  (attribute)
```
What `on_b` lies on, as `kind_a`.

```python
clash.index_b  (attribute)
```
The kernel's id for part `b`'s feature, as `index_a`.

```python
clash.edge_b  (attribute)
```
Part `b`'s edge, as `edge_a`.

```python
clash.refined  (attribute)
```
Whether the distance was measured on the exact surfaces, as `Closest.refined`; false for a penetrating or refused pair.

```python
clash.depth  (attribute)
```
The thinnest side of a penetrating pair's overlap box; 0 for any other.

```python
clash.text  (attribute)
```
Why a refused pair could not be decided; empty otherwise.

```python
clash.solid() -> Solid
```
The exact shared volume of this penetrating pair, at the placement it was found at, as a new `Solid`. raises `BuildError` for a pair that is not penetrating.

```python
clash.intersect() -> Intersection
```
Where this pair's two parts cross or coincide at the placement it was found at, as `Solid.intersect()` reports it: a touching pair's shared face is an overlap region. raises `BuildError` for a refused pair.

### SweptClash

```python
class SweptClash
```

One pair `swept_clash` or `Collider.swept_clash()` found to clash somewhere on the path, as plain data: when it first came within the clearance, the `Clash` there, and every time range it stays in clash. Times are in pose units: pose `k` is at time `k`, and a time between two poses is the fraction of the way from one to the next.

```python
sweptClash.a  (attribute)
```
The first part's index: in the one set, or in the collider (then `a < b`); in `swept_clash` with two sets, an index into `parts`.

```python
sweptClash.b  (attribute)
```
The second part's index; with two sets, an index into `others`.

```python
sweptClash.first_time  (attribute)
```
The first time the pair came within the clearance, found to within the tolerance over the pair's speed; for a refused pair, the time it was refused at.

```python
sweptClash.first  (attribute)
```
The `Clash` at `first_time` — its kind, distance, points, features and depth — at the frames the motion places the two parts at that time, so its `Clash.solid()` and `Clash.intersect()` rebuild the contact there. A pair refused on the way (a part that will not mesh closed, or more than `max_steps` tests) has a `"refused"` first, whose `text` says why.

```python
sweptClash.intervals  (attribute)
```
The time ranges the pair stays in clash, as `(start, end)` pairs, ascending and disjoint; the first starts at `first_time`. An end is found to within `resolution` while the parts share volume, and two ranges closer than that may be one; a range across a pose is one range. Empty for a refused pair.

### Collider

```python
class Collider
```

Parts meshed once, asked pose after pose which of them interfere: `solids` at rest, meshed at `tolerance` (0.05 by default); `groups` one group index per solid (`None`: each solid its own group — `Collider.check()` then takes one frame per solid, and refuses a `groups` of any other length); `allowed` pairs of part indices never tested (designed contacts, by part index, flat: `(a0, b0, a1, b1, ...)`). Close it when done, or let the language's scope do it; see Lifetimes.

```python
collider.group_count: int  (property)
```
How many groups this collider has — the highest group index past the constructor, plus one.

```python
collider.stats: ColliderStats  (property)
```
Counts of the last `Collider.check()` call, as a `ColliderStats` (all zero before the first one).

```python
collider.check(frames: Iterable[FrameLike], share: tuple[int, int] | None = None) -> list[CollisionHit]
```
The pairs that interfere, or could not be decided, with each group placed at its matching frame in `frames` (one `Frame`, or twelve numbers, per group, in group order), as `CollisionHit` values. `share`: `None`, every pair past the box filters is decided now; `(k, n)`, only those whose index is `k` modulo `n` — the shares of one pose are disjoint and cover it, so a caller splits one pose's work across `n` workers and puts the answers back together. Overlap is all `check` answers; the parts that touch or lie within a clearance of each other are `Collider.clash()`'s. `frames` not the collider's own `Collider.group_count`, a frame that is not twelve finite numbers or not rigid, or a `share` with `k >= n`, raises `BuildError`.

```python
collider.clash(frames: Iterable[FrameLike], clearance: float = 0.0, share: tuple[int, int] | None = None) -> list[Clash]
```
Every pair of parts that penetrates, touches or lies within `clearance` of the other, as `Clash` rows in pair order, with each group placed at its matching frame in `frames` (as `Collider.check()`, which answers overlap alone). The four kinds, their order of decision and the `clearance` are `clash`'s; the tolerance is the one the collider was built with. `share` as for `check`: the rows of the shares of one pose are disjoint and cover it. A pair's distance is measured on a closest mesh of each part, built at a third of the tolerance the first time a pair needs it and kept for the collider's lifetime, so a later pose pays only the measuring. `clearance` negative or not finite, the wrong number of frames, a frame that is not twelve finite numbers or not rigid, or a `share` with `k >= n` raises `BuildError`. The motion between poses is `Collider.swept_clash()`'s question.

```python
collider.swept_clash(poses: Iterable[Iterable[FrameLike]], clearance: float = 0.0, resolution: float = 0.001, max_steps: int = 100000, share: tuple[int, int] | None = None) -> list[SweptClash]
```
Every pair of parts that penetrates, touches or comes within `clearance` of the other anywhere on the path through `poses` — not only at the poses — as `SweptClash` rows in pair order, each with the first time it does and the time ranges it stays in clash. `poses` is two or more poses, each the `frames` `Collider.clash()` takes (one per group); time runs in pose units, pose `k` at time `k`.

Between two poses each group moves rigidly about a pivot, the centre of its rest box: the pivot on the straight line between its two places, the rotation turning at a steady rate the shorter way round, so at each pose a group is exactly where that pose puts it. A part swinging about a far hinge cuts the chord between two poses: add poses where the true path matters.

The answer is not sampled. Each pair is stepped by conservative advancement: the gap is measured, and the next step is as long as the gap allows at the fastest the two parts can close on each other, so the guarantee is that **no moment where the true gap is below `clearance` less the tolerance (for `clearance` 0: no penetration deeper than the tolerance) falls between two steps**, and the first time is found to within the tolerance over that speed. While the parts share volume, how deep they are bounds how long they must stay so. `resolution` (in (0, 1], a fraction of a segment, 1e-3 by default) is how closely an interval's end is found; `max_steps` (100,000 by default) the tests one pair may take over the whole path — a pair that needs more, typically a thin part grazing another at speed, is a `"refused"` row whose `first.text` says so; raise it or add poses.

Pairs come from the swept boxes first: each part's box over a segment, both poses' boxes joined and grown by how far its rotation can carry a point off the chord. A pair whose swept boxes never come within the clearance is not stepped at all. `share` as for `Collider.check()`, over the pairs whose swept boxes meet: the shares of one call are disjoint and cover it. The pose caches `Collider.check()` and `Collider.clash()` keep are neither read nor filled (each time on the path is a new placement); the parts' meshes are made as those calls make them, and kept.

Fewer than two poses, a pose with the wrong number of frames, a frame that is not twelve finite numbers or not rigid, `clearance` negative or not finite, `resolution` outside (0, 1], `max_steps` 0, or a `share` with `k >= n` raises `BuildError`.

```python
collider.close() -> None
```
Free this handle now. The garbage collector, or the language's scope, does it otherwise.

### ThicknessGauge

```python
class ThicknessGauge
```

Wall thickness over `solids`, measured against each other: each solid meshed once at `tolerance` — absolute, in model units (0.01 by default) — and indexed, then asked reading after reading. A reading's `body` is the solid's index in `solids`. The gauge keeps its own reference to the bodies, so it answers on after they are closed. Close it when done, or let the language's scope do it; see Lifetimes. A `tolerance` not positive and finite raises `BuildError`.

The rule reads the measuring mesh (`ThicknessGauge.mesh()`). From a point P the thickness is the distance to the nearest triangle that opposes P's own face (their normals more than 89 degrees apart) with P on or behind its plane — not a ray cast along the normal, so a box's corner reads the plate's thickness, not the diagonal. A triangle with a vertex exactly at P is skipped; where one of those meets P's own face at an interior angle under `sharp_angle` radians, P is a knife edge and reads 0. A point with no such triangle, or one further than `maximum`, gives no reading: readings are dropped, not clamped. Each reading then carries the opposite point refined onto its exact face (`Thickness.exact_thickness`), and the diameter of the largest ball tangent at P that holds none of the surfaces (`Thickness.sphere`). The two differ on a tilted wall: the rule reads the perpendicular foot, so a right wedge reads 3.54 at a point where the ball that fits there is 4.14 across; the ball is the wall's inscribed thickness.

```python
thicknessGauge.tolerance: float  (property)
```
The tolerance the gauge meshed its bodies at.

```python
thicknessGauge.thickness(maximum: float, sharp_angle: float = 0.0) -> list[Thickness]
```
One `Thickness` per measuring-mesh vertex that reads within `maximum`, by body then vertex; `sharp_angle` (radians, 0 by default) sets which vertices are knife edges. `maximum` not positive and finite, or `sharp_angle` negative or not finite, raises `BuildError`.

```python
thicknessGauge.thickness_at(body: int, face: int, point: Point3, maximum: float, sharp_angle: float = 0.0) -> Thickness | None
```
The reading at `point`'s foot on face `face` of body `body`, its `vertex` `None`: the foot read against the exact tangent plane there, so a wall is measured between the mesh's vertices too. `None` where the foot lies off the face, or the wall there is thicker than `maximum`. A body or a face past the end, a `point` not finite, or a bad `maximum` or `sharp_angle` raises `BuildError`.

```python
thicknessGauge.thickness_at_face(body: int, face: int, at: Point3 | None = None, *, maximum) -> FaceThickness | None
```
One figure for face `face` of body `body`, as a `FaceThickness`, the other bodies measured with it: at `at`'s foot on the face, or with no `at` over the face's vertices. `maximum` has no default. `None` where nothing on the face reads within `maximum`, or `at`'s foot lies off the face. A body or a face past the end, an `at` not finite, or `maximum` not positive and finite raises `BuildError`.

```python
thicknessGauge.mesh(body: int) -> ThicknessMesh
```
Body `body`'s measuring mesh, as a `ThicknessMesh`: the mesh a reading's `vertex` indexes, copied out, so it outlives the gauge. A body past the end raises `BuildError`.

```python
thicknessGauge.close() -> None
```
Free this handle now. Leaving a `with` block or the garbage collector does the same.

### Thickness

```python
class Thickness
```

One wall-thickness reading on a solid, as plain data: what `ThicknessGauge.thickness()`, `ThicknessGauge.thickness_at()` and `thickness` return. Points are three numbers.

```python
thickness.body  (attribute)
```
The body read: its index among the gauge's solids.

```python
thickness.vertex  (attribute)
```
The vertex of that body's `ThicknessGauge.mesh()` the reading is at; `None` for a reading at a point (`ThicknessGauge.thickness_at()`).

```python
thickness.face  (attribute)
```
The face of `body` that `point` lies on.

```python
thickness.point  (attribute)
```
Where the wall is read.

```python
thickness.thickness  (attribute)
```
The rule's figure on the measuring mesh: the distance from `point` to `opposite`; 0 on a knife edge.

```python
thickness.opposite  (attribute)
```
The nearest point on the opposing triangle; `point` itself on a knife edge.

```python
thickness.opposite_body  (attribute)
```
The body `opposite` lies on: the gauge's bodies are measured against each other.

```python
thickness.opposite_face  (attribute)
```
The face of `opposite_body` that `opposite` lies on.

```python
thickness.knife  (attribute)
```
Whether `point` is a knife edge: thickness 0, `opposite` equal to `point`.

```python
thickness.exact_thickness  (attribute)
```
The distance from `point` to `exact_opposite`: the figure to compare with a closed form.

```python
thickness.exact_opposite  (attribute)
```
`opposite` moved onto its face's exact surface, where that foot lies within the tolerance of it and inside the face's trims; otherwise `opposite` itself.

```python
thickness.sphere  (attribute)
```
The diameter of the largest ball tangent at `point` that holds none of the surfaces — the wall's inscribed thickness, which on a tilted wall is more than `thickness`; `None` where no ball up to `maximum` is bounded, and 0 on a knife edge.

### FaceThickness

```python
class FaceThickness
```

One face's wall thickness, as plain data: what `ThicknessGauge.thickness_at_face()` and `Solid.thickness_at_face()` return when something on the face reads. Over the face's vertices, `thickness` is the median of their exact readings, each vertex counting once (by vertex count, not by area); at a point, `thickness`, `min` and `max` are the one reading. The figure is meant for plate-like faces: by the rule a solid cylinder's side face (radius 5) reads about 7.07, 5√2, the chord to the first opposing facet past a quarter turn — not its diameter, and not uniform.

```python
faceThickness.thickness  (attribute)
```
The median of the face's readings, or the reading at the point asked.

```python
faceThickness.min  (attribute)
```
The thinnest reading on the face.

```python
faceThickness.max  (attribute)
```
The thickest reading on the face.

```python
faceThickness.uniform  (attribute)
```
Whether `max - min` is within the gauge's tolerance; a very gentle taper reads as uniform.

### ThicknessMesh

```python
class ThicknessMesh
```

A body's measuring mesh, copied out of the gauge: what `ThicknessGauge.mesh()` returns. Its vertices are split per face — no vertex is shared between two faces — so each carries its own face's exact normal.

```python
thicknessMesh.positions  (attribute)
```
One point per vertex; a reading's `vertex` indexes them.

```python
thicknessMesh.normals  (attribute)
```
One unit outward normal per vertex, its face's exact surface normal.

```python
thicknessMesh.triangles  (attribute)
```
Three vertex indices per triangle.

```python
thicknessMesh.faces  (attribute)
```
The face of the body each triangle lies on.

### MeshThickness

```python
class MeshThickness
```

One reading on a plain mesh, as plain data: what `mesh_thickness` returns. Points are three numbers.

```python
meshThickness.mesh  (attribute)
```
The mesh read: its index among the meshes passed.

```python
meshThickness.vertex  (attribute)
```
The vertex of that mesh the reading is at.

```python
meshThickness.thickness  (attribute)
```
The distance from `point` to `opposite`; 0 on a knife edge.

```python
meshThickness.point  (attribute)
```
The vertex's position.

```python
meshThickness.opposite  (attribute)
```
The nearest point on the opposing triangle; `point` itself on a knife edge.

```python
meshThickness.opposite_mesh  (attribute)
```
The mesh `opposite` lies on: the meshes are measured against each other.

```python
meshThickness.opposite_triangle  (attribute)
```
The triangle of `opposite_mesh` that `opposite` lies on.

```python
meshThickness.knife  (attribute)
```
Whether the vertex is a knife edge: thickness 0, `opposite` equal to `point`.

### RTree

```python
class RTree
```

A spatial index over boxes with ids (an R\*-tree): which entries a box meets, which are within a distance of a point or nearest it, which a ray passes through, and which pairs of boxes meet, between two trees or within one. `RTree()` is an empty tree; `RTree.from_boxes()`, `RTree.from_points()` and `RTree.from_triangles()` pack a whole set at once, and `Solid.face_tree()` gives one over a solid's faces. The tree changes in place (`RTree.insert()`, `RTree.remove()`) and stays balanced; its length is how many entries it holds.

An entry is an id and a box. **Ids are the caller's own and may repeat**: two entries may share an id, or an id and a box, and the same `(id, box)` twice is two entries, found twice. A box is `(min, max)` — two `(x, y, z)` triples — a `Box`, or 6 numbers `[minx, miny, minz, maxx, maxy, maxz]`; a point stands for a zero box. A box with a NaN or infinite coordinate, or `min` above `max` on an axis, is not a box. **Touching boxes meet**, everywhere: a box's faces count.

**Answers come in a fixed order**, so the same entries give the same answer whatever order they arrived in and however the tree was built: `RTree.search()` ids ascending, `RTree.within()` and `RTree.nearest()` by distance then id, pairs ascending. Distances are Euclidean from the point to the box, 0 inside it. **`slack` is the largest gap between two boxes that still pair**: two boxes at most `slack` apart on every axis pair, so 0 is touching. Calls on one tree must not overlap from two threads. Close it when done, or let the language's scope do it; see Lifetimes.

```python
RTree.from_boxes(items: 'Iterable[tuple[int, BoxLike]]') -> RTree
```
A tree over `(id, box)` pairs at once, packed (sort-tile-recursive): fuller and faster to query than the same entries inserted one by one, and the same tree for any order of them. The first entry whose box is not a box raises `BuildError`, by index.

```python
RTree.from_points(points: 'Iterable[Point3] | numpy.ndarray') -> RTree
```
A tree over `points`, each a zero box whose id is its index. The first point with a NaN or infinite coordinate raises `BuildError`, by index.

```python
RTree.from_triangles(positions: 'Iterable[Point3] | numpy.ndarray', triangles: 'Iterable[tuple[int, int, int]] | numpy.ndarray') -> RTree
```
A tree over a mesh's triangles in one call: `triangles` an (m, 3) sequence of indices into `positions` (an (n, 3) sequence of points), one entry per triangle, its id the triangle's index and its box its three corners' box. The first corner past the points (`triangle 1 names point 9 of 4`) or at a point with a NaN or infinite coordinate raises `BuildError`, by triangle and point; points no triangle uses are not checked.

```python
rTree.insert(id: int, box: 'BoxLike') -> None
```
Add the entry `(id, box)`, `box` a box or a point. A box that is not a box, or a point that is not finite, raises `BuildError` and leaves the tree as it was.

```python
rTree.remove(id: int, box: 'BoxLike') -> bool
```
Take out one entry equal to `(id, box)` and say whether there was one. **`remove` needs the box the entry was inserted with**, compared coordinate by coordinate (a point's is its zero box): the id alone does not find it. None found is `False`, not an error; with duplicates one goes per call. A box that is not a box raises `BuildError`.

```python
rTree.bounds: tuple[tuple[float, float, float], tuple[float, float, float]] | None  (property)
```
The union of every entry's box as `(min, max)`, or `None` for an empty tree.

```python
rTree.search(box: 'BoxLike') -> list[int]
```
The ids of every entry whose box meets `box` — touching counts — ascending, one per entry (a repeated id comes back as often as it was inserted). A box that is not a box raises `BuildError`.

```python
rTree.within(point: Point3, r: float) -> list[tuple[int, float]]
```
Every entry whose box is within `r` of `point` (0 inside the box; exactly `r` counts), as `(id, distance)` pairs by distance then id. A point not finite, or an `r` negative or NaN, raises `BuildError`.

```python
rTree.nearest(point: Point3, k: int) -> list[tuple[int, float]]
```
The `k` entries whose boxes are nearest `point`, as `(id, distance)` pairs by distance then id — the smaller ids win a tie at the `k`-th place; every entry when `k` is over the count, none for `k` 0 or an empty tree. A point not finite, or a `k` above 1,000,000, raises `BuildError`.

```python
rTree.ray(origin: Point3, direction: Point3, max_t: float = math.inf) -> list[tuple[int, float]]
```
Every entry whose box the ray `origin + t * direction`, `0 <= t <= max_t`, meets, as `(id, t)` pairs by `t` then id: `t` is where the ray enters the box, 0 when `origin` is inside it. Touching counts — a ray grazing a face or an edge, or running along one, meets the box. `t` is in units of `direction`'s length, which is not normalised; `max_t` defaults to infinity. The boxes are what is tested: for a triangle or a face the caller tests the hits' own geometry. An origin or direction not finite, a zero direction, or a `max_t` negative or NaN raises `BuildError`.

```python
rTree.overlaps(other: 'RTree', slack: float = 0.0) -> list[tuple[int, int]]
```
Every pair `(a, b)`, `a` an entry of this tree and `b` one of `other`, whose boxes are at most `slack` apart on every axis (0 by default: touching), ascending. A `slack` negative or NaN raises `BuildError`.

```python
rTree.self_overlaps(slack: float = 0.0) -> list[tuple[int, int]]
```
Every unordered pair of distinct entries at most `slack` apart on every axis, once each as `(smaller id, larger id)`, ascending — an id pairs with itself only where two entries share it. A `slack` negative or NaN raises `BuildError`.

```python
rTree.close() -> None
```
Free this handle now. Leaving a `with` block or the garbage collector does the same.

### Interpolator

```python
class Interpolator
```

A list of samples read at a fractional index, as Rhino's `Interpolator`: animation keys, a value along a pattern, a smoothed profile of measurements. `Interpolator(samples, cyclic)` takes numbers, or equal-length sequences of numbers — 2D or 3D points, or vectors of any dimension; samples of unequal lengths are refused before the call. Its length is how many samples it holds.

**`t` is a fractional sample index**: `t = 2` is sample 2, `t = 2.5` halfway between samples 2 and 3. **An open list clamps** `t` to `[0, length - 1]` and stops on its first and last samples, an end sample standing in for its missing neighbour; **a cyclic list wraps** `t` with period `length` (`t = length` is sample 0, `t = -0.5` halfway between the last sample and the first).

The five modes are Paul Bourke's formulas, in the notation `mu` the fraction past sample `i` and `y0 ... y3` the samples at `i - 1 ... i + 2`; every mode returns the sample itself at a whole `t`. **A dimension-1 interpolator answers numbers, others tuples**, each component read on its own (every mode is a fixed linear combination of at most four samples). A sample that is NaN or infinite, no samples at all, or a `t` that is NaN or infinite raises `BuildError`; a mode name not among the five is refused before the call. It never changes once made. Close it when done, or let the language's scope do it; see Lifetimes.

```python
interpolator.dimension: int  (property)
```
How many numbers a sample holds: 1 answers numbers, more answers tuples.

```python
interpolator.cyclic: bool  (property)
```
Whether `t` wraps round the list (`True`) or is clamped to its ends (`False`).

```python
interpolator.at(t: float, mode: str = 'linear') -> float | tuple[float, ...]
```
The value at the fractional index `t` by `mode` — `"nearest"`, `"linear"` (the default), `"cosine"`, `"cubic"` or `"catmull_rom"`. A `t` that is NaN or infinite raises `BuildError`.

```python
interpolator.sample(ts: 'Iterable[float]', mode: str = 'linear') -> list[float | tuple[float, ...]]
```
The values at every `t` of `ts` by `mode`, as `Interpolator.at()` reads each, in one call. A value of `t` that is NaN or infinite (by its index), or more than 1,000,000 of them, raises `BuildError`.

```python
interpolator.nearest(t: float) -> float | tuple[float, ...]
```
The sample at `floor(t + 1/2)` — a half rounds up — after the clamp or wrap.

```python
interpolator.linear(t: float) -> float | tuple[float, ...]
```
Straight between the samples either side of `t`: `y1 + (y2 - y1) mu`.

```python
interpolator.cosine(t: float) -> float | tuple[float, ...]
```
Linear at `(1 - cos(pi mu)) / 2` instead of `mu`: an ease, flat at every sample.

```python
interpolator.cubic(t: float) -> float | tuple[float, ...]
```
Bourke's cubic over the four samples about `t`: `a0 mu^3 + a1 mu^2 + a2 mu + y1` with `a0 = y3 - y2 - y0 + y1`, `a1 = y0 - y1 - a0`, `a2 = y2 - y0`. Through every sample, but not C1, and it does not reproduce a straight ramp.

```python
interpolator.catmull_rom(t: float) -> float | tuple[float, ...]
```
The Catmull-Rom spline over the four samples about `t`: through every sample, C1, its tangent at each `(y2 - y0) / 2`. It reproduces straight ramps and parabolas sampled at whole `t`.

```python
interpolator.close() -> None
```
Free this handle now. Leaving a `with` block or the garbage collector does the same.

### Document

```python
class Document
```

A model as data: a graph of nodes (`profile.rect`, `solid.extrude`, `measure.mass`, ...), each a blacksmith verb reading other nodes by id, with named parameters that any number can be an `"=expression"` of, evaluated incrementally, and edited by ops that are undoable and branch. The whole thing — nodes, parameters, history, branches — saves as JSON text (the `cadaclysm-blacksmith` format, version 1) and loads back to the same document.

A node has a kind, which names the verb and its inputs, and fields: a number, an `"=expression"` over the parameters and other nodes' values, or the id of another node to read. An expression holds numbers with units (`3 mm`, `45 deg`), lists (`[1, 2, 3 mm]`, `range(0, 360, 60)`, `item`, `slice`, `merge`, `flatten`, `reverse`, `len`, `polar`, `zip`), comparisons, `and`, `or`, `not` and `if(c, a, b)`; arithmetic maps over lists item by item, the shorter padded with its last item. A node given a list where a field takes one number runs once per item and gives the list of its results (`"lacing": "cross"` takes every combination); a `value` node holds one expression for others to read by its id (`"=v1"`). Every edit is an op — `add`, `set`, `remove`, `rename` or `param` — and one op is one commit. A refused op raises `BuildError` with the reason, and the document is unchanged.

The nodes are brought up to date when you read one: only the nodes an edit made stale are evaluated again, and a node that fails is reported by `errors` while the nodes that do not read it still answer. A node's result comes out as the language's own type: a `Solid`, a `Profile`, a `NurbsCurve`, a `Subd`, or a plain value.

**The web build's history.** The kernel wasm module carries the same document, and also a JavaScript-only history binding, `cadaclysm_blacksmith_history_*`, over the same commits and branches for a page that shows a timeline. It is not part of this page's wrapper surface: for now the Python members below are the history surface.

Close it when done, or let the language's scope do it; see Lifetimes. One thread at a time.

```python
Document.load(text: str) -> Document
```
The document that `save` wrote as text: its nodes, parameters, history and branches.

```python
Document.open(path: FilePath) -> Document
```
The document saved in the file at a path.

```python
Document.kinds() -> list[dict[str, Any]]
```
Every node kind the library knows, one record a kind: its `name`, `inputs`, `output`, `cost` and `help`. Needs no document.

```python
Document.new_bim(units: str = 'mm') -> Document
```
An empty building document: the blacksmith kinds and the `bim.*` ones (levels, layered walls and their joins, doors, windows, floors), holding a `bim.project` node whose random guid seeds every IFC GlobalId it exports.

```python
Document.load_bim(text: str) -> Document
```
A building document that `save` wrote as text, opened with the `bim.*` kinds.

```python
Document.open_bim(path: FilePath) -> Document
```
The building document saved in the file at a path.

```python
Document.bim_kinds() -> list[dict[str, Any]]
```
Every node kind a building document knows, the blacksmith's and the `bim.*` ones, as `kinds` lists them. Needs no document.

```python
Document.parts_catalog(directory: FilePath) -> None
```
Loads the parts catalogue (a directory of family files and their index) that `parts.catalog` nodes build their parts from: servos, bars, brackets, bearings, pulleys. Replaces the one loaded before.

```python
Document.new_parts() -> Document
```
An empty bench document, in millimetres: the blacksmith kinds, the `assembly.*` ones among them, and `parts.catalog`, a catalogue part by its entry and parameters.

```python
Document.load_parts(text: str) -> Document
```
A bench document that `save` wrote as text (the robot bench's file), opened with the `parts.*` kinds. A file that is not a document raises `BuildError` saying so.

```python
Document.open_parts(path: FilePath) -> Document
```
The bench document saved in the file at a path.

```python
Document.parts_kinds() -> list[dict[str, Any]]
```
Every node kind a bench document knows, the blacksmith's and the `parts.*` ones, as `kinds` lists them. Needs no document.

```python
document.export_ifc(path: 'FilePath | None' = None, *, schema='IFC4', geometry='parametric', timestamp=None, name='') -> str
```
The building as IFC text, IFC4 or IFC2x3, its geometry parametric (the design intent: extruded outlines, openings voiding their walls) or exact (the evaluated bodies, openings already cut); with a path, also written to that file. The time stamp defaults to now. A document that cannot be written in full raises `BuildError` with every reason at once, one a line, each on its node, and nothing is written.

```python
document.save(path: 'FilePath | None' = None) -> str
```
The document as JSON text; with a path, also written to that file.

```python
document.apply(op: 'str | dict[str, Any]', message: 'str | None' = None) -> dict[str, Any]
```
Applies one op, given as a JSON record or its text (`{"op": "add", "node": {...}}`, `set`, `remove`, `rename`, `param`), and records it as one commit with an optional message. Answers the changed set: the ids added, changed and removed, and the parameter names touched.

```python
document.add(kind: str) -> str
```
A new node of a kind with its fields, one commit. Its id is made up unless the call gives one; the id is returned.

```python
document.add_solid(solid: 'Solid', sheet: bool = False) -> str
```
A node holding a solid the caller already has — made in code or read from a file — for other nodes to read like any built one: a `solid.body` node (a `sheet.body` one for a sheet) carrying the kernel's own B-rep (`Solid.document_body()`), in the document's units, inside the saved file, which gives back exactly that body. Edges and faces are referenced on it as on any node, and replacing its body later finds them again by geometry. Colours and names are not kept. The new id is returned.

```python
document.add_profile(profile: 'Profile') -> str
```
A `profile.path` node holding a `Profile` exactly (`Profile.document_path()`: arcs and NURBS as they are, holes included), in the document's units. The new id is returned.

```python
document.set(id: str) -> dict[str, Any]
```
Sets fields of a node, one commit; answers the changed set.

```python
document.remove(id: str, cascade: bool = False, message: 'str | None' = None) -> dict[str, Any]
```
Removes a node. Refused while another node reads it, unless `cascade` takes those readers with it.

```python
document.rename(id: str, name: 'str | None', message: 'str | None' = None) -> dict[str, Any]
```
Gives a node a display name; none clears it.

```python
document.params: MutableMapping[str, Any]  (property)
```
The parameters, name to value (a number, or an `"=expression"`), as a mutable mapping. Assigning one is a `param` op, one commit; deleting one removes it.

```python
document.batch(message: 'str | None' = None) -> Iterator[None]
```
Ops applied live inside the block are recorded as one commit with the block's message. An error inside rolls every op of the batch back and is passed on.

```python
document.preview() -> Iterator[None]
```
Ops applied inside the block evaluate but are never recorded, and are taken back on leaving, normally or by an error: a drag, a what-if.

```python
document.undo() -> bool
```
Takes back the head commit. False when there was nothing to take back.

```python
document.redo() -> bool
```
Puts back the commit `undo` took back. False when there was nothing to put back.

```python
document.can_undo: bool  (property)
```
Whether `undo` has a commit to take back.

```python
document.can_redo: bool  (property)
```
Whether `redo` has a commit to put back.

```python
document.branch: str | None  (property)
```
The current branch's name, or none when the head is detached (switched to a commit id).

```python
document.branches: dict[str, str]  (property)
```
Every branch, name to the id of its tip commit.

```python
document.branch_new(name: str, at: 'str | None' = None) -> None
```
A new branch. Without a commit id it starts at the head and the document switches onto it; with one it starts there.

```python
document.switch(name_or_commit_id: str) -> None
```
Moves the head to the branch of that name, else to the commit of that id, which detaches the head. The nodes follow.

```python
document.branch_rename(old: str, new: str) -> None
```
Renames a branch; refused when the old name is missing or the new one is taken.

```python
document.branch_delete(name: str) -> None
```
Deletes a branch; the current branch is refused. Its commits stay, as tips.

```python
document.tips() -> list[Commit]
```
The tips of the lines no branch names — what an undo followed by an edit leaves behind — each as a whole `Commit`.

```python
document.log(branch: 'str | None' = None) -> list[Commit]
```
The commits of a branch's line, newest first, the root `c0` last; with no branch, the line from the head back to the root.

```python
document.head: Commit  (property)
```
The commit the document is at.

```python
document.evaluate(cheap_only: bool = False) -> list[dict[str, Any]]
```
Evaluates the nodes that are stale (only the cheap kinds when asked) and answers the status of every node: `ok`, `error`, `blocked` or `pending`.

```python
document.errors() -> list[dict[str, Any]]
```
The nodes the evaluation left in error or blocked, each with its message.

```python
document.value(id: str) -> Any
```
A node's value: a number, a point or list, a record, or text. raises `BuildError` for a node with none (missing, or in error).

```python
document.result(id: str) -> Any
```
What a node evaluated to, by its kind: a `Solid` (solids and sheets), a `Profile`, a list of profiles, a `NurbsCurve`, a `Subd`, a list of these for a node run over a list (each item also read as `id#i`), or the `value` of a number, point, record, list and the like; none for no such node or one that failed. Each handle is the caller's own and outlives later edits.

```python
document.close() -> None
```
Free this handle now. Leaving a `with` block or the garbage collector does the same.

### Commit

```python
class Commit
```

One commit of a `Document`'s history, as plain data: what `Document.log()`, `Document.tips()` and `Document.head` return.

```python
commit.id  (attribute)
```
The commit's id; `c0` is the root.

```python
commit.parents  (attribute)
```
The ids of the commits it follows.

```python
commit.message  (attribute)
```
The message it was recorded with; none when not set.

```python
commit.author  (attribute)
```
Who recorded it; none when not set.

```python
commit.time  (attribute)
```
When it was recorded; none when not set.

```python
commit.ops  (attribute)
```
The ops it applied, each as the record that was sent.

### SubdMesh

```python
class SubdMesh
```

One level of a cage's smooth surface, as `Subd.smooth_mesh()` returns it: `positions` and `normals` (limit positions and unit outward limit normals, three numbers a vertex), `indices` (three vertex ids a triangle) and `triangle_face` (the face of the **full** cage each triangle lies on; on a mirrored half, face `f` of the half is `f` and its reflection `f + len(faces)`). Copied out of the cage, so it outlives it; the arrays are writable. At the C ABI the same arrays are views into the cage's handle, good until that handle is freed.

```python
subdMesh.positions  (attribute)
```
The limit positions, an (n, 3) float64 array.

```python
subdMesh.normals  (attribute)
```
The unit outward limit normals, an (n, 3) float64 array matching `positions`.

```python
subdMesh.indices  (attribute)
```
The triangles, an (m, 3) uint32 array of ids into `positions`.

```python
subdMesh.triangle_face  (attribute)
```
The cage face each triangle lies on, an (m,) uint32 array: the **full** cage's numbering (see above for a mirrored half).

### SubdReport

```python
class SubdReport
```

What `Subd.to_solid()` did and how close it came, as plain data: how many patches were built exactly from their own net (`regular`) and how many from a refined neighbourhood (`refined`), the Catmull-Clark `steps` taken first, the deepest local refinement a patch needed (`levels`), and the two figures the options bound — the largest `deviation` from the limit surface and the largest tangent break `g1_angle_deg` across a side that is not creased — with the world points they were measured at.

```python
subdReport.regular  (attribute)
```
Patches built exactly from their own net, with no refinement.

```python
subdReport.refined  (attribute)
```
Patches built from a refined neighbourhood.

```python
subdReport.steps  (attribute)
```
The Catmull-Clark steps taken before the patches were cut: 1 or 2.

```python
subdReport.levels  (attribute)
```
The deepest local refinement a patch took; 0 when none was refined.

```python
subdReport.deviation  (attribute)
```
The largest deviation from the limit surface, as a fraction of the cage's bounding-box diagonal.

```python
subdReport.g1_angle_deg  (attribute)
```
The largest tangent break across a side that is not creased, in degrees.

```python
subdReport.deviation_at  (attribute)
```
The world point `deviation` was measured at, three numbers.

```python
subdReport.g1_at  (attribute)
```
The world point `g1_angle_deg` was measured at, three numbers.

### Subd

```python
class Subd
```

A Catmull-Clark control cage: positions, faces, creased edges, pinned vertices, an optional mirror plane, and the selection of the edit that made it. It is immutable — every edit returns a new `Subd`, whose `selection` names what that edit touched — and `Subd.to_solid()` turns it into an exact B-rep that every `Solid` call takes. Close it when done, or let the language's scope do it; see Lifetimes. A refusal raises `BuildError` with the kernel's own words.

What the conversion to a solid does and does not do: it cuts **one NURBS face per quad after one Catmull-Clark step, or two when a quad of the first step has two extraordinary corners** (every cylinder primitive; `SubdReport.steps` says which) — so a cage quad gives 4 faces after one step, an n-gon n, and the 6-sided plain cylinder gives 144 — with a tangent-continuous block at each extraordinary vertex. A smooth vertex of high valence (7 or more on these primitives) may be refused at the default tolerances, with the measured figures: a plain 7-sided cylinder is, while an 8-sided one with creased rims converts. A crease or boundary side with 4 or more faces on one side has no tangent plane there, so a conversion through one may be refused. Fillets along edges that are splines are not available yet. At the C ABI, the arrays `Subd.positions` and `Subd.smooth_mesh()` give are views into the cage's handle, good until that handle is freed.

```python
subd.close() -> None
```
Free this handle now. The garbage collector, or the language's scope, does it otherwise.

```python
Subd.cuboid(size: Sequence[float] = (2.0, 2.0, 2.0), segments: Sequence[int] = (1, 1, 1)) -> Subd
```
A box of `size` (x, y, z), centred on the origin, with `segments` quads along each axis (1 to 1024 each). Default: a 2 x 2 x 2 box of one quad a side.

```python
Subd.cylinder(radius: float = 1.0, height: float = 2.0, sides: int = 8, rings: int = 1, creased_rims: bool = True) -> Subd
```
A cylinder along +Z: one n-gon cap per end with `sides` sides and `rings` bands of quads between them. With `creased_rims` (the default in Python) the two rim loops are creased, so the caps stay flat; an uncreased cylinder of 7 or more sides is refused by `Subd.to_solid()` at the default tolerances.

```python
Subd.sphere(radius: float = 1.0, segments: int = 2) -> Subd
```
A quad ball of `radius`: a cube grid with `segments` quads per edge (at most 1024), each vertex pushed out to the radius.

```python
Subd.torus(major: float = 3.0, minor: float = 1.0, around: int = 12, tube: int = 8) -> Subd
```
A torus around +Z, all quads: `around` steps about the axis at radius `major`, `tube` steps round the tube of radius `minor`.

```python
Subd.from_parts(positions: 'Sequence[Sequence[float]] | numpy.ndarray', faces: 'Sequence[Sequence[int]]', creases: 'Iterable[tuple[int, int]]' = (), pins: Iterable[int] = (), symmetry: 'tuple[str, float] | None' = None) -> Subd
```
A cage from its parts, the lossless inverse of reading them back: `positions` (n, 3), `faces` lists of vertex ids, `creases` (a, b) pairs that are edges, `pins` vertex ids, and `symmetry` `None` or an axis (`"x"`, `"y"` or `"z"`) with a tolerance, for a mirrored half, as `Subd.symmetry` reports it. The new cage selects nothing. A malformed cage raises `BuildError`.

```python
subd.positions: numpy.ndarray  (property)
```
The cage's vertices, an (n, 3) float64 array of your own: a copy.

```python
subd.faces: list[list[int]]  (property)
```
Each face's vertex ids, in loop order.

```python
subd.creases: list[tuple[int, int]]  (property)
```
The creased edges, each as (smaller id, larger id), sorted.

```python
subd.pins: list[int]  (property)
```
The pinned vertices: they refine as corners and stay put.

```python
subd.symmetry: tuple[str, float] | None  (property)
```
`None` for an ordinary cage; for a mirrored half, the plane's axis (`"x"`, `"y"` or `"z"`) and how far from it a vertex counts as on it.

```python
subd.selection: tuple[str, list] | None  (property)
```
What the edit that made this cage touched: `"vertices"` or `"faces"` with ids, or `"edges"` with (a, b) pairs; `None` for a cage no edit selected (a primitive, `Subd.from_parts()`, the mirror calls).

```python
subd.transform(selection: 'tuple[str, Sequence]', matrix: 'Sequence[float] | Sequence[Sequence[float]]') -> Subd
```
A new cage with the selected elements moved by `matrix`, and the same elements selected. `selection` is `"vertices"`, `"edges"` or `"faces"` with ids (edges as (a, b) pairs); `matrix` is sixteen numbers column-major. A rotation about a point is baked into the matrix by the caller.

```python
subd.crease(edges: 'Iterable[tuple[int, int]]', on: bool = True) -> Subd
```
A new cage with `edges` ((a, b) pairs) creased, or un-creased when `on` is `False`; it selects them. A pair that is not an edge raises `BuildError`.

```python
subd.pin(vertices: Iterable[int], on: bool = True) -> Subd
```
A new cage with `vertices` pinned (they refine as corners and stay put), or released when `on` is `False`; it selects them.

```python
subd.extrude(faces: Iterable[int], distance: float) -> Subd
```
A new cage with `faces` pushed out by `distance` along each connected region's average normal, with a quad wall on each boundary edge. The moved faces keep their ids and the new cage selects them.

```python
subd.inset(faces: Iterable[int], amount: float, individual: bool = False) -> Subd
```
A new cage with `faces` shrunk by `amount`, in (0, 1), within their surface, and a ring of quads round each region (round each face, with `individual`). The new cage selects the inner faces.

```python
subd.subdivide(faces: Optional[Iterable[int]] = None) -> Subd
```
A new cage with `faces` subdivided once by the Catmull-Clark rules (the whole cage when no faces are given): each face becomes quads round a new point, and an unpicked face beside them takes the new edge points as corners. The whole cage keeps its smooth surface exactly. The new cage selects the new faces.

```python
subd.insert_loop(edge: 'tuple[int, int]', at: float = 0.5) -> Subd
```
A new cage with a loop of edges cut across the ring of quads through `edge` (an (a, b) pair), at `a + at * (b - a)` with `at` in (0, 1). It selects the new loop.

```python
subd.edge_loop(edge: 'tuple[int, int]') -> list[tuple[int, int]]
```
The loop of edges through `edge`, straight across each valence-four vertex, the picked edge first and each pair smaller id first; empty when `edge` is not an edge of the cage.

```python
subd.mirror_on(axis: str) -> Subd
```
The positive half of the cage across the plane perpendicular to `axis` (`"x"`, `"y"` or `"z"`), as a mirrored cage: every later edit keeps it symmetric.

```python
subd.mirror_off() -> Subd
```
The mirror baked: the whole cage as an ordinary one, no longer mirrored.

```python
subd.full() -> Subd
```
The whole cage of a mirrored half — the half's vertices first, then the reflections of those off the plane — or a copy of an ordinary cage.

```python
subd.smooth_mesh(levels: int = 3) -> SubdMesh
```
The smooth surface refined `levels` times (1 to 6, 3 by default), as a `SubdMesh`.

```python
subd.pick(point: Point3, kind: str) -> int | tuple[int, int] | None
```
The cage element of `kind` (`"vertex"`, `"edge"` or `"face"`) under `point`, a point on or near the smooth surface: a vertex or face id, or an edge as (a, b) with the smaller id first. `None` when nothing is within 0.05 of the cage's diagonal — not an error. A `point` that is not finite raises `BuildError`, which is not the same answer as nothing near.

```python
subd.to_solid(tolerance: float = 0.0001, g1_angle: float = 0.1, max_levels: int = 6) -> tuple[Solid, SubdReport]
```
The cage as an exact `Solid`, one NURBS face per patch (see above), and a `SubdReport` of what the conversion did. `tolerance` is the largest deviation from the limit surface as a fraction of the cage's diagonal (1e-4 by default), `g1_angle` the largest tangent break across an uncreased side in degrees (0.1), `max_levels` the deepest local refinement (2 to 6, 6). A `tolerance` or `g1_angle` of 0 or less, or a `max_levels` of 0, takes the default; any other `max_levels` outside 2 to 6 raises `BuildError`. A cage that cannot be held within them raises `BuildError`, with the figures it measured.

### Tool

```python
class Tool
```

A cutter: Grbl tool `number` (1 to 255, the `T` word), `diameter` and `flute_length` in mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed, ramping into its cuts at `ramp_angle` degrees. Immutable; a job keeps its own copy.

```python
Tool.flat(number: int, diameter: float, flute_length: float, feed: float, plunge: float, rpm: float, ramp_angle: float = 3.0) -> Tool
```
A flat end mill. A `number` outside 1..255, a size, feed or speed not positive and finite, or a `ramp_angle` outside (0, 90], raises `BuildError`.

```python
Tool.ball(number: int, diameter: float, flute_length: float, feed: float, plunge: float, rpm: float, ramp_angle: float = 3.0) -> Tool
```
A ball end mill, as `flat` but its tip a half sphere of the diameter; in 2.5D it cuts where a flat does, `bottom` being the tip.

```python
Tool.drill(number: int, diameter: float, flute_length: float, feed: float, rpm: float) -> Tool
```
A drill, plunging at `feed`. A job takes it for `Job.drill()` only.

```python
tool.number: int  (property)
```
The Grbl tool number, 1 to 255 (the `T` word).

```python
tool.shape: str  (property)
```
The cutting end: `"flat"`, `"ball"`, `"drill"`, `"vbit"` or `"bullnose"` — spelled as a machining view's tool description spells it.

```python
tool.diameter: float  (property)
```
The cutting diameter, in mm.

```python
tool.flute_length: float  (property)
```
How far up the cutting edge reaches from the tip, in mm.

```python
tool.angle: float | None  (property)
```
A V-bit's included angle, in degrees; `None` for every other shape.

```python
tool.corner_radius: float | None  (property)
```
A bull-nose's corner radius, in mm; `None` for every other shape.

### Stock

```python
class Stock
```

The block of material a job cuts, an axis-aligned box. Immutable; a job keeps its own copy.

```python
Stock.box(min: Point3, max: Point3) -> Stock
```
The box from `min` (x, y, z) to `max`. Unless every min is below its max and all six are finite, raises `BuildError`.

```python
Stock.around(solid: 'Solid', margin: float = 0.0) -> Stock
```
`solid`'s bounds grown by `margin` in -X, +X, -Y, +Y and +Z; the bottom stays at the solid's lowest Z. A `margin` negative or not finite raises `BuildError`.

### Program

```python
class Program
```

One file a job wrote: a Grbl program (`tool` its `T` number, `name` `<job name>-T<n>`, or `<job name>-<k>-T<n>` for a repeated tool) or, from `Job.write_camotics()`, a simulation copy or the CAMotics project (`tool` 0). Read-only.

```python
program.tool  (attribute)
```
The program's Grbl `T` number, or 0 for a CAMotics project file.

```python
program.name  (attribute)
```
The program's name without extension (`<name>-T<n>`, or `<name>-<k>-T<n>` for a repeated tool) from `Job.gcode()`; the file name from `Job.write_camotics()`.

```python
program.text  (attribute)
```
The program's text.

### Job

```python
class Job
Job(stock: Stock, safe_z: float, clearance: float=1.0, tolerance: float=0.01, name: str='job', spindle_dwell: float=2.0, resolution: float=0.1)  # the constructor
```

A machining job on a `Stock`: operations kept in the order they are added, written as one Grbl 1.1 program per run of operations sharing a tool. Mutable — each operation is added in place, and a refused one leaves the job as it was. `safe_z` is the absolute Z of rapids between operations and at a program's start and end, above the stock's top; an operation enters and leaves its passes `clearance` above its top; `tolerance` fits free-form sides and offsets; `name` names the programs (`<name>-T<n>`); every program waits `spindle_dwell` seconds after starting the spindle; `resolution` is the CAMotics project's voxel size in mm. A `safe_z` not above the stock, or a setting the job refuses, raises `BuildError`.

```python
job.face(tool: Tool, z: float, stepover: float, stepdown: float) -> None
```
Face the stock's top down to `z`, in zigzag rows along X `stepover` apart and passes at most `stepdown` deep. A drill, a `z` above the stock's top, a stepover past the tool's diameter, or what the job otherwise refuses, raises `BuildError`.

```python
job.contour(tool: Tool, profile: Profile, top: float, bottom: float, side: Literal['outside', 'inside', 'on'] = 'outside', stepdown: float = 1.0, climb: bool = True, open: bool = False) -> None
```
Cut along `profile` from `top` to `bottom` in passes at most `stepdown` deep: `side` "outside" the profile, "inside" it, or "on" its line; `climb` for climb milling, else conventional; `open` to cut the outline as an open chain (only "on" its line, and with no holes). Any other `side` raises `ValueError`; what the job otherwise refuses, raises `BuildError`.

```python
job.pocket(tool: Tool, profile: Profile, top: float, bottom: float, stepover: float, stepdown: float) -> None
```
Clear `profile` — its holes left standing as islands — from `top` to `bottom`, in rings `stepover` apart (at most the tool's radius) and passes at most `stepdown` deep. What the job refuses raises `BuildError`; a pocket too small for the tool is refused by `Job.gcode()`, naming the operation.

```python
job.drill(tool: Tool, points: Iterable[Point2], top: float, bottom: float, peck: float | None = None) -> None
```
Drill a hole at each (x, y) of `points` from `top` to `bottom`, pecking `peck` deep at a time (retracting between pecks), or straight to depth for none. A point that is not two numbers raises `ValueError`; a tool that is not a drill, no points, or what the job otherwise refuses, raises `BuildError`.

```python
job.gcode() -> list[Program]
```
The job as Grbl 1.1 programs, one per run of consecutive operations sharing a tool (T1, T2, T1 gives three), each named `<name>-T<n>` (or `<name>-<k>-T<n>` for run `k` of a tool that runs more than once); an empty list for a job with no operations. An operation whose geometry the tool cannot cut (named by its index and kind) raises `BuildError`.

```python
job.write_camotics(path: FilePath) -> list[str]
```
A CAMotics project at `path` and its files beside it, named after the project's file stem (`out/part.camotics` writes `out/part-T1.nc`), not the job's name: each program, a simulation copy of it (`.sim.nc`, which the project lists), and the project last. Creates the directory. Returns the paths written, the project last. A path with no file stem, what `Job.gcode()` refuses, or a file that cannot be written, raises `BuildError`.

```python
job.machine(part: 'Solid', end_mill: 'Tool | Iterable[Tool]', drills: Tool | Iterable[Tool] = (), stepover: float | None = None, stepdown: float | None = None, skin: float = 0.3, peck: float | None = None) -> Report
```
Recognise `part` — a solid inside the job's stock — by Z-level sectioning, and append the operations that make it: one face (if the stock top is above the part's top), the pockets level by level from the top down, then one drill per drill tool and bottom. `end_mill` must be a flat or ball tool, not a drill; `drills` are tried against each hole found, the closest match within 0.05 mm winning. `end_mill` may also be a list of end mills, largest first: the first clears as above, and each later one cleans only what the earlier ones left — inside corners, regions too narrow for them, and holes no drill matches — with pockets of its own after the earlier tools' and before the drills. Each later tool's stepover and stepdown default to its own; one given applies to the first and is clamped to each later tool's radius and flutes. The report then lists only what no end mill reached; a corner, or a region too narrow, names the smallest end mill that tried. `stepover` defaults to `0.4 x diameter`, `stepdown` to `min(diameter / 2, flute_length)` (`None` asks for the kernel's own default for either); `skin` (at least 0, default 0.3) is how far above the part's lowest point the outline stops, so the part stays attached to the stock — `0` cuts through; `peck` is passed to every drill operation (`None` for none). Returns a `Report` of what could not be cut — nothing that would gouge is ever emitted; a feature the tools can't make is machined as far as possible and reported instead. The job changes only on success: what the kernel otherwise refuses (a drill as `end_mill`, a `drills` entry that isn't a drill, a tool number clashing with one already in the job, `part` outside the stock, a `skin` negative or not less than the part's height, no level found, a stepover or stepdown out of range, an empty list of end mills, one not smaller than the one before it, two sharing a number) raises `BuildError` and leaves the job exactly as it was.

```python
job.operations() -> list[Operation]
```
Every operation added to this job so far, in order — whether by `Job.face()`, `Job.contour()`, `Job.pocket()`, `Job.drill()` or `Job.machine()` — as a list of `Operation`.

```python
job.show(part: Optional[Solid] = None, tolerance: float = 0.05) -> None
```
Play the job on its stock with the GPU view library, in the one shared window, from its start at real time, and return at once. The window's keys drive it — space plays or pauses, left and right step a move, up and down multiply the speed by 4 or divide it, Home and End seek the start and the end, L loops — and its title is the status line (`move 370 of 638 · T1 flat 6 mm · X12.3 Y-4.0 Z7.0`). `part`, a `Solid`, colours the stock by deviation from it. The terminal library cannot cut a stock and refuses. In the notebook, draw with `show(job, part)`.

```python
job.view(part: Optional[Solid] = None, tolerance: float = 0.05) -> dict[str, Any]
```
`Job.show()` in a fresh window that blocks until it is closed; returns the camera and the last pick, as `Solid.view()` does.

```python
job.stock: tuple[tuple[float, float, float], tuple[float, float, float]]  (property)
```
The stock's box as the job holds it, `((min_x, min_y, min_z), (max_x, max_y, max_z))` — what `Stock.box()` was given, or what `Stock.around()` worked out.

```python
job.tools: dict[int, Tool]  (property)
```
The tools this job was given — by `Job.face()`, `Job.contour()`, `Job.pocket()`, `Job.drill()` and `Job.machine()` (the end mill and drills its operations use; it refuses two different tools offered under one number) — by Grbl number, so a `Program`'s `tool` finds its tool. A refused call adds none. A new mapping each time.

### Report

```python
class Report
```

What `Job.machine()` could not make: a read-only sequence of `ReportItem`, in the order found, read once when `machine` returns. `len(report)` counts the items, it iterates and indexes them, and `str(report)` is the kernel's own text — one line per item, or "nothing left uncut"; `bool(report)` is `True` when it has items.

### ReportItem

```python
class ReportItem
```

One thing `Job.machine()` left uncut, one of `Report`'s items. Read-only.

```python
reportItem.kind  (attribute)
```
`"corner"` (material the end mill doesn't reach), `"hole"` (a round hole no drill matches or a matched drill can't make), `"slope"` (a face that is neither horizontal nor vertical, cut as steps), `"undercut"` (material under an overhang) or `"too_deep"` (a level below the end mill's flute length, cut only that far).

```python
reportItem.at  (attribute)
```
The item's XYZ location — a centroid for an area, the axis point at the top for a hole.

```python
reportItem.size  (attribute)
```
An area in mm^2 for `corner`/`undercut`, a diameter in mm for `hole`, and a height in mm (its Z range) for `slope` and `too_deep`.

```python
reportItem.reason  (attribute)
```
One sentence naming the cause and the tool involved.

```python
reportItem.top  (attribute)
```
The highest Z the item stands at: a corner's or undercut's band top, a hole's top, a slope's top, or for `too_deep` the flutes' reach.

```python
reportItem.bottom  (attribute)
```
The lowest Z the item stands down to: the floor a corner or undercut reaches, a hole's floor, a slope's foot, or for `too_deep` the level.

```python
reportItem.region  (attribute)
```
The XY area the item covers, as a list of `Profile`: a corner's or undercut's piece, a hole's disc, the area a slope's face covers, or for `too_deep` the reachable area cut short (the whole stock when it is the part's top).

### Operation

```python
class Operation
```

One operation of a `Job`, read back by `Job.operations()`. Read-only.

```python
operation.kind  (attribute)
```
`"face"`, `"contour"`, `"pocket"` or `"drill"`.

```python
operation.tool  (attribute)
```
Its Grbl `T` number.

```python
operation.params  (attribute)
```
A dict of the operation's own arguments, in the kind-specific order it stores them — z, top, bottom, stepover, stepdown, side, climb, open, peck and the point count, with a profile summarised by its bounds. `side` reads as `"outside"`/`"inside"`/`"on"`; `climb` and `open` as a bool; `points` as an int; a `NaN` `peck` as `None`; every other value stays a float.

### Sketch

```python
class Sketch
```

A 2D sketch of points, lines, circles, arcs and free curves (Bezier, conic, NURBS), held by geometric constraints and dimensions and solved on request — the sketcher a parametric part starts from. Draw roughly, constrain, `Sketch.solve()`, then hand `Sketch.profiles()` to `Solid.extrude()` or any other verb that takes a `Profile`.

Entities and constraints are named by integer ids, which are never reused. Entity kinds are `"point"`, `"line"`, `"circle"`, `"arc"` and `"free_curve"`; a constraint's kind is the name of the method that added it (`"point_line_distance"`, ...), but for `Sketch.radius_of()`, whose kind is `"radius"`. Lengths are the kernel's own unitless numbers, angles radians. A sense is `"auto"` (taken from the geometry when the constraint is added), `"positive"` (a line and a circle: the centre on the left of the line, from its first point to its second; two circles: touching from outside) or `"negative"` (the centre on the right; one circle inside the other); an end is `"start"` or `"end"`.

A constraint that conflicts with the ones already there is refused when it is added, the refusal naming the constraints it fights, so a sketch is never left over-constrained by an edit; a redundant one (already implied) is kept and reported by `Sketch.diagnose()`. An edit that will not converge (`Sketch.set_value()`, `Sketch.set_driving()`) rolls the sketch back to where it was. Close it when done, or let the language's scope do it; see Lifetimes.

In Python an unknown sense or end name raises `ValueError`; every other wrapper raises its kernel error.

```python
Sketch.from_profile(profile: Profile, infer: bool = True, tolerance: float = 1e-06) -> Sketch
```
A sketch of `profile`'s lines, arcs and curves, joined end to end by coincident constraints, holes included. With `infer` (the default) it also adds every constraint the geometry already meets within `tolerance` — horizontal and vertical lines, tangent joints, concentric arcs, equal radii — so the profile comes back as a sketch a designer can dimension. Ends within `tolerance` (1e-6 by default) count as joined.

```python
sketch.close() -> None
```
Free this handle now. The garbage collector, or the language's scope, does it otherwise.

```python
sketch.add_point(x: float, y: float) -> int
```
A free point at (`x`, `y`): its id. A coordinate that is not finite raises `BuildError`.

```python
sketch.add_line(a: int, b: int) -> int
```
A line from the point `a` to the point `b`: its id. Refused for ids that are not two distinct points.

```python
sketch.add_circle(centre: int, r: float) -> int
```
A circle of radius `r` about the point `centre`: its id. Refused for a radius that is not positive and finite.

```python
sketch.add_arc(centre: int, start: int, end: int) -> int
```
A counter-clockwise arc about the point `centre` from the point `start` to the point `end`: its id. Its radius is `start`'s distance from `centre`; `end` is held on that circle by the solve, not moved there now. The three must be different points.

```python
sketch.add_bezier(start: int, c1: Point2, c2: Point2, to: Point2) -> int
```
A cubic Bezier free curve from the point `start` through the controls `c1` and `c2` (each an (x, y) pair) to a new end point at `to`: its id. The curve owns its control and end points (`Sketch.ends()` lists them), which constraints and drags move like any other point.

```python
sketch.add_conic(start: int, control: Point2, to: Point2, weight: float) -> int
```
A rational quadratic (conic) free curve from the point `start` with the control `control` of `weight` to a new end point at `to`: its id. A weight below 1 is an ellipse's arc, 1 a parabola, above 1 a hyperbola.

```python
sketch.add_nurbs(start: int, points: Iterable[Point2], knots: Iterable[float], degree: int = 3, weights: Iterable[float] | None = None) -> int
```
A NURBS free curve of `degree` (3 by default) from the point `start` through the control `points` after it, on `knots`: its id. `weights` is `None` for a plain B-spline, or one per control point counting the start (one more than `points` holds); any other count, a negative degree, or knots that do not fit the points and the degree, raises `BuildError`.

```python
sketch.add_rect(a: Point2, b: Point2) -> tuple[list[int], list[int]]
```
The rectangle with opposite corners `a` and `b`, as two lists: its four corner points, counter-clockwise from `a`, and its four sides (side `i` runs from corner `i` to corner `i + 1`). Its sides come held level and plumb by two horizontal and two vertical constraints, so a fix and two lengths constrain it fully.

```python
sketch.kind(id: int) -> str
```
The kind of entity `id`: `"point"`, `"line"`, `"circle"`, `"arc"` or `"free_curve"`. An unknown or removed id raises `BuildError`.

```python
sketch.entities() -> list[int]
```
The live entity ids, ascending.

```python
sketch.point(id: int) -> tuple[float, float]
```
The point `id`'s position, as an (x, y) pair. Not a point, raises `BuildError`.

```python
sketch.set_point(id: int, x: float, y: float) -> None
```
Moves the point `id` to (`x`, `y`) without solving — a raw write, as loading a saved sketch does.

```python
sketch.radius(id: int) -> float
```
The radius of the circle or arc `id`. (The RADIUS dimension is `Sketch.radius_of()`.)

```python
sketch.set_radius(id: int, r: float) -> None
```
Sets the circle `id`'s radius to `r` without solving. Refused for an arc, whose radius its points set, and for a radius that is not positive and finite.

```python
sketch.centre(id: int) -> int
```
The centre point of the circle or arc `id`.

```python
sketch.ends(id: int) -> list[int]
```
The points entity `id` runs between: a line's `[a, b]`, an arc's `[start, end]`, a free curve's `[start, controls..., end]`. Refused for a point or a circle.

```python
sketch.set_construction(id: int, on: bool = True) -> None
```
Marks entity `id` as construction geometry (`on`, the default) or back: still solved and constrained, but never part of `Sketch.profiles()` or `Sketch.open_chains()`.

```python
sketch.is_construction(id: int) -> bool
```
Whether entity `id` is construction geometry (`False` for an unknown id).

```python
sketch.is_reference(id: int) -> bool
```
Whether entity `id` is a reference copy of another sketch's, made by `Sketch.reference()` (`False` for an unknown id).

```python
sketch.remove_entity(id: int) -> list[int]
```
Removes entity `id`, each of its points no other entity uses, and every constraint on any of them: the removed constraint ids, ascending. A point a line, circle, arc or curve still uses is refused, raises `BuildError` naming those entities. Nothing is solved.

```python
sketch.reference(other: Sketch, entity: int) -> int
```
A fixed construction copy of `other`'s entity `entity` in this sketch, its id: something to dimension against that this sketch's solve never moves. `Sketch.update_reference()` re-reads it. `other` must be a different sketch.

```python
sketch.update_reference(id: int, other: Sketch) -> SolveReport
```
Re-reads the reference `id` from `other` (where `other`'s solve has moved it) and re-solves this sketch, as a `SolveReport`.

```python
sketch.coincident(a: int, b: int) -> int
```
The points `a` and `b` at one place. Each constraint method returns the new constraint's id, and refuses one that conflicts with the sketch, raises `BuildError`.

```python
sketch.point_on_line(point: int, line: int) -> int
```
The point `point` on the line `line`, taken as infinite.

```python
sketch.point_on_circle(point: int, circle: int) -> int
```
The point `point` on the circle `circle`, or on an arc's whole circle.

```python
sketch.horizontal(a: int, b: int) -> int
```
The points `a` and `b` level with each other (one y).

```python
sketch.vertical(a: int, b: int) -> int
```
The points `a` and `b` one above the other (one x).

```python
sketch.parallel(a: int, b: int) -> int
```
The lines `a` and `b` parallel, either way round.

```python
sketch.perpendicular(a: int, b: int) -> int
```
The lines `a` and `b` at right angles.

```python
sketch.collinear(a: int, b: int) -> int
```
Line `b`'s two ends on line `a`, taken as infinite.

```python
sketch.tangent(a: int, b: int, sense: str = 'auto') -> int
```
A line and a circle or arc, or two circles or arcs, tangent; `sense` picks the side (`"auto"`: the side they are on now). Where the two meet end to end — the ends one point, or held together by a coincident when the tangent is added — it is held at that joint instead, their directions there running on smoothly, and `sense` plays no part (`Sketch.is_joint_tangent()`).

```python
sketch.tangent_at_end(curve: int, other: int, end: str = 'start') -> int
```
The free curve `curve`'s handle at its `end` (`"start"` or `"end"`) along `other` when that is a line, or square to its radius at the curve's end when it is a circle or an arc.

```python
sketch.concentric(a: int, b: int) -> int
```
The circles or arcs `a` and `b` about one centre.

```python
sketch.equal_length(a: int, b: int) -> int
```
The lines `a` and `b` the same length.

```python
sketch.equal_radius(a: int, b: int) -> int
```
The circles or arcs `a` and `b` the same radius.

```python
sketch.midpoint(point: int, line: int) -> int
```
The point `point` at the middle of the line `line`.

```python
sketch.symmetric(a: int, b: int, about: int) -> int
```
The points `a` and `b` mirror images of each other across the line `about`.

```python
sketch.fix(entity: int) -> int
```
Every parameter of `entity` held where it is now: a point's position, a circle's centre and radius, ...

```python
sketch.distance(a: int, b: int, value: float, driving: bool = True) -> int
```
The points `a` and `b` `value` apart. Every dimension takes `driving`: `True` (the default) sets the geometry, `False` only reports what it measures (`Sketch.measure()`), never conflicting.

```python
sketch.point_line_distance(point: int, line: int, value: float, driving: bool = True, sense: str = 'auto') -> int
```
The point `point` `value` from the line `line` (taken as infinite), on the side `sense` says.

```python
sketch.line_distance(a: int, b: int, value: float, driving: bool = True, sense: str = 'auto') -> int
```
Line `b`'s start `value` from line `a`, on the side `sense` says — with `Sketch.parallel()`, the gap between two lines. It is measured from the second line's start point, not from the line as a whole.

```python
sketch.circle_line_distance(circle: int, line: int, value: float, driving: bool = True, sense: str = 'auto') -> int
```
The circle `circle`'s rim `value` from the line `line` (its centre's distance less the radius), on the side `sense` says.

```python
sketch.circle_distance(a: int, b: int, value: float, driving: bool = True) -> int
```
The circles `a` and `b` `value` apart rim to rim: their centres' distance less both radii, negative where they overlap.

```python
sketch.horizontal_distance(a: int, b: int, value: float, driving: bool = True) -> int
```
`b`'s x less `a`'s, signed, equal to `value`.

```python
sketch.vertical_distance(a: int, b: int, value: float, driving: bool = True) -> int
```
`b`'s y less `a`'s, signed, equal to `value`.

```python
sketch.length(line: int, value: float, driving: bool = True) -> int
```
The line `line` `value` long.

```python
sketch.angle(a: int, b: int, value: float, driving: bool = True) -> int
```
The angle counter-clockwise from line `a`'s direction to line `b`'s, `value` radians.

```python
sketch.radius_of(circle: int, value: float, driving: bool = True) -> int
```
The circle or arc `circle`'s radius `value`: the RADIUS dimension, kind `"radius"`, named apart from `Sketch.radius()`, which reads a radius.

```python
sketch.diameter(circle: int, value: float, driving: bool = True) -> int
```
The circle or arc `circle`'s diameter `value`.

```python
sketch.constraints() -> list[int]
```
The live constraint ids, ascending.

```python
sketch.constraint_kind(id: int) -> str
```
The kind of constraint `id`, e.g. `"point_line_distance"`. An unknown or removed id raises `BuildError`.

```python
sketch.constraint_refs(id: int) -> list[int]
```
The entity ids constraint `id` was made on, in the order they were given.

```python
sketch.constraint_value(id: int) -> float | None
```
The value of the dimension `id`; `None` for a constraint that is not a dimension. An unknown id raises `BuildError`.

```python
sketch.constraint_driving(id: int) -> bool
```
Whether the dimension `id` drives the geometry; `False` for a constraint that is not a dimension. An unknown id raises `BuildError`.

```python
sketch.constraint_sense(id: int) -> str
```
The sense of constraint `id` as the sketch holds it, `"auto"` resolved to the side it took; `"auto"` for a kind without one.

```python
sketch.constraint_end(id: int) -> str
```
The end (`"start"` or `"end"`) of the free curve a `Sketch.tangent_at_end()` constraint `id` holds; `"start"` for a kind without one. An unknown id raises `BuildError`.

```python
sketch.is_joint_tangent(id: int) -> bool
```
Whether the tangent `id` is held at a joint (two curves meeting end to end) rather than as a touch; `False` for any other constraint.

```python
sketch.remove(id: int) -> None
```
Removes the constraint `id`. Nothing is solved; a joint tangent the removed coincident held goes back to a touch.

```python
sketch.set_value(id: int, value: float) -> SolveReport
```
Sets the dimension `id` to `value` and re-solves, as a `SolveReport`. One that will not converge is refused, raises `BuildError`, and the sketch is left as it was.

```python
sketch.set_driving(id: int, driving: bool) -> SolveReport
```
Makes the dimension `id` drive the geometry (`True`) or only report it, and re-solves, as a `SolveReport`. Made driving, it first takes the value it measures now, so nothing moves; one that would conflict is refused and the sketch left as it was.

```python
sketch.measure(id: int) -> float
```
What the geometry measures for the dimension `id` right now, driving or not.

```python
sketch.solve() -> SolveReport
```
Solves the sketch, as a `SolveReport`. Each independent part is solved alone, every point moving as little as it can; a part that conflicts or does not converge is put back where it was and named in the report — reported, not raised.

```python
sketch.drag(moves: Mapping[int, Point2]) -> SolveReport
```
Drags each point id in `moves` (a mapping of id to (x, y)) towards its target while the constraints hold, as a pointer drag does, as a `SolveReport`: the dragged points go where they can and everything else moves as little as it can; a fully constrained point stays put. An id that is not a point raises `BuildError`. The moves are sent in ascending id order, whatever order they are given in, and an id given twice is refused where the language can hold one (`sketch_drag: point <id> given twice`).

```python
sketch.diagnose() -> Dof
```
The sketch's degrees of freedom, as a `Dof`: whole and per independent part.

```python
sketch.profiles(tolerance: float = 1e-06) -> list[Profile]
```
The closed loops among the solved, non-construction curves, as `Profile` values of exact segments (lines, arcs, the free curves' own shapes); a loop inside another becomes its hole. Ends within `tolerance` (1e-6 by default) join.

```python
sketch.open_chains(tolerance: float = 1e-06) -> list[Profile]
```
The chains of curves that do not close, as open `Profile` values — sweep paths; ends within `tolerance` join.

### SolveReport

```python
class SolveReport
```

What a `Sketch.solve()`, `Sketch.drag()`, `Sketch.set_value()`, `Sketch.set_driving()` or `Sketch.update_reference()` did, as plain data.

```python
solveReport.status  (attribute)
```
`"converged"`, `"conflicting"` (constraints that cannot all hold) or `"diverged"` (no solution found within the iteration budget). The library hands the number back as a double and every wrapper converts it exactly: a value that is not a whole number in range is an error naming the call, never a status.

```python
solveReport.converged: bool  (property)
```
Whether `status` is `"converged"`.

```python
solveReport.iterations  (attribute)
```
The most solver iterations any one part took (each part is solved alone).

```python
solveReport.max_residual  (attribute)
```
The largest constraint residual left, scaled by the sketch's size; 0 when nothing was left to solve.

```python
solveReport.ids  (attribute)
```
The constraints a conflict ran into, or the worst ones of a diverged solve; empty when it converged.

### Dof

```python
class Dof
```

A sketch's degrees of freedom, as `Sketch.diagnose()` returns them: plain data, read after a solve. A sketch is `"under"` constrained while something can still move, `"full"` when nothing can and nothing fights, `"over"` when constraints fight.

```python
dof.free  (attribute)
```
How many degrees of freedom are left: the unknowns less the rank of the constraint equations. The counts arrive as doubles and are converted exactly: a value that is not a whole number in range is an error naming the call, never a state.

```python
dof.state  (attribute)
```
`"under"`, `"full"` or `"over"`.

```python
dof.redundant  (attribute)
```
The constraint ids already implied by earlier ones — harmless, kept.

```python
dof.conflicting  (attribute)
```
The constraint ids that fight earlier ones.

```python
dof.free_entities  (attribute)
```
The entity ids that can still move, ascending (references never).

```python
dof.parts  (attribute)
```
The independent parts the sketch splits into, as `PartDof` values: each solved, and dragged, alone.

### PartDof

```python
class PartDof
```

One independent part of a diagnosed sketch — constraints and the unknowns they share, solved apart from the rest: one of `Dof.parts`. Plain data.

```python
partDof.params  (attribute)
```
How many unknowns the part has.

```python
partDof.free  (attribute)
```
How many of them stay free.

```python
partDof.state  (attribute)
```
`"under"`, `"full"` or `"over"`.

```python
partDof.constraints  (attribute)
```
The constraint ids in the part, in the order they were added.

```python
partDof.redundant  (attribute)
```
Its constraints already implied by earlier ones.

```python
partDof.conflicting  (attribute)
```
Its constraints that fight earlier ones.

```python
partDof.free_entities  (attribute)
```
Its entities that can still move; a curve whose points lie in two parts may be in both.

### BuildError

```python
class BuildError(Exception)
```

What the kernel refused, in its own words: a profile that crosses itself, a fillet too large for its faces, a boolean with nothing left. Raised by the call that failed, at once.

```python
buildError.ids  (attribute)
```
The ids a `Sketch` refusal names, as a list: the constraints a new constraint, value or reference conflicts with (`Sketch.coincident()` and the other constraint methods, `Sketch.set_value()`, `Sketch.set_driving()`, `Sketch.update_reference()`), or the entities still using a point (`Sketch.remove_entity()`). Empty when the refusal names none, and for every error outside a sketch — so a sketcher's interface can mark the clash without reading the text.
