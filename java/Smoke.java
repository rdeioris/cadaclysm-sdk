// Open one file through the Java binding and check what comes back, then build a part
// through the kernel binding, write it as STEP and read it back. The exit code is the
// verdict: the release pipeline runs this against every library it ships.
import java.io.IOException;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

// "try": a smoke builds things inside try-with-resources only to prove the call succeeds
// or is refused, and never touches them after; and it closes the read-back STEP scene by
// hand, early, to check a solid made from it (Solid.fromNode) outlives it. Both are the
// point of the check, so javac's lint on them is off here and nowhere else.
@SuppressWarnings("try")
public final class Smoke {
    public static void main(String[] args) {
        String path = args.length > 0 ? args[0] : "samples/cube.scad";
        try {
            run(path, args.length > 1 ? args[1] : null);
            kernel(args.length > 1 ? args[1] : null);
            silhouette(path);
        } catch (Cad.CadaclysmException | Blacksmith.BuildException e) {
            fail(e.getMessage());
        } catch (IOException e) {
            fail(e.toString());
        }
    }

    private static void run(String path, String license) throws IOException {
        if (license != null) Cad.license(license);
        System.out.println("cadaclysm " + Cad.version() + " built " + Cad.buildDate());
        System.out.println("license: " + Cad.licenseInfo());

        try (Cad.Scene scene = Cad.open(path)) {
            Cad.Bounds bounds = scene.bounds();
            System.out.printf("bounds min=(%s,%s,%s) max=(%s,%s,%s)%n",
                    bounds.min()[0], bounds.min()[1], bounds.min()[2],
                    bounds.max()[0], bounds.max()[1], bounds.max()[2]);

            int triangles = 0;
            for (Cad.Node node : scene.walk()) {
                if (!node.canMesh()) continue;
                Cad.Mesh mesh = node.mesh();
                if (mesh != null) triangles += mesh.triangleCount();
            }
            System.out.println("triangles=" + triangles);

            // All six bounds values, not just three: a bug that only flips one axis still
            // passes a partial check, so every component of both corners is compared.
            boolean cube = bounds.min()[0] == 0 && bounds.min()[1] == 0 && bounds.min()[2] == 0
                    && bounds.max()[0] == 20 && bounds.max()[1] == 20 && bounds.max()[2] == 20;
            if (path.endsWith("cube.scad") && (!cube || triangles != 12)) {
                fail("the cube did not come back as a 20-unit cube of 12 triangles");
            }

            // The reader's own extras: a query, the diagnostics, an in-memory open of the same
            // bytes, and a round trip through save_mesh. "class == solid" is the OpenSCAD
            // reader's own node.kind() for cube.scad, not "mesh".
            List<Cad.Node> matched = scene.query("class == solid");
            System.out.println("query: " + matched.size() + " node(s)");
            System.out.println("diagnostics: " + scene.diagnostics().size());

            boolean iges = Cad.formats().stream().anyMatch(f -> f.name().equals("IGES") && f.extensions().equals(List.of("iges", "igs")));
            if (!iges) fail("formats() lacks IGES iges;igs");
            if (Cad.meshFormats().stream().noneMatch(f -> f.name().equals("stl") && f.label().equals("STL (binary)"))) fail("mesh format label is not the library's");
            System.out.println("geometry diagnostics: " + scene.geometryDiagnostics().size());

            // Kinematics: a file with no mechanism carries no links or joints; mechanism.stp,
            // beside whatever sample this smoke was given, carries the fixed two-link
            // one-joint mechanism.
            if (path.endsWith("cube.scad") && (!scene.links().isEmpty() || !scene.joints().isEmpty() || !scene.states().isEmpty()))
                fail("the cube scene has links, joints or states");
            Path mechanismPath = Path.of(path).toAbsolutePath().getParent().resolve("mechanism.stp");
            try (Cad.Scene mechanism = Cad.open(mechanismPath.toString())) {
                List<Cad.Link> links = mechanism.links();
                if (links.size() != 2 || !links.get(0).name().equals("base") || !links.get(1).name().equals("arm"))
                    fail("mechanism links are not [base, arm]");
                for (Cad.Link link : links) {
                    List<Cad.Node> nodes = link.nodes();
                    if (nodes.size() != 1 || !nodes.get(0).name().equals(link.name()))
                        fail("link " + link.name() + " does not name exactly one node of its own name");
                }
                List<Cad.Joint> joints = mechanism.joints();
                if (joints.size() != 1 || !joints.get(0).name().equals("hinge"))
                    fail("mechanism does not carry exactly one joint named hinge");
                Cad.Joint joint = joints.get(0);
                Cad.Link start = joint.start(), end = joint.end();
                // The file's order, (arm, base): a swap into (parent, child) would fail here.
                if (!start.name().equals("arm") || start.index() != 1 || !end.name().equals("base") || end.index() != 0)
                    fail("joint hinge reads start=" + start.name() + "#" + start.index() + " end=" + end.name() + "#" + end.index());
                System.out.println("kinematics: links " + links.size() + ", joints " + joints.size()
                        + ", hinge " + start.name() + "->" + end.name());

                // The pair: revolute about Z, ranged -1.5..1.5, both contact frames at (0, 0, 100).
                Cad.Pair pair = joint.pair();
                if (pair == null || pair.kind() != Cad.PairKind.REVOLUTE) fail("hinge has no pair, or it is not revolute");
                if (pair.typeName() != null || pair.pitch() != null) fail("a revolute pair has a type name or a pitch");
                for (double[] frame : new double[][]{pair.rawFrameStart(), pair.rawFrameEnd()}) {
                    if (!close(frame[12], 0.0) || !close(frame[13], 0.0) || !close(frame[14], 100.0))
                        fail("a pair frame's origin is not (0, 0, 100)");
                    if (!close(frame[8], 0.0) || !close(frame[9], 0.0) || !close(frame[10], 1.0))
                        fail("a pair frame's z axis is not (0, 0, 1)");
                }
                List<Cad.Freedom> freedoms = pair.freedoms();
                if (freedoms.size() != 1 || freedoms.get(0).motion() != Cad.Motion.ROTATION || freedoms.get(0).axis() != Cad.FreedomAxis.Z)
                    fail("the hinge's freedom is not one rotation about z");
                Double lower = freedoms.get(0).lower(), upper = freedoms.get(0).upper();
                if (lower == null || upper == null || !close(lower, -1.5) || !close(upper, 1.5))
                    fail("the hinge's freedom range is not [-1.5, 1.5]");

                // The state: one named "open", one row (hinge, [0.5]).
                List<Cad.State> states = mechanism.states();
                if (states.size() != 1 || states.get(0).index() != 0 || !states.get(0).name().equals("open"))
                    fail("mechanism does not carry exactly one state named open");
                List<Cad.StateValue> values = states.get(0).values();
                if (values.size() != 1 || values.get(0).joint() == null || !values.get(0).joint().name().equals("hinge")
                        || values.get(0).joint().index() != 0
                        || values.get(0).values().length != 1 || !close(values.get(0).values()[0], 0.5))
                    fail("state open does not set hinge to [0.5]");
                System.out.println("pair: " + pair.kind() + ", freedoms " + freedoms.size() + ", states " + states.size());

                // Posing: Scene.base/pose/poseState and Pose, at parity with the Python reference's
                // six pose facts (mechanism.stp declares no base; base=links[0], arm=links[1]).
                Cad.Link baseLink = links.get(0), armLink = links.get(1);
                Cad.Node armNode = armLink.nodes().get(0), baseNode = baseLink.nodes().get(0);
                if (mechanism.base() != null) fail("mechanism.stp declares a base but declares none");
                Cad.Pose posedState = mechanism.poseState(states.get(0));
                if (posedState.ground().index() != baseLink.index()) fail("poseState's ground is not the base link");
                if (!posedState.unsolved().isEmpty() || !posedState.outOfRange().isEmpty())
                    fail("poseState reports unsolved or out-of-range joints");
                double q = 0.5; // the arm is the joint's start, reached from its end: it turns by -q
                double[][] armTransform = posedState.transform(armNode);
                double[] armTip = apply(armTransform, 10, 0, 0);
                if (!close(armTip[0], 10 * Math.cos(q)) || !close(armTip[1], -10 * Math.sin(q)) || !close(armTip[2], 100))
                    fail("poseState does not turn the arm by -0.5");
                double[] armOrigin = apply(armTransform, 0, 0, 0);
                if (!close(armOrigin[0], 0) || !close(armOrigin[1], 0) || !close(armOrigin[2], 100))
                    fail("poseState's arm origin is not (0, 0, 100)");
                if (!Arrays.equals(posedState.rawTransform(baseNode), baseNode.rawTransform()))
                    fail("poseState moves the ground link's own node");

                Cad.Pose pastRange = mechanism.pose(List.of(new Cad.StateValue(joint, new double[]{2.0})));
                List<Cad.OutOfRange> outOfRange = pastRange.outOfRange();
                if (outOfRange.size() != 1 || outOfRange.get(0).joint().index() != joint.index()
                        || outOfRange.get(0).freedom() != 0 || !close(outOfRange.get(0).value(), 2.0))
                    fail("pose does not report the out-of-range value");
                double[] pastRangeTip = apply(pastRange.transform(armNode), 10, 0, 0);
                if (!close(pastRangeTip[0], 10 * Math.cos(2.0)) || !close(pastRangeTip[1], -10 * Math.sin(2.0)) || !close(pastRangeTip[2], 100))
                    fail("pose does not use the out-of-range value");

                Cad.Pose groundedOnArm = mechanism.pose(List.of(new Cad.StateValue(joint, new double[]{0.5})), armLink);
                if (groundedOnArm.ground().index() != armLink.index()) fail("pose does not hold the named ground");
                if (!Arrays.equals(groundedOnArm.rawTransform(armNode), armNode.rawTransform()))
                    fail("pose does not leave the named ground at its rest transform");

                Cad.Pose fromStateValues = mechanism.pose(values);
                if (!Arrays.equals(fromStateValues.rawTransform(armNode), posedState.rawTransform(armNode)))
                    fail("pose(state.values()) does not match poseState(state)");
                Cad.Pose rest = mechanism.pose(List.of());
                for (Cad.Node node : mechanism.nodes())
                    if (!Arrays.equals(rest.rawTransform(node), node.rawTransform()))
                        fail("pose([]) does not leave every node at its rest transform");

                try {
                    mechanism.pose(List.of(new Cad.StateValue(joint, new double[]{1.0, 2.0})));
                    fail("a joint given the wrong number of values was accepted");
                } catch (Cad.CadaclysmException e) {
                    if (!e.getMessage().contains("takes 1 value(s)")) fail("wrong pose error: " + e.getMessage());
                }
                System.out.println("pose: base=" + mechanism.base() + ", ground=" + posedState.ground().name()
                        + ", out-of-range " + outOfRange.size());
            }
            // Motion sequences: samples/mechanism-sequence.stp's two sequences, at parity with
            // the Python reference (plan 2026-10-05-motion-sequences-2).
            Path sequencePath = Path.of(path).toAbsolutePath().getParent().resolve("mechanism-sequence.stp");
            try (Cad.Scene sequenceScene = Cad.open(sequencePath.toString())) {
                List<Cad.Sequence> sequences = sequenceScene.sequences();
                if (sequences.size() != 2 || !sequences.get(0).name().equals("swing") || !sequences.get(1).name().equals("snap"))
                    fail("sequences: the file does not carry swing then snap");
                Cad.Sequence swing = sequences.get(0), snap = sequences.get(1);
                if (!swing.closed() || swing.secondsPerUnit() == null || swing.secondsPerUnit().doubleValue() != 1.0)
                    fail("sequences: swing is not closed at 1 second per unit");
                if (snap.closed() || snap.secondsPerUnit() != null)
                    fail("sequences: snap is not open with no unit");
                String swingSegments = swing.segments().stream()
                        .map(g -> g.state().name() + "@" + g.t() + " " + g.interpolation())
                        .collect(java.util.stream.Collectors.joining(", "));
                if (!swingSegments.equals("shut@0.0 linear, open@1.0 synchronous, wide@2.0 linear"))
                    fail("sequences: swing's segments are " + swingSegments);
                String snapSegments = snap.segments().stream()
                        .map(g -> g.state().name() + "@" + g.t() + " " + g.interpolation())
                        .collect(java.util.stream.Collectors.joining(", "));
                if (!snapSegments.equals("shut@0.0 discontinuous, wide@0.5 discontinuous"))
                    fail("sequences: snap's segments are " + snapSegments);
                if (swing.start() != 0.0 || swing.end() != 2.0) fail("sequences: swing does not run 0 to 2");
                for (Cad.Segment g : swing.segments()) {
                    Cad.Pose at = swing.pose(g.t());
                    Cad.Pose want = sequenceScene.poseState(g.state());
                    for (Cad.Node node : sequenceScene.nodes())
                        if (!Arrays.equals(at.rawTransform(node), want.rawTransform(node)))
                            fail("sequences: swing at " + g.t() + " does not match state " + g.state().name());
                }
                try {
                    swing.pose(Double.NaN);
                    fail("sequences: pose(NaN) was accepted");
                } catch (Cad.CadaclysmException e) {
                    if (!e.getMessage().contains("the sequence parameter must be a finite number"))
                        fail("sequences: pose(NaN) was refused with " + e.getMessage());
                }
                System.out.println("sequences: swing and snap read as the file records them, and swing poses at each keyframe");
            }

            // IFC work schedules: samples/schedule.ifc's one schedule, at parity with the Python
            // reference (plan 2026-10-06-ifc-4d-2).
            Path schedulePath = Path.of(path).toAbsolutePath().getParent().resolve("schedule.ifc");
            try (Cad.Scene scheduleScene = Cad.open(schedulePath.toString())) {
                final double day = 86400.0, t0 = 1772438400.0;
                List<Cad.WorkSchedule> schedules = scheduleScene.schedules();
                if (schedules.size() != 1) fail("schedules: the file does not carry one schedule");
                Cad.WorkSchedule programme = schedules.get(0);
                if (!programme.name().equals("Programme") || !programme.identification().equals("WS-1")
                        || !programme.kind().equals("planned") || !programme.kindName().isEmpty()
                        || programme.start() == null || programme.start().doubleValue() != t0 || programme.finish() != null)
                    fail("schedules: the schedule's own fields are off");
                List<Cad.Task> tasks = programme.tasks();
                String taskNames = tasks.stream().map(Cad.Task::name).collect(java.util.stream.Collectors.joining(", "));
                if (!taskNames.equals("Slab, Structure, Walls north, Walls south, Topping out, Demolish shed, Fit-out"))
                    fail("schedules: the tasks are " + taskNames);
                Map<String, Cad.Task> byName = new java.util.HashMap<>();
                for (Cad.Task task : tasks) byName.put(task.name(), task);
                Cad.Task slab = byName.get("Slab");
                if (slab.parent() != null || byName.get("Walls north").parent() == null
                        || !byName.get("Walls north").parent().name().equals("Structure")
                        || !byName.get("Walls south").parent().name().equals("Structure"))
                    fail("schedules: the parents are off");
                if (!slab.kind().equals("construction") || !byName.get("Demolish shed").kind().equals("demolition")
                        || !byName.get("Topping out").kind().equals("notdefined")
                        || !byName.get("Topping out").milestone() || slab.milestone())
                    fail("schedules: the task kinds or milestones are off");
                Cad.TaskTime time = slab.time();
                if (!slab.identification().equals("T1") || !slab.status().equals("COMPLETED")
                        || time.scheduleStart() == null || time.scheduleStart().doubleValue() != t0
                        || time.scheduleFinish() != null
                        || time.duration() == null || time.duration().doubleValue() != 10 * day
                        || time.actualStart() == null || time.actualStart().doubleValue() != t0
                        || time.actualFinish() == null || time.actualFinish().doubleValue() != t0 + 8 * day)
                    fail("schedules: Slab's identification, status or times are off");
                Set<String> southNodes = new HashSet<>(), fitNodes = new HashSet<>();
                for (Cad.Node n : byName.get("Walls south").nodes()) southNodes.add(n.name());
                for (Cad.Node n : byName.get("Fit-out").nodes()) fitNodes.add(n.name());
                if (!southNodes.equals(Set.of("Wall S1", "Wall S2")) || !fitNodes.equals(Set.of("Desk", "Room")))
                    fail("schedules: the task nodes are " + southNodes + " and " + fitNodes);
                List<String> links = new java.util.ArrayList<>();
                for (Cad.TaskLink link : programme.links())
                    links.add(link.from().name() + ">" + link.to().name() + " " + link.kind() + " " + link.lag());
                if (!links.equals(List.of("Slab>Structure finish_start null",
                        "Walls north>Walls south start_start " + (2 * day),
                        "Walls south>Topping out finish_start null",
                        "Topping out>Fit-out finish_start null")))
                    fail("schedules: the links are " + links);
                Map<String, Cad.ElementState> states = new java.util.HashMap<>();
                for (Cad.ElementState s : programme.at(t0 + 3 * day)) states.put(s.node().name(), s);
                if (!states.keySet().equals(Set.of("Slab", "Wall N1", "Wall N2", "Wall S1", "Wall S2", "Shed", "Room", "Desk")))
                    fail("schedules: at(T0+3D) names " + states.keySet());
                if (!states.get("Slab").phase().equals("building") || Math.abs(states.get("Slab").progress() - 0.3) > 1e-9
                        || !states.get("Shed").phase().equals("demolishing") || !states.get("Wall S1").phase().equals("unbuilt"))
                    fail("schedules: at(T0+3D) phases are off");
                Map<String, Cad.ElementState> actual = new java.util.HashMap<>();
                for (Cad.ElementState s : programme.at(t0 + 32 * day, "actual")) actual.put(s.node().name(), s);
                if (!actual.get("Wall S1").phase().equals("building") || actual.get("Wall S1").variance() == null
                        || actual.get("Wall S1").variance().doubleValue() != 5 * day
                        || actual.get("Slab").variance() == null || actual.get("Slab").variance().doubleValue() != -2 * day)
                    fail("schedules: at(T0+32D, actual) variances are off");
                try {
                    programme.at(Double.NaN);
                    fail("schedules: at(NaN) was accepted");
                } catch (Cad.CadaclysmException e) {
                    if (!e.getMessage().contains("the date must be a finite number"))
                        fail("schedules: at(NaN) was refused with " + e.getMessage());
                }
                try {
                    programme.at(t0, "compare");
                    fail("schedules: at(T0, compare) was accepted");
                } catch (Cad.CadaclysmException e) {
                    if (!e.getMessage().equals("dates must be 'scheduled' or 'actual'"))
                        fail("schedules: at(T0, compare) was refused with " + e.getMessage());
                }
                System.out.println("schedules: Programme reads as the file records it, and at() plays both date sets");
            }
            try (Cad.Scene noSchedule = Cad.open(Path.of(path).toAbsolutePath().getParent().resolve("cube.scad").toString())) {
                if (!noSchedule.schedules().isEmpty()) fail("schedules: the cube has schedules");
            }

            // pose([]) on the cube sample (no mechanism) fails with a message naming that, as
            // the Python reference's test_a_bad_pose_raises checks on the same file.
            Path cubePath = Path.of(path).toAbsolutePath().getParent().resolve("cube.scad");
            try (Cad.Scene cubeScene = Cad.open(cubePath.toString())) {
                try {
                    cubeScene.pose(List.of());
                    fail("pose([]) on a file without a mechanism was accepted");
                } catch (Cad.CadaclysmException e) {
                    if (!e.getMessage().contains("no mechanism")) fail("wrong no-mechanism error: " + e.getMessage());
                }
            }
            scene.forgetMeshes();
            long rebuiltTriangles = 0;
            for (Cad.Node n : scene.walk()) { Cad.Mesh m = n.canMesh() ? n.mesh() : null; if (m != null) rebuiltTriangles += m.triangleCount(); }
            if (rebuiltTriangles != triangles) fail("forgetMeshes did not rebuild");

            if (Cad.lodLevels() != 3) fail("lodLevels is not 3");
            Cad.Node first = null;
            for (Cad.Node n : scene.walk()) if (n.canMesh()) { first = n; break; }
            if (first.meshLod(0).triangleCount() != first.mesh().triangleCount()) fail("LOD 0 is not the mesh");
            if (first.lodError(0) != 0f || first.meshLod(4) != null) fail("LOD errors or levels are off");
            if (path.endsWith("cube.scad") && (first.meshLod(1).triangleCount() != 3 || first.edgeBeziers().count() != 12 || first.edgeBeziers().points().remaining() != 12 * 12)) fail("the cube's LOD 1 or Béziers are off");

            // f64 twins: mesh64, beziers64 and bounds64 mirror their f32 twins, narrowed
            // exactly, on this small-coordinate cube -- see the far-from-origin note in the
            // task report for what this comparison cannot see.
            Cad.Mesh mesh32 = first.mesh();
            Cad.Mesh64 mesh64 = first.mesh64();
            if (mesh64 == null || mesh64.vertexCount() != mesh32.vertexCount() || mesh64.indexCount() != mesh32.indexCount())
                fail("mesh64's vertex/index counts do not equal mesh's");
            double[] positions64 = mesh64.copy().positions();
            float[] positions32 = mesh32.copy().positions();
            if (positions32.length >= 3 &&
                    ((float) positions64[0] != positions32[0] || (float) positions64[1] != positions32[1] || (float) positions64[2] != positions32[2]))
                fail("mesh64's first position narrowed to float does not equal mesh's first position");
            Cad.Beziers edgeBeziers32 = first.edgeBeziers();
            Cad.Beziers64 edgeBeziers64 = first.edgeBeziers64();
            if (edgeBeziers64.count() != edgeBeziers32.count() || edgeBeziers64.points().remaining() != edgeBeziers32.points().remaining())
                fail("edgeBeziers64's count/length does not equal edgeBeziers's");
            if (edgeBeziers32.points().remaining() >= 3 && (float) edgeBeziers64.copy().points()[0] != edgeBeziers32.copy().points()[0])
                fail("edgeBeziers64's first point narrowed does not equal edgeBeziers's");
            if (first.curveBeziers64().count() != first.curveBeziers().count()) fail("curveBeziers64's count does not equal curveBeziers's");
            if (first.isocurveBeziers64().count() != first.isocurveBeziers().count()) fail("isocurveBeziers64's count does not equal isocurveBeziers's");
            Cad.Bounds64 nodeBounds64 = first.bounds64();
            Cad.Bounds nodeBounds32 = first.bounds();
            if ((float) nodeBounds64.max()[0] != nodeBounds32.max()[0] || (float) nodeBounds64.max()[1] != nodeBounds32.max()[1] || (float) nodeBounds64.max()[2] != nodeBounds32.max()[2])
                fail("bounds64's max does not equal bounds's max widened");
            Cad.Bounds64 sceneBounds64 = scene.bounds64();
            if ((float) sceneBounds64.max()[0] != bounds.max()[0] || (float) sceneBounds64.max()[1] != bounds.max()[1] || (float) sceneBounds64.max()[2] != bounds.max()[2])
                fail("scene bounds64's max does not equal bounds's max widened");
            System.out.printf("reader f64 twins: mesh64 %d triangles, edgeBeziers64 %d, bounds64 max (%s,%s,%s)%n",
                    mesh64.triangleCount(), edgeBeziers64.count(), sceneBounds64.max()[0], sceneBounds64.max()[1], sceneBounds64.max()[2]);

            // forgetMeshes frees the document's own mesh, which Mesh64 lends, so a Mesh64 made
            // before the forget throws a stale view rather than being read. The float mesh and
            // the edge views are the scene's own caches and survive it, as the C ABI says they
            // do -- they must not be reported stale, nor must the node.
            {
                Cad.Mesh64 lent = first.mesh64();
                Cad.Mesh keptMesh = first.mesh();
                Cad.Polylines keptEdges = first.edges();
                int lentTriangles = lent.triangleCount();
                double[] early = lent.copy().positions();
                scene.forgetMeshes();
                boolean tripped = false;
                try {
                    lent.positions();
                } catch (Cad.CadaclysmException e) {
                    tripped = e.getMessage().contains("forgotten");
                }
                if (!tripped) fail("a Mesh64 read after forgetMeshes did not throw a stale view");
                tripped = false;
                try {
                    lent.copy();
                } catch (Cad.CadaclysmException e) {
                    tripped = e.getMessage().contains("forgotten");
                }
                if (!tripped) fail("a Mesh64 copied after forgetMeshes did not throw a stale view");
                if (keptMesh.positions().remaining() != keptMesh.vertexCount() * 3 || keptEdges.positions().remaining() == 0 || !first.canMesh())
                    fail("forgetMeshes staled the float mesh, an edge view or the node");
                Cad.Mesh64 relent = first.mesh64();
                if (relent.triangleCount() != lentTriangles || !java.util.Arrays.equals(relent.copy().positions(), early))
                    fail("a Mesh64 asked for after forgetMeshes does not read");
            }

            Cad.Collision fit = first.collision(0);
            if (fit == null || fit.error() != 0 || fit.frame().length != 16 || fit.hullVertexCount() != 8) fail("the collision fit is off");
            if (first.collisionHull(0).vertexCount() != 8 || first.collisionHull(0).indices().remaining() != 36) fail("the collision hull is off");

            Cad.Mesh full = first.mesh();
            try (Cad.Meshlets meshlets = Cad.Meshlets.build(full.copy().positions(), full.copy().normals(), full.copy().indices(), 124, 64, 0)) {
                if (meshlets.count() < 1) fail("no meshlets");
                Cad.Meshlet one = meshlets.meshlet(0);
                if (one.positions().length != one.vertexCount() * 3 || one.indices().length != one.triangleCount() * 3 || one.level() != 0) fail("meshlet 0 is off");
                if (path.endsWith("cube.scad") && (meshlets.count() != 1 || one.triangleCount() != 12 || one.vertexCount() != 36)) fail("the cube's meshlets are off");
            }
            try { Cad.Meshlets.build(full.copy().positions(), null, full.copy().indices(), 0, 64, 0); fail("a zero budget was accepted"); }
            catch (Cad.CadaclysmException expected) { }

            long est = first.triangleEstimate();
            if (est <= 0 && est != -1) fail("triangle estimate is neither a count nor -1");
            if (path.endsWith("cube.scad")) {
                if (est != 12 || first.surfaceEdges().polylineCount() != 0 || first.surfaceProxyMesh(4) != null) fail("the cube has no surface products");
                if (first.surfacePick(new double[] {10, 10, 100}, new double[] {10, 10, -100}) != null || !first.boundsPlaced(null).isEmpty()) fail("the cube picks or bounds through surfaces");
                if (!first.boundsPlaced64(null).isEmpty()) fail("the cube's boundsPlaced64 is not empty");
                if (first.surfaceEdgeBeziers().count() != 0) fail("the cube hands exact edges to the surface path");
                if (first.edgeColours().length != 0 || first.surfaceEdgeColours().length != 0) fail("the unpainted cube has edge colours");
            }
            // Edge colours: samples/edge-colours.stp sits beside the given sample and paints
            // one edge teal (0.1, 0.6, 0.55) on the body -- everything else, edge and
            // surface-edge alike, stays unstyled.
            try (Cad.Scene edgeColoursScene = Cad.open(Path.of(path).resolveSibling("edge-colours.stp").toString())) {
                Cad.Node body = null;
                for (Cad.Node n : edgeColoursScene.walk()) if (n.edges().polylineCount() > 0) { body = n; break; }
                if (body == null) fail("edge colours: edge-colours.stp has no node with edges");
                int[] counts = { body.edges().polylineCount(), body.surfaceEdges().polylineCount() };
                float[][][] colours = { body.edgeColours(), body.surfaceEdgeColours() };
                for (int i = 0; i < 2; i++) {
                    if (colours[i].length != counts[i]) fail("edge colours: " + colours[i].length + " entries for " + counts[i] + " polylines");
                    int styledCount = 0, nullCount = 0;
                    float[] styled = null;
                    for (float[] c : colours[i]) {
                        if (c == null) nullCount++;
                        else { styledCount++; styled = c; }
                    }
                    if (styledCount != 1 || nullCount != colours[i].length - 1) fail("edge colours: " + styledCount + " styled entries, not exactly one");
                    if (Math.abs(styled[0] - 0.1f) > 1e-6 || Math.abs(styled[1] - 0.6f) > 1e-6
                            || Math.abs(styled[2] - 0.55f) > 1e-6 || Math.abs(styled[3] - 1.0f) > 1e-6)
                        fail("edge colours: the styled entry reads (" + styled[0] + "," + styled[1] + "," + styled[2] + "," + styled[3] + "), not (0.1,0.6,0.55,1.0)");
                }
                // The STEP body has surfaces to hand over, so this reads them through SURFACES,
                // the layout cadaclysm_node_surfaces returns by value. A short one is written
                // past silently -- the layout itself is pinned by tests/bindings.rs, not here.
                int faces = body.surfaces().size();
                if (faces == 0) fail("surfaces: the STEP body came back with no faces");
                System.out.println("surfaces: " + faces + " face(s)");
            }
            try (Cad.Scene fresh = Cad.open(path)) {
                Cad.Node body = null;
                for (Cad.Node n : fresh.walk()) if (n.canMesh()) { body = n; break; }
                if (body.isMeshed()) fail("a fresh scene is already meshed");
                if (fresh.realizeMeshes(false) == 0 || !body.isMeshed()) fail("realizeMeshes(false) did not build");
            }
            // A Rhino extrusion hands its exact edges to the surface path without meshing, in
            // both conventions: UNREAL goes through the decorator that maps every getter into
            // the caller's space. The fixture is the repository's, not an SDK checkout's, so
            // this runs where found.
            Path sampleRoot = Path.of(path).toAbsolutePath().getParent().getParent();
            Path extrusions = sampleRoot == null ? null : sampleRoot.resolve("crates/cadaclysm-acis/tests/fixtures/rhino/extrusion-objects.3dm");
            if (extrusions != null && Files.exists(extrusions)) {
                for (Cad.Convention convention : new Cad.Convention[] {Cad.Convention.NATIVE, Cad.Convention.UNREAL}) {
                    Cad.OpenOptions options = new Cad.OpenOptions(convention, false, false, null, false, 0.0);
                    try (Cad.Scene surfaced = Cad.open(extrusions.toString(), options)) {
                        int found = 0;
                        for (Cad.Node n : surfaced.walk()) {
                            if (!n.canMesh() || n.surfaceEdges().polylineCount() == 0) continue;
                            int exact = n.surfaceEdgeBeziers().count();
                            if (exact == 0 || n.isMeshed()) fail("an extrusion's exact edges are not free");
                            if (exact != n.edgeBeziers().count()) fail("surfaceEdgeBeziers is not edgeBeziers' segments");
                            found++;
                        }
                        if (found == 0) fail("extrusion-objects.3dm has no surfaced extrusion");
                        System.out.printf("surfaceEdgeBeziers (%s): %d extrusions, exact and unmeshed%n", convention, found);
                    }
                }
            }

            byte[] bytes = Files.readAllBytes(Path.of(path));
            Cad.Mesh borrowed;
            try (Cad.Scene again = Cad.openMemory(bytes, Path.of(path).getFileName().toString())) {
                if (again.bounds().max()[2] != bounds.max()[2]) fail("open_memory disagrees with open");
                borrowed = again.query("class == solid").get(0).mesh();
            }
            // A view borrowed from a scene since closed refuses to read, as the kernel's stale
            // views do, rather than handing out a buffer over freed memory.
            try {
                borrowed.positions();
                fail("a mesh view read a closed scene");
            } catch (Cad.CadaclysmException expected) {
                // the scene's own "closed" exception
            }
            // The format given on its own, as Python's open_memory takes it -- the name has no
            // extension to fall back on here, so the argument is what opens it.
            try (Cad.Scene typed = Cad.openMemory(bytes, "cube-bytes", "scad")) {
                if (!Arrays.equals(typed.bounds().max(), bounds.max())) fail("open_memory with an explicit format disagrees with open");
            }

            Path stl = Files.createTempFile("cadaclysm-smoke", ".stl");
            scene.roots().get(0).saveMesh(stl.toString(), "stl");
            if (Files.size(stl) < 84) fail("save_mesh wrote no triangles");

            femReader(first, path);

            // SVG: the library's own camera, no viewer. fov = 200 is a refusal it words the
            // same way as the kernel's.
            String svgText = scene.svgText();
            if (!svgText.startsWith("<svg") || !svgText.contains("<path")) fail("scene SVG text did not look like an SVG wireframe");
            Path svgPath = Files.createTempFile("cadaclysm-smoke", ".svg");
            scene.svg(svgPath.toString());
            if (Files.size(svgPath) == 0) fail("Scene.svg wrote an empty file");
            String nodeSvgText = first.svgText();
            if (!nodeSvgText.startsWith("<svg") || !nodeSvgText.contains("<path")) fail("node SVG text did not look like an SVG wireframe");
            try {
                scene.svgText(new Cad.SvgOptions(null, null, null, null, 200.0, 1000.0, 1000.0, 0.05, 0.1,
                        "#000000", 1.0, null, true, false, false, false, true));
                fail("scene svg: fov=200 was accepted");
            } catch (Cad.CadaclysmException expected) {
                // the library's own refusal
            }
            System.out.println("svg: scene and node text, file written, fov=200 refused");

            // CSS colour names: Cad.packed(String) turns one into the ABI's packed 0xRRGGBB
            // (SvgOptions.background's own type), and SvgOptions.stroke reads names too.
            if (Cad.packed("navy") != 0x000080) fail("Cad.packed(\"navy\") is not 0x000080");
            try {
                Cad.packed("bogus");
                fail("Cad.packed(\"bogus\") was accepted");
            } catch (Cad.CadaclysmException expected) {
                String msg = expected.getMessage();
                if (!msg.contains("not 'bogus'") || msg.contains("0..1")) fail("Cad.packed(\"bogus\"): " + msg);
            }
            String redStrokeSvg = scene.svgText(new Cad.SvgOptions(null, null, null, null, 0.0, 1000.0, 1000.0, 0.05, 0.1,
                    "Red", 1.0, null, true, false, false, false, true));
            if (!redStrokeSvg.contains("#ff0000")) fail("SvgOptions.stroke(\"Red\") did not draw #ff0000: " + redStrokeSvg);
            // background takes colour text, and stroke a packed number, through the withers.
            String textBackgroundSvg = scene.svgText(Cad.SvgOptions.defaults().withBackground("Navy").withStroke(0x00FF00));
            if (!textBackgroundSvg.contains("#000080")) fail("withBackground(\"Navy\") did not draw #000080: " + textBackgroundSvg);
            if (!textBackgroundSvg.contains("#00ff00")) fail("withStroke(0x00FF00) did not draw #00ff00: " + textBackgroundSvg);
            try {
                Cad.SvgOptions.defaults().withBackground("bogus");
                fail("withBackground(\"bogus\") was accepted");
            } catch (Cad.CadaclysmException e) {
                if (!e.getMessage().startsWith("svg: background:")) fail("withBackground(\"bogus\"): " + e.getMessage());
            }
            System.out.println("colour: Cad.packed(\"navy\")=0x000080, packed(\"bogus\") refused, stroke(\"Red\") drew #ff0000, withBackground(\"Navy\") drew #000080");
        }
    }

