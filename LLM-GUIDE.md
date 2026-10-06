# Cadaclysm blacksmith: a modelling guide for language models

**For cadaclysm 0.10.0.** The API below is this release's: use it with the wrappers and libraries of 0.10.0.

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

### A drone motor

A base, a bell with windows, a shaft and a nut; then the parts as an assembly with a joint.

```python
import math
from cadaclysm_blacksmith import Frame, Profile, Solid

# A drone motor: an orange base, a black bell with six windows, a shaft and a nut.
base = Solid.cylinder(15, 3).coloured("#ff6b0d")
bell = Solid.cylinder(15, 12).translate(0, 0, 3)
for k in range(6):
    a = k * math.pi / 3
    bell = bell.cut(Solid.cylinder(4, 10).translate(8.5 * math.cos(a), 8.5 * math.sin(a), 7))
bell = bell.coloured("#111113")
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

## API reference (Python)

Every class and call a part needs, as the wrapper declares it. `Solid.name(...)` is called on the class, `solid.name(...)` on an instance; the other classes likewise. Frames and axes: pass a `Frame`, twelve numbers or four `(x, y, z)` triples for a frame, and six numbers or two triples for an axis.

### Module functions

The kernel's own library, licence, STEP and `.brep` writers. It is a separate shared library (`cadaclysm_blacksmith`) from the reader, with its own licence call; one licence file serves both.

```python
write_step(path, solids, schema=None, unit='mm') -> None
```
Write several solids as one STEP file, each its own body. `unit` is `mm`, `m` or `in`. `schema` is left out for AP203 (built in — no file needed; AP242 when any solid, face or edge is coloured, since AP203 has no colour entities), the name of another built-in schema such as AP242's `AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF` (AP214's `AUTOMOTIVE_DESIGN` cannot carry the writer's `mechanical_context`), or a custom EXPRESS schema: a path to its `.exp` or its text. Colours from `coloured` and `edges_coloured` are written as STEP styling wherever the schema has it, a solid's read back as the node's colour; a named schema without it writes the solids bare.

```python
write_step_assembly(path, parts, placements, schema=None, unit='mm') -> None
```
Write an assembly as one STEP file: `parts` names each solid, in its own coordinates, and each is written once as its own product; `placements` lists `(name, frame)` pairs, each an occurrence of that part at that frame (right-handed and orthonormal), all under one root product. A reader tessellates a part once however many times it is placed, and shows each placement under its part's name. `schema` and `unit` as `write_step`.

```python
write_brep(path, solids)
```
Write several solids as one OCCT `.brep` file, each its own solid under one compound (a single solid is the file's root): the exact surfaces and curves, with a curve in each face's own parameters for every edge, so Open CASCADE's `BRepTools::Read` gives a shape its `BRepCheck_Analyzer` finds valid. No unit is declared — a `.brep` carries none — so the numbers written are the numbers held. The library writes the file itself.

```python
write_sat(path, solids, unit='mm')
```
Write several solids as one ACIS SAT file, each its own body: planes, cylinders, cones, spheres and tori as their own records, splines and swept surfaces as exact NURBS, in the layout Rhino's own exporter writes. `unit` is `mm`, `m` or `in` and goes into the header as millimetres per unit. The library writes the file itself, so a refusal names it.

```python
svg(things, path=None) -> str | None
```
Several solids and profiles' wireframe as one SVG, any mix and any order: a `<g id="solid-<i>">` per solid then a `<g id="profile-<i>">` per profile, each stroked in its own colour where it carries one — a solid's edge colour first, then its body colour (a face colour says nothing about a wireframe) — and the keywords' `stroke=` otherwise. The keywords are `Scene.svg`'s own: `view=` (front, back, left, right, top, bottom, iso), `az=`/`el=` over it, `up=` (default `z`: neither a solid nor a profile carries a convention of its own to default it from), `fov=` (0, the default, is orthographic), `size=`, `margin=`, `tolerance=`, `stroke=` and `background=` (`"#rgb"`, `"#rrggbb"` or a CSS colour name; a language that keeps these numeric reads the same text through its `packed()`/`Packed()` helper; `background=` `None` for transparent), `width=` (the stroke's, in page units), `edges=`, `curves=`, `isocurves=`, `polylines=` (which line sets are drawn; edges by default), and `silhouettes=` (also draw where each solid's surfaces turn away from the eye — the outline a sphere has no edge for, on by default: a sphere's and a torus's only curves are the seams where their one face meets itself, which are not edges of the body and are never drawn, so without it those two draw a blank page. A line set in its own right, so `silhouettes=` with `edges=` off draws the outline alone).

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
boxes_apart(a: Box, frame_a, b: Box, frame_b) -> bool
```
True only if box `a` at `frame_a` and box `b` at `frame_b` cannot touch — a separating axis among the boxes' face normals and edge-direction crosses; touching is not apart. Sharper than moving each box (`Box.moved()`) and asking `Box.overlaps()`, which boxes the *result* on the world axes again and so can call two oriented boxes overlapping when they are not (two unit boxes, the second turned 45 degrees about z and moved 2.3 along x: their world boxes overlap, but the boxes themselves do not touch). `frame_a` or `frame_b` not twelve finite numbers or not rigid raises `BuildError`.

### Profile

```python
class Profile
```

A closed outline with holes, in its own x/y — what gets extruded, revolved, lofted or swept. Immutable: every method returns a new one.

Its loops must be simple: an outline that crosses or touches itself (a figure-eight, a vertex landing on another side), a hole that runs into the boundary, or two holes that overlap are refused by every call that builds a face or a closed solid, naming the loops — `extrude: hole 0 crosses the boundary`. The open calls (`extrude_open`, `revolve_open`, `sweep_open`, `loft_open`) build sheets, and take such a profile as it is.

```python
Profile.rect(w, h) -> Profile
```
A `w` × `h` rectangle centred on the origin.

```python
Profile.circle(r) -> Profile
```
A circle of radius `r` about the origin.

```python
Profile.slot(centre, length, r) -> Profile
```
A slot (stadium) `length` long overall, with end radius `r`, centred on `centre` and running along x. `length` must exceed `2 * r`.

```python
Profile.polygon(points) -> Profile
```
A closed polygon through the points, in order, its side back to the first point a segment of its own. At least three points.

```python
Profile.regular_polygon(centre, radius, sides, angle=0.0) -> Profile
```
A regular polygon of `sides` sides (at least 3) on the circle of `radius` about `centre`, its first corner at `angle` radians from the sketch's x axis (0 by default), the rest counter-clockwise.

```python
Profile.star(centre, outer, inner, points, angle=0.0) -> Profile
```
A star of `points` tips (at least 3) on the circle of `outer` about `centre`, its inner corners on the circle of `inner` (positive, under `outer`), alternating: the first tip at `angle` radians from the sketch's x axis (0 by default), the rest counter-clockwise, each inner corner half a step on from the tip before it. `2 * points` straight sides; an `inner` not under `outer` raises `BuildError`.