    // The kernel: the plate with a hole and a pin, filleted, as STEP -- then read back.
    // Every profile and solid is closed by its try-with-resources; the unfilleted `part`
    // outlives `rounded` because `edges()` and `faceKind()` were read off it.
    private static void kernel(String license) throws IOException {
        if (license != null) Blacksmith.license(license);
        System.out.println("blacksmith " + Blacksmith.version() + " built " + Blacksmith.buildDate());
        System.out.println("license: " + Blacksmith.licenseInfo());

        try (Blacksmith.Profile hole = Blacksmith.Profile.circle(4);
             Blacksmith.Profile rect = Blacksmith.Profile.rect(80, 40);
             Blacksmith.Profile outline = rect.withHole(hole);
             Blacksmith.Solid plate = Blacksmith.Workplane.xy().extrude(outline, 6).solid();
             Blacksmith.Solid pin = Blacksmith.Workplane.fromSolid(plate)
                     .faces(Blacksmith.Selector.max(Blacksmith.Axis.Z)).onFace()
                     .cylinder(5, 10).solid();
             Blacksmith.Solid part = plate.join(pin)) {
            List<Blacksmith.Edge> corners = part.edges().stream()
                    .filter(e -> e.isLine() && Math.abs(e.direction()[2]) > 0.99)
                    .filter(e -> Arrays.stream(e.faces()).allMatch(f -> part.faceKind(f).equals("plane")))
                    .toList();
            // `released` and `scene` outlive the block below: the block's own close of
            // `rounded` is what the checks after it are about.
            Blacksmith.Solid released;
            Cad.Scene scene;
            sheetVerbs(plate);
            frames();
            hits();
            machining();
            edgeCurves();
            intersections();
            collider();
            subd();
            solidHits();
            assemblies();
            mechanism();
            try (Blacksmith.Solid rounded = part.fillet(corners, 1.0)) {
                released = rounded;
                int faces = rounded.faces();
                boolean watertight = rounded.isWatertight();
                System.out.println("faces=" + faces + " watertight=" + watertight);
                if (!watertight) fail("the filleted part is not watertight");
                Cad.Manifold shape = rounded.manifold();
                System.out.println("manifold: " + shape);
                if (!shape.isClosed() || shape.faces() != faces) fail("the filleted part is not a closed manifold: " + shape);
                // A plate has 6 faces, the hole adds 1 cylinder, the pin 2 (its wall and its
                // top), and each of the four corners rounded trades one edge for one face.
                if (faces != 15) fail("the filleted part has " + faces + " faces, not 15");

                // Colour: a gold plate joined with a blue pin -- the part is gold, the pin's
                // top keeps its blue.
                try (Blacksmith.Solid gold = plate.coloured(0.8, 0.6, 0.4);
                     Blacksmith.Solid blue = pin.coloured(0.2, 0.4, 1.0);
                     Blacksmith.Solid coloured = gold.join(blue)) {
                    double[] top = coloured.faceColour(coloured.selectFace(Blacksmith.Selector.max(Blacksmith.Axis.Z)));
                    System.out.println("colour=" + Arrays.toString(coloured.colour()) + " pin top=" + Arrays.toString(top));
                    if (!Arrays.equals(coloured.colour(), new double[] {0.8, 0.6, 0.4})
                            || !Arrays.equals(top, new double[] {0.2, 0.4, 1.0}) || plate.colour() != null)
                        fail("the colours did not carry through the join");
                }

                // Edge and profile colour: all of a plate's edges gold, then edge 0 blue over it;
                // a profile carries its own colour too.
                try (Blacksmith.Solid goldEdges = plate.edgesColoured(0.8, 0.6, 0.4);
                     Blacksmith.Solid blueEdge = goldEdges.edgesColoured(new int[] { 0 }, 0.2, 0.4, 1.0);
                     Blacksmith.Profile goldRect = Blacksmith.Profile.rect(10, 4).coloured(0.8, 0.6, 0.4)) {
                    double[][] edgeColours = blueEdge.edgePolylineColours();
                    System.out.println("edge 0=" + Arrays.toString(blueEdge.edgeColour(0)) + " edge 1=" + Arrays.toString(blueEdge.edgeColour(1))
                            + " polylines=" + edgeColours.length + " rect=" + Arrays.toString(goldRect.colour()));
                    if (!Arrays.equals(blueEdge.edgeColour(0), new double[] { 0.2, 0.4, 1.0 }) || !Arrays.equals(blueEdge.edgeColour(1), new double[] { 0.8, 0.6, 0.4 })
                            || edgeColours.length == 0 || !Arrays.equals(goldRect.colour(), new double[] { 0.8, 0.6, 0.4 }) || plate.edgeColour(0) != null)
                        fail("edge or profile colours");
                    // An empty edges list colours no edge -- not "every edge" (which null would
                    // mean, and Java has no overload for) -- so edge 0 stays blue and edge 1 gold.
                    try (Blacksmith.Solid untouched = blueEdge.edgesColoured(new int[0], 0.1, 0.1, 0.1)) {
                        if (!Arrays.equals(untouched.edgeColour(0), new double[] { 0.2, 0.4, 1.0 })
                                || !Arrays.equals(untouched.edgeColour(1), new double[] { 0.8, 0.6, 0.4 }))
                            fail("an empty edge list should colour nothing");
                    }
                }

                // CSS colour names: every paint entry point's String overload reads them through
                // the library's own parser, and Blacksmith.packed(String) turns one into the
                // ABI's packed 0xRRGGBB (SvgOptions.background's own type).
                try (Blacksmith.Solid red = Blacksmith.Solid.cuboid(1, 1, 1).coloured("red")) {
                    if (!Arrays.equals(red.colour(), new double[] {1, 0, 0})) fail("coloured(\"red\") did not read as (1, 0, 0)");
                }
                try (Blacksmith.Solid bogus = Blacksmith.Solid.cuboid(1, 1, 1).coloured("notacolour")) {
                    fail("coloured(\"notacolour\") was accepted");
                } catch (Blacksmith.BuildException expected) {
                    if (!expected.getMessage().contains("a CSS colour name")) fail("coloured(\"notacolour\"): " + expected.getMessage());
                }
                if (Blacksmith.packed("navy") != 0x000080) fail("Blacksmith.packed(\"navy\") is not 0x000080");
                try {
                    Blacksmith.packed("bogus");
                    fail("Blacksmith.packed(\"bogus\") was accepted");
                } catch (Blacksmith.BuildException expected) {
                    String msg = expected.getMessage();
                    if (!msg.contains("not 'bogus'") || msg.contains("0..1")) fail("Blacksmith.packed(\"bogus\"): " + msg);
                }
                try (Blacksmith.Solid redEdges = Blacksmith.Solid.cuboid(1, 1, 1).edgesColoured("red")) {
                    if (!Arrays.equals(redEdges.edgeColour(0), new double[] {1, 0, 0})) fail("edgesColoured(\"red\") did not read as (1, 0, 0)");
                }
                try (Blacksmith.Profile redRect = Blacksmith.Profile.rect(10, 4).coloured("red")) {
                    if (!Arrays.equals(redRect.colour(), new double[] {1, 0, 0})) fail("Profile.coloured(\"red\") did not read as (1, 0, 0)");
                }
                String redStrokeSvg = Blacksmith.Solid.cuboid(1, 1, 1).svgText(new Blacksmith.SvgOptions(null, null, null, null,
                        0.0, 1000.0, 1000.0, 0.05, 0.1, "red", 1.0, null, true, false, false, false, true));
                if (!redStrokeSvg.contains("#ff0000")) fail("SvgOptions.stroke(\"red\") did not draw #ff0000: " + redStrokeSvg);
                String textBackgroundSvg = Blacksmith.Solid.cuboid(1, 1, 1).svgText(
                        Blacksmith.SvgOptions.defaults().withBackground("Navy").withStroke(0x00FF00));
                if (!textBackgroundSvg.contains("#000080")) fail("blacksmith withBackground(\"Navy\") did not draw #000080: " + textBackgroundSvg);
                if (!textBackgroundSvg.contains("#00ff00")) fail("blacksmith withStroke(0x00FF00) did not draw #00ff00: " + textBackgroundSvg);
                try {
                    Blacksmith.SvgOptions.defaults().withBackground("bogus");
                    fail("blacksmith withBackground(\"bogus\") was accepted");
                } catch (Blacksmith.BuildException e) {
                    if (!e.getMessage().startsWith("svg: background:")) fail("blacksmith withBackground(\"bogus\"): " + e.getMessage());
                }
                System.out.println("blacksmith colour:CSS colour names accepted on coloured/edgesColoured/stroke, bad names refused, packed(\"navy\")=0x000080");

                // A face: the outline as a sheet, which pushed out is the plate again.
                try (Blacksmith.Solid sheet = Blacksmith.Solid.face(outline, new double[] {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1});
                     Blacksmith.Solid pushed = sheet.extrudeFaces(6)) {
                    System.out.println("face: " + sheet.faces() + " face, pushed out " + pushed.faces() + " faces");
                    if (sheet.faces() != 1 || pushed.faces() != plate.faces() || !pushed.isWatertight())
                        fail("the outline's face did not push out to the plate");
                }

                // The plate is 80 x 40 x 6 centred on the origin and the pin adds 10, so the
                // far corner sits at (40, 20, 16) -- checked on the kernel's own bounds, on
                // the STEP read back through the reader, and on toScene's scene.
                Blacksmith.Bounds own = rounded.bounds();
                if (!near(own.max(), 40, 20, 16)) fail("the kernel's own bounds are off: " + Arrays.toString(own.max()));

                // No schema at all: the kernel writes against its built-in AP203, no
                // ap203.exp needed.
                String noSchemaText = rounded.stepText();
                if (!noSchemaText.startsWith("ISO-10303-21;")) fail("stepText() with no schema did not write valid STEP");
                System.out.println("stepText() with no schema: ISO-10303-21; ok");

                // A single-line custom EXPRESS schema is text, not a path, even though it
                // holds ':' and ';' -- characters java.nio.file.Path.of() refuses on
                // Windows (InvalidPathException). schemaText must treat that as "not a
                // file" and pass the string through, so the failure below is the ABI's own
                // parse error, not a Java path exception.
                try {
                    rounded.stepText("SCHEMA x; ENTITY a; s : STRING := 'x'; END_ENTITY; END_SCHEMA;", "mm");
                    fail("a bogus single-line custom schema should have failed to parse");
                } catch (Blacksmith.BuildException e) {
                    if (e.getMessage() == null || !e.getMessage().contains("step: schema:"))
                        fail("expected the ABI's step: schema: parse error, got: " + e.getMessage());
                    System.out.println("single-line custom schema text reached the ABI: " + e.getMessage());
                }

                Path step = Files.createTempFile("cadaclysm-smoke", ".stp");
                rounded.step(step.toString());
                try (Cad.Scene back = Cad.open(step.toString())) {
                    float[] max = back.bounds().max();
                    System.out.printf("step read back: bounds max=(%s,%s,%s)%n", max[0], max[1], max[2]);
                    if (!near(max, 40, 20, 16)) fail("the STEP did not read back as the plate with its pin");
                    // And back into the kernel: the read body's brep, shared with the scene
                    // rather than copied, as a solid that outlives the scene it came from.
                    Cad.Node body = null;
                    for (Cad.Placement p : back.placements()) {
                        try (Cad.Brep brep = p.geometry().brep()) {
                            if (brep != null) {
                                Cad.Manifold read = brep.manifold();
                                if (!read.isClosed() || read.faces() != 15) fail("the read body is not the closed manifold written: " + read);
                                Cad.Sewn sewn = brep.sewed(null, null);
                                try (Cad.Brep sewnBrep = sewn.brep()) {
                                    if (sewn.report().freeBefore() != read.boundaryEdges() || brep.manifold().boundaryEdges() != read.boundaryEdges())
                                        fail("sewed reports " + sewn.report().freeBefore() + " free edges before, the brep has " + read.boundaryEdges());
                                }
                                body = p.geometry();
                                break;
                            }
                        }
                    }
                    if (body == null) fail("no placement of the read-back STEP has a brep");
                    try (Blacksmith.Solid imported = Blacksmith.Solid.fromNode(back, body)) {
                        back.close();
                        if (imported.faces() != faces) fail("fromNode gave " + imported.faces() + " faces, not " + faces);
                        try (Blacksmith.Solid opened = Blacksmith.Solid.open(step.toString())) {
                            if (opened.faces() != faces) fail("Solid.open gave " + opened.faces() + " faces, not " + faces);
                        }
                        System.out.println("fromNode: " + imported.faces() + " faces after the scene closed; Solid.open: the same");
                    }
                }

                femKernel(rounded, faces);
                femBrep(step, faces);

                // The same solid as SAT, written by the library itself, read back the same way.
                Path sat = Files.createTempFile("cadaclysm-smoke", ".sat");
                rounded.sat(sat.toString());
                if (!rounded.satText().startsWith("400 0 1 0")) fail("the SAT text does not open with the record version");
                try (Cad.Scene back = Cad.open(sat.toString())) {
                    float[] max = back.bounds().max();
                    System.out.printf("sat read back: bounds max=(%s,%s,%s)%n", max[0], max[1], max[2]);
                    if (!near(max, 40, 20, 16)) fail("the SAT did not read back as the plate with its pin");
                }

                // The OCCT .brep writer, and its reader.
                Path brep = Files.createTempFile("cadaclysm-smoke", ".brep");
                rounded.brep(brep.toString());
                if (!rounded.brepText().startsWith("DBRep_DrawableShape")) fail("the .brep text does not begin as one");
                try (Cad.Scene back = Cad.open(brep.toString())) {
                    float[] max = back.bounds().max();
                    System.out.printf("brep read back: bounds max=(%s,%s,%s)%n", max[0], max[1], max[2]);
                    if (!near(max, 40, 20, 16)) fail("the .brep did not read back as the plate with its pin");
                }

                // SVG: the kernel's own camera, no viewer -- fov = 200 is a refusal it words
                // the same way as the reader's.
                String solidSvgText = rounded.svgText();
                if (!solidSvgText.startsWith("<svg") || !solidSvgText.contains("<path")) fail("solid SVG text did not look like an SVG wireframe");
                Path solidSvgPath = Files.createTempFile("cadaclysm-smoke-solid", ".svg");
                rounded.svg(solidSvgPath.toString());
                if (Files.size(solidSvgPath) == 0) fail("Solid.svg wrote an empty file");
                try {
                    rounded.svgText(new Blacksmith.SvgOptions(null, null, null, null, 200.0, 1000.0, 1000.0, 0.05, 0.1,
                            "#000000", 1.0, null, true, false, false, false, true));
                    fail("blacksmith svg: fov=200 was accepted");
                } catch (Blacksmith.BuildException expected) {
                    // the library's own refusal
                }
                System.out.println("blacksmith svg: solid text, file written, fov=200 refused");

                // A profile draws its own plane, top by default -- unlike a solid, a sketch has
                // no camera-facing convention of its own, so its plane (z = 0) is already the
                // page. The default is pinned against an explicit iso view, not just checked
                // non-empty: a top default silently left at iso would make the two calls equal.
                String profileSvgText = outline.svgText();
                if (!profileSvgText.startsWith("<svg") || !profileSvgText.contains("<path")) fail("profile SVG text did not look like an SVG wireframe");
                String profileSvgIso = outline.svgText(new Blacksmith.SvgOptions(Blacksmith.SvgView.ISO, null, null, null,
                        0.0, 1000.0, 1000.0, 0.05, 0.1, "#000000", 1.0, null, true, false, false, false, true));
                if (profileSvgText.equals(profileSvgIso)) fail("profile svg: top default did not differ from an explicit iso view");
                Path profileSvgPath = Files.createTempFile("cadaclysm-smoke-profile", ".svg");
                outline.svg(profileSvgPath.toString());
                if (Files.size(profileSvgPath) == 0) fail("Profile.svg wrote an empty file");
                System.out.println("blacksmith svg: profile text, file written, top default confirmed against iso");

                // The module writer draws a solid and a profile on one page: one <g> per
                // drawable, an id each -- the overload writeSvgText/writeSvg take, widened
                // from the solids-only ones.
                String mixedSvgText = Blacksmith.writeSvgText(List.of(rounded), List.of(outline), null);
                if (!mixedSvgText.contains("<path") || !mixedSvgText.contains("id=\"solid-0\"") || !mixedSvgText.contains("id=\"profile-0\""))
                    fail("mixed solid+profile SVG did not carry both group ids");
                Path mixedSvgPath = Files.createTempFile("cadaclysm-smoke-mixed", ".svg");
                Blacksmith.writeSvg(mixedSvgPath.toString(), List.of(rounded), List.of(outline), null);
                if (Files.size(mixedSvgPath) == 0) fail("writeSvg (solids and profiles) wrote an empty file");
                System.out.println("blacksmith svg: solid and profile drawn together, both group ids present");

                // toScene: a reader scene over the same STEP text, and one that stands on
                // its own -- the solid's close must not take it down.
                scene = rounded.toScene();
                float[] sceneMax = scene.bounds().max();
                if (!near(sceneMax, 40, 20, 16)) fail("toScene's bounds disagree: " + Arrays.toString(sceneMax));

                // A mesh view owns a held tessellation of its own: meshing the solid again at
                // another tolerance leaves an already-taken view untouched -- nothing about it
                // goes stale.
                Blacksmith.Mesh first = rounded.mesh(0.05);
                int triangles = first.triangleCount();
                FloatBuffer positions = first.positions();
                if (positions.remaining() != first.vertexCount() * 3) fail("the mesh view is the wrong length");
                float[] kept = first.copy().positions();
                rounded.mesh(0.5);
                rounded.mesh(0.01);
                if (!Arrays.equals(first.copy().positions(), kept)) fail("a held mesh view changed under a re-mesh at another tolerance");
                System.out.println("triangles=" + triangles);

                // ...and the solid closing does not touch it either: the view's handle, not
                // the solid's cache, is what the pointers actually borrow from.
                try (Blacksmith.Solid meshBox = Blacksmith.Solid.cuboid(1, 2, 3)) {
                    Blacksmith.Mesh boxMesh = meshBox.mesh(0.05);
                    float boxKept = boxMesh.positions().get(0);
                    meshBox.close();
                    if (boxMesh.positions().get(0) != boxKept) fail("a held mesh view changed when its solid was closed");
                }

                // f64 twins on the kernel: mesh64 shares mesh's cache and bounds64 the same
                // tessellation's unnarrowed positions.
                Blacksmith.Mesh kMesh32 = rounded.mesh(0.05);
                Blacksmith.Mesh64 kMesh64 = rounded.mesh64(0.05);
                if (kMesh64.vertexCount() != kMesh32.vertexCount() || kMesh64.indexCount() != kMesh32.indexCount())
                    fail("blacksmith mesh64(0.05)'s counts do not equal mesh(0.05)'s");
                double[] kPositions64 = kMesh64.copy().positions();
                float[] kPositions32 = kMesh32.copy().positions();
                if (kPositions32.length >= 3 &&
                        ((float) kPositions64[0] != kPositions32[0] || (float) kPositions64[1] != kPositions32[1] || (float) kPositions64[2] != kPositions32[2]))
                    fail("blacksmith mesh64's first position narrowed does not equal mesh's");
                Blacksmith.Bounds kBounds = rounded.boundsAt(0.05);
                Blacksmith.Bounds kBounds64 = rounded.boundsAt64(0.05);
                if (Math.abs(kBounds64.min()[0] - kBounds.min()[0]) > 1e-9 || Math.abs(kBounds64.min()[1] - kBounds.min()[1]) > 1e-9 || Math.abs(kBounds64.min()[2] - kBounds.min()[2]) > 1e-9
                        || Math.abs(kBounds64.max()[0] - kBounds.max()[0]) > 1e-9 || Math.abs(kBounds64.max()[1] - kBounds.max()[1]) > 1e-9 || Math.abs(kBounds64.max()[2] - kBounds.max()[2]) > 1e-9)
                    fail("blacksmith bounds64(0.05) does not equal bounds(0.05)");
                System.out.printf("blacksmith f64 twins: mesh64 %d triangles, bounds64 max z %s%n", kMesh64.triangleCount(), kBounds64.max()[2]);
            }

            try (Blacksmith.Solid box = Blacksmith.Solid.cuboid(1, 2, 3); Blacksmith.Solid big = box.scaled(2)) {
                Blacksmith.Bounds bb = big.bounds();
                if (Math.abs(bb.max()[0] - bb.min()[0] - 2) > 1e-9 || Math.abs(bb.max()[2] - bb.min()[2] - 6) > 1e-9) fail("scaled bounds");
                try { box.scaled(0); fail("scaled(0) not refused"); }
                catch (Blacksmith.BuildException e) { if (!e.getMessage().startsWith("scaled:")) fail("scaled message: " + e.getMessage()); }
            }

            // Leaving the block closed `rounded`: a call on it now throws, and the scene
            // from toScene is its own document, still readable after the solid that made
            // it is gone.
            if (!released.closed()) fail("leaving the block did not close the solid");
            boolean closedThrows;
            try {
                released.faces();
                closedThrows = false;
            } catch (IllegalStateException e) {
                closedThrows = true;
            }
            if (!closedThrows) fail("a call on a closed solid did not throw");
            try (scene) {
                if (!near(scene.bounds().max(), 40, 20, 16)) fail("toScene's scene died with the solid");
            }
            System.out.println("toScene ok, closed solid throws");
        }
    }

    // The FEM surface mesh, the reader's side. cube.scad carries no brep, so this is the
    // mesh-only path: one face, every node on it, no B-rep topology at all, and the scene's own
    // convention rather than the file's. Every check below names the wrong implementation it
    // catches; `#` marks the ones a break-the-code proof was run against.
    private static void femReader(Cad.Node first, String path) throws IOException {
        try (Cad.FemMesh fem = first.femMesh(0.5)) {
            int nodeCount = fem.nodes().remaining() / 3;
            int triangleCount = fem.triangles().remaining() / 3;
            if (fem.nodes().remaining() % 3 != 0 || fem.triangles().remaining() % 3 != 0 || nodeCount == 0)
                fail("fem: the node and triangle buffers read " + fem.nodes().remaining() + " and " + fem.triangles().remaining());
            // Catches `triangles` lent over `node_count` (or `nodes` over `triangle_count`): the
            // buffers would be the wrong length and the indices would run past the nodes.
            if (fem.triangleFace().remaining() != triangleCount) fail("fem: triangleFace is not one per triangle");
            IntBuffer triangles = fem.triangles();
            for (int i = 0; i < triangles.remaining(); i++)
                if (triangles.get(i) < 0 || triangles.get(i) >= nodeCount)
                    fail("fem: a triangle names node " + triangles.get(i) + " of " + nodeCount);
            IntBuffer triangleFace = fem.triangleFace();
            for (int i = 0; i < triangleFace.remaining(); i++)
                if (triangleFace.get(i) < 0 || triangleFace.get(i) >= fem.faceCount())
                    fail("fem: a triangle lies on face " + triangleFace.get(i) + " of " + fem.faceCount());
            // Catches nodeKind and nodeEntity lent from each other's pointer: a kind would then be
            // a face index and an entity a 0/1/2. Bounding each entity by the list its own kind
            // names is what tells the two apart -- the widths cannot, both being one uint32 array
            // per node.
            if (fem.nodeKind().remaining() != nodeCount || fem.nodeEntity().remaining() != nodeCount)
                fail("fem: nodeKind/nodeEntity are not one per node");
            // Read once, outside the loop: every ask rebuilds the list from the handle at one C
            // call an element, and the two are empty here only because this body has no B-rep
            // topology.
            List<Cad.FemEdge> edges = fem.edges();
            List<Cad.FemVertex> vertices = fem.vertices();
            IntBuffer kinds = fem.nodeKind(), entities = fem.nodeEntity();
            for (int k = 0; k < nodeCount; k++) {
                int kind = kinds.get(k), entity = entities.get(k);
                int limit = switch (kind) {
                    case 0 -> vertices.size();
                    case 1 -> edges.size();
                    case 2 -> fem.faceCount();
                    default -> 0;
                };
                if (kind < 0 || kind > 2 || entity < 0 || entity >= limit)
                    fail("fem: node " + k + " lies on kind " + kind + " entity " + entity + ", of " + limit);
            }
            if (fem.minAngle() <= 0 || fem.minAngle() >= 90 || fem.longestEdge() <= 0 || fem.worstTriangle() >= triangleCount)
                fail("fem: the quality figures read " + fem);
            if (path.endsWith("cube.scad")) {
                // # Catches fromMesh read off the neighbouring `watertight` field -- true for this
                // body too, so only a body where the two differ separates them (the B-rep below).
                if (!fem.fromMesh() || fem.faceCount() != 1 || !edges.isEmpty() || !vertices.isEmpty())
                    fail("fem: the cube reads " + fem + ", not a mesh-only body of one face");
                for (int k = 0; k < nodeCount; k++)
                    if (kinds.get(k) != 2 || entities.get(k) != 0) fail("fem: a mesh body's nodes all lie on face 0");
                if (!fem.watertight() || !fem.openEdges().isEmpty() || !fem.foldedEdges().isEmpty() || !fem.crossings().isEmpty())
                    fail("fem: the closed cube reads " + fem.openEdges().size() + " cracks, " + fem.foldedEdges().size()
                            + " folds and " + fem.crossings().size() + " crossings");
            }
            String msh = fem.mshText();
            if (!msh.startsWith("$MeshFormat") || !msh.contains("$Nodes")) fail("fem: mshText is not Gmsh 4.1 ASCII");
            // The borrowed slot is copied into a String on the way through, so a second ask does
            // not free the first answer: both are this program's own and both still read.
            if (fem.mshText().length() != msh.length()) fail("fem: a second mshText disagrees with the first");
            Path mshPath = Files.createTempFile("cadaclysm-smoke", ".msh");
            fem.saveMsh(mshPath.toString());
            if (Files.size(mshPath) < msh.length() / 2) fail("fem: saveMsh wrote less than mshText");
            // The reader's placement is sixteen numbers, column-major; the kernel's is twelve. A
            // caller handing one ABI the other's is refused here rather than read as garbage --
            // and the length is the one thing a wrapper must check itself, the ABI seeing only a
            // pointer.
            try {
                first.femMesh(0.5, 0.0, new double[12]);
                fail("fem: a twelve-number placement was accepted");
            } catch (Cad.CadaclysmException e) {
                if (!e.getMessage().contains("16 numbers")) fail("fem: the placement refusal reads " + e.getMessage());
            }
            // A mesh-only body is meshed by a path that takes no options at all
            // (`fem::fem_mesh_of_mesh`), so neither field is read here, let alone validated: a
            // zero, a negative and a NaN all come back with the mesh. What is pinned is the
            // wrapper's pass-through, not the mesher's checking -- a wrapper that validated
            // `tolerance` or `maxSize` itself would refuse calls this ABI accepts. (Both *are*
            // refused on a B-rep body; femBrep checks the tolerance half.)
            double[][] unread = {{0, 0}, {-1, 0}, {Double.NaN, 0}, {0.5, -1}, {0.5, Double.NaN}, {0.5, Double.POSITIVE_INFINITY}};
            for (double[] pair : unread) {
                try (Cad.FemMesh any = first.femMesh(pair[0], pair[1])) {
                    if (any.nodes().remaining() != nodeCount * 3)
                        fail("fem: a mesh-only body read its options after all (tolerance " + pair[0]
                                + ", maxSize " + pair[1] + " gave " + any + ")");
                }
            }
            // # A freed handle refuses every accessor rather than reading the pointers it left
            // behind: the view struct is cached, so an accessor that does not ask the handle first
            // hands out a buffer over freed memory instead of throwing. The kernel's own sweep in
            // femKernel is the twin -- the guard is per wrapper class, so proving one says nothing
            // about the other.
            //
            // What this does *not* prove, because Java cannot: a buffer already in hand is a
            // window on an address with no owner left to ask. Measured once while writing this,
            // on the kernel side: a DoubleBuffer taken before free() and read after did not
            // throw -- it read the freed block and handed back 1.29e-311 where the mesh had 4.0.
            // Not checked here on purpose: a deliberate read of freed memory in the smoke the
            // release pipeline runs on nine platforms is an intermittent crash waiting to
            // happen. Both wrappers' docs say which half is guarded.
            Cad.FemMesh staleReader = first.femMesh(0.5);
            staleReader.free();
            if (!staleReader.closed()) fail("fem: a freed mesh does not say so");
            staleReader.free();   // idempotent
            List<Runnable> reads = List.of(
                    staleReader::nodes, staleReader::triangles, staleReader::triangleFace,
                    staleReader::nodeKind, staleReader::nodeEntity, staleReader::faceCount,
                    staleReader::edges, staleReader::vertices, staleReader::openEdges,
                    staleReader::foldedEdges, staleReader::crossings, staleReader::watertight, staleReader::fromMesh,
                    staleReader::minAngle, staleReader::worstTriangle, staleReader::longestEdge,
                    staleReader::mshText, () -> staleReader.saveMsh(mshPath.toString()));
            if (reads.size() != 18) fail("fem: the freed sweep covers " + reads.size() + " reads, not 18");
            for (Runnable read : reads) {
                try {
                    read.run();
                    fail("fem: a freed mesh read anyway");
                } catch (Cad.CadaclysmException e) {
                    if (e.getMessage() == null || !e.getMessage().contains("freed")) fail("fem: a freed mesh said " + e.getMessage());
                }
            }
            System.out.println("fem (reader): " + fem + ", minAngle " + fem.minAngle() + ", longestEdge " + fem.longestEdge()
                    + "; a freed mesh refuses all eighteen reads");
        }
        if (path.endsWith("cube.scad")) {
            femCensusWiring(Path.of(path).resolveSibling("open-sheet.scad"));
            femCrossings(Path.of(path).resolveSibling("dented-box.stp"));
        }
    }

    // # Which count feeds which entry point -- the census *wiring*, which nothing else here pins.
    // Every other FEM check proves a row is extracted correctly; none proves openEdges() reads
    // openEdgeCount rows through cadaclysm_fem_mesh_open_edge rather than the folded count or the
    // folded call. samples/open-sheet.scad is the only body in this repository where both censuses
    // are non-empty and of different lengths: the B-rep path computes no census unless the topology
    // is closed (the documented "not asked" pair) and every closed body has none, while the mesh
    // path always computes one -- so a polyhedron with a flap over one of its own directed edges is
    // the way in. Six cracks, one fold, and the fold is not the first crack.
    private static void femCensusWiring(Path sheet) {
        try (Cad.Scene scene = Cad.open(sheet.toString())) {
            Cad.Node body = null;
            for (Cad.Node n : scene.walk()) if (n.canMesh()) { body = n; break; }
            if (body == null) fail("fem census: open-sheet.scad has no meshable node");
            try (Cad.FemMesh census = body.femMesh()) {
                if (census.nodes().remaining() != 15 || census.triangles().remaining() != 9
                        || !census.fromMesh() || census.watertight())
                    fail("fem census: open-sheet.scad reads " + census + ", not five open, folded, mesh-only nodes");
                List<int[]> cracks = census.openEdges(), folds = census.foldedEdges();
                // The counts are what separate the two lists: a swapped count reads 1 where 6
                // belongs, and a swapped call cannot read row 1 of a one-row table at all.
                if (cracks.size() != 6 || folds.size() != 1)
                    fail("fem census: " + cracks.size() + " cracks and " + folds.size() + " folds, not 6 and 1");
                // And the contents, which separates a wrapper that swapped both consistently.
                int[] fold = folds.get(0), crack = cracks.get(0);
                if (fold[0] != 2 || fold[1] != 0 || fold[2] != -1)
                    fail("fem census: the fold reads (" + fold[0] + "," + fold[1] + "," + fold[2] + "), not (2,0,NONE)");
                if (crack[0] != 1 || crack[1] != 2)
                    fail("fem census: the first crack reads (" + crack[0] + "," + crack[1] + "), not (1,2)");
                System.out.println("fem census: open-sheet.scad reads " + cracks.size() + " cracks and "
                        + folds.size() + " fold at (" + fold[0] + "," + fold[1] + ")");
            }
        }
    }

    // Crossings: samples/dented-box.stp is a closed B-rep box whose top dips through its own
    // floor, 296 pairs measured 2026-09-26 -- once through this reader, and once through the
    // kernel's own open of the same file, which must agree with it.
    private static void femCrossings(Path dentedBox) {
        try (Cad.Scene scene = Cad.open(dentedBox.toString())) {
            Cad.Node body = null;
            for (Cad.Node n : scene.walk()) if (n.canMesh()) { body = n; break; }
            if (body == null) fail("fem crossings: dented-box.stp has no meshable node");
            try (Cad.FemMesh fem = body.femMesh()) {
                if (!fem.watertight() || fem.fromMesh())
                    fail("fem crossings: dented-box.stp reads " + fem + ", not a watertight brep");
                List<int[]> crossings = fem.crossings();
                if (crossings.size() != 296) fail("fem crossings: dented-box.stp reads " + crossings.size() + " pairs, not 296");
                int[] first = crossings.get(0);
                if (first[0] >= first[1])
                    fail("fem crossings: the first pair reads (" + first[0] + "," + first[1] + "), not a < b");
                try (Blacksmith.Solid kernelSolid = Blacksmith.Solid.open(dentedBox.toString());
                     Blacksmith.FemMesh kernelFem = kernelSolid.femMesh()) {
                    List<int[]> kernelCrossings = kernelFem.crossings();
                    if (kernelCrossings.size() != 296)
                        fail("kernel fem crossings: dented-box.stp reads " + kernelCrossings.size() + " pairs, not 296");
                    System.out.println("fem crossings: dented-box.stp reads " + crossings.size()
                            + " pairs through the reader and " + kernelCrossings.size() + " through the kernel");
                }
            }
        }
    }

    // The FEM surface mesh on a B-rep body, read back from the STEP this run wrote: the topology
    // the mesh-only body has none of -- edges with the body's own ids, vertices, and nodes on all
    // three kinds of entity.
    private static void femBrep(Path step, int faces) {
        try (Cad.Scene back = Cad.open(step.toString())) {
            Cad.Node body = null;
            for (Cad.Node n : back.walk()) if (n.canMesh()) { body = n; break; }
            if (body == null) fail("fem: the read-back STEP has no meshable body");
            try (Cad.FemMesh fem = body.femMesh(0.5)) {
                // # The other half of the fromMesh proof: false here where it was true on the
                // cube, the neighbouring watertight being true for both.
                if (fem.fromMesh() || !fem.watertight() || fem.faceCount() != faces)
                    fail("fem: the read plate reads " + fem + ", not a closed B-rep of " + faces + " faces");
                List<Cad.FemEdge> edges = fem.edges();
                List<Cad.FemVertex> vertices = fem.vertices();
                if (edges.isEmpty() || vertices.isEmpty()) fail("fem: a B-rep body carries edges and vertices");
                Set<Integer> kinds = new HashSet<>();
                IntBuffer nodeKind = fem.nodeKind();
                for (int i = 0; i < nodeKind.remaining(); i++) kinds.add(nodeKind.get(i));
                if (!kinds.equals(Set.of(0, 1, 2))) fail("fem: the plate's nodes lie on kinds " + kinds + ", not 0, 1 and 2");
                // # `id` is the body's own B-rep edge id, not this list's index: the list is a
                // densely renumbered subset ascending by id. Catches an `id` filled from the loop
                // counter -- which a body whose ids happened to run 0, 1, 2 would hide, so both
                // halves are checked.
                boolean ascending = true, offIndex = false;
                for (int i = 0; i < edges.size(); i++) {
                    if (i > 0 && edges.get(i).id() < edges.get(i - 1).id()) ascending = false;
                    if (edges.get(i).id() != i) offIndex = true;
                }
                if (!ascending) fail("fem: the edge ids do not ascend");
                if (!offIndex) fail("fem: every edge id equals its own index -- id is the index, not the body's id");
                int nodeCount = fem.nodes().remaining() / 3;
                for (Cad.FemEdge edge : edges) {
                    int[] runs = edge.runs(), nodes = edge.nodes();
                    if (runs.length == 0 || runs[0] != 0 || runs[runs.length - 1] >= nodes.length)
                        fail("fem: " + edge + "'s runs do not start at 0 inside its chain");
                    for (int node : nodes) if (node < 0 || node >= nodeCount) fail("fem: " + edge + " names a node past the mesh");
                    // # A closed body has no rim, so every edge has two faces and neither is the
                    // NONE sentinel.
                    if (edge.faces()[0] < 0 || edge.faces()[0] >= faces || edge.faces()[1] < 0 || edge.faces()[1] >= faces)
                        fail("fem: " + edge + " on a closed body bounds faces " + Arrays.toString(edge.faces()) + " of " + faces);
                    if (edge.closed() && runs.length > 1) fail("fem: " + edge + " is one loop with a broken chain");
                    if (edge.seam() && edge.faces()[0] != edge.faces()[1]) fail("fem: " + edge + " is a seam whose two faces differ");
                    // # The chain includes its end vertices, so the two ends name the nodes it
                    // begins and finishes at -- which is what tells `ends` from `faces`, both a
                    // pair of indices a swap would leave in range on a body of this shape.
                    Set<Integer> ends = new HashSet<>();
                    for (int end : edge.ends()) if (end != -1) ends.add(vertices.get(end).node());
                    if (!ends.equals(new HashSet<>(List.of(nodes[0], nodes[nodes.length - 1]))))
                        fail("fem: " + edge + " does not end at its own vertices");
                }
                boolean placed = false;
                for (Cad.FemVertex vertex : vertices) {
                    if (vertex.hasPosition()) placed = true;
                    if (vertex.point().length != 3 || (vertex.node() != -1 && vertex.node() >= nodeCount))
                        fail("fem: " + vertex + " is not a node of this mesh");
                }
                if (!placed) fail("fem: no vertex of the plate has a position");
                // A B-rep body *does* have geometry to follow, so here the tolerance is read and
                // refused -- in the library's own words, not a message this wrapper invented.
                try {
                    body.femMesh(0);
                    fail("fem: a zero tolerance was accepted on a B-rep body");
                } catch (Cad.CadaclysmException e) {
                    if (!e.getMessage().contains("tolerance must be finite and > 0"))
                        fail("fem: the tolerance refusal reads " + e.getMessage());
                }
                System.out.println("fem (read brep): " + fem + ", " + edges.size() + " edges, "
                        + vertices.size() + " vertices, edge 0 " + edges.get(0));
            }
        }
    }