```python
Profile.text(text, size=10.0, font='', halign='left', valign='baseline', spacing=1.0, direction='ltr', font_bytes=None) -> list[Profile]
```
`text` set in a font, one profile per closed shape — a letter with its counters as holes (`o` one, `8` two; `i` is two profiles) — on the sketch plane, the baseline along x from the origin, each outline counter-clockwise and its holes clockwise, a curved side the font's own cubic Bezier kept exactly: an extruded `O` has curved walls, and writes to STEP as splines. `size` (10 by default) is roughly the height of a capital. `font` is a family, optionally with a style (`"Liberation Sans:style=Bold"`), a font file's path, or empty for the bundled Liberation Sans Regular — which also serves when the family is not found, so text never comes back empty; `font_bytes` a font file's bytes, used instead of `font` when given (a page or a phone fetches its own font). `halign` is `left` (default), `center` or `right`; `valign` `baseline` (default), `bottom`, `center` or `top`; `spacing` (1 by default) multiplies the gap between glyphs; `direction` `ltr` (default) or `rtl`. Glyphs are laid out one after another by their advance widths — no shaping, so Latin sets as expected and scripts that need ligatures or reordering do not. Empty text is an empty list. A size or spacing not positive and finite, an alignment or direction not one of those words, or font bytes that are not a font raises `BuildError`.

```python
Profile.spline(points, degree=3, weights=None, closed=False) -> Profile
```
A spline of `degree` (3 by default) through the control polygon `points`, `weights` one per point or `None`. Open, it starts on the first point and ends on the last: an open chain, for `Solid.extrude_open()` or `Profile.chain()`. Closed, it is periodic — smooth through its own start, no corner there — and a closed profile. The degree is lowered to fit the points; a degree of zero, too few points (two open, three closed) or a weight not positive raises `BuildError`.

```python
Profile.path(start) -> Path
```
Start drawing an outline segment by segment at `start`; see `Path`.

```python
Profile.parabola(vertex, axis, focal, from_, to) -> Path
```
Start drawing on the arc of the parabola with `vertex`, axis direction `axis` and focal length `focal`, over the across-axis coordinates `from`..`to`: the path begins at the arc's first point and holds the arc as one conic segment — a reflector from rim to rim; `parabola((0, 0), (0, 1), 20, -50, 50)` is a dish 100 wide opening up. A zero axis, a focal length not positive and finite, or `from` not under `to` raises `BuildError`.

```python
Profile.chain(pieces, tolerance=1e-06) -> Profile
```
Open profiles — paths ended open — joined end to end into one: the forge's merge. They may come in any order and either way round: each next piece is the first of the rest with an end within `tolerance` (1e-6 by default) of either end of the chain so far, reversed where that makes it meet. Every segment is kept exactly — a line a line, an arc an arc, a spline the same spline. Closed where the chain's two ends meet, otherwise an open chain. A piece that is empty, has holes, is closed on its own or meets none of the others raises `BuildError` naming it by its index.

```python
Profile.from_loops(loops) -> Profile
```
Closed loops, in any order, as one profile: the loop enclosing the most area is the boundary and every other a hole in it, in the order given — a sketch's rectangle and the circles drawn inside it. Each loop is a closed profile with no holes of its own, wound either way; one that closes within rounding is closed exactly. A loop that is open, empty or encloses no area, loops that cross or touch, a hole outside the boundary, or one inside another hole (an island) raises `BuildError`, naming the loops by their index.

```python
profile.close_loop() -> Profile
```
This profile closed — the forge's sketch "close": where its last segment stops short of its start (a path ended open), a straight segment back to it; where it already comes back within 1e-9 of its extent, its last segment made to land on the start exactly. A closed profile comes back as it is, and holes are closed the same way.

```python
profile.pieces(cutters, tolerance=1e-06) -> list[Profile]
```
This curve cut where the `cutters` cross, touch or run along it — the sketch trim's pieces: in order along the curve from its start, each an open profile of portions of this one's own segments (a line's stretch a line, an arc's an arc, a spline's the same spline over part of its domain, nothing refitted). One piece, this curve, where nothing cuts it; a closed curve's piece round its start is one piece. Cuts closer than `tolerance` to each other fold onto one. A curve with no segments raises `BuildError`.

```python
profile.trim(cutters, piece, tolerance=1e-06) -> list[Profile]
```
This curve with piece `piece` of `Profile.pieces()` taken away — the sketch trim, the forge's: what is left, as open profiles. One for a closed curve (its other pieces run together from where the removed one ended), the stretches before and after for an open one, none where the piece was the whole curve. A piece the curve does not have raises `BuildError`.

```python
profile.with_hole(hole: 'Profile') -> Profile
```
This outline with `hole` cut out of it.

```python
profile.common(other, tolerance=1e-06) -> list[Profile]
```
The region this outline and `other` share, both read in one plane, as a list of zero or more profiles — each boundary counter-clockwise, each hole clockwise, arcs and splines kept exact. An arc kept from an input can still come out split at that input's own seam point (two circles' lens is four arcs, one pair per circle) — exact, not an approximation. Two loops of a result may touch at a point (two holes whose corners meet, one from each input): a right point set that the verbs needing simple loops — `Solid.extrude()`, a boolean taking it as an input — refuse. Both must be closed and simple; no shared area is an empty list. A `tolerance` not positive and finite, an outline open or crossing itself, a `tolerance` too fine for these outlines (following their arcs and splines to a tenth of it would take more than 8 million points, about 128 MB), and, as a defect rather than an outcome, a result that fails to close, raises `BuildError`.

```python
profile.translate(dx, dy) -> Profile
```
This outline moved by (`dx`, `dy`).

```python
profile.coloured(colour) -> Profile
```
A new outline coloured (r, g, b), each 0..1, `"#rgb"`, `"#rrggbb"` or a CSS colour name (`"tomato"`, `"RebeccaPurple"`): how it is drawn. The verbs that make a profile from one carry it (`translate`, `round`, `with_hole` keeps the outer's, `chain` and `from_loops` the first's); a solid made from it takes nothing — colour a solid with `Solid.coloured()`.

```python
profile.colour: tuple[float, float, float] | None  (property)
```
The outline's colour as (r, g, b), or none.

```python
profile.round(radius, corners=None, open=False) -> Profile
```
This outline with its corners rounded by `radius`: where two straight segments meet, both are cut back and an exact arc tangent to both goes between them; a corner next to an arc or a spline is left as it is. With no `corners` every such corner is rounded, the holes' too; a list picks corners of the outline — corner `k` is where segment `k` ends. `open` reads the profile as an open chain whose two ends stay square. A radius that does not fit raises `BuildError` naming the corner.