    // The kernel's own FEM mesh: the same solid through `cadaclysm_blacksmith_fem_mesh`, whose
    // placement is twelve numbers and whose `.msh` text is owned rather than borrowed.
    private static void femKernel(Blacksmith.Solid rounded, int faces) throws IOException {
        Path mshPath = Files.createTempFile("cadaclysm-smoke-kernel", ".msh");
        try (Blacksmith.FemMesh fem = rounded.femMesh(0.5)) {
            if (fem.fromMesh() || !fem.watertight() || fem.faceCount() != faces || fem.nodes().remaining() == 0)
                fail("kernel fem: the filleted part reads " + fem);
            if (!fem.openEdges().isEmpty() || !fem.foldedEdges().isEmpty() || !fem.crossings().isEmpty())
                fail("kernel fem: a watertight solid reads " + fem.openEdges().size() + " cracks, "
                        + fem.foldedEdges().size() + " folds and " + fem.crossings().size() + " crossings");
            // maxSize bounds the boundary segments and only targets the interior, so the figure a
            // solver caller checks is longestEdge -- not the ceiling it asked for. Catches a
            // wrapper that dropped maxSize on the floor: the mesh would not refine at all.
            try (Blacksmith.FemMesh fine = rounded.femMesh(0.5, 3.0)) {
                // 1.05 and not 3.0 exactly: the ceiling is not a guarantee (1.03 x was measured on
                // a face whose parameters run unevenly), so a tighter pin here would assert
                // something the ABI deliberately does not promise.
                if (fine.longestEdge() > 3.0 * 1.05) fail("kernel fem: maxSize 3 came to longestEdge " + fine.longestEdge());
                if (fine.nodes().remaining() <= fem.nodes().remaining() || fine.longestEdge() >= fem.longestEdge())
                    fail("kernel fem: maxSize 3 gave " + fine.nodes().remaining() / 3 + " nodes and longestEdge "
                            + fine.longestEdge() + ", no finer than " + fem.nodes().remaining() / 3 + "/" + fem.longestEdge());
            }
            String msh = fem.mshText();
            if (!msh.startsWith("$MeshFormat")) fail("kernel fem: mshText is not Gmsh 4.1 ASCII");
            // Owned on this side, not borrowed: two asks give two independent texts, each released
            // by `cadaclysm_blacksmith_string_free` on the way out, and neither dies with the other
            // or with the handle.
            if (fem.mshText().length() != msh.length()) fail("kernel fem: a second mshText disagrees with the first");
            fem.saveMsh(mshPath.toString());
            if (Files.size(mshPath) < msh.length() / 2) fail("kernel fem: saveMsh wrote less than mshText");
            // # The kernel's placement is twelve numbers where the reader's is sixteen.
            try {
                rounded.femMesh(0.5, 0.0, new double[16]);
                fail("kernel fem: a sixteen-number placement was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().contains("12 numbers")) fail("kernel fem: the placement refusal reads " + e.getMessage());
            }
            try {
                rounded.femMesh(0);
                fail("kernel fem: a zero tolerance was accepted");
            } catch (Blacksmith.BuildException expected) {
                // the library's own refusal, not this wrapper's
            }
            System.out.println("kernel fem: " + fem + ", minAngle " + fem.minAngle() + ", longestEdge " + fem.longestEdge());
        }
        // An open sheet: the one body where the sentinel and the "not asked" census trio show.
        try (Blacksmith.Profile square = Blacksmith.Profile.rect(20, 20);
             Blacksmith.Solid sheet = Blacksmith.Solid.face(square, new double[] {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1});
             Blacksmith.FemMesh sheetFem = sheet.femMesh(0.5)) {
            // # watertight false with *both* censuses empty is "not asked", not "nothing found": a
            // sheet makes no claim to enclose anything. A caller reading only openEdges cannot tell
            // this from a sound body, which is why foldedEdges is checked beside it.
            if (sheetFem.watertight() || !sheetFem.openEdges().isEmpty() || !sheetFem.foldedEdges().isEmpty())
                fail("kernel fem: the sheet reads " + sheetFem + " rather than open with an unasked census");
            // # Catches `face_b` filled with 0 instead of the NONE sentinel: every rim edge of a
            // one-faced sheet bounds face 0 and nothing else, so a 0 there reads as a real second
            // face -- a coherent wrong answer no field count or width can catch.
            StringBuilder rim = new StringBuilder();
            for (Blacksmith.FemEdge edge : sheetFem.edges()) rim.append(edge.faces()[0]).append("/").append(edge.faces()[1]).append("; ");
            if (sheetFem.faceCount() != 1) fail("kernel fem: the sheet has " + sheetFem.faceCount() + " faces, not 1");
            for (Blacksmith.FemEdge edge : sheetFem.edges())
                if (edge.faces()[0] != 0 || edge.faces()[1] != -1) fail("kernel fem: the sheet's rim reads " + rim);
            System.out.println("kernel fem: the sheet's rim reads " + rim);
        }
        // # The freed sweep, the kernel's own: seventeen reads, each refusing rather than reading
        // the pointers the handle left behind.
        Blacksmith.FemMesh stale = rounded.femMesh(0.5);
        stale.free();
        if (!stale.closed()) fail("kernel fem: a freed mesh does not say so");
        stale.free();   // idempotent
        List<Runnable> reads = List.of(
                stale::nodes, stale::triangles, stale::triangleFace, stale::nodeKind,
                stale::nodeEntity, stale::faceCount, stale::edges, stale::vertices,
                stale::openEdges, stale::foldedEdges, stale::crossings, stale::watertight, stale::fromMesh,
                stale::minAngle, stale::worstTriangle, stale::longestEdge, stale::mshText,
                () -> stale.saveMsh(mshPath.toString()));
        if (reads.size() != 18) fail("kernel fem: the freed sweep covers " + reads.size() + " reads, not 18");
        for (Runnable read : reads) {
            try {
                read.run();
                fail("kernel fem: a freed mesh read anyway");
            } catch (IllegalStateException e) {
                if (e.getMessage() == null || !e.getMessage().contains("freed")) fail("kernel fem: a freed mesh said " + e.getMessage());
            }
        }
        System.out.println("kernel fem: a freed mesh refuses all eighteen reads");
    }

    private static boolean near(float[] v, double x, double y, double z) {
        return Math.abs(v[0] - x) <= 0.01 && Math.abs(v[1] - y) <= 0.01 && Math.abs(v[2] - z) <= 0.01;
    }

    private static boolean near(double[] v, double x, double y, double z) {
        return Math.abs(v[0] - x) <= 0.01 && Math.abs(v[1] - y) <= 0.01 && Math.abs(v[2] - z) <= 0.01;
    }

    // Hits: two radius-5 circles six apart cross at two points, (3, -4) and (3, 4). At
    // (3, 4) the first circle's upper arc is at t 0.2952 and the moved one's at 0.7048; at
    // (3, -4) the other way round -- which catches the two sides read swapped.
    private static void hits() {
        try (Blacksmith.Profile left = Blacksmith.Profile.circle(5);
             Blacksmith.Profile five = Blacksmith.Profile.circle(5);
             Blacksmith.Profile right = five.translate(6, 0)) {
            List<Blacksmith.Hit> crossing = left.hits(right);
            if (crossing.size() != 2) fail("hits: two circles hit " + crossing.size() + " times, not 2");
            double[] ys = crossing.stream().mapToDouble(h -> h.start()[1]).sorted().toArray();
            if (Math.abs(ys[0] + 4) > 1e-9 || Math.abs(ys[1] - 4) > 1e-9)
                fail("hits: y " + ys[0] + ", " + ys[1] + ", not -4 and 4");
            for (Blacksmith.Hit h : crossing) {
                double ta = h.start()[1] > 0 ? 0.2952 : 0.7048, tb = h.start()[1] > 0 ? 0.7048 : 0.2952;
                if (h.run() || h.touch() || h.aStart().loopIndex() != 0 || Math.abs(h.start()[0] - 3) > 1e-9
                        || Math.abs(h.aStart().t() - ta) > 1e-3 || Math.abs(h.bStart().t() - tb) > 1e-3)
                    fail("hits: " + h + " is not a crossing at (3, +-4) at t " + ta + " on a and " + tb + " on b");
            }
            System.out.println("hits: " + crossing.get(0) + ", " + crossing.get(1));
            // Common: the same two circles share one lens, four arcs (each circle's own seam
            // stays a join) between two caps once extruded; moved apart they share nothing.
            List<Blacksmith.Profile> lenses = left.common(right);
            if (lenses.size() != 1) fail("common: two circles share " + lenses.size() + " regions, not 1");
            try (Blacksmith.Profile lens = lenses.get(0);
                 Blacksmith.Solid lensSolid = Blacksmith.Workplane.xy().extrude(lens, 1).solid();
                 Blacksmith.Profile far = five.translate(100, 0)) {
                if (lensSolid.faces() != 6) fail("common: the lens extrudes to " + lensSolid.faces() + " faces, not 6");
                if (!left.common(far).isEmpty()) fail("common: circles 100 apart share a region");
                try {
                    left.common(right, 0.0);
                    fail("common: a zero tolerance was accepted");
                } catch (Blacksmith.BuildException e) {
                    if (!e.getMessage().contains("profile_common: tolerance must be positive and finite")) throw e;
                }
                System.out.println("common: one lens, " + lensSolid.faces() + " faces extruded");
            }
        }
    }

    // Machining: the Python SDK's to_arcs, offset and section, then Tool, Stock and Job -- the
    // fixtures of test_cadaclysm_blacksmith.py's "machining" block and Node's pocketedBlock on.
    // A profile is measured by extruding it 1 and reading the solid's bounds.
    private static void machining() {
        try (Blacksmith.Profile rect2010 = Blacksmith.Profile.rect(20, 10)) {
            List<Blacksmith.Profile> grown = rect2010.offset(2);
            if (grown.size() != 1 || !near(footprint(grown.get(0)), new double[] {-12, 12, -7, 7}, 1e-3))
                fail("offset: grown by 2 is " + grown.size() + " profile(s)");
            grown.get(0).close();
            List<Blacksmith.Profile> shrunk = rect2010.offset(-2);
            if (shrunk.size() != 1 || !near(footprint(shrunk.get(0)), new double[] {-8, 8, -3, 3}, 1e-3))
                fail("offset: shrunk by 2 is not one profile over [-8, 8, -3, 3]");
            shrunk.get(0).close();
            if (!rect2010.offset(-6).isEmpty()) fail("offset: a shrink past half the width left something");
            try {
                rect2010.offset(Double.NaN);
                fail("offset: a NaN distance was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().equals("profile_offset: distance must be finite")) fail("offset: wrong message: " + e.getMessage());
            }
            System.out.println("offset: grown to [-12, 12, -7, 7], shrunk to [-8, 8, -3, 3], eaten at -6, NaN refused");
        }

        try (Blacksmith.Profile spline = Blacksmith.Profile.spline(
                new double[][] {{0, 0}, {10, 0}, {10, 10}, {0, 10}}, 3, null, true);
             Blacksmith.Profile fitted = spline.toArcs(0.01)) {
            if (!near(footprint(fitted), footprint(spline), 0.011))
                fail("to_arcs: the fit's footprint is not within 0.011 of the spline's");
            try {
                spline.toArcs(0);
                fail("to_arcs: a zero tolerance was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().equals("profile_to_arcs: tolerance must be positive and finite")) fail("to_arcs: wrong message: " + e.getMessage());
            }
            System.out.println("to_arcs: the fit bounds the spline within 0.011, zero tolerance refused");
        }

        try (Blacksmith.Solid box2010 = Blacksmith.Solid.cuboid(20, 10, 5)) {
            List<Blacksmith.Profile> middle = box2010.section(0);
            if (middle.size() != 1 || !near(footprint(middle.get(0)), new double[] {-10, 10, -5, 5}, 1e-3))
                fail("section: the box's middle is not one profile over [-10, 10, -5, 5]");
            middle.get(0).close();
            if (!box2010.section(50).isEmpty()) fail("section: a plane missing the box cut something");
            try {
                box2010.section(2.5);
                fail("section: a plane on the top face was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().equals("solid_section: a face lies in the plane -- section a little above or below it"))
                    fail("section: wrong message: " + e.getMessage());
            }
            System.out.println("section: the box's middle, a miss above it, a face in the plane refused");
        }

        // The pocketed block: a 6 mm end mill is too big for the pocket's four square corners.
        try (Blacksmith.Solid block = pocketedBlock();
             Blacksmith.Tool endMill = Blacksmith.Tool.flat(1, 6, 20, 800, 200, 12000)) {
            try (Blacksmith.Job job = new Blacksmith.Job(Blacksmith.Stock.around(block, 2), 30)) {
                Blacksmith.Report report = job.machine(block, endMill);
                if (report.size() != 4) fail("machine: the pocketed block reports " + report.size() + " item(s), not 4:\n" + report);
                if (!report.toString().equals(report.text()) || report.text().split("\n").length != 4)
                    fail("machine: the report's text is not four lines:\n" + report.text());
                // the records are read-only: a copy in and out of the array, an unmodifiable list
                Blacksmith.ReportItem first = report.get(0);
                double was = first.at()[0];
                first.at()[0] = was + 1e9;
                if (first.at()[0] != was) fail("machine: an item's at is shared with the array a caller changed");
                // and in: the array and list a record is built from are copied, not kept
                double[] given = {1, 2, 3};
                List<Blacksmith.Profile> regionGiven = new java.util.ArrayList<>();
                Blacksmith.ReportItem built = new Blacksmith.ReportItem("corner", given, 1, "why", regionGiven);
                given[0] = 99;
                regionGiven.add(null);
                if (built.at()[0] != 1 || !built.region().isEmpty())
                    fail("machine: a ReportItem kept the array or list it was built from: " + built);
                try {
                    first.region().add(null);
                    fail("machine: an item's region accepted an add");
                } catch (UnsupportedOperationException expected) {
                    // read-only
                }
                for (Blacksmith.ReportItem item : report) {
                    if (!item.kind().equals("corner") || !(item.size() > 0) || item.region().isEmpty() || item.reason().isEmpty()
                            || !Double.isFinite(item.at()[0]) || !Double.isFinite(item.at()[1]) || !Double.isFinite(item.at()[2]))
                        fail("machine: " + item + " is not a corner with a location, a size and a region");
                    for (Blacksmith.Profile p : item.region()) p.close();
                }
                List<Blacksmith.Operation> ops = job.operations();
                if (ops.isEmpty() || ops.stream().anyMatch(o -> o.kind().isEmpty() || o.tool() != 1 || o.params().isEmpty()))
                    fail("machine: the pocketed block's operations are missing a kind, a tool or params");
                try {
                    ops.get(0).params().put("z", 1.0);
                    fail("machine: an operation's params accepted a put");
                } catch (UnsupportedOperationException expected) {
                    // read-only
                }
                System.out.println("machine: the pocketed block leaves four corners, " + ops.size() + " operations (" + report.get(0) + ")");
            }

            // A drill as the end mill is refused, and leaves the job as it was.
            try (Blacksmith.Tool drill5 = Blacksmith.Tool.drill(2, 5, 30, 150, 3000);
                 Blacksmith.Job fresh = new Blacksmith.Job(Blacksmith.Stock.around(block, 2), 30)) {
                try {
                    fresh.machine(block, drill5);
                    fail("machine: a drill as the end mill was accepted");
                } catch (Blacksmith.BuildException e) {
                    if (!e.getMessage().contains("end mill must not be a drill")) fail("machine: wrong message: " + e.getMessage());
                }
                if (!fresh.operations().isEmpty()) fail("machine: a refused call changed the job");

                // A closed job refuses every later call.
                fresh.close();
                fresh.close();   // idempotent
                if (!fresh.closed()) fail("job: closed but not closed()");
                try {
                    fresh.machine(block, endMill);
                    fail("job: machine() after close() was accepted");
                } catch (IllegalStateException e) {
                    if (!e.getMessage().contains("job: closed")) fail("job: wrong message: " + e.getMessage());
                }
                try {
                    fresh.operations();
                    fail("job: operations() after close() was accepted");
                } catch (IllegalStateException e) {
                    if (!e.getMessage().contains("job: closed")) fail("job: wrong message: " + e.getMessage());
                }
                try {
                    fresh.gcode();
                    fail("job: gcode() after close() was accepted");
                } catch (IllegalStateException e) {
                    if (!e.getMessage().contains("job: closed")) fail("job: wrong message: " + e.getMessage());
                }
                System.out.println("machine: a drill as the end mill refused, the job unchanged; a closed job refuses");
            }
        }

        // The plate of spec 2026-09-28: machined cleanly by one end mill and one drill.
        Blacksmith.Profile plateOutline = Blacksmith.Profile.rect(80, 50).round(6);
        Blacksmith.Solid platePart = Blacksmith.Solid.extrude(plateOutline, Blacksmith.Frame.xy().toArray(), 12);
        try (Blacksmith.Profile pocketOutline = Blacksmith.Profile.rect(40, 24).round(4).withHole(Blacksmith.Profile.circle(5));
             Blacksmith.Solid pocket = Blacksmith.Solid.extrude(pocketOutline, Blacksmith.Frame.xy(new double[] {0, 0, 7}).toArray(), 5)) {
            Blacksmith.Solid was = platePart;
            platePart = was.cut(pocket);
            was.close();
        }
        for (double x : new double[] {-32, 32}) {
            for (double y : new double[] {-17, 17}) {
                try (Blacksmith.Solid bore = Blacksmith.Solid.cylinder(3, 12).translate(x, y, 0)) {
                    Blacksmith.Solid was = platePart;
                    platePart = was.cut(bore);
                    was.close();
                }
            }
        }
        try (Blacksmith.Solid plateSolid = platePart;
             Blacksmith.Tool plateEndMill = Blacksmith.Tool.flat(1, 6, 20, 800, 200, 12000);
             Blacksmith.Tool plateDrill = Blacksmith.Tool.drill(2, 6, 30, 150, 3000);
             Blacksmith.Job job = new Blacksmith.Job(Blacksmith.Stock.around(plateSolid, 3), 25, 1.0, 0.01, "plate")) {
            Blacksmith.Report report = job.machine(plateSolid, plateEndMill, new Blacksmith.Tool[] {plateDrill});
            if (!report.isEmpty() || !report.toString().equals("nothing left uncut")) fail("plate: the report is not empty:\n" + report);
            List<Blacksmith.Operation> ops = job.operations();
            if (!ops.get(0).kind().equals("face") || ops.stream().noneMatch(o -> o.kind().equals("pocket"))
                    || !ops.get(ops.size() - 1).kind().equals("drill"))
                fail("plate: the operations run " + ops.stream().map(Blacksmith.Operation::kind).toList());
            Blacksmith.Operation lastOp = ops.get(ops.size() - 1);
            if (!Double.valueOf(4).equals(lastOp.params().get("points")) || !lastOp.params().containsKey("peck")
                    || lastOp.params().get("peck") != null)
                fail("plate: the drill's params are " + lastOp);
            List<Blacksmith.Program> programs = job.gcode();
            if (programs.size() != 2 || programs.stream().anyMatch(p -> p.tool() < 1 || p.name().isEmpty() || p.text().isEmpty()))
                fail("plate: gcode() gives " + programs);
            Path folder = Path.of(System.getProperty("java.io.tmpdir"), "cadaclysm-smoke-cam-" + ProcessHandle.current().pid());
            try {
                List<String> written = job.writeCamotics(folder.resolve("plate.camotics").toString());
                if (written.isEmpty() || written.stream().anyMatch(p -> !Files.exists(Path.of(p)))
                        || !written.get(written.size() - 1).endsWith("plate.camotics"))
                    fail("plate: write_camotics wrote " + written);
                System.out.println("plate: nothing left uncut, " + ops.size() + " operations, " + programs.size()
                        + " programs, " + written.size() + " CAMotics files");
            } finally {
                deleteRecursive(folder);
            }
        }

        // The four verbs by hand -- the spec's own example -- and the refusals in the kernel's words.
        try (Blacksmith.Profile specOutline = Blacksmith.Profile.rect(60, 40).round(5);
             Blacksmith.Solid specPart = Blacksmith.Solid.extrude(specOutline, Blacksmith.Frame.xy().toArray(), 20);
             Blacksmith.Tool end = Blacksmith.Tool.flat(1, 6, 20, 800, 200, 12000);
             Blacksmith.Tool drill = Blacksmith.Tool.drill(2, 5, 30, 150, 3000);
             Blacksmith.Job job = new Blacksmith.Job(Blacksmith.Stock.around(specPart, 2), 30)) {
            job.face(end, 20, 3, 1);
            job.contour(end, specOutline, 20, 0, "outside", 2, true, false);
            try (Blacksmith.Profile level = specPart.section(15).get(0)) {
                job.pocket(end, level, 20, 10, 2.4, 2);
            }
            job.drill(drill, new double[][] {{10, 10}, {40, 10}}, 20, -1, 3.0);
            List<Blacksmith.Program> programs = job.gcode();
            if (programs.size() != 2 || programs.get(0).tool() != 1 || !programs.get(0).name().equals("job-T1")
                    || programs.get(1).tool() != 2 || !programs.get(1).name().equals("job-T2")
                    || !programs.get(0).text().startsWith("(cadaclysm: job-T1, T1 flat D6)\n")
                    || !programs.get(1).text().startsWith("(cadaclysm: job-T2, T2 drill D5)\n"))
                fail("job: the spec example's programs are " + programs);
            List<String> kinds = job.operations().stream().map(Blacksmith.Operation::kind).toList();
            if (!kinds.equals(List.of("face", "contour", "pocket", "drill"))) fail("job: the operations are " + kinds);
            Map<String, Double> drilled = job.operations().get(3).params();
            if (!Double.valueOf(3).equals(drilled.get("peck")) || !Double.valueOf(2).equals(drilled.get("points")))
                fail("job: the drill's params are " + job.operations().get(3));

            String root = Path.of(System.getProperty("java.io.tmpdir")).getRoot().toString();
            try {
                job.writeCamotics(root);
                fail("job: write_camotics(" + root + ") was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().equals("job_camotics: " + root + " has no file stem"))
                    fail("job: write_camotics(root) message: " + e.getMessage());
            } catch (NullPointerException e) {
                fail("job: write_camotics(root) threw NPE instead of BuildException: " + e);
            }

            try (Blacksmith.Stock stock = Blacksmith.Stock.box(new double[] {-15, -10, 0}, new double[] {15, 10, 10});
                 Blacksmith.Profile square = Blacksmith.Profile.rect(20, 10)) {
                record Refusal(Runnable make, String text) {
                }
                for (Refusal r : List.of(
                        new Refusal(() -> Blacksmith.Tool.flat(0, 6, 20, 800, 200, 12000).close(), "tool: number must be at least 1"),
                        new Refusal(() -> Blacksmith.Tool.ball(1, 6, 20, 800, 200, 12000, 91).close(), "tool: ramp angle must be in (0, 90] degrees"),
                        new Refusal(() -> Blacksmith.Stock.box(new double[] {0, 0, 0}, new double[] {0, 10, 10}).close(),
                                "stock: min must be below max on every axis, all finite"),
                        new Refusal(() -> new Blacksmith.Job(stock, 5).close(), "job: safe z must be above the stock's top"),
                        new Refusal(() -> new Blacksmith.Job(stock, 30, 0, 0.01, "job").close(), "job: clearance must be positive and finite"),
                        new Refusal(() -> new Blacksmith.Job(stock, 30, 1.0, 0.01, "a/b").close(),
                                "job: a name must be non-empty and without brackets"),
                        new Refusal(() -> new Blacksmith.Job(stock, 30, 1.0, 0.01, "a\0b").close(),
                                "job: a name must be non-empty and without brackets"))) {
                    try {
                        r.make().run();
                        fail("cam: \"" + r.text() + "\" was accepted");
                    } catch (Blacksmith.BuildException e) {
                        if (!e.getMessage().startsWith(r.text())) fail("cam: wrong message: " + e.getMessage());
                    }
                }
                try (Blacksmith.Job empty = new Blacksmith.Job(stock, 30)) {
                    record Refusal2(Runnable add, String text) {
                    }
                    for (Refusal2 r : List.of(
                            new Refusal2(() -> empty.contour(drill, square, 10, 5), "contour: a drill only drills"),
                            new Refusal2(() -> empty.drill(end, new double[][] {{0, 0}}, 10, 5), "drill: drilling needs a drill"),
                            new Refusal2(() -> empty.drill(drill, new double[0][], 10, 5), "drill: there are no points"),
                            new Refusal2(() -> empty.pocket(end, square, 10, 5, 4, 1),
                                    "pocket: stepover must be at most the tool's radius for a pocket"),
                            new Refusal2(() -> empty.face(end, 11, 3, 1), "face: z must be finite and not above the stock's top"))) {
                        try {
                            r.add().run();
                            fail("cam: \"" + r.text() + "\" was accepted");
                        } catch (Blacksmith.BuildException e) {
                            if (!e.getMessage().equals(r.text())) fail("cam: wrong message: " + e.getMessage());
                        }
                    }
                    try {
                        empty.contour(end, square, 10, 5, "left", 1.0, true, false);
                        fail("contour: side \"left\" was accepted");
                    } catch (IllegalArgumentException e) {
                        if (!e.getMessage().equals("side must be 'outside', 'inside' or 'on'")) fail("contour: wrong message: " + e.getMessage());
                    }
                    if (!empty.gcode().isEmpty()) fail("cam: a refused operation changed the job");
                    // a NUL in a CAMotics stem is refused in the kernel's words, before the library
                    try {
                        empty.writeCamotics("cadaclysm-nul/a\0b.camotics");
                        fail("write_camotics: a NUL stem was accepted");
                    } catch (Blacksmith.BuildException e) {
                        if (!e.getMessage().equals("job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |"))
                            fail("write_camotics: wrong message: " + e.getMessage());
                    }
                }
            }
            System.out.println("job: face, contour, pocket and drill by hand give two programs; every refusal in the kernel's words");
        }
    }

    // A profile's [x0, x1, y0, y1], read off the bounds of it extruded 1, at a fine tolerance.
    private static double[] footprint(Blacksmith.Profile profile) {
        try (Blacksmith.Solid solid = Blacksmith.Solid.extrude(profile, Blacksmith.Frame.xy().toArray(), 1)) {
            Blacksmith.Bounds b = solid.boundsAt(0.001);
            return new double[] {b.min()[0], b.max()[0], b.min()[1], b.max()[1]};
        }
    }

    private static boolean near(double[] a, double[] b, double tolerance) {
        if (a.length != b.length) return false;
        for (int i = 0; i < a.length; i++) if (Math.abs(a[i] - b[i]) > tolerance) return false;
        return true;
    }

    // A 40x30x10 block on z = 0 with a 20x10 pocket 8 deep: four corners a 6 mm end mill misses.
    private static Blacksmith.Solid pocketedBlock() {
        try (Blacksmith.Solid block0 = Blacksmith.Solid.cuboid(40, 30, 10);
             Blacksmith.Solid block = block0.translate(0, 0, 5);
             Blacksmith.Solid pocket0 = Blacksmith.Solid.cuboid(20, 10, 8);
             Blacksmith.Solid pocket = pocket0.translate(0, 0, 6)) {
            return block.cut(pocket);
        }
    }

    private static void deleteRecursive(Path dir) {
        if (!Files.exists(dir)) return;
        try (var stream = Files.walk(dir)) {
            stream.sorted(Comparator.reverseOrder()).forEach(p -> {
                try {
                    Files.delete(p);
                } catch (IOException ignored) {
                    // best-effort cleanup
                }
            });
        } catch (IOException ignored) {
            // best-effort cleanup
        }
    }

    // Edge curves: a cylinder's rims are circles of its radius about a cap centre in a unit
    // frame, a whole turn each; a cuboid's edges are lines whose origin + x is the far end;
    // an extruded closed spline keeps a nurbs edge with knots = poles + degree + 1.
    private static void edgeCurves() {
        try (Blacksmith.Solid cyl = Blacksmith.Solid.cylinder(5, 3);
             Blacksmith.Solid box = Blacksmith.Solid.cuboid(2, 4, 6);
             Blacksmith.Profile square = Blacksmith.Profile.spline(
                     new double[][] {{0, 0}, {10, 0}, {10, 10}, {0, 10}}, 3, null, true);
             Blacksmith.Solid loop = Blacksmith.Workplane.xy().extrude(square, 2).solid()) {
            List<Blacksmith.Curve> rims = cyl.edges().stream()
                    .filter(e -> e.kind().equals("circle")).map(Blacksmith.Edge::curve).toList();
            if (rims.size() < 2 || rims.stream().anyMatch(c -> c == null)) fail("edge_curve: the cylinder's rims have no curve");
            for (Blacksmith.Curve c : rims) {
                boolean unit = Math.abs(norm(c.x()) - 1) < 1e-9 && Math.abs(norm(c.y()) - 1) < 1e-9
                        && Math.abs(c.x()[0] * c.y()[0] + c.x()[1] * c.y()[1] + c.x()[2] * c.y()[2]) < 1e-9;
                boolean centred = Math.abs(c.origin()[0]) < 1e-9 && Math.abs(c.origin()[1]) < 1e-9
                        && Math.min(Math.abs(c.origin()[2]), Math.abs(c.origin()[2] - 3)) < 1e-9;
                if (!c.kind().equals("circle") || Math.abs(c.radius() - 5) > 1e-9 || !unit || !centred
                        || Math.abs(Math.abs(c.t1() - c.t0()) - 2 * Math.PI) > 1e-9
                        || c.degree() != 0 || c.knots().length != 0 || c.weights() != null)
                    fail("edge_curve: a rim reads " + c);
            }
            for (Blacksmith.Edge e : box.edges()) {
                Blacksmith.Curve c = e.curve();
                if (c == null || !c.kind().equals("line") || c.t0() != 0 || c.t1() != 1) fail("edge_curve: a cuboid edge reads " + c);
                double[] far = {c.origin()[0] + c.x()[0], c.origin()[1] + c.x()[1], c.origin()[2] + c.x()[2]};
                boolean atOrigin = false, atFar = false;
                for (Blacksmith.Edge.Segment s : e.segments()) {
                    for (double[] p : new double[][] {s.a(), s.b()}) {
                        atOrigin |= norm(new double[] {p[0] - c.origin()[0], p[1] - c.origin()[1], p[2] - c.origin()[2]}) < 1e-9;
                        atFar |= norm(new double[] {p[0] - far[0], p[1] - far[1], p[2] - far[2]}) < 1e-9;
                    }
                }
                if (!atOrigin || !atFar) fail("edge_curve: a cuboid line's ends are not its own vertices: " + c);
            }
            List<Blacksmith.Curve> splines = loop.edges().stream()
                    .filter(e -> e.kind().equals("nurbs")).map(Blacksmith.Edge::curve).toList();
            if (splines.isEmpty()) fail("edge_curve: the extruded spline keeps no nurbs edge");
            for (Blacksmith.Curve c : splines) {
                if (!c.kind().equals("nurbs") || c.degree() != 3
                        || c.knots().length != c.poles().length / 3 + c.degree() + 1 || c.weights() != null)
                    fail("edge_curve: the spline edge reads " + c);
            }
            System.out.println("edge_curve: " + rims.get(0) + "; " + box.edges().get(0).curve() + "; " + splines.get(0));
        }
    }

    // Intersect: two equal pipes crossing at right angles meet on ellipse chains whose points
    // lie on both pipes; apart, nothing; a zero tolerance refused in the kernel's words. Two
    // coaxial pipes overlapping in height share a wall band: an overlap whose rings lie on it.
    private static void intersections() {
        double tol = 1e-3;
        try (Blacksmith.Solid pipeA = Blacksmith.Solid.cylinder(1, 6);
             Blacksmith.Solid upright = Blacksmith.Solid.cylinder(1, 6);
             Blacksmith.Solid pipeB = upright.rotate(new double[] {0, 0, 3, 1, 0, 0}, Math.PI / 2);
             Blacksmith.Solid far = pipeB.translate(10, 0, 0);
             Blacksmith.Solid lower = Blacksmith.Solid.cylinder(1, 4);
             Blacksmith.Solid base = Blacksmith.Solid.cylinder(1, 4);
             Blacksmith.Solid upper = base.translate(0, 0, 2)) {
            Blacksmith.Intersection found = pipeA.intersect(pipeB, tol);
            if (found.chains().size() < 2 || !found.overlaps().isEmpty()) fail("intersect: the crossed pipes read " + found);
            int ellipses = 0;
            for (Blacksmith.Chain c : found.chains()) {
                if (c.faceA() < 0 || c.faceA() >= pipeA.faces() || c.faceB() < 0 || c.faceB() >= pipeB.faces() || c.points().length < 2)
                    fail("intersect: a chain reads " + c);
                for (double[] p : c.points())
                    if (offA(p) > 50 * tol || offB(p) > 50 * tol) fail("intersect: a chain leaves the pipes: " + c);
                Blacksmith.Curve curve = c.curve();
                if (curve == null) continue;
                if (!curve.kind().equals("ellipse") && !curve.kind().equals("nurbs")) fail("intersect: a chain's curve reads " + curve);
                if (!curve.kind().equals("ellipse")) continue;
                ellipses++;
                double t = (curve.t0() + curve.t1()) / 2;
                double[] q = new double[3];
                for (int k = 0; k < 3; k++)
                    q[k] = curve.origin()[k] + curve.x()[k] * curve.radius() * Math.cos(t) + curve.y()[k] * curve.radius2() * Math.sin(t);
                if (offA(q) > 50 * tol || offB(q) > 50 * tol) fail("intersect: the ellipse leaves the pipes at " + curve);
            }
            if (ellipses == 0) fail("intersect: two equal pipes cross on ellipses");
            Blacksmith.Intersection apart = pipeA.intersect(far);
            if (!apart.chains().isEmpty() || !apart.overlaps().isEmpty()) fail("intersect: pipes apart read " + apart);
            try {
                pipeA.intersect(pipeB, 0.0);
                fail("intersect: a zero tolerance was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().contains("intersect: tolerance must be positive and finite")) throw e;
            }
            Blacksmith.Intersection shared = lower.intersect(upper, tol);
            if (shared.overlaps().isEmpty() || shared.overlaps().get(0).loops().length < 1) fail("intersect: the coaxial pipes read " + shared);
            for (double[][] ring : shared.overlaps().get(0).loops()) {
                if (ring.length < 3) fail("intersect: an overlap ring is not a polygon: " + shared.overlaps().get(0));
                for (double[] p : ring)
                    if (offA(p) > 50 * tol || p[2] < 2 - 50 * tol || p[2] > 4 + 50 * tol)
                        fail("intersect: an overlap ring leaves the shared band: " + shared.overlaps().get(0));
            }
            System.out.println("intersect: " + found + " (" + ellipses + " ellipses); " + shared.overlaps().get(0));
        }
    }

    // The collider: two cuboids overlapping by 2 along x, plus one far away -> one hit (0, 1),
    // depth 2, solid() non-null.
    private static void collider() {
        double[] xy0 = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
        try (Blacksmith.Solid partA = Blacksmith.Solid.cuboid(4, 4, 4);
             Blacksmith.Solid partB = Blacksmith.Solid.cuboid(4, 4, 4).translate(2, 0, 0);
             Blacksmith.Solid partC = Blacksmith.Solid.cuboid(4, 4, 4).translate(100, 0, 0)) {
            Blacksmith.Box boxA = partA.boundsBox();
            Blacksmith.Box boxB = partB.boundsBox();
            if (!boxA.overlaps(boxB)) fail("collider: the two overlapping cuboids' bounds boxes do not overlap");
            try (Blacksmith.Collider collider = new Blacksmith.Collider(new Blacksmith.Solid[] {partA, partB, partC})) {
                if (collider.groupCount() != 3) fail("collider: the group count is not one per part");
                List<Blacksmith.CollisionHit> hits = collider.check(new double[][] {xy0, xy0, xy0});
                if (hits.size() != 1) fail("collider: found other than one hit: " + hits);
                Blacksmith.CollisionHit hit = hits.get(0);
                if (hit.a != 0 || hit.b != 1) fail("collider: the hit does not name parts 0 and 1: " + hit);
                if (!hit.overlap || !"overlap".equals(hit.kind) || !hit.text.isEmpty())
                    fail("collider: the hit is not a clean overlap: " + hit);
                if (Math.abs(hit.depth - 2.0) > 1e-9) fail("collider: the hit's depth is not exactly 2: " + hit);
                try (Blacksmith.Solid overlapSolid = hit.solid()) {
                    if (overlapSolid.faces() == 0) fail("collider: the hit's rebuilt solid has no faces");
                }
                Blacksmith.ColliderStats stats = collider.stats();
                if (stats.considered() != 3) fail("collider: the stats do not consider all three pairs: " + stats);
                System.out.println("collider: " + hits.size() + " hit(s), depth " + hit.depth + ", " + stats);
            }
            try (Blacksmith.Collider shortGroups =
                    new Blacksmith.Collider(new Blacksmith.Solid[] {partA, partB, partC}, 0.05, new int[] {0, 1}, null)) {
                fail("collider: a short groups list was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().contains("groups must have one entry per solid")) throw e;
            }
        }
    }

    // ---- the SubD cage (The Kiln, Plan 2b): Python's test_subd_*, one for one -------------------

    private static void subdRefused(String what, Runnable call, String exact, String contains, String prefix) {
        try {
            call.run();
        } catch (Blacksmith.BuildException e) {
            String m = e.getMessage();
            if (exact != null && !exact.equals(m)) fail("subd: " + what + " reads \"" + m + "\", not \"" + exact + "\"");
            if (contains != null && (m == null || !m.contains(contains))) fail("subd: " + what + " reads \"" + m + "\", without \"" + contains + "\"");
            if (prefix != null && (m == null || !m.startsWith(prefix))) fail("subd: " + what + " reads \"" + m + "\", not starting \"" + prefix + "\"");
            return;
        }
        fail("subd: " + what + " was accepted");
    }

    private static void subdClosed(String what, Runnable call) {
        try {
            call.run();
        } catch (IllegalStateException e) {
            if (!"subd: closed".equals(e.getMessage())) fail("subd: " + what + " after close reads \"" + e.getMessage() + "\"");
            return;
        }
        fail("subd: " + what + " after close was accepted");
    }

    private static final double[] SUBD_ROT = {0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    private static final double[] SUBD_SHIFT = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 0, 0, 1};

    private static void subd() throws IOException {
        // 1: the unit cuboid and its parts; the read-back is a copy; from_parts is the inverse.
        try (Blacksmith.Subd c = Blacksmith.Subd.cuboid()) {
            double[] p = c.positions();
            int[][] f = c.faces();
            if (p.length != 24 || f.length != 6) fail("subd: cuboid has " + p.length / 3 + " positions and " + f.length + " faces");
            for (int[] face : f) if (face.length != 4) fail("subd: a cuboid face has " + face.length + " vertices");
            if (!c.creases().isEmpty() || c.pins().length != 0 || c.symmetry().isPresent() || c.selection().isPresent())
                fail("subd: a fresh cuboid has creases, pins, symmetry or a selection");
            p[0] = 99;
            if (c.positions()[0] == 99) fail("subd: writing to the positions changed the cage");
            try (Blacksmith.Subd again = Blacksmith.Subd.fromParts(c.positions(), f)) {
                if (!Arrays.equals(again.positions(), c.positions()) || !Arrays.deepEquals(again.faces(), f))
                    fail("subd: from_parts did not give the cage back");
            }
            // 2: extrude returns a new cage; the input is as it was.
            try (Blacksmith.Subd e = c.extrude(new int[] {1}, 1)) {
                if (e.positions().length != 36) fail("subd: extrude has " + e.positions().length / 3 + " positions, not 12");
                SelectionCheck.faces(e, 1);
                if (c.positions().length != 24) fail("subd: extrude changed its input");
            }
            // 3: creases, pins, and both set off again.
            try (Blacksmith.Subd cr = c.crease(List.of(new Blacksmith.SubdEdge(0, 1)));
                 Blacksmith.Subd both = cr.pin(new int[] {6});
                 Blacksmith.Subd kept = Blacksmith.Subd.fromParts(both.positions(), both.faces(), both.creases(), both.pins(), null);
                 Blacksmith.Subd offCrease = both.crease(List.of(new Blacksmith.SubdEdge(0, 1)), false);
                 Blacksmith.Subd offPin = both.pin(new int[] {6}, false)) {
                SelectionCheck.edges(cr, new Blacksmith.SubdEdge(0, 1));
                if (!cr.creases().equals(List.of(new Blacksmith.SubdEdge(0, 1)))) fail("subd: crease reads " + cr.creases());
                if (!both.creases().equals(List.of(new Blacksmith.SubdEdge(0, 1))) || !Arrays.equals(both.pins(), new int[] {6}))
                    fail("subd: crease then pin reads " + both.creases() + " and " + Arrays.toString(both.pins()));
                SelectionCheck.vertices(both, 6);
                if (!kept.creases().equals(both.creases()) || !Arrays.equals(kept.pins(), both.pins())) fail("subd: from_parts dropped creases or pins");
                if (!offCrease.creases().isEmpty()) fail("subd: crease on=false left " + offCrease.creases());
                if (offPin.pins().length != 0) fail("subd: pin on=false left " + Arrays.toString(offPin.pins()));
            }
            // 6: transform.
            try (Blacksmith.Subd all = c.transform(Blacksmith.SubdSelection.ofVertices(0, 1, 2, 3, 4, 5, 6, 7), SUBD_ROT);
                 Blacksmith.Subd one = c.transform(Blacksmith.SubdSelection.ofVertices(0), SUBD_ROT);
                 Blacksmith.Subd edge = c.transform(Blacksmith.SubdSelection.ofEdges(new Blacksmith.SubdEdge(0, 1)), SUBD_SHIFT)) {
                double[] was = c.positions(), now = all.positions(), moved = one.positions(), slid = edge.positions();
                for (int v = 0; v < 8; v++) {
                    double x = was[3 * v], y = was[3 * v + 1], z = was[3 * v + 2];
                    if (Math.abs(now[3 * v] + y) > 1e-12 || Math.abs(now[3 * v + 1] - x) > 1e-12 || Math.abs(now[3 * v + 2] - z) > 1e-12)
                        fail("subd: the rotation did not map vertex " + v + " to (-y, x, z)");
                    boolean same = moved[3 * v] == x && moved[3 * v + 1] == y && moved[3 * v + 2] == z;
                    if (v == 0 ? same : !same) fail("subd: transforming vertex 0 alone moved vertex " + v + " or not vertex 0");
                }
                if (Math.abs(slid[0] - (was[0] + 3)) > 1e-12 || slid[1] != was[1] || slid[2] != was[2]) fail("subd: the edge shift is not exactly 3 in x");
                SelectionCheck.edges(edge, new Blacksmith.SubdEdge(0, 1));
            }
            subdRefused("a 3-number matrix",
                    () -> c.transform(Blacksmith.SubdSelection.ofVertices(0), new double[] {1, 2, 3}), null, "matrix", null);
            // 7: inset and insert_loop.
            try (Blacksmith.Subd inset = c.inset(new int[] {1}, 0.25);
                 Blacksmith.Subd loop = c.insertLoop(new Blacksmith.SubdEdge(0, 1))) {
                if (inset.faces().length != 10) fail("subd: inset has " + inset.faces().length + " faces, not 10");
                if (loop.positions().length != 36) fail("subd: insert_loop has " + loop.positions().length / 3 + " positions, not 12");
                if (loop.selection().orElseThrow().kind() != Blacksmith.SubdElements.EDGES) fail("subd: insert_loop selects " + loop.selection());
            }
            subdRefused("insert_loop at 1.5", () -> c.insertLoop(new Blacksmith.SubdEdge(0, 1), 1.5), null, null, "bad selection: ");
            // 5: a diagonal is no edge, nor is a stranger.
            int[] f0 = f[0];
            if (!c.edgeLoop(new Blacksmith.SubdEdge(f0[0], f0[2])).isEmpty()) fail("subd: a face diagonal has an edge loop");
            if (!c.edgeLoop(new Blacksmith.SubdEdge(0, 99)).isEmpty()) fail("subd: edge (0, 99) has an edge loop");
            // 9: pick.
            {
                Blacksmith.SubdMesh m = c.smoothMesh(3);
                double[] pos6 = c.positions();
                int best = 0;
                double bestD = Double.MAX_VALUE;
                for (int v = 0; v < m.positions().length / 3; v++) {
                    double d = 0;
                    for (int k = 0; k < 3; k++) d += Math.pow(m.positions()[3 * v + k] - pos6[18 + k], 2);
                    if (d < bestD) {
                        bestD = d;
                        best = v;
                    }
                }
                double[] near = Arrays.copyOfRange(m.positions(), 3 * best, 3 * best + 3);
                Blacksmith.SubdSelection v = c.pick(near, Blacksmith.SubdElements.VERTICES).orElseThrow();
                if (v.kind() != Blacksmith.SubdElements.VERTICES || !Arrays.equals(v.ids(), new int[] {6})) fail("subd: pick vertex reads " + v);
                Blacksmith.SubdSelection e = c.pick(near, Blacksmith.SubdElements.EDGES).orElseThrow();
                if (e.kind() != Blacksmith.SubdElements.EDGES || e.edges().size() != 1 || (e.edges().get(0).a() != 6 && e.edges().get(0).b() != 6))
                    fail("subd: pick edge reads " + e);
                Blacksmith.SubdSelection fa = c.pick(near, Blacksmith.SubdElements.FACES).orElseThrow();
                if (fa.kind() != Blacksmith.SubdElements.FACES || fa.ids().length != 1 || fa.ids()[0] < 0 || fa.ids()[0] >= 6)
                    fail("subd: pick face reads " + fa);
                if (c.pick(new double[] {100, 100, 100}, Blacksmith.SubdElements.VERTICES).isPresent()) fail("subd: a far point picked something");
                subdRefused("a NaN pick", () -> c.pick(new double[] {Double.NaN, 0, 0}, Blacksmith.SubdElements.VERTICES),
                        "bad selection: pick: point is not finite", null, null);
                if (c.pick(new double[] {100, 100, 100}, Blacksmith.SubdElements.VERTICES).isPresent()) fail("subd: a far point after a refusal picked something");
            }
        }
        // 4: mirror.
        try (Blacksmith.Subd whole = Blacksmith.Subd.cuboid(new double[] {2, 2, 2}, new int[] {2, 1, 1});
             Blacksmith.Subd half = whole.mirrorOn(Blacksmith.SubdAxis.X);
             Blacksmith.Subd back = Blacksmith.Subd.fromParts(half.positions(), half.faces(), half.creases(), half.pins(), half.symmetry().orElseThrow());
             Blacksmith.Subd full = half.full();
             Blacksmith.Subd off = half.mirrorOff()) {
            Blacksmith.SubdSymmetry s = half.symmetry().orElseThrow();
            if (s.axis() != Blacksmith.SubdAxis.X || !(s.tolerance() > 0)) fail("subd: mirror_on symmetry reads " + s);
            if (half.selection().isPresent()) fail("subd: mirror_on selects " + half.selection());
            if (half.positions().length >= whole.positions().length) fail("subd: the mirrored half is not smaller than the whole");
            if (!Arrays.equals(back.positions(), half.positions()) || !back.symmetry().equals(half.symmetry())) fail("subd: from_parts dropped the symmetry");
            if (full.positions().length != whole.positions().length) fail("subd: full has " + full.positions().length / 3 + " positions");
            if (off.symmetry().isPresent()) fail("subd: mirror_off left a symmetry");
        }
        // 5: an edge loop round a 2x2x2 cuboid.
        try (Blacksmith.Subd grid = Blacksmith.Subd.cuboid(new double[] {2, 2, 2}, new int[] {2, 2, 2})) {
            int[] f0 = grid.faces()[0];
            List<Blacksmith.SubdEdge> loop = grid.edgeLoop(new Blacksmith.SubdEdge(f0[0], f0[1]));
            if (loop.size() < 4) fail("subd: the edge loop has " + loop.size() + " edges");
            if (!loop.get(0).equals(new Blacksmith.SubdEdge(Math.min(f0[0], f0[1]), Math.max(f0[0], f0[1]))))
                fail("subd: the loop's first edge is " + loop.get(0));
        }
        // 8: the smooth mesh, and its life past the cage.
        Blacksmith.SubdMesh kept;
        try (Blacksmith.Subd c = Blacksmith.Subd.cuboid()) {
            Blacksmith.SubdMesh two = c.smoothMesh(2);
            int n = two.positions().length / 3;
            if (n <= 8 || two.normals().length != 3 * n) fail("subd: smooth_mesh(2) has " + n + " positions and " + two.normals().length / 3 + " normals");
            for (int v = 0; v < n; v++) {
                double len = Math.sqrt(Math.pow(two.normals()[3 * v], 2) + Math.pow(two.normals()[3 * v + 1], 2) + Math.pow(two.normals()[3 * v + 2], 2));
                if (Math.abs(len - 1) > 1e-9) fail("subd: normal " + v + " has length " + len);
            }
            for (int i : two.indices()) if (i < 0 || i >= n) fail("subd: an index " + i + " is past the " + n + " positions");
            if (two.triangleFace().length != two.indices().length / 3) fail("subd: triangle_face has " + two.triangleFace().length + " entries");
            for (int tf : two.triangleFace()) if (tf < 0 || tf >= 6) fail("subd: a triangle names face " + tf);
            if (c.smoothMesh(1).positions().length >= two.positions().length) fail("subd: smooth_mesh(1) is not smaller than smooth_mesh(2)");
            if (!Arrays.equals(c.smoothMesh(2).positions(), two.positions())) fail("subd: a second smooth_mesh(2) differs");
            subdRefused("smooth_mesh(7)", () -> c.smoothMesh(7), null, "levels", null);
            kept = c.smoothMesh(2);
        }
        System.gc();
        if (kept.positions().length == 0 || kept.normals().length != kept.positions().length
                || kept.triangleFace().length != kept.indices().length / 3)
            fail("subd: a mesh read after its cage closed is not whole");
        double checkSum = 0;
        for (double x : kept.positions()) checkSum += Math.abs(x);
        if (!(checkSum > 0)) fail("subd: a mesh read after its cage closed is all zeros");
        // 10, 15: to_solid and its report; the pipeline and its STEP.
        try (Blacksmith.Subd c = Blacksmith.Subd.cuboid()) {
            Blacksmith.SubdSolid made = c.toSolid();
            try (Blacksmith.Solid solid = made.solid()) {
                Blacksmith.SubdReport r = made.report();
                if (r.regular() != 0 || r.refined() != 24 || r.levels() < 2 || r.steps() < 1 || r.deviation() > 1e-4 || r.g1AngleDeg() > 0.1
                        || r.deviationAt().length != 3 || r.g1At().length != 3)
                    fail("subd: the cuboid's report reads " + r);
                if (!solid.manifold().isClosed()) fail("subd: the solid is not closed");
                if (!(solid.mass(0).volume() > 0)) fail("subd: the solid has no volume");
            }
            try (Blacksmith.Solid again = c.toSolid(1e-4, 0.1, 6).solid()) {
                if (again.faces() == 0) fail("subd: to_solid(1e-4, 0.1, 6) has no faces");
            }
        }
        try (Blacksmith.Subd base = Blacksmith.Subd.cuboid();
             Blacksmith.Subd out = base.extrude(new int[] {1}, 0.5);
             Blacksmith.Subd in = out.inset(new int[] {1}, 0.25)) {
            Blacksmith.SubdSolid made = in.toSolid();
            try (Blacksmith.Solid solid = made.solid()) {
                if (!solid.manifold().isClosed() || made.report().deviation() > 1e-4) fail("subd: the pipeline's solid " + made.report());
                String step = solid.stepText();
                if (!step.startsWith("ISO-10303-21;") || !step.contains("ADVANCED_FACE")) fail("subd: the pipeline's STEP text is not STEP");
                try (Cad.Scene scene = Cad.openMemory(step.getBytes(java.nio.charset.StandardCharsets.UTF_8), "subd.stp", "stp")) {
                    int meshable = 0;
                    for (Cad.Node node : scene.nodes()) {
                        Cad.Mesh mesh = node.mesh();
                        if (mesh != null && mesh.positions() != null) meshable++;
                    }
                    if (meshable != 1) fail("subd: the STEP text reads back as " + meshable + " meshable nodes");
                }
            }
        }
        // 11, 12: the creased rim is what converts.
        try (Blacksmith.Subd bare = Blacksmith.Subd.cylinder(1, 2, 8, 1, false)) {
            try {
                bare.toSolid();
                fail("subd: the uncreased cylinder was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().matches("(?s).*subd:.*tangent break.*")) fail("subd: the uncreased cylinder was refused as \"" + e.getMessage() + "\"");
            }
        }
        try (Blacksmith.Subd cyl = Blacksmith.Subd.cylinder()) {
            Blacksmith.SubdSolid made = null;
            try {
                made = cyl.toSolid();
            } catch (Blacksmith.BuildException e) {
                fail("subd: the default cylinder (rims creased by default) does not convert: " + e.getMessage());
            }
            made.solid().close();
            if (made.report().deviation() > 1e-4 || made.report().g1AngleDeg() > 0.1) fail("subd: the default cylinder's report " + made.report());
        }
        // 13: the other primitives, and their refusals.
        try (Blacksmith.Subd a = Blacksmith.Subd.cylinder(1, 2, 8, 2, true);
             Blacksmith.Subd b = Blacksmith.Subd.sphere(1, 2);
             Blacksmith.Subd t = Blacksmith.Subd.torus(3, 1, 12, 8)) {
            if (a.faces().length == 0 || b.faces().length == 0 || t.faces().length == 0) fail("subd: a primitive has no faces");
        }
        subdRefused("a cuboid of 0 segments", () -> Blacksmith.Subd.cuboid(new double[] {2, 2, 2}, new int[] {0, 1, 1}),
                "bad selection: cuboid: segments >= 1", null, null);
        subdRefused("a sphere of 2000 segments", () -> Blacksmith.Subd.sphere(1, 2000), null, "1024", null);
        subdRefused("a negative segment count", () -> Blacksmith.Subd.sphere(1, -1), null, "segments", null);
        // 14: from_parts refusals.
        subdRefused("a crease that is no edge", () -> {
            try (Blacksmith.Subd c = Blacksmith.Subd.cuboid();
                 Blacksmith.Subd bad = Blacksmith.Subd.fromParts(c.positions(), c.faces(), List.of(new Blacksmith.SubdEdge(0, 6)), new int[0], null)) {
                bad.close();
            }
        }, null, null, "bad selection: ");
        subdRefused("no positions", () -> Blacksmith.Subd.fromParts(new double[0], new int[0][]), null, "vertex_count", null);
        subdRefused("a negative id", () -> {
            try (Blacksmith.Subd c = Blacksmith.Subd.cuboid(); Blacksmith.Subd bad = c.extrude(new int[] {-1}, 1)) {
                bad.close();
            }
        }, null, "extrude faces", null);
        // 16: close, twice, and use after close.
        Blacksmith.Subd closed = Blacksmith.Subd.cuboid();
        closed.close();
        closed.close();
        if (!closed.closed()) fail("subd: a closed cage is not closed");
        subdClosed("positions", closed::positions);
        subdClosed("extrude", () -> closed.extrude(new int[] {1}, 1));
        subdClosed("smooth_mesh", closed::smoothMesh);
        subdClosed("pick", () -> closed.pick(new double[] {0, 0, 0}, Blacksmith.SubdElements.VERTICES));
        subdClosed("to_solid", closed::toSolid);
        System.out.println("subd: the cage, its edits, picks, smooth mesh and conversion all read as Python's");
    }

    /** What a cage says it selected. */
    private static final class SelectionCheck {
        static void faces(Blacksmith.Subd cage, int... want) {
            Blacksmith.SubdSelection s = cage.selection().orElse(null);
            if (s == null || s.kind() != Blacksmith.SubdElements.FACES || !Arrays.equals(s.ids(), want))
                fail("subd: selection reads " + s + ", not faces " + Arrays.toString(want));
            Blacksmith.SubdSelection same = Blacksmith.SubdSelection.ofFaces(want);
            if (!s.equals(same) || s.hashCode() != same.hashCode())
                fail("subd: a selection read back is not equal to " + same);
            if (s.equals(Blacksmith.SubdSelection.ofVertices(want)))
                fail("subd: selections of different kinds compare equal");
        }

        static void vertices(Blacksmith.Subd cage, int... want) {
            Blacksmith.SubdSelection s = cage.selection().orElse(null);
            if (s == null || s.kind() != Blacksmith.SubdElements.VERTICES || !Arrays.equals(s.ids(), want))
                fail("subd: selection reads " + s + ", not vertices " + Arrays.toString(want));
        }

        static void edges(Blacksmith.Subd cage, Blacksmith.SubdEdge... want) {
            Blacksmith.SubdSelection s = cage.selection().orElse(null);
            if (s == null || s.kind() != Blacksmith.SubdElements.EDGES || !s.edges().equals(List.of(want)))
                fail("subd: selection reads " + s + ", not edges " + Arrays.toString(want));
            if (!s.equals(Blacksmith.SubdSelection.ofEdges(want)))
                fail("subd: an edge selection read back is not equal to " + Blacksmith.SubdSelection.ofEdges(want));
        }
    }

    // Solid x profile hits: a line through a cuboid pierces two faces and is cut into three
    // pieces, outside/inside/outside, the middle one spanning the box and sweeping; a loop no
    // hit cuts is one piece; an open sheet has no pieces; a zero tolerance refused verbatim.
    private static void solidHits() {
        double[] xy = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
        try (Blacksmith.Solid box = Blacksmith.Solid.cuboid(10, 20, 30);
             Blacksmith.Profile line = Blacksmith.Profile.path(new double[] {-20, 0}).lineTo(20, 0).endOpen();
             Blacksmith.Profile circle = Blacksmith.Profile.circle(1);
             Blacksmith.Profile square = Blacksmith.Profile.rect(20, 20);
             Blacksmith.Solid flat = Blacksmith.Solid.face(square, xy);
             Blacksmith.Profile upright = Blacksmith.Profile.path(new double[] {0, -20}).lineTo(0, 20).endOpen()) {
            Blacksmith.SolidHits found = box.hits(line, xy);
            if (found.hits().size() != 2 || found.pieces().size() != 3) fail("solid hits: a line through a cuboid reads " + found);
            for (int k = 0; k < 2; k++) {
                Blacksmith.Hit h = found.hits().get(k);
                if (h.run() || h.touch() || Math.abs(h.start()[0] - (k == 0 ? -5 : 5)) > 0.05 || h.aStart().segment() != 0
                        || h.aStart().face() != -1 || h.bStart().face() == -1
                        || !Double.isFinite(h.bStart().u()) || !Double.isFinite(h.bStart().v()))
                    fail("solid hits: hit " + k + " reads " + h + " (" + h.aStart() + ", " + h.bStart() + ")");
            }
            List<Blacksmith.Piece> p = found.pieces();
            if (p.get(0).inside() || !p.get(1).inside() || p.get(2).inside()) fail("solid hits: the pieces read " + p);
            if (p.get(0).start().t() != 0 || p.get(2).end().t() != 1 || p.get(0).end().t() != p.get(1).start().t()
                    || p.get(1).end().t() != p.get(2).start().t())
                fail("solid hits: the pieces do not run head to tail: " + p);
            try (Blacksmith.Solid middle = Blacksmith.Solid.extrudeOpen(p.get(1).profile(), xy, 1);
                 Blacksmith.SweepPath along = Blacksmith.SweepPath.along(p.get(1).profile(), xy, 0.05, true)) {
                Blacksmith.Bounds b = middle.bounds();
                if (Math.abs(b.min()[0] + 5) > 0.05 || Math.abs(b.max()[0] - 5) > 0.05)
                    fail("solid hits: the middle piece spans x " + b.min()[0] + " .. " + b.max()[0] + ", not the box");
            }
            for (Blacksmith.Piece piece : p) piece.profile().close();
            Blacksmith.SolidHits far = box.hits(circle, new double[] {100, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1});
            if (!far.hits().isEmpty() || far.pieces().size() != 1 || far.pieces().get(0).inside()) fail("solid hits: a circle far off reads " + far);
            Blacksmith.SolidHits across = flat.hits(upright, new double[] {0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0});
            if (across.hits().isEmpty() || !across.pieces().isEmpty()) fail("solid hits: a line across a sheet reads " + across);
            try {
                box.hits(line, xy, 0.0);
                fail("solid hits: a zero tolerance was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().equals("solid_profile_hits: tolerance must be positive and finite")) throw e;
            }
            System.out.println("solid hits: " + found + "; " + p.get(1));
        }
    }

    /** How far {@code p} is off the pipe up z (radius 1). */
    private static double offA(double[] p) {
        return Math.abs(Math.sqrt(p[0] * p[0] + p[1] * p[1]) - 1);
    }

    /** How far {@code p} is off the pipe along y through (0, 0, 3) (radius 1). */
    private static double offB(double[] p) {
        return Math.abs(Math.sqrt(p[0] * p[0] + (p[2] - 3) * (p[2] - 3)) - 1);
    }

    private static double norm(double[] v) {
        return Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    }

    // Assemblies: Assembly, Solid.named and Solid.name, at parity with the Python reference's
    // _shared_assembly() and the tests built on it.
    private static void assemblies() {
        try (Blacksmith.Solid asmBolt = Blacksmith.Solid.cylinder(1, 6).named("bolt");
             Blacksmith.Solid asmPlate = Blacksmith.Solid.cuboid(20, 10, 2).named("plate").coloured(1, 0.5, 0);
             Blacksmith.Assembly bracket = new Blacksmith.Assembly("bracket")) {
            String platePlacement = bracket.place(asmPlate, Blacksmith.Frame.xy().toArray());
            String bolt1Placement = bracket.place(asmBolt, Blacksmith.Frame.xy(new double[] {5, 5, 2}).toArray());
            String bolt2Placement = bracket.place(asmBolt, Blacksmith.Frame.xy(new double[] {15, 5, 2}).toArray());
            if (!platePlacement.equals("plate") || !bolt1Placement.equals("bolt") || !bolt2Placement.equals("bolt 2"))
                fail("assembly: bracket placements were \"" + platePlacement + "\", \"" + bolt1Placement + "\", \"" + bolt2Placement + "\", not plate/bolt/bolt 2");

            try (Blacksmith.Assembly asmFrame = new Blacksmith.Assembly("frame")) {
                String leftPlacement = asmFrame.place(bracket, Blacksmith.Frame.xy(new double[] {0, 0, 0}).toArray(), "left");
                String rightPlacement = asmFrame.place(bracket,
                        new Blacksmith.Frame(new double[] {100, 0, 0}, new double[] {0, 1, 0}, new double[] {-1, 0, 0}, new double[] {0, 0, 1}).toArray(),
                        "right");
                String rootBoltPlacement = asmFrame.place(asmBolt, Blacksmith.Frame.xy(new double[] {50, 50, 0}).toArray());
                if (!leftPlacement.equals("left") || !rightPlacement.equals("right") || !rootBoltPlacement.equals("bolt"))
                    fail("assembly: frame placements were \"" + leftPlacement + "\", \"" + rightPlacement + "\", \"" + rootBoltPlacement + "\", not left/right/bolt");

                String frameStepText = asmFrame.stepText();
                int manifoldCount = countOf(frameStepText, "=MANIFOLD_SOLID_BREP(");
                int productCount = countOf(frameStepText, "=PRODUCT(");
                int nauoCount = countOf(frameStepText, "=NEXT_ASSEMBLY_USAGE_OCCURRENCE(");
                if (manifoldCount != 2 || productCount != 4 || nauoCount != 6)
                    fail("assembly: frame step_text has " + manifoldCount + " breps, " + productCount + " products, " + nauoCount + " NAUOs, not 2/4/6");
                if (!frameStepText.contains("'left'") || !frameStepText.contains("'right'") || !frameStepText.contains("'bolt 2'"))
                    fail("assembly: frame step_text is missing 'left', 'right' or 'bolt 2'");
                System.out.println("assembly: frame writes " + manifoldCount + " breps, " + productCount + " products, " + nauoCount + " NAUOs");

                // Read-back, through the same reader door as Solid.toScene -- structure only, at
                // this (pre-late-placement) text: one root "frame", two "bracket" containers each
                // holding plate/bolt/bolt, and one root-level "bolt". The world origins are
                // Python's to check.
                try (Cad.Scene readScene = Cad.openMemory(frameStepText.getBytes(java.nio.charset.StandardCharsets.UTF_8), "frame.stp")) {
                    List<Cad.Node> roots = readScene.roots();
                    if (roots.size() != 1 || !roots.get(0).name().equals("frame")) fail("assembly: the read-back root is not one node named \"frame\"");
                    List<Cad.Node> rootChildren = roots.get(0).children();
                    if (rootChildren.size() != 3) fail("assembly: the read-back root has " + rootChildren.size() + " children, not 3");
                    List<Cad.Node> containers = rootChildren.stream().filter(c -> c.name().equals("bracket")).toList();
                    List<Cad.Node> rootBolts = rootChildren.stream().filter(c -> c.name().equals("bolt")).toList();
                    if (containers.size() != 2 || rootBolts.size() != 1)
                        fail("assembly: the read-back root does not have two bracket containers and one bolt");
                    for (Cad.Node container : containers) {
                        List<String> names = container.children().stream().map(Cad.Node::name).sorted().toList();
                        if (!names.equals(List.of("bolt", "bolt", "plate")))
                            fail("assembly: a read-back bracket container does not hold plate, bolt, bolt");
                    }
                }
                System.out.println("assembly: the read-back tree has one root, two bracket containers of plate+bolt+bolt, and one root bolt");

                // A late placement into bracket shows up wherever bracket is placed (left and
                // right both).
                bracket.place(asmBolt, Blacksmith.Frame.xy(new double[] {10, 8, 2}).toArray());
                int laterNauoCount = countOf(asmFrame.stepText(), "=NEXT_ASSEMBLY_USAGE_OCCURRENCE(");
                if (laterNauoCount != 7) fail("assembly: a late placement gave " + laterNauoCount + " NAUOs, not 7");
                System.out.println("assembly: a late placement into bracket shows up wherever it is placed");

                // A cycle, a duplicate placement name, a mirrored frame, and an assembly (or one
                // reachable from it) that places nothing are all refused.
                try {
                    bracket.place(asmFrame, Blacksmith.Frame.xy().toArray());
                    fail("assembly: a cycle (bracket -> frame -> bracket) was accepted");
                } catch (Blacksmith.BuildException e) {
                    if (e.getMessage() == null || !e.getMessage().contains("bracket → frame → bracket")) fail("assembly: cycle message: " + e.getMessage());
                }
                try {
                    asmFrame.place(bracket, Blacksmith.Frame.xy().toArray(), "left");
                    fail("assembly: a duplicate placement name was accepted");
                } catch (Blacksmith.BuildException e) {
                    if (e.getMessage() == null || !e.getMessage().contains("left")) fail("assembly: duplicate name message: " + e.getMessage());
                }
                // A raw twelve-number frame, not the Frame type, which refuses a left-handed
                // triple before place is ever called -- the one way to drive a mirrored frame
                // into the ABI's own rigidity check.
                try {
                    asmFrame.place(bracket, new double[] {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, -1});
                    fail("assembly: a mirrored raw frame was accepted");
                } catch (Blacksmith.BuildException e) {
                    if (e.getMessage() == null || !e.getMessage().contains("right-handed and orthonormal")) fail("assembly: mirrored frame message: " + e.getMessage());
                }
                try (Blacksmith.Assembly x = new Blacksmith.Assembly("x")) {
                    x.stepText();
                    fail("assembly: an empty assembly wrote step text");
                } catch (Blacksmith.BuildException expected) {
                    // the library's own refusal
                }
                try (Blacksmith.Assembly outer = new Blacksmith.Assembly("outer");
                     Blacksmith.Assembly hollow = new Blacksmith.Assembly("hollow")) {
                    outer.place(hollow, Blacksmith.Frame.xy().toArray());
                    try {
                        outer.stepText();
                        fail("assembly: an assembly reachable from the root that places nothing wrote step text");
                    } catch (Blacksmith.BuildException e) {
                        if (e.getMessage() == null || !e.getMessage().contains("hollow")) fail("assembly: empty-reachable message: " + e.getMessage());
                    }
                }
                System.out.println("assembly: a cycle, a duplicate name, a mirrored frame, and an empty assembly are all refused");
            }

            // Solid.named/Solid.name: the name rides through a one-source operation (place,
            // coloured) and is dropped by a two-source one (join) or a fresh primitive.
            if (!"bolt".equals(asmBolt.name())) fail("assembly: bolt.name() is not \"bolt\"");
            try (Blacksmith.Solid placedBolt = asmBolt.place(Blacksmith.Frame.xy(new double[] {1, 2, 3}).toArray())) {
                if (!"bolt".equals(placedBolt.name())) fail("assembly: bolt.place(...).name() is not \"bolt\"");
            }
            try (Blacksmith.Solid colouredBolt = asmBolt.coloured(1, 0, 0)) {
                if (!"bolt".equals(colouredBolt.name())) fail("assembly: bolt.coloured(...).name() is not \"bolt\"");
            }
            try (Blacksmith.Solid cube = Blacksmith.Solid.cuboid(1, 1, 1);
                 Blacksmith.Solid joinedBolt = asmBolt.join(cube)) {
                if (joinedBolt.name() != null) fail("assembly: bolt.join(...).name() is not null");
            }
            try (Blacksmith.Solid freshCube = Blacksmith.Solid.cuboid(1, 1, 1)) {
                if (freshCube.name() != null) fail("assembly: a fresh cuboid's name() is not null");
            }
            System.out.println("assembly: named()/name() ride through one-source operations and drop through two-source ones");
        }
    }

    // Assembly.link / Assembly.joint, at parity with the Python reference's _mechanism() and
    // its tests (test_a_mechanism_is_written_as_ap242_kinematic_topology,
    // test_every_bad_link_or_joint_is_refused_and_changes_nothing).
    private static void mechanism() {
        try (Blacksmith.Solid mechBolt = Blacksmith.Solid.cylinder(1, 6).named("bolt");
             Blacksmith.Solid mechPlate = Blacksmith.Solid.cuboid(20, 10, 2).named("plate"); // uncoloured
             Blacksmith.Assembly bracket = new Blacksmith.Assembly("bracket");
             Blacksmith.Assembly arm = new Blacksmith.Assembly("arm")) {
            bracket.place(mechPlate, Blacksmith.Frame.xy().toArray());
            bracket.place(mechBolt, Blacksmith.Frame.xy(new double[] {5, 5, 2}).toArray());
            bracket.place(mechBolt, Blacksmith.Frame.xy(new double[] {15, 5, 2}).toArray());
            bracket.link("fixed", "plate");
            bracket.link("bolts", "bolt", "bolt 2");
            bracket.joint("screw", "fixed", "bolts");

            arm.place(mechPlate, Blacksmith.Frame.xy().toArray(), "base");
            arm.place(bracket, Blacksmith.Frame.xy(new double[] {0, 0, 10}).toArray(), "upper");
            arm.place(mechBolt, Blacksmith.Frame.xy(new double[] {5, 5, 2}).toArray(), "pin");
            arm.link("ground", "base");
            arm.link("upper arm", "upper", "pin");
            arm.joint("shoulder", "ground", "upper arm");

            // Fact 1: the default schema (no explicit schema) carries the kinematic entities.
            String armStepText = arm.stepText();
            if (!armStepText.contains("AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"))
                fail("mechanism: arm.stepText() does not name AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF");
            int linkCount = countOf(armStepText, "=KINEMATIC_LINK(");
            int rigidCount = countOf(armStepText, "=RIGID_LINK_REPRESENTATION(");
            int cdklrCount = countOf(armStepText, "=CONTEXT_DEPENDENT_KINEMATIC_LINK_REPRESENTATION(");
            int jointCount = countOf(armStepText, "=KINEMATIC_JOINT(");
            int topoCount = countOf(armStepText, "=KINEMATIC_TOPOLOGY_STRUCTURE(");
            if (linkCount != 4 || rigidCount != 6 || cdklrCount != 6 || jointCount != 2 || topoCount != 2)
                fail("mechanism: arm.stepText() has " + linkCount + " links, " + rigidCount + " rigid reps, " + cdklrCount
                        + " context-dependent reps, " + jointCount + " joints, " + topoCount + " topologies, not 4/6/6/2/2");
            System.out.println("mechanism: arm.stepText() writes " + linkCount + " links, " + rigidCount + " rigid reps, "
                    + cdklrCount + " context-dependent reps, " + jointCount + " joints, " + topoCount + " topologies");

            // Fact 2: an explicit schema without kinematic entities is refused.
            try {
                arm.stepText("config_control_design", "mm");
                fail("mechanism: config_control_design was not refused");
            } catch (Blacksmith.BuildException e) {
                if (e.getMessage() == null || !e.getMessage().contains("no kinematic entities"))
                    fail("mechanism: config_control_design was not refused right: " + e.getMessage());
            }
            System.out.println("mechanism: an explicit schema without kinematic entities is refused");

            // Fact 3: each of the eleven refusals raises with exactly its message, and afterwards
            // the STEP text (with FILE_NAME( lines stripped) is unchanged.
            String before = noStamp(arm.stepText());
            record Refusal(Runnable call, String message) {}
            List<Refusal> refusals = List.of(
                    new Refusal(() -> arm.link("", "base"), "link: a name cannot be empty"),
                    new Refusal(() -> arm.link("ground", "base"), "link: assembly 'arm' already has a link named 'ground'"),
                    new Refusal(() -> arm.link("free"), "link: link 'free' names no placements"),
                    new Refusal(() -> arm.link("free", "base", "base"), "link: link 'free' names placement 'base' twice"),
                    new Refusal(() -> arm.link("free", "bolt"), "link: assembly 'arm' has no placement named 'bolt'"),
                    new Refusal(() -> arm.link("free", "pin"), "link: placement 'pin' of assembly 'arm' is already in link 'upper arm'"),
                    new Refusal(() -> arm.joint("", "ground", "upper arm"), "joint: a name cannot be empty"),
                    new Refusal(() -> arm.joint("shoulder", "upper arm", "ground"), "joint: assembly 'arm' already has a joint named 'shoulder'"),
                    new Refusal(() -> arm.joint("wrist", "ground", "hand"), "joint: assembly 'arm' has no link named 'hand'"),
                    new Refusal(() -> arm.joint("wrist", "ground", "ground"), "joint: joint 'wrist' joins link 'ground' to itself"),
                    new Refusal(() -> arm.joint("wrist", "ground", "upper arm"), "joint: assembly 'arm' already joins 'ground' to 'upper arm'"));
            for (Refusal r : refusals) {
                try {
                    r.call().run();
                    fail("mechanism: \"" + r.message() + "\" was accepted");
                } catch (Blacksmith.BuildException e) {
                    if (!r.message().equals(e.getMessage())) fail("mechanism: got \"" + e.getMessage() + "\", not \"" + r.message() + "\"");
                }
            }
            String after = noStamp(arm.stepText());
            if (!after.equals(before)) fail("mechanism: a refused link or joint changed the assembly");
            System.out.println("mechanism: all eleven bad links and joints are refused with their exact message, unchanged");

            // Fact 5: read-back through the reader, before fact 4 adds "back" -- arm.toScene()
            // carries the same links and joints back in, by name and node count, with no
            // kinematics diagnostic. (The Python reference checks this on a fresh
            // _mechanism() build, i.e. before the reverse-pair joint exists; done here in
            // place, ahead of fact 4, so it sees the same two joints.)
            try (Cad.Scene mechScene = arm.toScene()) {
                List<Cad.Link> mechLinks = mechScene.links();
                String[] wantNames = {"fixed", "bolts", "ground", "upper arm"};
                int[] wantNodes = {1, 2, 1, 2};
                if (mechLinks.size() != wantNames.length) fail("mechanism: read-back has " + mechLinks.size() + " links, not " + wantNames.length);
                for (int i = 0; i < mechLinks.size(); i++) {
                    Cad.Link link = mechLinks.get(i);
                    if (!link.name().equals(wantNames[i])) fail("mechanism: read-back link " + i + " is \"" + link.name() + "\", not \"" + wantNames[i] + "\"");
                    if (link.nodes().size() != wantNodes[i]) fail("mechanism: read-back link \"" + link.name() + "\" has " + link.nodes().size() + " nodes, not " + wantNodes[i]);
                }
                List<Cad.Joint> mechJoints = mechScene.joints();
                if (mechJoints.size() != 2
                        || !mechJoints.get(0).name().equals("screw") || mechJoints.get(0).start().index() != 0 || mechJoints.get(0).end().index() != 1
                        || !mechJoints.get(1).name().equals("shoulder") || mechJoints.get(1).start().index() != 2 || mechJoints.get(1).end().index() != 3)
                    fail("mechanism: read-back joints are not (screw, 0, 1) and (shoulder, 2, 3)");
                for (String d : mechScene.diagnostics())
                    if (d.startsWith("kinematics:")) fail("mechanism: read-back carries a kinematics: diagnostic");
                System.out.println("mechanism: read-back through arm.toScene() matches links, joints and diagnostics");
            }

            // Pairs: Assembly.pair/Assembly.state/Assembly.base and the static
            // Blacksmith.pairFreedomCount, at parity with the Python reference's _paired()
            // fixture and its tests (spec 2026-09-29). Built on bracket/arm before "back" is
            // added below: a joint with no pair refuses stepText(), so facts 1-6 and 9's
            // diagnostics check need arm without it.
            bracket.pair("screw", "prismatic", Blacksmith.Frame.xy(new double[] {1, 2, 3}),
                    new Blacksmith.PairOptions(Blacksmith.Frame.xy(new double[] {4, 2, 3}), null, null));
            arm.pair("shoulder", "revolute", Blacksmith.Frame.xy(new double[] {0, 0, 10}),
                    new Blacksmith.PairOptions(null, List.of(new Blacksmith.Range(-1.5, 1.5)), null));
            arm.state("reach", List.of(new Blacksmith.StateRow("shoulder", new double[] {0.5})));
            arm.base("ground");

            // Fact 1: the pair/state entity counts in the default schema.
            String pairedStepText = arm.stepText();
            int mechReprCount = countOf(pairedStepText, "=MECHANISM_REPRESENTATION(");
            int pairRelCount = countOf(pairedStepText, "=PAIR_REPRESENTATION_RELATIONSHIP(");
            int revoluteRangeCount = countOf(pairedStepText, "REVOLUTE_PAIR_WITH_RANGE");
            int prismaticCount = countOf(pairedStepText, "PRISMATIC_PAIR");
            int kinPropCount = countOf(pairedStepText, "=KINEMATIC_PROPERTY_MECHANISM_REPRESENTATION(");
            int mechStateCount = countOf(pairedStepText, "=MECHANISM_STATE_REPRESENTATION(");
            if (mechReprCount != 2 || pairRelCount != 2 || revoluteRangeCount != 1 || prismaticCount != 1
                    || kinPropCount != 1 || mechStateCount != 1)
                fail("pairs: arm.stepText() has " + mechReprCount + " mechanism reps, " + pairRelCount + " pair rels, "
                        + revoluteRangeCount + " revolute-with-range, " + prismaticCount + " prismatic, " + kinPropCount
                        + " kinematic property reps, " + mechStateCount + " mechanism states, not 2/2/1/1/1/1");
            System.out.println("pairs: arm.stepText() writes " + mechReprCount + " mechanism reps, " + pairRelCount
                    + " pair rels, " + revoluteRangeCount + " revolute-with-range, " + prismaticCount + " prismatic, "
                    + kinPropCount + " kinematic property reps, " + mechStateCount + " mechanism states");

            // Facts 2-6 and 9 (diagnostics half): read back through the reader.
            try (Cad.Scene pairedScene = arm.toScene()) {
                Cad.Joint shoulder = pairedScene.joints().stream().filter(j -> j.name().equals("shoulder")).findFirst().orElseThrow();
                Cad.Pair shoulderPair = shoulder.pair();
                if (shoulderPair == null) fail("pairs: shoulder has no pair");
                if (shoulderPair.kind() != Cad.PairKind.REVOLUTE) fail("pairs: shoulder's pair is not revolute");
                for (double[][] frame : new double[][][] {shoulderPair.frameStart(), shoulderPair.frameEnd()}) {
                    if (!close(frame[0][3], 0.0) || !close(frame[1][3], 0.0) || !close(frame[2][3], 10.0)
                            || !close(frame[0][2], 0.0) || !close(frame[1][2], 0.0) || !close(frame[2][2], 1.0))
                        fail("pairs: shoulder's pair frames are not at (0,0,10) with z (0,0,1)");
                }
                List<Cad.Freedom> shoulderFreedoms = shoulderPair.freedoms();
                if (shoulderFreedoms.size() != 1 || shoulderFreedoms.get(0).motion() != Cad.Motion.ROTATION
                        || shoulderFreedoms.get(0).axis() != Cad.FreedomAxis.Z
                        || shoulderFreedoms.get(0).lower() == null || !close(shoulderFreedoms.get(0).lower(), -1.5)
                        || shoulderFreedoms.get(0).upper() == null || !close(shoulderFreedoms.get(0).upper(), 1.5))
                    fail("pairs: shoulder's pair is not one rotation-about-z freedom ranged [-1.5, 1.5]");
                System.out.println("pairs: shoulder's pair is revolute, one rotation-about-z freedom ranged [-1.5, 1.5]");

                Cad.Joint screw = pairedScene.joints().stream().filter(j -> j.name().equals("screw")).findFirst().orElseThrow();
                Cad.Pair screwPair = screw.pair();
                if (screwPair == null) fail("pairs: screw has no pair");
                if (screwPair.kind() != Cad.PairKind.PRISMATIC) fail("pairs: screw's pair is not prismatic");
                for (Cad.Freedom f : screwPair.freedoms())
                    if (f.lower() != null || f.upper() != null) fail("pairs: screw's pair has a ranged freedom");
                if (!close(screwPair.frameStart()[0][3], 1.0) || !close(screwPair.frameStart()[1][3], 2.0) || !close(screwPair.frameStart()[2][3], 13.0)
                        || !close(screwPair.frameEnd()[0][3], 4.0) || !close(screwPair.frameEnd()[1][3], 2.0) || !close(screwPair.frameEnd()[2][3], 13.0))
                    fail("pairs: screw's pair frames are not (1,2,13) to (4,2,13)");
                System.out.println("pairs: screw's pair is prismatic with no ranges, frames (1,2,13) to (4,2,13)");

                Cad.Link pairedBase = pairedScene.base();
                if (pairedBase == null || !pairedBase.name().equals("ground")) fail("pairs: the scene's base is not 'ground'");
                List<Cad.State> pairedStates = pairedScene.states();
                if (pairedStates.size() != 1 || !pairedStates.get(0).name().equals("reach"))
                    fail("pairs: the scene does not carry exactly one state named 'reach'");
                List<Cad.StateValue> reachValues = pairedStates.get(0).values();
                if (reachValues.size() != 1 || !reachValues.get(0).joint().name().equals("shoulder")
                        || reachValues.get(0).values().length != 1 || !close(reachValues.get(0).values()[0], 0.5))
                    fail("pairs: state 'reach' is not exactly one row (shoulder, [0.5])");
                System.out.println("pairs: the scene's base is 'ground', with one state 'reach' of (shoulder, [0.5])");

                // Fact 5: poseState(reach) carries the pin node to (5cos0.5-5sin0.5, 5sin0.5+5cos0.5, 2).
                Cad.Pose reachPose = pairedScene.poseState(pairedStates.get(0));
                Cad.Link upperArmLink = pairedScene.links().stream().filter(l -> l.name().equals("upper arm")).findFirst().orElseThrow();
                Cad.Node pinNode = upperArmLink.nodes().stream()
                        .filter(n -> close(n.transform()[0][3], 5.0) && close(n.transform()[1][3], 5.0) && close(n.transform()[2][3], 2.0))
                        .findFirst().orElseThrow();
                double[][] posedPin = reachPose.transform(pinNode);
                double wantX = 5 * Math.cos(0.5) - 5 * Math.sin(0.5);
                double wantY = 5 * Math.sin(0.5) + 5 * Math.cos(0.5);
                if (!close(posedPin[0][3], wantX) || !close(posedPin[1][3], wantY) || !close(posedPin[2][3], 2.0))
                    fail("pairs: poseState(reach) did not carry the pin node to the expected point");
                System.out.println("pairs: poseState(reach) carries the pin node to the expected point");

                // Fact 6: pose([(screw, [3.0])]) leaves every 'bolts' node at rest; [5.0] moves by (2,0,0).
                Cad.Pose pose3 = pairedScene.pose(List.of(new Cad.StateValue(screw, new double[] {3.0})));
                Cad.Pose pose5 = pairedScene.pose(List.of(new Cad.StateValue(screw, new double[] {5.0})));
                Cad.Link bolts = pairedScene.links().stream().filter(l -> l.name().equals("bolts")).findFirst().orElseThrow();
                for (Cad.Node node : bolts.nodes()) {
                    double[][] rest = node.transform();
                    double[][] at3 = pose3.transform(node);
                    double[][] at5 = pose5.transform(node);
                    if (!close(at3[0][3], rest[0][3]) || !close(at3[1][3], rest[1][3]) || !close(at3[2][3], rest[2][3]))
                        fail("pairs: pose([(screw, [3.0])]) moved a 'bolts' node off rest");
                    if (!close(at5[0][3], rest[0][3] + 2.0) || !close(at5[1][3], rest[1][3]) || !close(at5[2][3], rest[2][3]))
                        fail("pairs: pose([(screw, [5.0])]) did not move a 'bolts' node by (2,0,0)");
                }
                System.out.println("pairs: pose([(screw, [3.0])]) rests, pose([(screw, [5.0])]) moves 'bolts' by (2,0,0)");

                // Fact 9 (diagnostics half): no diagnostic names kinematics.
                for (String d : pairedScene.diagnostics())
                    if (d.startsWith("kinematics:")) fail("pairs: the paired scene carries a kinematics: diagnostic");
            }

            // Motion sequences, written: a state rest and a swing over rest and reach, read back.
            arm.state("rest", List.of(new Blacksmith.StateRow("shoulder", new double[] {0.0})));
            arm.sequence("swing", List.of(new Blacksmith.SequenceSegment("rest", 0.0, "linear"),
                    new Blacksmith.SequenceSegment("reach", 1.0, "linear")), true);
            try (Cad.Scene swingScene = arm.toScene()) {
                List<Cad.Sequence> written = swingScene.sequences();
                if (written.size() != 1 || !written.get(0).name().equals("swing") || !written.get(0).closed()
                        || written.get(0).secondsPerUnit() == null || written.get(0).secondsPerUnit().doubleValue() != 1.0)
                    fail("sequences: the written swing did not read back closed at 1 second per unit");
                List<Cad.Segment> writtenSegments = written.get(0).segments();
                if (writtenSegments.size() != 2
                        || !writtenSegments.get(0).state().name().equals("rest") || writtenSegments.get(0).t() != 0.0 || !writtenSegments.get(0).interpolation().equals("linear")
                        || !writtenSegments.get(1).state().name().equals("reach") || writtenSegments.get(1).t() != 1.0 || !writtenSegments.get(1).interpolation().equals("linear"))
                    fail("sequences: the written swing's segments are not rest@0 then reach@1, linear");
            }
            try {
                arm.sequence("bad", List.of(new Blacksmith.SequenceSegment("rest", 0.0, "linear"),
                        new Blacksmith.SequenceSegment("nowhere", 1.0, "linear")), false);
                fail("sequences: a sequence over an unknown state was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().equals("sequence: assembly 'arm' has no state named 'nowhere'"))
                    fail("sequences: a sequence over an unknown state was not refused exactly: " + e.getMessage());
            }
            System.out.println("sequences: Assembly.sequence round-trips and refuses an unknown state exactly");

            // Fact 4: the reverse pair is a new joint.
            arm.joint("back", "upper arm", "ground");
            System.out.println("mechanism: the reverse pair (\"back\") is accepted as a new joint");

            // Fact 7: the eight bad pair/state/base calls are refused with exactly their
            // message, and Fact 8's unpaired-joint refusal ("back" has no pair) stays
            // byte-identical before and after -- proof none of them mutated "back", or
            // anything else stepText() would notice, even though a wholly valid stepText()
            // snapshot is unavailable while "back" has no pair.
            String pairedBefore = pairedUnpairedMessage(arm);
            record PairRefusal(Runnable call, String message) {}
            List<PairRefusal> pairRefusals = List.of(
                    new PairRefusal(() -> arm.pair("shoulder", "revolute", Blacksmith.Frame.xy(new double[] {0, 0, 10})),
                            "pair: joint 'shoulder' already has a pair"),
                    new PairRefusal(() -> arm.pair("back", "orbital", Blacksmith.Frame.xy()),
                            "pair: 'orbital' is not a pair kind (revolute, prismatic, cylindrical, screw, gear, rack_and_pinion, spherical, "
                                    + "spherical_with_pin, planar, universal, homokinetic, fully_constrained, unconstrained)"),
                    new PairRefusal(() -> arm.pair("back", "screw", Blacksmith.Frame.xy()), "pair: a screw needs a non-zero pitch"),
                    new PairRefusal(() -> arm.pair("back", "revolute", Blacksmith.Frame.xy(),
                            new Blacksmith.PairOptions(null, List.of(new Blacksmith.Range(-1.0, 1.0), new Blacksmith.Range(-1.0, 1.0)), null)),
                            "pair: 'revolute' has 1 freedoms, but 2 ranges were given"),
                    new PairRefusal(() -> arm.pair("back", "revolute", Blacksmith.Frame.xy(),
                            new Blacksmith.PairOptions(null, List.of(new Blacksmith.Range(1.0, -1.0)), null)),
                            "pair: range 0 of joint 'back' has lower >= upper"),
                    new PairRefusal(() -> arm.pair("back", "prismatic",
                            Blacksmith.Frame.at(new double[3], new double[] {0, 0, 1}, new double[] {0, 1, 0}),
                            new Blacksmith.PairOptions(Blacksmith.Frame.xy(), null, null)),
                            "pair: joint 'back' is prismatic, but its end frame is turned 90\u00b0 about -z, "
                                    + "which prismatic (does not turn) cannot make"),
                    new PairRefusal(() -> arm.state("overreach", List.of(new Blacksmith.StateRow("shoulder", new double[] {5.0}))),
                            "state: value 0 of joint 'shoulder' is outside its range"),
                    new PairRefusal(() -> arm.base("upper arm"), "base: assembly 'arm' already has base 'ground'"));
            for (PairRefusal r : pairRefusals) {
                try {
                    r.call().run();
                    fail("pairs: \"" + r.message() + "\" was accepted");
                } catch (Blacksmith.BuildException e) {
                    if (!r.message().equals(e.getMessage())) fail("pairs: got \"" + e.getMessage() + "\", not \"" + r.message() + "\"");
                }
            }
            System.out.println("pairs: all eight bad pair/state/base calls are refused with their exact message");

            // Fact 8: joint "back" with no pair refuses stepText() with exactly this message.
            String noPairMessage = "assembly_step: assembly 'arm': joint 'back' has no pair; "
                    + "a mechanism with pairs needs one on every joint (AP242)";
            if (!pairedBefore.equals(noPairMessage))
                fail("pairs: stepText()'s unpaired-joint refusal is \"" + pairedBefore + "\", not the expected text");
            String pairedAfter = pairedUnpairedMessage(arm);
            if (!pairedAfter.equals(pairedBefore)) fail("pairs: a refused pair/state/base call changed the unpaired-joint refusal");
            System.out.println("pairs: joint 'back' with no pair refuses stepText() with exactly its message, unchanged by any refusal above");

            // Fact 9 (freedom-count half): Blacksmith.pairFreedomCount.
            if (Blacksmith.pairFreedomCount("spherical") != 3 || Blacksmith.pairFreedomCount("revolute") != 1
                    || Blacksmith.pairFreedomCount("fully_constrained") != 0 || Blacksmith.pairFreedomCount("not_a_kind") != 0)
                fail("pairs: Blacksmith.pairFreedomCount does not give 3/1/0/0 for spherical/revolute/fully_constrained/unknown");
            System.out.println("pairs: Blacksmith.pairFreedomCount gives 3/1/0/0 for spherical/revolute/fully_constrained/an unknown name");

            // Fact 10 (controller ruling, added after review): a one-sided range survives
            // the round trip. Without has_lower/has_upper actually carried (an
            // implementation that always sends true for both would pass every other fact),
            // joint "j"'s freedom would come back with a lower limit it was never given.
            try (Blacksmith.Assembly hinge = new Blacksmith.Assembly("hinge")) {
                hinge.place(mechPlate, Blacksmith.Frame.xy().toArray(), "base");
                hinge.place(mechBolt, Blacksmith.Frame.xy(new double[] {0, 0, 2}).toArray(), "arm");
                hinge.link("base", "base");
                hinge.link("arm", "arm");
                hinge.joint("j", "base", "arm");
                hinge.pair("j", "revolute", Blacksmith.Frame.xy(),
                        new Blacksmith.PairOptions(null, List.of(new Blacksmith.Range(null, 1.0)), null));
                try (Cad.Scene hingeScene = hinge.toScene()) {
                    Cad.Joint hingeJoint = hingeScene.joints().stream().filter(j -> j.name().equals("j")).findFirst().orElseThrow();
                    Cad.Pair hingePair = hingeJoint.pair();
                    if (hingePair == null) fail("pairs: hinge joint 'j' has no pair");
                    List<Cad.Freedom> hingeFreedoms = hingePair.freedoms();
                    if (hingeFreedoms.size() != 1 || hingeFreedoms.get(0).lower() != null
                            || hingeFreedoms.get(0).upper() == null || !close(hingeFreedoms.get(0).upper(), 1.0))
                        fail("pairs: hinge joint 'j' is not one freedom with no lower limit and upper exactly 1.0");
                    System.out.println("pairs: a one-sided range (no lower, upper 1.0) survives the round trip");
                }
            }
        }
        gearRoundTrip();
        posed();
    }

    // Drives plan 4's round trip, ported from the Python reference's _geared(): a pinion
    // turning on "drive" meshes, by the gear pair "mesh" (radii 10 and 20, ratio -0.5, bevel
    // 0.25, helical 0.125), with a wheel turning on "driven" about (30, 0); the wheel's part
    // sits 5 off its axis, at (35, 0, 2). The two are different parts: AP242 refuses a pair
    // between two placements of one.
    private static Blacksmith.Assembly geared(boolean mesh) {
        Blacksmith.Solid plate = Blacksmith.Solid.cuboid(40, 10, 2).named("plate");
        Blacksmith.Solid pin = Blacksmith.Solid.cylinder(1, 6).named("pin");
        Blacksmith.Solid hub = Blacksmith.Solid.cylinder(2, 4).named("hub");
        Blacksmith.Assembly gears = new Blacksmith.Assembly("gears");
        gears.place(plate, Blacksmith.Frame.xy().toArray(), "frame");
        gears.place(pin, Blacksmith.Frame.xy(new double[] {0, 0, 2}).toArray(), "pinion");
        gears.place(hub, Blacksmith.Frame.xy(new double[] {35, 0, 2}).toArray(), "wheel");
        gears.link("base", "frame");
        gears.link("driver", "pinion");
        gears.link("follower", "wheel");
        gears.joint("drive", "base", "driver");
        gears.joint("driven", "base", "follower");
        gears.joint("mesh", "driver", "follower");
        gears.pair("drive", "revolute", Blacksmith.Frame.xy(new double[] {0, 0, 2}));
        gears.pair("driven", "revolute", Blacksmith.Frame.xy(new double[] {30, 0, 2}));
        if (mesh)
            gears.pairWith("mesh", "gear", Blacksmith.Frame.xy(new double[] {0, 0, 2}), 10, 20, -0.5, 0.25, 0.125);
        return gears;
    }

    private static void gearRoundTrip() {
        try (Blacksmith.Assembly gears = geared(true); Cad.Scene scene = gears.toScene()) {
            Cad.Joint mesh = null, drive = null, driven = null;
            for (Cad.Joint j : scene.joints()) {
                switch (j.name()) {
                    case "mesh" -> mesh = j;
                    case "drive" -> drive = j;
                    case "driven" -> driven = j;
                    default -> { }
                }
            }
            Cad.Pair meshPair = mesh.pair();
            if (meshPair.kind() != Cad.PairKind.OTHER || !meshPair.kindName().equals("gear"))
                fail("gear: the mesh pair reads as " + meshPair.kind() + "/" + meshPair.kindName() + ", not OTHER/gear");
            double[] want = {10, 20, -0.5, 0.25, 0.125};
            if (meshPair.parameters().size() != want.length) fail("gear: the mesh pair has " + meshPair.parameters() + " parameters");
            for (int i = 0; i < want.length; i++)
                if (Math.abs(meshPair.parameters().get(i) - want[i]) > 1e-12)
                    fail("gear: parameter " + i + " is " + meshPair.parameters().get(i) + ", not " + want[i]);
            Cad.Pair drivePair = drive.pair();
            if (!drivePair.kindName().equals("revolute") || !drivePair.parameters().isEmpty())
                fail("gear: drive reads as " + drivePair.kindName() + " " + drivePair.parameters() + ", not revolute with no parameters");

            // the driver alone turns the wheel by ratio x 0.4 about (30, 0): nothing to report
            Cad.Pose pose = scene.pose(List.of(new Cad.StateValue(drive, new double[] {0.4})));
            if (!pose.diagnostics().isEmpty() || !pose.unsolved().isEmpty())
                fail("gear: the driver-only pose reports " + pose.diagnostics() + " / " + pose.unsolved());
            Cad.Node wheel = scene.links().get(2).nodes().get(0);
            double[][] at = pose.transform(wheel);
            double[] origin = {30 + 5 * Math.cos(-0.2), 5 * Math.sin(-0.2), 2.0};
            for (int i = 0; i < 3; i++)
                if (Math.abs(at[i][3] - origin[i]) > 1e-9)
                    fail("gear: the wheel's origin is off on axis " + i + ": " + at[i][3] + ", not " + origin[i]);

            // both sides given, against the law: one diagnostic, in the kernel's words
            pose = scene.pose(List.of(new Cad.StateValue(drive, new double[] {0.4}),
                    new Cad.StateValue(driven, new double[] {0.4})));
            if (pose.diagnostics().size() != 1
                    || !pose.diagnostics().get(0).startsWith("coupling 'mesh': both 'drive' and 'driven' are given and disagree by"))
                fail("gear: the disagreeing pose reports " + pose.diagnostics());
        }

        try (Blacksmith.Assembly gears = geared(false)) {
            try {
                gears.pairWith("mesh", "gear", Blacksmith.Frame.xy(), 10, 20);
                fail("gear: a two-parameter gear was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().equals("pair: a gear takes 3 or 5 parameters, not 2"))
                    fail("gear: the wrong-count refusal reads \"" + e.getMessage() + "\"");
            }
            gears.pairWith("mesh", "gear", Blacksmith.Frame.xy(), 10, 20, -0.5); // unchanged: it takes one now
        }
        System.out.println("gear: pairWith round-trips kind_name, parameters and pose diagnostics, and refuses a wrong count");
    }

    // Assembly.posed, ported from the Python reference's _paired(), _posed_frame() and
    // test_posed_*, compared by STEP text (stamp stripped), plus the gears' disagreeing drives.
    private static void expectRefusal(String what, Runnable call, String exact, String prefix) {
        try {
            call.run();
        } catch (Blacksmith.BuildException e) {
            String m = e.getMessage();
            if (exact != null && !exact.equals(m)) fail("posed: " + what + " reads \"" + m + "\", not \"" + exact + "\"");
            if (prefix != null && (m == null || !m.startsWith(prefix))) fail("posed: " + what + " reads \"" + m + "\", not starting \"" + prefix + "\"");
            return;
        }
        fail("posed: " + what + " was accepted");
    }

    private static void posed() {
        try (Blacksmith.Solid bolt = Blacksmith.Solid.cylinder(1, 6).named("bolt");
             Blacksmith.Solid plate = Blacksmith.Solid.cuboid(20, 10, 2).named("plate");
             Blacksmith.Assembly bracket = new Blacksmith.Assembly("bracket");
             Blacksmith.Assembly arm = new Blacksmith.Assembly("arm")) {
            bracket.place(plate, Blacksmith.Frame.xy().toArray());
            bracket.place(bolt, Blacksmith.Frame.xy(new double[] {5, 5, 2}).toArray());
            bracket.place(bolt, Blacksmith.Frame.xy(new double[] {15, 5, 2}).toArray());
            bracket.link("fixed", "plate");
            bracket.link("bolts", "bolt", "bolt 2");
            bracket.joint("screw", "fixed", "bolts");
            arm.place(plate, Blacksmith.Frame.xy().toArray(), "base");
            arm.place(bracket, Blacksmith.Frame.xy(new double[] {0, 0, 10}).toArray(), "upper");
            arm.place(bolt, Blacksmith.Frame.xy(new double[] {5, 5, 2}).toArray(), "pin");
            arm.link("ground", "base");
            arm.link("upper arm", "upper", "pin");
            arm.joint("shoulder", "ground", "upper arm");
            bracket.pair("screw", "prismatic", Blacksmith.Frame.xy(new double[] {1, 2, 3}),
                    new Blacksmith.PairOptions(Blacksmith.Frame.xy(new double[] {4, 2, 3}), null, null));
            arm.pair("shoulder", "revolute", Blacksmith.Frame.xy(new double[] {0, 0, 10}),
                    new Blacksmith.PairOptions(null, List.of(new Blacksmith.Range(-1.5, 1.5)), null));
            arm.state("reach", List.of(new Blacksmith.StateRow("shoulder", new double[] {0.5})));
            arm.base("ground");

            String rest = noStamp(arm.stepText());
            List<Blacksmith.StateRow> shoulderHalf = List.of(new Blacksmith.StateRow("shoulder", new double[] {0.5}));
            String moved;
            try (Blacksmith.Assembly p = arm.posed(shoulderHalf)) {
                if (!p.name().equals("arm")) fail("posed: the posed arm is named " + p.name());
                moved = noStamp(p.stepText());
            }
            if (moved.equals(rest)) fail("posed: the shoulder at 0.5 left the arm's STEP text as at rest");
            try (Blacksmith.Assembly p = arm.posed(List.of(new Blacksmith.StateRow("upper/screw", new double[] {5.0})))) {
                if (noStamp(p.stepText()).equals(rest)) fail("posed: the screw at 5 left the arm's STEP text as at rest");
            }
            try (Blacksmith.Assembly p = arm.posed(List.of())) {
                if (!noStamp(p.stepText()).equals(rest)) fail("posed: no rows changed the arm");
            }

            // a state, and a ground
            try (Blacksmith.Assembly byState = arm.posed(List.of(), "reach", null)) {
                if (!noStamp(byState.stepText()).equals(moved)) fail("posed: state 'reach' differs from shoulder = [0.5]");
            }
            try (Blacksmith.Assembly held = arm.posed(shoulderHalf, null, "upper arm")) {
                if (noStamp(held.stepText()).equals(moved)) fail("posed: holding 'upper arm' fixed changed nothing");
            }
            expectRefusal("shoulder = 2", () -> arm.posed(List.of(new Blacksmith.StateRow("shoulder", new double[] {2.0}))).close(),
                    "posed: value 0 of joint 'shoulder' is 2, outside its range", null);
            expectRefusal("state 'fold'", () -> arm.posed(List.of(), "fold", null).close(),
                    "posed: assembly 'arm' has no state named 'fold'", null);
            if (!noStamp(arm.stepText()).equals(rest)) fail("posed: posing changed the original arm");
        }

        // the ambiguous name, and a path with a slash in a name
        try (Blacksmith.Solid pbolt = Blacksmith.Solid.cuboid(1, 1, 6).named("bolt");
             Blacksmith.Solid pplate = Blacksmith.Solid.cuboid(20, 10, 2).named("plate");
             Blacksmith.Assembly bracket = new Blacksmith.Assembly("bracket");
             Blacksmith.Assembly frame = new Blacksmith.Assembly("frame")) {
            bracket.place(pplate, Blacksmith.Frame.xy().toArray());
            bracket.place(pbolt, Blacksmith.Frame.xy(new double[] {5, 5, 2}).toArray());
            bracket.link("fixed", "plate");
            bracket.link("bolts", "bolt");
            bracket.joint("turn", "fixed", "bolts");
            bracket.pair("turn", "revolute", Blacksmith.Frame.xy(new double[] {10, 5, 2}));
            frame.place(bracket, Blacksmith.Frame.xy().toArray(), "left");
            frame.place(bracket, Blacksmith.Frame.xy(new double[] {100, 0, 0}).toArray(), "right/rear");
            String before = noStamp(frame.stepText());
            expectRefusal("bare 'turn'", () -> frame.posed(List.of(new Blacksmith.StateRow("turn", new double[] {0.3}))).close(),
                    "posed: 'turn' names 2 joints: left/turn, right\\/rear/turn; give one by its path", null);
            try (Blacksmith.Assembly posed = frame.posed(List.of(new Blacksmith.StateRow("right\\/rear/turn", new double[] {0.3})))) {
                if (!posed.name().equals("frame")) fail("posed: the posed frame is named " + posed.name());
                if (noStamp(posed.stepText()).equals(before)) fail("posed: turning right/rear left the frame as it was");
            }
            try (Blacksmith.Assembly posed = frame.posed(List.of(new Blacksmith.StateRow("right\\/rear/turn", new double[] {0.0})))) {
                if (!noStamp(posed.stepText()).equals(before)) fail("posed: turning right/rear by 0 changed the frame");
            }
            if (!noStamp(frame.stepText()).equals(before)) fail("posed: posing changed the original frame");
        }

        // the drives: both sides of a coupling, disagreeing, are refused
        try (Blacksmith.Assembly gears = geared(true)) {
            String before = noStamp(gears.stepText());
            try (Blacksmith.Assembly p = gears.posed(List.of(new Blacksmith.StateRow("drive", new double[] {0.4})))) {
                if (!p.name().equals("gears")) fail("posed: the posed gears are named " + p.name());
            }
            expectRefusal("disagreeing drives", () -> gears.posed(List.of(
                            new Blacksmith.StateRow("drive", new double[] {0.4}),
                            new Blacksmith.StateRow("driven", new double[] {0.4}))).close(), null,
                    "posed: assembly 'gears': coupling 'mesh': both 'drive' and 'driven' are given and disagree by");
            if (!noStamp(gears.stepText()).equals(before)) fail("posed: posing changed the original gears");
        }
        System.out.println("posed: moves, takes a path/state/ground, refuses with the kernel's words, leaves the original alone");
    }

    private static String pairedUnpairedMessage(Blacksmith.Assembly arm) {
        try {
            arm.stepText();
        } catch (Blacksmith.BuildException e) {
            return e.getMessage();
        }
        fail("pairs: arm.stepText() with an unpaired joint 'back' was accepted");
        return null;
    }

    // A refused link or joint changes nothing: STEP text compared with every FILE_NAME( line
    // removed, since that line carries a timestamp.
    private static String noStamp(String text) {
        StringBuilder kept = new StringBuilder();
        for (String line : text.split("\n", -1)) {
            if (!line.startsWith("FILE_NAME(")) {
                if (kept.length() > 0) kept.append('\n');
                kept.append(line);
            }
        }
        return kept.toString();
    }

    private static int countOf(String haystack, String needle) {
        int count = 0;
        for (int at = haystack.indexOf(needle); at >= 0; at = haystack.indexOf(needle, at + needle.length())) count++;
        return count;
    }

    // Frames: built, checked, and passed wherever twelve numbers go.
    private static void frames() {
        if (!Blacksmith.Frame.at(new double[3], new double[] {0, -1, 0}).equals(Blacksmith.Frame.xz())
                || !Blacksmith.Frame.at(new double[] {1, 2, 3}, new double[] {0, 0, 5}).equals(Blacksmith.Frame.xy(new double[] {1, 2, 3}))
                || !Blacksmith.Frame.xy().offset(5).equals(Blacksmith.Frame.xy(new double[] {0, 0, 5}))
                || !Arrays.equals(Blacksmith.Frame.yz().toArray(), Blacksmith.Workplane.yz().frame()))
            fail("Frame.at / xy / xz / offset disagree");
        try {
            new Blacksmith.Frame(new double[3], new double[] {1, 0, 0}, new double[] {0, 1, 0}, new double[] {0, 0, -1});
            fail("a left-handed frame did not throw");
        } catch (Blacksmith.BuildException e) {
            if (!e.getMessage().contains("left-handed")) fail("a left-handed frame: " + e.getMessage());
        }
        try (Blacksmith.Profile rect = Blacksmith.Profile.rect(10, 4);
             Blacksmith.Solid lid = Blacksmith.Solid.extrude(rect, Blacksmith.Frame.xy(new double[] {0, 0, 5}).toArray(), 2);
             Blacksmith.Solid wall = Blacksmith.Workplane.on(Blacksmith.Frame.xz(new double[] {0, 3, 0}).toArray()).extrude(rect, 1).solid()) {
            Blacksmith.Frame top = Blacksmith.Frame.of(lid.faceFrame(lid.selectFace(Blacksmith.Selector.max(Blacksmith.Axis.Z))));
            Blacksmith.Bounds b = lid.bounds();
            if (Math.abs(b.min()[2] - 5) > 1e-6 || Math.abs(b.max()[2] - 7) > 1e-6 || Math.abs(wall.bounds().max()[1] - 3) > 1e-6
                    || Math.abs(top.origin()[2] - 7) > 1e-6 || Math.abs(top.z()[2] - 1) > 1e-9)
                fail("frames: lid " + Arrays.toString(b.min()) + ".." + Arrays.toString(b.max()) + ", top " + top);
        }
        System.out.println("frames: " + Blacksmith.Frame.at(new double[3], new double[] {1, 1, 1}) + ": ok");
    }

    // The sheet verbs: a face from a profile, a solid's face alone, faces dropped, a trim, a
    // rounded profile and a path along a curve -- checked by their face counts.
    private static void sheetVerbs(Blacksmith.Solid plate) {
        double[] xy = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
        int top = plate.selectFace(Blacksmith.Selector.max(Blacksmith.Axis.Z));
        try (Blacksmith.Profile square = Blacksmith.Profile.rect(20, 20);
             Blacksmith.Profile circle = Blacksmith.Profile.circle(4);
             Blacksmith.Solid sheet = Blacksmith.Solid.face(square, xy);
             Blacksmith.Solid peg = Blacksmith.Solid.extrude(circle, new double[] {0, 0, -6, 1, 0, 0, 0, 1, 0, 0, 0, 1}, 12);
             Blacksmith.Solid holed = sheet.trim(peg);
             Blacksmith.Solid disc = sheet.trim(peg, "inside");
             Blacksmith.Solid lid = plate.faceSheet(top);
             Blacksmith.Solid walls = plate.dropFaces(new int[] {0, 1});
             Blacksmith.Profile rounded = square.round(2);
             Blacksmith.Solid slab = Blacksmith.Solid.extrude(rounded, xy, 1);
             Blacksmith.Profile wave = Blacksmith.Profile.path(new double[] {0, 0})
                     .bezierTo(new double[] {20, 0}, new double[] {20, 20}, new double[] {40, 10}).endOpen();
             Blacksmith.SweepPath along = Blacksmith.SweepPath.along(wave, xy, 0.01, true);
             Blacksmith.Profile ring = Blacksmith.Profile.circle(1);
             Blacksmith.Solid tube = Blacksmith.Solid.sweep(ring, new double[] {0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0}, along);
             Blacksmith.Solid onPlane = Blacksmith.Workplane.xy().face(square).solid();
             Blacksmith.Solid away = peg.translate(100, 0, 0)) {
            if (sheet.faces() != 1 || holed.faces() < 1 || disc.faces() < 1 || lid.faces() != 1
                    || walls.faces() != plate.faces() - 2 || slab.faces() != 10 || !tube.isWatertight() || onPlane.faces() != 1)
                fail("sheet verbs: sheet=" + sheet.faces() + " holed=" + holed.faces() + " disc=" + disc.faces()
                        + " lid=" + lid.faces() + " walls=" + walls.faces() + " slab=" + slab.faces());
            try {
                sheet.trim(away, "inside").close();
                fail("a trim with nothing inside the tool did not throw");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().contains("trim: nothing of the sheet lies inside the tool")) fail("trim: " + e.getMessage());
            }
            // Chain: an L's two sides, the second drawn back to front, joined -- open, two walls.
            try (Blacksmith.Profile sideA = Blacksmith.Profile.path(new double[] {0, 0}).lineTo(10, 0).endOpen();
                 Blacksmith.Profile sideB = Blacksmith.Profile.path(new double[] {10, 8}).lineTo(10, 0).endOpen();
                 Blacksmith.Profile ell = Blacksmith.Profile.chain(List.of(sideA, sideB));
                 Blacksmith.Solid ellWalls = Blacksmith.Solid.extrudeOpen(ell, xy, 2)) {
                if (ellWalls.faces() != 2) fail("chain: an L extruded open has " + ellWalls.faces() + " walls, not 2");
            }
            // Close: the open L's first side and a line back -- closed, a triangle's three walls.
            try (Blacksmith.Profile openL = Blacksmith.Profile.path(new double[] {0, 0}).lineTo(10, 0).lineTo(10, 8).endOpen();
                 Blacksmith.Profile closedL = openL.closeLoop();
                 Blacksmith.Solid closedWalls = Blacksmith.Solid.extrudeOpen(closedL, xy, 2)) {
                if (closedWalls.faces() != 3) fail("close_loop: a closed L has " + closedWalls.faces() + " walls, not 3");
            }
            // Push-pull: a cube's top raised is one taller box, six faces, not a box and a prism.
            try (Blacksmith.Solid cube = Blacksmith.Solid.cuboid(10, 10, 10);
                 Blacksmith.Solid raised = cube.pushPull(cube.selectFace(Blacksmith.Selector.max(Blacksmith.Axis.Z)), 5)) {
                if (raised.faces() != 6 || !raised.isWatertight()) fail("push_pull: the raised cube has " + raised.faces() + " faces, not 6");
                // Its top and a side pushed together: a 15 x 10 x 15 box, still six faces.
                int[] twoWays = {cube.selectFace(Blacksmith.Selector.max(Blacksmith.Axis.Z)), cube.selectFace(Blacksmith.Selector.max(Blacksmith.Axis.X))};
                try (Blacksmith.Solid grown = cube.pushPull(twoWays, 5)) {
                    if (grown.faces() != 6 || !grown.isWatertight()) fail("push_pull: the cube grown two ways has " + grown.faces() + " faces, not 6");
                }
                // Quick solids: a coiled wire and a pipe close; a cube split by a plane is two bodies.
                try (Blacksmith.Profile unit = Blacksmith.Profile.circle(1);
                     Blacksmith.Profile wire = unit.translate(10, 0);
                     Blacksmith.Solid spring = Blacksmith.Solid.coil(wire, new double[] {0, 0, 0, 0, 0, 1}, 4, 2);
                     Blacksmith.SweepPath pipePath = Blacksmith.SweepPath.at(new double[] {0, 0, 0}).lineTo(new double[] {0, 0, 10});
                     Blacksmith.Solid pipe = Blacksmith.Solid.pipe(pipePath, 2, 0.5)) {
                    if (!spring.isWatertight()) fail("coil: the spring leaks");
                    if (pipe.faces() != 6) fail("pipe: the tube has " + pipe.faces() + " faces, not 6");
                    List<Blacksmith.Solid> halves = cube.splitByPlane(new double[] {2, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0});
                    if (halves.size() != 2 || halves.get(0).faces() != 6) fail("split_by_plane: " + halves.size() + " bodies, not 2");
                    for (Blacksmith.Solid half : halves) half.close();
                }
                // A rectangle drawn above a sphere cores it: the ball with a square hole, then the core.
                try (Blacksmith.Solid ball = Blacksmith.Solid.sphere(10); Blacksmith.Profile coreSquare = Blacksmith.Profile.rect(6, 6)) {
                    List<Blacksmith.Solid> cored = ball.splitByProfile(coreSquare, new double[] {0, 0, 40, 1, 0, 0, 0, 1, 0, 0, 0, 1});
                    double whole = ball.mass(0).volume();
                    if (cored.size() != 2) fail("split_by_profile: " + cored.size() + " bodies, not 2");
                    double outside = cored.get(0).mass(0).volume(), inside = cored.get(1).mass(0).volume();
                    if (!(inside > 0 && inside < outside) || Math.abs(outside + inside - whole) > 0.01 * whole)
                        fail("split_by_profile: " + outside + " + " + inside + " is not the ball's " + whole);
                    for (Blacksmith.Solid piece : cored) piece.close();
                }
            }
            // From loops: a circle given before the square it lies in -- the square is the boundary.
            try (Blacksmith.Profile loopHole = Blacksmith.Profile.circle(4);
                 Blacksmith.Profile loopSquare = Blacksmith.Profile.rect(30, 30);
                 Blacksmith.Profile fromLoops = Blacksmith.Profile.fromLoops(List.of(loopHole, loopSquare));
                 Blacksmith.Solid holedSquare = Blacksmith.Solid.extrude(fromLoops, xy, 2)) {
                if (holedSquare.faces() != 8) fail("from_loops: the holed square has " + holedSquare.faces() + " faces, not 8");
            }
            // Revolve in plane: a plate drawn beside the y axis turns into a tube of four walls.
            try (Blacksmith.Profile beside = Blacksmith.Profile.polygon(new double[][] {{5, 0}, {8, 0}, {8, 10}, {5, 10}});
                 Blacksmith.Solid turned = Blacksmith.Solid.revolveInPlane(beside, xy, new double[] {0, 0}, new double[] {0, 1}, 2 * Math.PI);
                 Blacksmith.Solid turnedWalls = Blacksmith.Solid.revolveOpenInPlane(beside, xy, new double[] {0, 0}, new double[] {0, 1}, Math.PI)) {
                if (turned.faces() != 4 || !turned.isWatertight() || turnedWalls.faces() != 4) fail("revolve_in_plane: " + turned.faces() + " and " + turnedWalls.faces() + " faces, not 4");
            }
            // A hexagon: six walls and two caps. A closed spline through a square's corners: one wall.
            try (Blacksmith.Profile hexagon = Blacksmith.Profile.regularPolygon(new double[] {0, 0}, 10, 6);
                 Blacksmith.Solid hexPrism = Blacksmith.Solid.extrude(hexagon, xy, 2);
                 Blacksmith.Profile loopSpline = Blacksmith.Profile.spline(new double[][] {{0, 0}, {10, 0}, {10, 10}, {0, 10}}, 3, null, true);
                 Blacksmith.Solid loopSolid = Blacksmith.Solid.extrude(loopSpline, xy, 2)) {
                if (hexPrism.faces() != 8 || loopSolid.faces() != 3 || !loopSolid.isWatertight()) fail("shapes: " + hexPrism.faces() + " and " + loopSolid.faces() + " faces, not 8 and 3");
            }
            // A five-pointed star: ten walls and two caps.
            try (Blacksmith.Profile star = Blacksmith.Profile.star(new double[] {0, 0}, 10, 4, 5);
                 Blacksmith.Solid starPrism = Blacksmith.Solid.extrude(star, xy, 2)) {
                if (starPrism.faces() != 12 || !starPrism.isWatertight()) fail("star: " + starPrism.faces() + " faces, not 12");
            }
            // Text: an `i` is two shapes and an `o` one; the `o` extrudes to a watertight ring with spline edges.
            java.util.List<Blacksmith.Profile> word = Blacksmith.Profile.text("io", 10);
            try (Blacksmith.Solid textRing = Blacksmith.Solid.extrude(word.get(2), xy, 2)) {
                boolean spline = textRing.edges().stream().anyMatch(e -> e.kind().equals("nurbs"));
                if (word.size() != 3 || !textRing.isWatertight() || !spline) fail("text: " + word.size() + " shapes, spline edges " + spline);
            }
            for (Blacksmith.Profile p : word) p.close();
            // A reflector: the parabola from rim to rim, closed and revolved -- watertight.
            try (Blacksmith.Profile dish = Blacksmith.Profile.parabola(new double[] {0, 0}, new double[] {0, 1}, 20, 0, 50)
                    .lineTo(0, 31.25).lineTo(0, 0).end();
                 Blacksmith.Solid bowl = Blacksmith.Solid.revolveInPlane(dish, xy, new double[] {0, 0}, new double[] {0, 1}, 2 * Math.PI)) {
                if (!bowl.isWatertight()) fail("parabola: the bowl leaks");
            }
            // The library reads a fixed count of weights: a wrong count is refused, not read past.
            double[][] corners = {{0, 0}, {10, 0}, {10, 10}, {0, 10}};
            double[][] control = {{5, 5}, {10, 0}};
            double[] knots = {0, 0, 0, 1, 1, 1};
            try (Blacksmith.Profile weighted = Blacksmith.Profile.spline(corners, 3, new double[] {1, 2, 1, 1}, true);
                 Blacksmith.Profile rational = Blacksmith.Profile.path(new double[] {0, 0}).nurbsTo(control, knots, 2, new double[] {1, 0.5, 1}).endOpen()) {
                // built: the right counts pass
            }
            try (Blacksmith.Profile p = Blacksmith.Profile.spline(corners, 3, new double[] {1, 1}, true)) {
                fail("a short spline weight list was not refused");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().equals("spline: 2 weights for 4 points; give one per point")) fail("a short weight list: " + e.getMessage());
            }
            try (Blacksmith.Path p = Blacksmith.Profile.path(new double[] {0, 0}).nurbsTo(control, knots, 2, new double[] {1, 1})) {
                fail("a short nurbs_to weight list was not refused");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().equals("nurbs_to: 2 weights for 3 control points (the current point and 2 given); give one per point")) fail("a short weight list: " + e.getMessage());
            }
            System.out.println("sheet verbs: face, trim (" + holed.faces() + "+" + disc.faces() + "), face_sheet, drop_faces, round ("
                    + slab.faces() + " faces), along, chain, push_pull, coil, pipe, split_by_plane, close_loop, from_loops, revolve_in_plane, regular_polygon, star, text, spline, parabola: ok");
        }
    }

    // silhouette_beziers, both libraries: the curves where a body's surfaces turn away from the
    // eye. The kernel assertions are on values that pin the layout, not on shapes: a stride-16 unpack
    // with the weights read as a coordinate, or the points shifted a slice, still gives arrays of
    // the right length.
    private static Blacksmith.SvgOptions kernelEye(Blacksmith.SvgView view, double tolerance) {
        return new Blacksmith.SvgOptions(view, null, null, null, 0.0, 1000.0, 1000.0, 0.05, tolerance,
                "#000000", 1.0, null, true, false, false, false, true);
    }

    private static Cad.SvgOptions readerEye(Cad.SvgView view, double tolerance) {
        return new Cad.SvgOptions(view, null, null, null, 0.0, 1000.0, 1000.0, 0.05, tolerance,
                "#000000", 1.0, null, true, false, false, false, true);
    }

    private static void silhouette(String path) {
        // Kernel. A radius-2 sphere's rim: the end points of every arc lie ON the sphere to 1e-9
        // (radius 2), and the end weights are exactly 1 with the two interior ones in (0, 1). The
        // interior control points are not checked, and the interior weights only to lie in (0, 1):
        // both move with how the rim is subdivided.
        try (Blacksmith.Solid sphere = Blacksmith.Solid.sphere(2.0)) {
            Cad.BeziersData64 rim = sphere.silhouetteBeziers();
            if (rim.count() == 0) fail("silhouette: a sphere gave no rim");
            if (rim.points().length != rim.count() * 12 || rim.weights().length != rim.count() * 4)
                fail("silhouette: " + rim.count() + " curves but " + rim.points().length + " point doubles and " + rim.weights().length + " weights");
            for (int c = 0; c < rim.count(); c++) {
                double[] r = new double[4];
                for (int k = 0; k < 4; k++) {
                    double x = rim.points()[c * 12 + k * 3], y = rim.points()[c * 12 + k * 3 + 1], z = rim.points()[c * 12 + k * 3 + 2];
                    r[k] = Math.sqrt(x * x + y * y + z * z);
                }
                double[] w = java.util.Arrays.copyOfRange(rim.weights(), c * 4, c * 4 + 4);
                if (Math.abs(r[0] - 2.0) > 1e-9 || Math.abs(r[3] - 2.0) > 1e-9)
                    fail("silhouette: arc " + c + " end points are at radius " + r[0] + " and " + r[3] + ", not 2");
                if (w[0] != 1.0 || w[3] != 1.0 || !(w[1] > 0 && w[1] < 1) || !(w[2] > 0 && w[2] < 1))
                    fail("silhouette: arc " + c + " weights are " + java.util.Arrays.toString(w) + ", not 1, then two weights in (0, 1), then 1");
            }
            System.out.println("silhouette: a radius-2 sphere gives " + rim.count() + " arcs, ends at radius 2, end weights 1, interior weights in (0, 1)");

            // An infinite tolerance is refused in the library's words.
            try {
                sphere.silhouetteBeziers(kernelEye(Blacksmith.SvgView.ISO, Double.POSITIVE_INFINITY));
                fail("silhouette: an infinite tolerance was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().contains("silhouette: ")) fail("silhouette: refused, but not in the library's words: " + e.getMessage());
            }
        }

        // A cylinder seen from the side is straight rulings: polynomial, every weight exactly 1.
        try (Blacksmith.Solid cylinder = Blacksmith.Solid.cylinder(1.0, 3.0)) {
            Cad.BeziersData64 rulings = cylinder.silhouetteBeziers(kernelEye(Blacksmith.SvgView.FRONT, 0.1));
            if (rulings.count() == 0) fail("silhouette: a cylinder gave no rulings");
            for (double w : rulings.weights()) if (w != 1.0) fail("silhouette: a cylinder's rulings are not all weight 1");
            // The axis. hypot(x, y) and the z extent are both symmetric in x and y, so an unpack
            // that returned [y, x, z] passes both; |x| at the radius and |y| at zero tell the two
            // apart (seen from the front a ruling sits at x = +-radius, y = 0). Only the magnitude
            // of x is asserted, not its sign, and the number of rulings is not asserted.
            for (int k = 0; k < rulings.count() * 4; k++) {
                double x = rulings.points()[k * 3], y = rulings.points()[k * 3 + 1];
                if (Math.abs(Math.sqrt(x * x + y * y) - 1.0) > 1e-6) fail("silhouette: a ruling's control point is off the cylinder's wall");
                if (Math.abs(Math.abs(x) - 1.0) > 1e-6) fail("silhouette: a ruling's control point has |x| = " + Math.abs(x) + ", not the radius 1");
                if (Math.abs(y) > 1e-6) fail("silhouette: a ruling's control point has |y| = " + Math.abs(y) + ", not 0");
            }
            double[] heights = new double[4];
            for (int k = 0; k < 4; k++) heights[k] = rulings.points()[k * 3 + 2];
            java.util.Arrays.sort(heights);
            for (int k = 0; k < 4; k++) if (Math.abs(heights[k] - k) > 1e-6) fail("silhouette: a ruling's heights are " + java.util.Arrays.toString(heights) + ", not 0..3 evenly");
        }

        // An all-planar body has no tangential silhouette: the empty answer, raising nothing -- and
        // a refusal left in the error slot by an earlier call must not turn it into one. Both
        // solids are built in the resource header, BEFORE the refusal, not between it and the ask:
        // every call that builds, reads or writes geometry in the library runs under its `guard`,
        // whose first act is `clear_error` (blacksmith-capi lib.rs:117), so building one in between
        // would wipe the refusal's message. The order is build, refuse, ask. What this pins is
        // narrower than it looks, though: the slot is already clear when the silhouette's native
        // call begins, because the wrapper first packs its options and packing the default stroke
        // "#000000" goes through `cadaclysm_blacksmith_parse_colour`, itself a `guard` (lib.rs:200)
        // that clears it (Java `buildSvgOptions` -> `packed` -> `tryParseRgb` ->
        // `cadaclysm_blacksmith_parse_colour`). `cadaclysm_blacksmith_svg_options_init` is a bare
        // struct fill and does not clear. So the test pins that the wrapper must not read the slot
        // BEFORE packing its options: a read there fails it, while a read placed after packing and
        // before the native call would pass. The library's own clearing at the silhouette's entry
        // is a library property, pinned for the reader's entry point by
        // `an_empty_answer_after_a_refusal_carries_no_stale_error`
        // (crates/cadaclysm-capi/tests/silhouette_abi.rs:401); this test covers the wrapper's half.
        // Only calls under `guard` clear: `cadaclysm_blacksmith_solid_free` and
        // `cadaclysm_blacksmith_silhouette_beziers_free` just drop a box and the error getter does
        // not clear either, so a free running between the refusal and the ask cannot wipe the slot.
        try (Blacksmith.Solid sphere = Blacksmith.Solid.sphere(2.0); Blacksmith.Solid box = Blacksmith.Solid.cuboid(10, 10, 10)) {
            try {
                sphere.silhouetteBeziers(kernelEye(Blacksmith.SvgView.ISO, Double.POSITIVE_INFINITY));
                fail("silhouette: an infinite tolerance was accepted");
            } catch (Blacksmith.BuildException expected) {
                // leaves its reason in the slot
            }
            Cad.BeziersData64 none;
            try {
                none = box.silhouetteBeziers();
            } catch (Blacksmith.BuildException e) {
                fail("silhouette: the empty answer after a refusal was an error: " + e.getMessage());
                return;
            }
            if (none.count() != 0 || none.points().length != 0 || none.weights().length != 0) fail("silhouette: an all-planar body gave a silhouette");
        }
        System.out.println("silhouette: cylinder rulings polynomial, infinite tolerance refused, a planar body is the empty answer");

        // Reader. The fixtures are the repository's, not an SDK checkout's, so this runs where found.
        Path sampleRoot = Path.of(path).toAbsolutePath().getParent().getParent();
        Path spherePath = sampleRoot == null ? null : sampleRoot.resolve("crates/cadaclysm-acis/tests/fixtures/rhino/sphere.sat");
        Path boxPath = sampleRoot == null ? null : sampleRoot.resolve("crates/cadaclysm-acis/tests/fixtures/rhino/box-chamfer-all.blacksmith.stp");
        if (spherePath == null || boxPath == null || !Files.exists(spherePath) || !Files.exists(boxPath)) return;
        try (Cad.Scene scene = Cad.open(spherePath.toString())) {
            // The body node above the lump holds no shape of its own; the first node with extent is the part.
            Cad.Node node = null;
            for (Cad.Node n : scene.walk()) {
                if (!java.util.Arrays.equals(n.bounds().min(), n.bounds().max())) {
                    node = n;
                    break;
                }
            }
            if (node == null) fail("silhouette (reader): sphere.sat has no node with extent");
            // Asked the LARGER answer first: iso gives 236 curves against front's 174, so the second
            // call below refills the scene's one slot in place and overwrites the head of what was kept,
            // which is what makes a non-copying implementation fail loudly. The reverse order can pass
            // with a view. It was front first until the lattice's spacing became a length in space
            // (44efabc88): front gave 1248 against iso's 1210 then.
            Cad.SvgOptions firstOptions = readerEye(Cad.SvgView.ISO, 0.1);
            Cad.BeziersData64 first = node.silhouetteBeziers(firstOptions);
            if (first.count() == 0) fail("silhouette (reader): a sphere gave no rim");
            if (first.points().length != first.count() * 12 || first.weights().length != first.count() * 4)
                fail("silhouette (reader): the arrays are not count*4*3 and count*4");
            for (double w : first.weights())
                if (!Double.isFinite(w) || !(w > 0.0)) fail("silhouette (reader): a weight is " + w + ", not finite and strictly positive");
            // Every control point lies within the library's fit budget of the sphere, at the bounds
            // radius from the bounds centre. That is NOT because control points lie on the sphere:
            // the silhouette curve does, but a cubic's interior control points do not. It holds
            // because the arcs are short (half a unit on a radius of 10), and the budget is the
            // tolerance the library fits the CURVE to, not its control polygon. The margin is
            // narrow: the curve itself uses nearly the whole budget (3.42e-3 against 3.46e-3) since
            // the lattice's spacing became a length in space (44efabc88); before, a lattice ten times
            // too fine left it at 1e-4. So this catches a displaced or scaled result and a
            // wildly mis-strided unpack. What it does with a slip of the unpack was measured here
            // as the worst radius DEVIATION of any control point from the sphere's radius 10
            // (budget about 3.5e-3): a correct read deviates by 3.04e-3 on iso and 2.97e-3 on front;
            // a one-double wrap slip by 0.87 on iso and 8.8 on front, over the budget at either
            // view; a one-CONTROL-POINT slip by exactly the correct read's figure at either view,
            // because it only moves whole points. So this catches a one-double slip but can never
            // catch a one-control-point slip, which is why the chaining assertion below is the only
            // one that does. This test asks iso, because the ownership order below forces it. It
            // also does NOT pin the eye or `up` (a silhouette point is a point of the surface, so
            // it is on the sphere from any view), the node choice (a wrong node fails earlier, as a
            // refusal or an empty answer), or the weights (all 1.0 on this fixture: degree-1
            // chords). The bound is the library's own budget: it fits the silhouette to within
            // `extent * tolerance / width` (`world_tolerance`, capi svg.rs), the extent being the
            // bounds' diagonal. Measured on the iso view this test asks, the radius deviation is
            // 3.04e-3 on a radius of 10 (front: 2.97e-3).
            Cad.Bounds sb = node.bounds();
            double[] sc = {(sb.min()[0] + sb.max()[0]) / 2.0, (sb.min()[1] + sb.max()[1]) / 2.0, (sb.min()[2] + sb.max()[2]) / 2.0};
            double sphereRadius = (sb.max()[0] - sb.min()[0]) / 2.0;
            double dxb = sb.max()[0] - sb.min()[0], dyb = sb.max()[1] - sb.min()[1], dzb = sb.max()[2] - sb.min()[2];
            // Read off the options the call was given, not copied from the numbers readerEye was built with.
            double budget = Math.sqrt(dxb * dxb + dyb * dyb + dzb * dzb) * (firstOptions.tolerance() / firstOptions.width());
            double lo = Double.MAX_VALUE, hi = 0;
            for (int k = 0; k < first.points().length / 3; k++) {
                double dx = first.points()[k * 3] - sc[0], dy = first.points()[k * 3 + 1] - sc[1], dz = first.points()[k * 3 + 2] - sc[2];
                double r = Math.sqrt(dx * dx + dy * dy + dz * dz);
                lo = Math.min(lo, r);
                hi = Math.max(hi, r);
            }
            if (sphereRadius <= 0 || Math.abs(lo - sphereRadius) > budget || Math.abs(hi - sphereRadius) > budget)
                fail("silhouette (reader): control points are at radii " + lo + ".." + hi + " from the bounds centre, not the sphere's " + sphereRadius);
            double[] keepPoints = first.points().clone();
            double[] keepWeights = first.weights().clone();
            // The next silhouette call on this scene refills the library's one slot in place.
            Cad.BeziersData64 second = node.silhouetteBeziers(readerEye(Cad.SvgView.FRONT, 0.1));
            if (second.count() == 0) fail("silhouette (reader): the second view gave no rim");
            if (second.count() > first.count())
                fail("silhouette (reader): the larger answer must come first (iso " + first.count() + ", front " + second.count() + ")");
            if (second.count() == keepPoints.length / 12 && java.util.Arrays.equals(second.points(), keepPoints))
                fail("silhouette (reader): the two views gave the same silhouette, so this cannot tell a copy from a view");
            if (!java.util.Arrays.equals(first.points(), keepPoints))
                fail("silhouette (reader): the first answer's points changed when the second was asked");
            if (!java.util.Arrays.equals(first.weights(), keepWeights))
                fail("silhouette (reader): the first answer's weights changed when the second was asked");
            // Chaining, the assertion that sees an offset slip; asked of the iso answer, whose figures
            // are quoted here (the front view chains much less). Count the consecutive pairs whose last
            // control point equals the next curve's first, to 1e-9 per coordinate (x, y and z each, so
            // a passing pair can be up to 1.73e-9 apart). The arcs come back in RUNS, not as one
            // ordered traversal, so "every arc ends where the next begins" is false and this is a count
            // with a margin, not an identity: measured on iso, 232 of the 235 consecutive pairs chain
            // (98.7%, four runs); the front view chains 96 of 173 (55%), which is why the eye matters
            // and the bound is 80, not near 230. A read shifted by one double or by one control point
            // leaves none (0 of 235 each). Those are wrap-around slips, which preserve the length and the
            // count, so each denominator is the unshifted pair count (a truncating slip loses a curve
            // and drops it by one). The count varies with how the sphere is tessellated; what makes a
            // lower bound of 80 safe is not that it cannot drift but that it sits about three times
            // below the count measured here. It has drifted once: the bound was 400 against 1206 of
            // 1209 until the lattice's spacing became a length in space (44efabc88) and the same four
            // runs came back in arcs five times longer.
            // Its limit: a shift by a whole CURVE (12 doubles) is NOT caught, because it preserves
            // the chaining: 231 of 235 pairs still chain on iso, since every arc is replaced by
            // its neighbour's and the neighbours still join.
            if (second.points().length != second.count() * 12 || second.weights().length != second.count() * 4)
                fail("silhouette (reader): the front arrays are not count*4*3 and count*4");
            for (double w : second.weights())
                if (!Double.isFinite(w) || !(w > 0.0)) fail("silhouette (reader): a front weight is " + w + ", not finite and strictly positive");
            int chained = 0;
            double[] ip = first.points();
            for (int c = 0; c + 1 < first.count(); c++) {
                int last = c * 12 + 9, next = (c + 1) * 12;
                if (Math.abs(ip[last] - ip[next]) <= 1e-9 && Math.abs(ip[last + 1] - ip[next + 1]) <= 1e-9
                        && Math.abs(ip[last + 2] - ip[next + 2]) <= 1e-9) chained++;
            }
            if (chained < 80)
                fail("silhouette (reader): only " + chained + " of " + (first.count() - 1)
                        + " consecutive arcs chain (last control point = the next one's first), want at least 80");
            // A refusal: an infinite tolerance, in the library's words.
            try {
                node.silhouetteBeziers(readerEye(Cad.SvgView.ISO, Double.POSITIVE_INFINITY));
                fail("silhouette (reader): an infinite tolerance was accepted");
            } catch (Cad.CadaclysmException e) {
                if (!e.getMessage().contains("silhouette: ")) fail("silhouette (reader): refused, but not in the library's words: " + e.getMessage());
            }
            System.out.println("silhouette (reader): sphere " + first.count() + " then " + second.count() + " curves, first answer kept; infinite tolerance refused");
        }
        // A planar body: the empty answer, after a refusal has left its reason in the slot.
        try (Cad.Scene scene = Cad.open(boxPath.toString())) {
            Cad.Node node = null;
            for (Cad.Node n : scene.walk()) {
                if (!java.util.Arrays.equals(n.bounds().min(), n.bounds().max())) {
                    node = n;
                    break;
                }
            }
            if (node == null) fail("silhouette (reader): the box has no node with extent");
            try {
                node.silhouetteBeziers(readerEye(Cad.SvgView.ISO, Double.POSITIVE_INFINITY));
                fail("silhouette (reader): an infinite tolerance was accepted on the box");
            } catch (Cad.CadaclysmException expected) {
                // leaves its reason in the slot
            }
            Cad.BeziersData64 none = node.silhouetteBeziers();
            if (none.count() != 0 || none.points().length != 0) fail("silhouette (reader): an all-planar body gave a silhouette");
            System.out.println("silhouette (reader): a planar box is the empty answer");
        }
    }
    private static void fail(String why) {
        System.err.println(why);
        System.exit(1);
    }

    private static boolean close(double a, double b) {
        return Math.abs(a - b) <= 1e-9;
    }

    // The point (x, y, z) carried by the row-major 4x4 matrix m -- rotation columns, then origin.
    private static double[] apply(double[][] m, double x, double y, double z) {
        return new double[]{
                m[0][0] * x + m[0][1] * y + m[0][2] * z + m[0][3],
                m[1][0] * x + m[1][1] * y + m[1][2] * z + m[1][3],
                m[2][0] * x + m[2][1] * y + m[2][2] * z + m[2][3]};
    }
}