```python
profile.to_arcs(tolerance=0.01) -> Profile
```
This profile with every free-form side (a Bezier, a conic, a NURBS) replaced by lines and arcs within `tolerance` of it — what a G-code writer can say. Lines and arcs pass through as they are, every loop closes on itself exactly, holes are converted the same way. `tolerance` (0.01 by default) not positive and finite, or a spline that does not evaluate, raises `BuildError`.

```python
profile.offset(distance, tolerance=0.01) -> list[Profile]
```
This profile grown by `distance` (shrunk where it is negative), as zero or more profiles, all lines and arcs: outward corners rounded by `|distance|`, holes moving against the boundary (a hole shrinks as the profile grows). Free-form sides are fitted to `tolerance` first (`Profile.to_arcs()`). A shrink that eats the whole profile is an empty list. A `distance` not finite, a `tolerance` (0.01 by default) not positive and finite, a loop with no sides, or loops that cross or touch, raises `BuildError`.

```python
profile.polylines(tolerance=0.05) -> list[numpy.ndarray]
```
The outline, then each hole, as polylines at z = 0 within `tolerance` of its arcs and splines — what a viewer draws it with. A closed loop repeats its first point at the end; an open chain (a profile ended open) stays open. Views, like `Solid.mesh()` — copies in Node, Godot and Python.

```python
profile.show(tolerance=0.05) -> None
```
Draw the outline and holes with the viewer in use, from the top by default. Keywords as `Solid.show()`; `edges=` is ignored, the lines being the whole picture. With the GPU library (`import cadaclysm.view.wgpu`) the drawing replaces what one shared window shows and stays live — at the REPL, in IPython and in Jupyter by themselves, in a script until it exits; `cadaclysm.view.View` draws several items or several windows.

```python
profile.svg(path=None, *, view='top') -> str | None
```
This profile's own loops as SVG: a line a line, an arc an arc, a spline the NURBS' own Béziers — exact curves, nothing flattened to the polyline `Profile.polylines()` samples. The keywords are `svg`'s own, except `view=` defaults to `top` here rather than `iso`: a profile lies in z = 0, so its own plane is already the page and it reads flat and true. In the languages whose options are a struct (view already `iso`, not nullable), that default holds only when no options value is passed at all — pass one for anything else and its own `view` applies. With `path`, writes the file and returns `None`; without, returns the SVG text. raises `BuildError` on a refused option or a failed write.

### Path

```python
class Path
```

An outline drawn a segment at a time — lines, arcs, Béziers, NURBS — then closed into a `Profile`. Ending it consumes the builder.

```python
path.line_to(x, y) -> Path
```
A straight segment to (`x`, `y`).

```python
path.arc_to(x, y, centre, ccw=True) -> Path
```
A circular arc to (`x`, `y`) about `centre`, counter-clockwise unless `ccw` is `False`.

```python
path.bezier_to(c1, c2, to) -> Path
```
A cubic Bézier through control points `c1`, `c2` to `to`.

```python
path.conic_to(x, y, control, weight) -> Path
```
A conic arc to (`x`, `y`) through the control point `control` with middle `weight`: under 1 an elliptical arc, 1 a parabola, over 1 a hyperbola — the rational quadratic Bézier, kept exact. A weight not positive and finite, an end on the current point, or a control point on the chord raises `BuildError`.

```python
path.parabola_to(x, y, control) -> Path
```
A parabolic arc to (`x`, `y`) whose end tangents meet at `control`: `Path.conic_to()` with weight 1.

```python
path.hyperbola_to(x, y, control, weight) -> Path
```
A hyperbolic arc to (`x`, `y`) through `control` with middle `weight` over 1; a weight of 1 or under raises `BuildError`.

```python
path.parabola_by_vertex(x, y, vertex) -> Path
```
The parabolic arc to (`x`, `y`) whose vertex is `vertex`: the axis and focal length are solved from the two ends. A vertex on the chord, or one no parabola through both ends has (the vertex must be the arc's extreme point), raises `BuildError`.

```python
path.parabola_by_focus(x, y, focus) -> Path
```
The parabolic arc to (`x`, `y`) whose focus is `focus`: of the two parabolas through the ends with that focus, the one whose vertex lies between the ends' projections, then the one whose arc cups the focus (the focus between the arc and its chord), then the more symmetric; with the focus beyond the chord that is the arch over the ends, not the shallow dish — draw that one with `Profile.parabola()`. A focus on the chord raises `BuildError`.

```python
path.nurbs_to(control, knots, degree, weights=None) -> Path
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
SweepPath.at(point) -> SweepPath
```
Start a path at a 3D point.

```python
SweepPath.along(curve: Profile, frame, tolerance=0.05, open=True) -> SweepPath
```
The path a 2D chain (usually from `Path.end_open()`) draws on `frame`: a line a straight piece, an arc a circular one, a Bézier or spline fitted with biarcs — arcs tangent to each other and to the curve — within `tolerance`, so the path is tangent throughout and the sweep exact along it. `open` false closes the path back to its start.

```python
sweepPath.line_to(point) -> SweepPath
```
A straight piece to a 3D point.

```python
sweepPath.arc(centre, axis, angle) -> SweepPath
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
Slant.flat(at) -> Slant
```
A flat plane at height `at`.

```python
Slant.of_plane(frame, point, normal) -> Slant
```
The plane through `point` square to `normal`, as heights over `frame`. A plane that contains the extrusion direction has no height and raises `BuildError`.

### Frame

```python
class Frame
Frame(origin, x, y, z)  # the constructor
```

A frame built for you instead of twelve numbers typed out: an origin and three unit axes, square to each other and right-handed (z = x × y). It goes wherever a `frame` does. Immutable. The constructor takes the origin and the three axes, normalises them, and raises `BuildError` when they are not square or not right-handed.

```python
Frame.xy(origin=(0, 0, 0)) -> Frame
```
The world XY plane through `origin`: z up, as `Workplane.xy()`.

```python
Frame.xz(origin=(0, 0, 0)) -> Frame
```
The world XZ plane through `origin`: x along X, y along Z, so z is -Y, as `Workplane.xz()`.

```python
Frame.yz(origin=(0, 0, 0)) -> Frame
```
The world YZ plane through `origin`: x along Y, y along Z, so z is +X, as `Workplane.yz()`.

```python
Frame.at(origin, normal, x=None) -> Frame
```
The plane through `origin` square to `normal`, which becomes the frame's z (it need not be unit). Its x axis is `x` laid onto that plane; with none, world X laid onto it, or world Y when the normal is within about 25° of X — the axes `Solid.face_frame()` gives a face facing `normal`. So a normal along +Z, -Y or +X gives exactly `Frame.xy()`, `Frame.xz()` or `Frame.yz()`. A zero normal, or an `x` along the normal, raises `BuildError`.

```python
Frame.of(frame) -> Frame
```
Twelve numbers — what `Solid.face_frame()` and `Workplane.frame` hand back — as a checked frame, to read its axes or move it.

```python
Frame.midplane(a, b) -> Frame
```
The plane midway between the planes of frames `a` and `b`: for parallel planes the one halfway between, on `a`'s axes; for planes that meet, the plane bisecting them through the line they meet on, its x along that line.

```python
Frame.through(p, q, r) -> Frame
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
frame.translate(dx, dy, dz) -> Frame
```
This frame moved by (`dx`, `dy`, `dz`) in world coordinates.

```python
frame.offset(distance) -> Frame
```
This frame moved `distance` along its own z: `Frame.xy().offset(5)` is the XY plane at z = 5.

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
Workplane.on(frame) -> Workplane
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
workplane.cuboid(x, y, z) -> Workplane
```
A box `x` × `y` × `z` centred on the current frame's origin and aligned to its axes — on a picked face, half of it below the face; replaces the solid.

```python
workplane.cylinder(r, h) -> Workplane
```
A cylinder of radius `r` and height `h` standing on the current frame; replaces the solid.

```python
workplane.face(profile: Profile) -> Workplane
```
The planar sheet the profile bounds on this frame — see `Solid.face()`; replaces the solid.

```python
workplane.extrude(profile: Profile, height) -> Workplane
```
The profile extruded `height` along the frame's z; replaces the solid.

```python
workplane.revolve(profile: Profile, angle) -> Workplane
```
The profile revolved `angle` radians about the frame's y axis; replaces the solid.

```python
workplane.translate(dx, dy, dz) -> Workplane
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
Selector.normal(direction) -> Selector
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
Solid.cuboid(x, y, z) -> Solid
```
A box `x` × `y` × `z`, centred on the origin.

```python
Solid.cylinder(r, h) -> Solid
```
A cylinder of radius `r`, from z = 0 to `h`.

```python
Solid.cone(r, h) -> Solid
```
A cone of base radius `r` and height `h`, apex up.

```python
Solid.sphere(r) -> Solid
```
A sphere of radius `r` about the origin.

```python
Solid.torus(major, minor) -> Solid
```
A torus about the z axis: `major` to the tube's centre, `minor` the tube's radius.

```python
Solid.wedge(x, y, z, top_x) -> Solid
```
A box whose top face is `top_x` long instead of `x`: a ramp.

```python
Solid.pyramid(sides, r, h) -> Solid
```
A pyramid of `sides` sides (at least 3): its base the regular polygon of radius `r` on z = 0 (`r` to a corner, the first on +x), its tip at height `h`.

#### From a profile

```python
Solid.extrude(profile: Profile, frame, height) -> Solid
```
The profile on `frame`, extruded `height` along the frame's z.

```python
Solid.extrude_open(profile: Profile, frame, height) -> Solid
```
The walls only, no caps: an open sheet. Takes an open `Path.end_open()` chain as well as a closed profile.

```python
Solid.extrude_tapered(profile: Profile, frame, height, taper) -> Solid
```
Extrude with a draft: the walls lean out by `taper` radians as they rise (in, when negative). Every wall stays exact — a plane off a line, a cone off an arc.

```python
Solid.extrude_open_tapered(profile: Profile, frame, height, taper) -> Solid
```
The tapered walls without caps.

```python
Solid.extrude_between(profile: Profile, frame, bottom, top) -> Solid
```
Extrude between two planes rather than two heights: `bottom` and `top` are each a `Slant` (a bare number is a flat one). With both flat this is `Solid.extrude()`; with a slope it is the mitred end of a frame member. A top that comes down to or through the bottom raises `BuildError`.

```python
Solid.extrude_open_between(profile: Profile, frame, bottom, top) -> Solid
```
`Solid.extrude_between()` without the caps.

```python
Solid.revolve(profile: Profile, axis, angle) -> Solid
```
The profile swung `angle` radians about `axis` (a point and a direction — see Frames). The profile's x is read as the radius and its y as the height along the axis, so it must lie to one side of it.

```python
Solid.revolve_open(profile: Profile, axis, angle) -> Solid
```
The revolved surface of an open profile: a sheet.

```python
Solid.revolve_in_plane(profile: Profile, frame, a, b, angle) -> Solid
```
The profile on `frame` swung `angle` radians about the axis through the sketch points `a` and `b` (each `(x, y)` on the frame) — the profile and its axis drawn together, as a sketch draws them, where `Solid.revolve()` reads the profile as (radius, height). The profile may lie on either side of the axis and touch it (a half-disc with its diameter on the axis turns into a ball), but not cross it. The sweep starts where the profile is drawn and turns right-handed about `b - a`, so a partial turn leaves one end of the solid over the profile itself.

```python
Solid.revolve_open_in_plane(profile: Profile, frame, a, b, angle) -> Solid
```
`Solid.revolve_in_plane()` for a curve: its segments swung into a sheet, no caps.

```python
Solid.coil(profile: Profile, axis, pitch, turns) -> Solid
```
The profile coiled about `axis` (a point and a direction): read as `Solid.revolve()` reads it — x the distance from the axis, y along it — and turned `turns` times while climbing `pitch` along the axis each turn: a spring, a thread. The walls follow the helix to a few millionths of the radius (a helix is not a NURBS curve, so they are a close fit, exact at both ends); the two ends are the profile itself, flat. A profile reaching the axis, one with holes, or — from a full turn up — a pitch no taller than the profile raises `BuildError`.

```python
Solid.loft(a: Profile, frame_a, b: Profile, frame_b) -> Solid
```
The solid between profile `a` on one frame and `b` on another: ruled walls between matching sides (both profiles need the same number of sides, and no holes), capped by the two.

```python
Solid.loft_open(a: Profile, frame_a, b: Profile, frame_b) -> Solid
```
The ruled walls without the caps.

```python
Solid.loft_through(sections) -> Solid
```
The solid smooth through every section — a profile on its frame, in order: each wall interpolates its side across all the profiles (cubic through four or more, quadratic through three, `Solid.loft()` through two), capped by the first and the last. Every section of the result is its profile exactly, arcs and all. The profiles must have the same number of sides and no holes; otherwise raises `BuildError`.

```python
Solid.loft_through_open(sections) -> Solid
```
The walls through the curves without the caps: an open sheet.

```python
Solid.sweep(profile: Profile, frame, path: SweepPath) -> Solid
```
The profile on `frame`, carried along a `SweepPath`. A straight piece is an extrusion and an arc a revolution about the arc's axis, so nothing is approximated — a circle along an arc is an exact torus wall.

```python
Solid.sweep_open(profile: Profile, frame, path: SweepPath) -> Solid
```
The swept walls without caps: an open sheet.

```python
Solid.pipe(path: SweepPath, radius, thickness=0.0) -> Solid
```
A circle of `radius` carried along a `SweepPath`, square to where it starts: a solid rod, or with a positive `thickness` a tube whose walls are that thick. The path is only borrowed, as by `Solid.sweep()`, and refused the same way.

```python
solid.extrude_faces(height) -> Solid
```
Every face of a sheet pushed `height` along its own normal, walled and closed: the sheet as a solid of that thickness.

```python
Solid.face(profile: Profile, frame) -> Solid
```
The flat sheet a profile bounds on `frame`: one planar face, each hole a hole through it, its normal the frame's z however the profile winds, every edge the exact line, arc or spline its segment is. An open sheet — raise it with `Solid.extrude_faces()`, cut it with `Solid.trim()`.

#### Placing

```python
solid.place(frame) -> Solid
```
A solid built about the origin moved onto `frame`: its origin to the frame's origin, its axes to the frame's (see Frames).

```python
solid.translate(dx, dy, dz) -> Solid
```
Moved by (`dx`, `dy`, `dz`).

```python
solid.scaled(factor) -> Solid
```
Scaled by `factor` about the origin: every length times `factor`, exactly. `factor` must be positive and finite.

```python
solid.rotate(axis, radians) -> Solid
```
Turned `radians` about `axis` (a point and a direction).

```python
solid.mirror(plane) -> Solid
```
Reflected across `plane`: a frame whose z is the mirror plane's normal.

#### Booleans

```python
solid.join(other: 'Solid', tolerance=0.05, progress=None, merge=False) -> Solid
```
The union with `other`, as an exact B-rep. `merge` (off by default, so face and edge numbers stay as they were) merges the flush faces the join leaves, as `Solid.merge_flush()` does — Go takes it as a trailing `true`, Java as an overload; `Solid.cut()` and `Solid.common()` take it too. `tolerance` (0.05 by default) is the mesh tolerance the boolean decides at: both solids are meshed at it, so a tighter one is as correct and slower. It is also the resolution: two faces on one surface to within it — a peg the size of its hole, or a hair thinner — are one surface, and the join is a fit; a gap wider than it is a gap. `progress`, where the wrapper takes one, is called with a phase name and a done/total count.

```python
solid.cut(other: 'Solid', tolerance=0.05, progress=None, merge=False) -> Solid
```
This solid with `other` removed.

```python
solid.common(other: 'Solid', tolerance=0.05, progress=None, merge=False) -> Solid
```
What this solid and `other` share.

```python
solid.section(z, tolerance=0.05) -> list[Profile]
```
This solid cut by the plane `Z = z`: its closed outlines there, in XY, nested into profiles with holes (boundaries counter-clockwise, holes clockwise), a line or a circle crossing kept exact and any other curve as lines within `tolerance`. A plane that misses the solid is an empty list. A `z` not finite, a `tolerance` (0.05 by default) not positive and finite, a face lying in the plane (section a little above or below it), or a crossing that does not close, raises `BuildError`.

```python
solid.split_sheet(tool: 'Solid', tolerance=0.05, progress=None) -> Solid
```
This solid or sheet cut along `tool`'s boundary with nothing removed: each face comes back as its pieces outside `tool` and then its pieces inside, in the original face order — the start of a surface trim. `tool` must be a closed solid. Keep the pieces you want with `Solid.drop_faces()`, or split and drop in one call with `Solid.trim()`.

#### Faces and sheets

```python
solid.face_sheet(face: int) -> Solid
```
One face alone, as an open sheet: its surface, its loops and the exact curves on its edges, the rest of the solid left behind — raised by `Solid.extrude_faces()` it is the prism over that face. Keeps the face's colour.

```python
solid.drop_faces(faces) -> Solid
```
This solid without the faces listed: the rest keep their surfaces, curves and colours in their order, so an index into the result is this one's with the dropped ones closed up. Dropping every face raises `BuildError`.

```python
solid.trim(tool: 'Solid', keep='outside', tolerance=0.05, progress=None) -> Solid
```
This sheet (or solid) cut along the closed `tool`'s boundary and the pieces on one side thrown away: `keep` `"outside"` (the default) keeps what lies outside the tool — a hole punched through — and `"inside"` what lies within it. Nothing on the kept side raises `BuildError`. `tolerance` and `progress` as for `Solid.join()`.

```python
solid.push_pull(face, distance, tolerance=0.05, progress=None) -> Solid
```
Face `face` pushed out by `distance` along its outward normal — pulled in, negative — as a face extrude does it: the prism over it joined on (cut out) at `tolerance`, and the flush faces merged, so a box's top raised is one taller box of six faces rather than a box and a prism with every side wall split at the seam. A face on a cylinder, a cone, a sphere or a torus moves out along its normal instead, as a press-pull does: the surface a step out — a boss fatter, a bore or a countersink narrower, a dome fuller — with the flat faces beside it carried along in their own planes. Any other curved face is refused, as is a curved face with anything but a plane it can follow beside it, reaching a cone's apex, pushed to its axis or centre, off a plane beside it or run into another edge. A flat face keeps its own colour where it now lies.

Several faces push together, as a press-pull on a selection: each by its own rule, one after another in the order given, each found again after the pushes before it renumbered the faces — a box's top and a side pushed 5 is the box 5 taller and 5 wider, a boss's top and wall the boss taller and fatter. A face on the same curved surface as one before it, and joined to it, moved with that one and is not pushed twice. No faces, or a face an earlier push took away, raises `BuildError`.

`face` is a face index or a list of them.

```python
solid.refillet(face, radius, tolerance=1e-06) -> Solid
```
The round `face` belongs to — a fillet's bands, balls and rim bands joined to that face — made again at `radius`, as a press-pull on a fillet face: taken back to the sharp edges it replaced, and those rounded again, so the round is the one `Solid.fillet()` makes at that radius. Rounds of straight edges between planes (their ends square corners, mitres, balls, or a cylinder, cone or sphere the edge runs into — a D-cut shaft's top edge, a rib's into a boss) and of circular rims between a plane and a cylinder or cone (a boss's foot, a bore's mouth, a counterbore's step); a face that is not one, or a radius that does not fit, raises `BuildError`.

```python
solid.unfillet(face) -> Solid
```
The round `face` belongs to taken off, the faces beside it made sharp again, meeting on the edges the round replaced — the delete of a fillet face. The same rounds as `Solid.refillet()`.

```python
solid.rechamfer(face, distance, tolerance=1e-06) -> Solid
```
The chamfer `face` belongs to — its bevels (flat between two planes, cones round rims) and the corner triangles joined to that face — cut again at `distance`, as a press-pull on a chamfer face: taken back to the sharp edges it cut, and those bevelled again, so the chamfer is the one `Solid.chamfer()` cuts at that distance. A flat bevel's ends may run into a cylinder, cone or sphere, as a round's may. A face that is not a chamfer's bevel, or a distance that does not fit, raises `BuildError`.

```python
solid.unchamfer(face) -> Solid
```
The chamfer `face` belongs to taken off, the faces beside it made sharp again — the delete of a chamfer face. The same chamfers as `Solid.rechamfer()`.

```python
solid.merge_flush() -> Solid
```
This solid with its flush faces merged: flat faces on one plane, facing one way and meeting along their edges — the seams `Solid.join()` leaves where two parts are flush — made one face, and the vertices left mid-way along a straight edge taken out.

```python
solid.split(tool: 'Solid', tolerance=0.05, progress=None) -> list
```
This solid split by `tool` into bodies — returned as a list: a closed `tool` gives the parts outside it, then the parts inside; a flat sheet (a `Solid.face()`) splits by the whole plane it lies on. Each connected part is a body of its own, so a U cut across both arms is three. The new faces are pieces of the tool's, the colours carried over. A tool that does not cross the solid, or a curved sheet, raises `BuildError`. `tolerance` and `progress` as for `Solid.join()`.

```python
solid.split_by_plane(plane, tolerance=0.05, progress=None) -> list
```
This solid split by the plane through `plane`'s origin, square to its z (a frame): the bodies in front of it first, then those behind.

```python
solid.lumps() -> list
```
This solid's connected bodies, each a solid of its own — faces sharing an edge are one body — in the order of their first faces. One body comes back as itself; a boolean that leaves two parts gives two.

#### Finishing

```python
solid.edges: list[Edge]  (property)
```
The solid's edges as `Edge` values — what `Solid.fillet()` and `Solid.chamfer()` take. Copied; safe to keep.

```python
solid.fillet(edges, radius, tolerance=1e-06, progress=None) -> Solid
```
Round the given edges (`Edge` values or their indices) with `radius`. Exact: the blend faces are cylinders, tori and NURBS, and the neighbours are trimmed back onto them.

```python
solid.chamfer(edges, distance, tolerance=1e-06) -> Solid
```
A flat bevel instead of a round: each edge cut back `distance` along both its faces.

```python
solid.shell(thickness, open=(), tolerance=1e-06, progress=None) -> Solid
```
Hollow the solid to walls `thickness` thick — inward for a positive thickness, outward (the solid becoming the cavity) for a negative one. The faces listed in `open` are removed so the hollow is reachable.

```python
solid.thicken(thickness, tolerance=1e-06, progress=None) -> Solid
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
solid.bounds_at(tolerance) -> tuple[tuple[float, float, float], tuple[float, float, float]]
```
The bounds over the tessellation at `tolerance` — the same cache `Solid.mesh()` fills, so asking both costs one mesh.

```python
solid.is_watertight(tolerance=0.05) -> bool
```
Whether `Solid.leaked_edges()` is zero.

```python
solid.mass(accuracy: float = 0.0) -> Mass
```
What this solid measures, per unit density, as a `Mass`: area, volume, centroid, the inertia tensor about the centroid and its principal moments and axes — each figure beside a bound on its own error. Measured on the exact surfaces, refined until every error is under `accuracy` (a share of the figure) or the refinement gives up, which `Mass.accuracy_met` reports; the values are honest either way, they are simply less certain, and the errors say by how much. Volume, centroid and inertia mean something only where the body is closed — `Mass.closed` — and a body whose faces all point inward is measured as if they did not, which `Mass.inverted` says. An accuracy not positive and finite raises `BuildError`.

```python
solid.bounds_box(tolerance=0.05) -> Box
```
This solid's `Box` at `tolerance` (0.05 by default): its boolean mesh, padded by twice that — the broad phase's own bound, cheaper to move and to test against another than the solid itself. `Collider` builds one of these per part at construction. A tolerance not positive and finite, or a solid that meshes to nothing, raises `BuildError`.

#### Naming

```python
solid.named(name: str) -> Solid
```
This solid, named `name`. The name rides through an operation with exactly one source solid (`place`, `translate`, `rotate`, `mirror`, `scaled`, `coloured`, `edges_coloured`, `fillet`, `chamfer`, `shell`, `thicken`, `face_sheet`, `drop_faces`, `lump`, `trim`, `split_by_plane`, `push_pull`, and so on) and is dropped by one with two or more sources (`join`, `cut`, `common`, `split_sheet`, `split`) and by a fresh primitive or sweep. It is what `Assembly.place()` defaults a placement's own name to, and the product name a lone named solid gets written into STEP (`Solid.step()`/`Solid.step_text()` — SAT and OCCT `.brep` have no product name to set). An empty name raises `BuildError`.

```python
solid.name: str | None  (property)
```
This solid's name, or none, as `Solid.named()` set it, kept or dropped by whatever built this solid.

#### Colour

```python
solid.coloured(colour, face=None) -> Solid
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
solid.edges_coloured(colour, edges=None) -> Solid
```
A new solid with its edges coloured (r, g, b), `"#rgb"`, `"#rrggbb"` or a CSS colour name: every edge, or, given `edges` (as `Solid.fillet()` takes them: `Edge` records or indices), just those, whose colour then wins over the all-edges one — an empty list colours none. Inherited as face colours are: a move keeps every edge colour; a boolean, fillet, chamfer or shell gives each edge the colour of the input edge it lies on, and a new edge (a cut's rim, a round's edges) the all-edges colour. `Solid.step()` and `write_step` write them as STEP `CURVE_STYLE` styling, which the reader reads back as `Node.edge_colours`.

```python
solid.edge_colour(edge) -> tuple[float, float, float] | None
```
An edge's colour as drawn: its own, else the solid's edge colour, else none.

```python
solid.brep(path)
```
Write this solid as an OCCT `.brep` file; see `write_brep`.

#### From files

```python
Solid.open(path, body=None) -> Solid
```
The body a CAD file holds, as a solid: STEP (AP203/214/242), ACIS `.sat`, Rhino `.3dm`, OCCT `.brep`, IGES or IFC, read where it draws, in the file's own units and axes. A file drawing several bodies needs `body` (0-based, in drawing order) or `Solid.open_all()`. What such a solid can do is what its geometry allows: fillet and chamfer want line and circle edges; booleans take any surface, but new edges traced on a free-form face are not always writable back to STEP; and every verb meshes its operands first, so its cost grows with the body's face count. Reads through the reader library, which must be from the same release.

```python
Solid.open_all(path) -> list[Solid]
```
Every body a CAD file draws, as solids placed where it draws them: one per placement, so a part placed twice is two solids.

#### Output

```python
solid.mesh(tolerance=0.05) -> tuple[numpy.ndarray, numpy.ndarray, numpy.ndarray]
```
Triangles at `tolerance`: positions, normals (three floats a vertex) and indices. **In every wrapper that lends a view, views owned by a held tessellation** — valid for as long as you keep the view, whatever happens to the solid: meshed again at any tolerance, closed. Rust borrows the solid for the view's lifetime instead; Node and Godot copy. **A raw span, slice or buffer taken out of a view does not keep the view itself reachable in a collected language**: hold the view while you read one, and copy what must outlive it. The same rule as a FEM mesh's views, for the same reason. **A view pins its whole tessellation** — positions, normals, indices, edges, face counts, in both precisions — until the view itself is freed or collected, whichever the language uses; for data that must outlive the view, `copy()` it and drop the view.

Read-only numpy views owned by a held tessellation: neither meshing again at another tolerance nor the solid's `close()` touches them (copies under Pyodide).

```python
solid.show(tolerance=0.05) -> None
```
Draw the solid with the viewer in use — in a terminal, the picture is left in the scrollback. Each face keeps its own colour (`Solid.face_colour()`: a colour of its own, else the solid's). Keywords: view= (front, back, left, right, top, bottom, iso), az=, el=, zoom=, up=, edges=, width=, height=, hint=, tolerance=. With the GPU library (`import cadaclysm.view.wgpu`) the drawing replaces what one shared window shows and stays live — at the REPL, in IPython and in Jupyter by themselves, in a script until it exits; `cadaclysm.view.View` draws several items or several windows.

```python
solid.step(path, schema=None, unit='mm') -> None
```
Write this solid as a STEP file (AP203, or AP242 when coloured); see `write_step` for `schema` and `unit`.

```python
solid.step_text(schema=None, unit='mm') -> str
```
The same STEP file as text.

```python
solid.sat(path, unit='mm')
```
Write this solid as an ACIS SAT file; see `write_sat` for `unit`.

```python
solid.svg(path=None) -> str | None
```
This solid's wireframe as SVG, from a camera the keywords describe — `svg`'s own words, read by the library itself rather than a viewer. With `path`, writes the file and returns `None`; without, returns the SVG text. raises `BuildError` on a refused option or a failed write.

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
assembly.place(thing: 'Solid | Assembly', frame, name: 'str | None' = None) -> str
```
Place `thing` (a `Solid` or another `Assembly`) at `frame` in this assembly, called `name` — or, with `name` left out, `thing`'s own name (`Solid.name` for a solid, `"part"` for an unnamed one, or the placed assembly's own name), numbered past any already taken here (`"bolt"`, `"bolt 2"`, ...). `frame` must be right-handed and orthonormal, or the call raises `BuildError`. An explicit `name` already taken here raises `BuildError`. Placing an assembly that is this one, or anywhere above this one in the tree already, raises `BuildError` naming the cycle, since writing that out would never terminate. Returns the placement's name.

```python
assembly.link(name: str, placements) -> None
```
Declare a rigid link called `name` over `placements`: a list of names of placements of this assembly itself (not of assemblies placed in it — give those their own mechanism); in Python, Node and LuaJIT, a single name in place of the list is refused. A placed assembly in a link moves as one piece. An empty name, a name taken by another link here, no placements, a placement named twice, one this assembly does not have, or one already in another link raises `BuildError`, and the assembly is left as it was. Written as an AP242 kinematic link; a mechanism anywhere in the tree makes AP242 the default schema of `Assembly.step_text()`, and an explicit schema without the kinematic entities raises `BuildError`. A reader `Scene` reads it back as links and joints.

```python
assembly.joint(name: str, start: str, end: str) -> None
```
Connect this assembly's links `start` and `end`, kept in that order, as a joint called `name`. An empty name, a name taken by another joint here, a link this assembly does not have, a link joined to itself or a (start, end) pair already joined raises `BuildError`; the reverse pair is a different joint.

```python
assembly.pair(joint: str, kind: str, frame, end_frame=None, ranges=None, pitch=None) -> None
```
Give joint `joint` its pair: `kind` (one of `revolute`, `prismatic`, `cylindrical`, `screw`, `spherical`, `spherical_with_pin`, `planar`, `universal`, `homokinetic`, `fully_constrained` or `unconstrained`), the contact frame at rest, an optional `end_frame` (the frame the pair reaches at its rest values; `frame` itself, i.e. all-zero rest values, when left out), `ranges` (one entry per freedom of `kind`, each unbounded or a lower/upper pair; left out entirely for a kind that allows none), and `pitch` (required and non-zero for `screw`, refused for any other kind). An unknown or already-paired joint, an unknown kind, a bad pitch, ranges given where none are allowed or of the wrong length, a non-finite or inverted range, or an `end_frame` this kind's motion cannot reach (or reaches only outside a given range) raises `BuildError`, and the assembly is left as it was.

```python
assembly.state(name: str, values) -> None
```
Add a named state: the rows (Python: a mapping, or an iterable of (joint, values) pairs) set each named joint to its values, in that joint's pair's freedom order. An empty or duplicate name, no rows, an unknown joint, a joint set twice, a joint with no pair or none of its pair's freedoms, a row of the wrong length, or a non-finite or out-of-range value raises `BuildError`, and the assembly is left as it was.

```python
assembly.sequence(name: str, segments, seconds: bool = False) -> None
```
Add a named motion sequence over this assembly's states: `segments` are (state name, parameter, interpolation) rows, the interpolation one of `"undefined"`, `"discontinuous"`, `"synchronous"` or `"linear"`, and `seconds` writes the parameter's unit as the second. Closed or open is the last segment's interpolation: closed unless it is `"discontinuous"`. An empty or duplicate name, fewer than two segments, an unknown state, a non-finite or decreasing parameter, or an unknown interpolation raises `BuildError`, and the assembly is left as it was.

```python
assembly.base(link: str) -> None
```
Declare this assembly's base link. `link` naming no link of this assembly, or a base already declared, raises `BuildError` naming the link already there.

```python
assembly.step_text(schema=None, unit='mm') -> str
```
This assembly, and everything placed under it, as one STEP file: this assembly the root product, each sub-assembly and each distinct part (the same solid with the same paint and name) written once, each placement an occurrence named as it was placed. `schema` and `unit` as `write_step`. An assembly reachable from this one, this one included, that places nothing raises `BuildError` — a reader would never show it.

```python
assembly.step(path, schema=None, unit='mm') -> None
```
`Assembly.step_text()` written to a file.

```python
assembly.to_scene(schema=None) -> cadaclysm.Scene
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
box.moved(frame) -> Box
```
This box moved by `frame` (rigid), boxed again on the world axes — not this box's corners individually moved, which would not in general be a box at all: the *bounding* box of the moved corners. A `frame` not twelve finite numbers or not rigid raises `BuildError`.

```python
box.overlaps(other: 'Box') -> bool
```
Whether this box and `other` share a point (touching counts).

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
collider.check(frames, share=None) -> list[CollisionHit]
```
The pairs that interfere, or could not be decided, with each group placed at its matching frame in `frames` (one `Frame`, or twelve numbers, per group, in group order), as `CollisionHit` values. `share`: `None`, every pair past the box filters is decided now; `(k, n)`, only those whose index is `k` modulo `n` — the shares of one pose are disjoint and cover it, so a caller splits one pose's work across `n` workers and puts the answers back together. `frames` not the collider's own `Collider.group_count`, a frame that is not twelve finite numbers or not rigid, or a `share` with `k >= n`, raises `BuildError`.

```python
collider.close() -> None
```
Free this handle now. The garbage collector, or the language's scope, does it otherwise.

### Tool

```python
class Tool
```

A cutter: Grbl tool `number` (1 to 255, the `T` word), `diameter` and `flute_length` in mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed, ramping into its cuts at `ramp_angle` degrees. Immutable; a job keeps its own copy.

```python
Tool.flat(number, diameter, flute_length, feed, plunge, rpm, ramp_angle=3.0) -> Tool
```
A flat end mill. A `number` outside 1..255, a size, feed or speed not positive and finite, or a `ramp_angle` outside (0, 90], raises `BuildError`.

```python
Tool.ball(number, diameter, flute_length, feed, plunge, rpm, ramp_angle=3.0) -> Tool
```
A ball end mill, as `flat` but its tip a half sphere of the diameter; in 2.5D it cuts where a flat does, `bottom` being the tip.

```python
Tool.drill(number, diameter, flute_length, feed, rpm) -> Tool
```
A drill, plunging at `feed`. A job takes it for `Job.drill()` only.

### Stock

```python
class Stock
```

The block of material a job cuts, an axis-aligned box. Immutable; a job keeps its own copy.

```python
Stock.box(min, max) -> Stock
```
The box from `min` (x, y, z) to `max`. Unless every min is below its max and all six are finite, raises `BuildError`.

```python
Stock.around(solid: 'Solid', margin=0.0) -> Stock
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
Job(stock: Stock, safe_z, clearance=1.0, tolerance=0.01, name='job', spindle_dwell=2.0, resolution=0.1)  # the constructor
```

A machining job on a `Stock`: operations kept in the order they are added, written as one Grbl 1.1 program per run of operations sharing a tool. Mutable — each operation is added in place, and a refused one leaves the job as it was. `safe_z` is the absolute Z of rapids between operations and at a program's start and end, above the stock's top; an operation enters and leaves its passes `clearance` above its top; `tolerance` fits free-form sides and offsets; `name` names the programs (`<name>-T<n>`); every program waits `spindle_dwell` seconds after starting the spindle; `resolution` is the CAMotics project's voxel size in mm. A `safe_z` not above the stock, or a setting the job refuses, raises `BuildError`.

```python
job.face(tool: Tool, z, stepover, stepdown) -> None
```
Face the stock's top down to `z`, in zigzag rows along X `stepover` apart and passes at most `stepdown` deep. A drill, a `z` above the stock's top, a stepover past the tool's diameter, or what the job otherwise refuses, raises `BuildError`.

```python
job.contour(tool: Tool, profile: Profile, top, bottom, side='outside', stepdown=1.0, climb=True, open=False) -> None
```
Cut along `profile` from `top` to `bottom` in passes at most `stepdown` deep: `side` "outside" the profile, "inside" it, or "on" its line; `climb` for climb milling, else conventional; `open` to cut the outline as an open chain (only "on" its line, and with no holes). Any other `side` raises `ValueError`; what the job otherwise refuses, raises `BuildError`.

```python
job.pocket(tool: Tool, profile: Profile, top, bottom, stepover, stepdown) -> None
```
Clear `profile` — its holes left standing as islands — from `top` to `bottom`, in rings `stepover` apart (at most the tool's radius) and passes at most `stepdown` deep. What the job refuses raises `BuildError`; a pocket too small for the tool is refused by `Job.gcode()`, naming the operation.

```python
job.drill(tool: Tool, points, top, bottom, peck=None) -> None
```
Drill a hole at each (x, y) of `points` from `top` to `bottom`, pecking `peck` deep at a time (retracting between pecks), or straight to depth for none. A point that is not two numbers raises `ValueError`; a tool that is not a drill, no points, or what the job otherwise refuses, raises `BuildError`.

```python
job.gcode() -> list[Program]
```
The job as Grbl 1.1 programs, one per run of consecutive operations sharing a tool (T1, T2, T1 gives three), each named `<name>-T<n>` (or `<name>-<k>-T<n>` for run `k` of a tool that runs more than once); an empty list for a job with no operations. An operation whose geometry the tool cannot cut (named by its index and kind) raises `BuildError`.

```python
job.write_camotics(path) -> list[str]
```
A CAMotics project at `path` and its files beside it, named after the project's file stem (`out/part.camotics` writes `out/part-T1.nc`), not the job's name: each program, a simulation copy of it (`.sim.nc`, which the project lists), and the project last. Creates the directory. Returns the paths written, the project last. A path with no file stem, what `Job.gcode()` refuses, or a file that cannot be written, raises `BuildError`.

```python
job.machine(part: 'Solid', end_mill: Tool, drills=(), stepover=None, stepdown=None, skin=0.3, peck=None) -> Report
```
Recognise `part` — a solid inside the job's stock — by Z-level sectioning, and append the operations that make it: one face (if the stock top is above the part's top), the pockets level by level from the top down, then one drill per drill tool and bottom. `end_mill` must be a flat or ball tool, not a drill; `drills` are tried against each hole found, the closest match within 0.05 mm winning. `stepover` defaults to `0.4 x diameter`, `stepdown` to `min(diameter / 2, flute_length)` (`None` asks for the kernel's own default for either); `skin` (at least 0, default 0.3) is how far above the part's lowest point the outline stops, so the part stays attached to the stock — `0` cuts through; `peck` is passed to every drill operation (`None` for none). Returns a `Report` of what could not be cut — nothing that would gouge is ever emitted; a feature the tools can't make is machined as far as possible and reported instead. The job changes only on success: what the kernel otherwise refuses (a drill as `end_mill`, a `drills` entry that isn't a drill, a tool number clashing with one already in the job, `part` outside the stock, a `skin` negative or not less than the part's height, no level found, or a stepover or stepdown out of range) raises `BuildError` and leaves the job exactly as it was.

```python
job.operations() -> list[Operation]
```
Every operation added to this job so far, in order — whether by `Job.face()`, `Job.contour()`, `Job.pocket()`, `Job.drill()` or `Job.machine()` — as a list of `Operation`.

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

### BuildError

```python
class BuildError(Exception)
```

What the kernel refused, in its own words: a profile that crosses itself, a fillet too large for its faces, a boolean with nothing left. Raised by the call that failed, at once.
