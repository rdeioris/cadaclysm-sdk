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
        readerHealth();
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
            transforms();
            values();
            hits();
            machining();
            edgeCurves();
            intersections();
            collider();
            clash();
            sweptClash();
            assemblySweptClash();
            wallThickness();
            measure();
            rtree();
            interpolator();
            merge();
            rtreeRays();
            subd();
            sketch();
            solidHits();
            assemblies();
            materials();
            mechanism();
            kernelHealth();
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
                Blacksmith.ReportItem built = new Blacksmith.ReportItem("corner", given, 1, "why", regionGiven, 10, 2);
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

            // Rest machining (the list form), W1-W4 of plan 3.
            try (Blacksmith.Tool small = Blacksmith.Tool.flat(2, 2, 20, 800, 200, 12000);
                 Blacksmith.Job alone = new Blacksmith.Job(Blacksmith.Stock.around(block, 2), 30);
                 Blacksmith.Job rest = new Blacksmith.Job(Blacksmith.Stock.around(block, 2), 30)) {
                Blacksmith.Report single = alone.machine(block, endMill);
                if (single.size() == 0) fail("machineWith: the single-tool report is empty");
                for (Blacksmith.ReportItem item : single) {
                    if (Math.abs(item.top() - 10) > 1e-6 || Math.abs(item.bottom() - 2) > 1e-6)
                        fail("machineWith: the single-tool item's z range is " + item.top() + ".." + item.bottom() + ", not 10..2");
                    for (Blacksmith.Profile p : item.region()) p.close();
                }
                Blacksmith.Report two = rest.machineWith(block, new Blacksmith.Tool[] {endMill, small});
                if (two.size() != 4) fail("machineWith: two end mills report " + two.size() + " item(s), not 4:\n" + two);
                for (Blacksmith.ReportItem item : two) {
                    if (!item.reason().contains("T2 (2 mm)")) fail("machineWith: reason does not name T2 (2 mm): " + item.reason());
                    if (Math.abs(item.top() - 10) > 1e-6 || Math.abs(item.bottom() - 2) > 1e-6)
                        fail("machineWith: the item's z range is " + item.top() + ".." + item.bottom() + ", not 10..2");
                    for (Blacksmith.Profile p : item.region()) p.close();
                }
                if (rest.operations().stream().noneMatch(o -> o.tool() == 2 && o.kind().equals("pocket")))
                    fail("machineWith: no pocket operation with tool 2");
                try (Blacksmith.Job empty = new Blacksmith.Job(Blacksmith.Stock.around(block, 2), 30)) {
                    try {
                        empty.machineWith(block, new Blacksmith.Tool[0]);
                        fail("machineWith: an empty list was accepted");
                    } catch (Blacksmith.BuildException e) {
                        if (!e.getMessage().contains("machine: at least one end mill is needed"))
                            fail("machineWith: wrong message for an empty list: " + e.getMessage());
                    }
                    try {
                        empty.machineWith(block, new Blacksmith.Tool[] {endMill, null});
                        fail("machineWith: a null end mill was accepted");
                    } catch (Blacksmith.BuildException e) {
                        if (!e.getMessage().contains("job_machine_with: null end mill 1"))
                            fail("machineWith: wrong message for a null end mill: " + e.getMessage());
                    }
                    if (!empty.operations().isEmpty()) fail("machineWith: a refused call changed the job");
                }
                System.out.println("machineWith: two end mills leave four T2 corners, z 10..2; an empty list and a null refused");
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

    // ---- clash detection (clash plan 3) ------------------------------------------------------
    // Python's test_clash_*, trimmed to what proves the marshalling, plus the edge row.

    private static double[] at(double x, double y, double z) {
        return new double[] {x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1};
    }

    private static void clashPrefix(String what, Runnable call, String prefix) {
        String said = refused(call);
        if (!said.startsWith(prefix)) fail("clash: " + what + " said '" + said + "', not '" + prefix + "...'");
    }

    private static void clash() {
        // 1. balls too close: every field read
        try (Blacksmith.Solid a = Blacksmith.Solid.sphere(1);
             Blacksmith.Solid b = Blacksmith.Solid.sphere(1);
             Blacksmith.Collider collider = new Blacksmith.Collider(new Blacksmith.Solid[] {a, b}, 1e-3, null, null)) {
            List<Blacksmith.Clash> rows = collider.clash(new double[][] {at(0, 0, 0), at(2.5, 0, 0)}, 1.0);
            if (rows.size() != 1) fail("clash: the balls gave " + rows);
            Blacksmith.Clash r = rows.get(0);
            if (r.a() != 0 || r.b() != 1 || !r.kind().equals("too_close")) fail("clash: the balls' row reads " + r);
            if (Math.abs(r.distance() - 0.5) > 1e-3) fail("clash: the balls' distance is " + r.distance());
            if (!r.kindA().equals("face") || !r.kindB().equals("face")) fail("clash: the balls' features are " + r.kindA() + "/" + r.kindB());
            if (r.indexA() == null || r.indexB() == null) fail("clash: the balls' face indices are missing");
            if (r.edgeA() != null || r.edgeB() != null) fail("clash: a ball face carries an edge: " + r.edgeA() + "/" + r.edgeB());
            if (Math.abs(r.onA()[0] - 1.0) > 2e-3 || Math.abs(r.onB()[0] - 1.5) > 2e-3)
                fail("clash: the balls' points are " + Arrays.toString(r.onA()) + " " + Arrays.toString(r.onB()));
            if (!r.text().isEmpty() || r.depth() != 0.0) fail("clash: the balls' text/depth read '" + r.text() + "' " + r.depth());
            if (!collider.clash(new double[][] {at(0, 0, 0), at(2.5, 0, 0)}, 0.25).isEmpty()) fail("clash: clearance 0.25 found rows");
            System.out.println("clash (balls): " + r + " refined=" + r.refined());
        }
        // 1b. a ball off a box's corner: the two sides' features differ, so a swap shows
        try (Blacksmith.Solid ball = Blacksmith.Solid.sphere(1);
             Blacksmith.Solid box = Blacksmith.Solid.cuboid(2, 2, 2);
             Blacksmith.Solid corner = box.translate(2, 2, 2)) {
            List<Blacksmith.Clash> rows = Blacksmith.clash(List.of(ball), List.of(corner), 1.0, 1e-3, null);
            if (rows.size() != 1) fail("clash: the ball by the corner gave " + rows);
            Blacksmith.Clash r = rows.get(0);
            if (!r.kindA().equals("face") || !r.kindB().equals("vertex") || r.indexA() == null || r.indexB() == null)
                fail("clash: the ball by the corner reads " + r.kindA() + " " + r.indexA() + " / " + r.kindB() + " " + r.indexB());
            if (Math.abs(r.distance() - (Math.sqrt(3) - 1)) > 1e-3) fail("clash: the ball by the corner is " + r.distance() + " away");
        }
        // 2. boxes face to face: touching, solid() refused, intersect() the shared face
        try (Blacksmith.Solid a = Blacksmith.Solid.cuboid(2, 2, 2);
             Blacksmith.Solid b = Blacksmith.Solid.cuboid(2, 2, 2)) {
            Blacksmith.Clash r;
            try (Blacksmith.Collider collider = new Blacksmith.Collider(new Blacksmith.Solid[] {a, b}, 1e-3, null, null)) {
                List<Blacksmith.Clash> rows = collider.clash(new double[][] {at(0, 0, 0), at(2, 0, 0)});
                if (rows.size() != 1) fail("clash: the boxes face to face gave " + rows);
                r = rows.get(0);
            }
            if (!r.kind().equals("touching") || r.distance() > 1e-3) fail("clash: face to face reads " + r);
            clashPrefix("solid() of a touching pair", r::solid, "clashes_solid: pair (0, 1) is not penetrating");
            Blacksmith.Intersection x = r.intersect();
            if (x.overlaps().size() != 1) fail("clash: face to face intersect reads " + x);
            double[][] ring = x.overlaps().get(0).loops()[0];
            double area = 0;
            for (int i = 0; i < ring.length; i++) {
                double[] p = ring[i], q = ring[(i + 1) % ring.length];
                if (Math.abs(p[0] - 1.0) > 1e-3) fail("clash: the shared face leaves x = 1: " + Arrays.toString(p));
                area += p[1] * q[2] - q[1] * p[2];
            }
            if (Math.abs(Math.abs(area) / 2 - 4.0) > 1e-6) fail("clash: the shared face's area is " + Math.abs(area) / 2);
        }
        // 3. boxes interpenetrating: depth, features none, solid()/intersect() after the collider
        //    is closed and the other rows dropped
        try (Blacksmith.Solid a = Blacksmith.Solid.cuboid(2, 2, 2);
             Blacksmith.Solid b = Blacksmith.Solid.cuboid(2, 2, 2)) {
            Blacksmith.Collider collider = new Blacksmith.Collider(new Blacksmith.Solid[] {a, b}, 1e-3, null, null);
            List<Blacksmith.Clash> rows = collider.clash(new double[][] {at(0, 0, 0), at(1.75, 0, 0)});
            collider.close();
            Blacksmith.Clash r = rows.get(0);
            rows = null;
            for (int i = 0; i < 3; i++) {
                System.gc();
                try {
                    Thread.sleep(20);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
            if (!r.kind().equals("penetrating") || Math.abs(r.depth() - 0.25) >= 1e-9 || r.distance() != 0.0)
                fail("clash: interpenetrating reads " + r + " depth " + r.depth());
            if (!r.kindA().equals("none") || r.indexA() != null || r.edgeA() != null
                    || !r.kindB().equals("none") || r.indexB() != null || r.edgeB() != null)
                fail("clash: a penetrating row's features are " + r.kindA() + " " + r.indexA() + " " + r.edgeA() + " / "
                     + r.kindB() + " " + r.indexB() + " " + r.edgeB());
            try (Blacksmith.Solid overlap = r.solid()) {
                if (Math.abs(overlap.mass(0).volume() - 1.0) > 1e-6) fail("clash: the overlap's volume is " + overlap.mass(0).volume());
            }
            r.intersect();
        }
        // 4. one-shot: two sets, one set, allowed
        try (Blacksmith.Solid a0 = Blacksmith.Solid.sphere(1);
             Blacksmith.Solid ball = Blacksmith.Solid.sphere(1);
             Blacksmith.Solid a1 = ball.translate(2.05, 0, 0);
             Blacksmith.Solid b0 = ball.translate(0, 2.5, 0);
             Blacksmith.Solid b1 = ball.translate(10, 0, 0)) {
            List<Blacksmith.Clash> two = Blacksmith.clash(List.of(a0, a1), List.of(b0, b1), 1.0, 1e-3, null);
            if (two.size() != 1 || two.get(0).a() != 0 || two.get(0).b() != 0 || !two.get(0).kind().equals("too_close"))
                fail("clash: two sets gave " + two);
            if (Math.abs(two.get(0).distance() - 0.5) > 1e-3) fail("clash: two sets' distance is " + two.get(0).distance());
            List<Blacksmith.Clash> one = Blacksmith.clash(List.of(a0, a1), null, 1.0, 1e-3, null);
            if (one.size() != 1 || one.get(0).a() != 0 || one.get(0).b() != 1) fail("clash: one set gave " + one);
            if (!Blacksmith.clash(List.of(a0, a1), null, 1.0, 1e-3, new int[] {0, 1}).isEmpty())
                fail("clash: an allowed pair was tested");
        }
        // 5. refusals, by prefix
        try (Blacksmith.Solid a = Blacksmith.Solid.cuboid(2, 2, 2);
             Blacksmith.Solid b = Blacksmith.Solid.cuboid(2, 2, 2)) {
            List<Blacksmith.Solid> ab = List.of(a, b);
            try (Blacksmith.Collider collider = new Blacksmith.Collider(new Blacksmith.Solid[] {a, b})) {
                double[][] two = {at(0, 0, 0), at(1.75, 0, 0)};
                clashPrefix("clearance -1", () -> collider.clash(two, -1.0), "collider_clash: clearance -1");
                clashPrefix("one frame", () -> collider.clash(new double[][] {at(0, 0, 0)}), "collider_clash: 1 frames for 2 groups");
                clashPrefix("share (2, 2)", () -> collider.clash(two, 0.0, 2, 2), "collider_clash: share (2, 2)");
            }
            clashPrefix("one-shot clearance -1", () -> Blacksmith.clash(ab, -1.0), "clash: clearance -1");
            clashPrefix("allowed (5, 0)", () -> Blacksmith.clash(ab, null, 0.0, 0.05, new int[] {5, 0}),
                        "clash: allowed pair (5, 0) names a part out of range");
            clashPrefix("an empty others", () -> Blacksmith.clash(ab, List.of(), 0.0), "clash: an empty set");
            clashPrefix("odd allowed", () -> Blacksmith.clash(ab, null, 0.0, 0.05, new int[] {0, 1, 2}),
                        "clash: allowed is 3 numbers, not pairs");
            clashPrefix("negative allowed", () -> Blacksmith.clash(ab, null, 0.0, 0.05, new int[] {-1, 0}),
                        "clash: allowed pair (-1, 0) is not two indices");
        }
        // 6. the edge row: b turned so its edge crosses a's edge on x = 1, y = 1, 0.1 apart
        try (Blacksmith.Solid a = Blacksmith.Solid.cuboid(2, 2, 2);
             Blacksmith.Solid b = Blacksmith.Solid.cuboid(2, 2, 2);
             Blacksmith.Collider collider = new Blacksmith.Collider(new Blacksmith.Solid[] {a, b}, 1e-3, null, null)) {
            double c = Math.sqrt(0.5), s = 0.1 * c;
            double[] turned = {2 + s, 2 + s, 0, c, -c, 0, 0.5, 0.5, c, -0.5, -0.5, c};
            List<Blacksmith.Clash> rows = collider.clash(new double[][] {at(0, 0, 0), turned}, 0.5);
            if (rows.size() != 1) fail("clash: the edge pose gave " + rows);
            Blacksmith.Clash r = rows.get(0);
            if (!r.kind().equals("too_close") || Math.abs(r.distance() - 0.1) > 1e-3) fail("clash: the edge row reads " + r);
            if (Math.abs(r.onA()[0] - 1) > 2e-3 || Math.abs(r.onA()[1] - 1) > 2e-3 || Math.abs(r.onA()[2]) > 2e-3)
                fail("clash: the edge row's on_a is " + Arrays.toString(r.onA()));
            if (!r.kindA().equals("edge") || !r.kindB().equals("edge")) fail("clash: the edge row's features are " + r.kindA() + "/" + r.kindB());
            List<Blacksmith.Edge> edgesA = a.edges();
            if (r.edgeA() == null || r.edgeA() < 0 || r.edgeA() >= edgesA.size()) fail("clash: the edge row's edge_a is " + r.edgeA());
            for (Blacksmith.Edge.Segment seg : edgesA.get(r.edgeA()).segments())
                for (double[] p : new double[][] {seg.a(), seg.b()})
                    if (Math.abs(p[0] - 1) > 2e-3 || Math.abs(p[1] - 1) > 2e-3)
                        fail("clash: edge_a " + r.edgeA() + " is not a's edge on x = 1, y = 1: " + Arrays.toString(p));
            if (r.edgeB() == null || r.edgeB() < 0 || r.edgeB() >= b.edges().size()) fail("clash: the edge row's edge_b is " + r.edgeB());
            System.out.println("clash (edge row): " + r + " edge_a " + r.edgeA() + " edge_b " + r.edgeB() + " of " + edgesA.size());
        }
        System.out.println("clash: ok");
    }

    // ---- swept clash (swept clash plan 2b) ------------------------------------------------------
    // Python's test_swept_clash_*, trimmed to the marshalling. A 2-cube moving along x from -5 to
    // 5 through a 2-cube at the origin meets it at t = 0.3 and leaves at 0.7.

    private static final double SWEPT_TOL = 1e-3, SWEPT_RES = 1e-3;

    private static double[] at(double x, double y) {
        return at(x, y, 0);
    }

    private static List<List<double[]>> through() {
        return List.of(List.of(at(-5, 0), at(0, 0)), List.of(at(5, 0), at(0, 0)));
    }

    private static void sweptPrefix(String what, Runnable call, String prefix) {
        String said = refused(call);
        if (!said.startsWith(prefix)) fail("swept clash: " + what + " said '" + said + "', not '" + prefix + "...'");
    }

    private static void sweptClash() {
        // 1. cube through cube: every field read, first a working Clash after the collider is gone
        try (Blacksmith.Solid a = Blacksmith.Solid.cuboid(2, 2, 2);
             Blacksmith.Solid b = Blacksmith.Solid.cuboid(2, 2, 2)) {
            Blacksmith.Collider collider = new Blacksmith.Collider(new Blacksmith.Solid[] {a, b}, SWEPT_TOL, null, null);
            List<Blacksmith.SweptClash> rows = collider.sweptClash(through());
            collider.close();
            for (int i = 0; i < 3; i++) {
                System.gc();
                try {
                    Thread.sleep(20);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
            if (rows.size() != 1) fail("swept clash: cube through cube gave " + rows);
            Blacksmith.SweptClash r = rows.get(0);
            if (r.a() != 0 || r.b() != 1) fail("swept clash: cube through cube reads " + r);
            if (Math.abs(r.firstTime() - 0.3) > SWEPT_TOL / 10 + 1e-9) fail("swept clash: first time " + r.firstTime());
            List<double[]> spans = r.intervals();
            if (spans.size() != 1) fail("swept clash: cube through cube's intervals are " + r);
            if (spans.get(0)[0] != r.firstTime() || Math.abs(spans.get(0)[1] - 0.7) > SWEPT_RES + SWEPT_TOL / 10)
                fail("swept clash: cube through cube's interval is " + Arrays.toString(spans.get(0)));
            Blacksmith.Clash first = r.first();
            if (first.a() != 0 || first.b() != 1 || !first.kind().equals("touching")) fail("swept clash: the first clash reads " + first);
            sweptPrefix("solid() of the first touch", first::solid, "clashes_solid: pair (0, 1) is not penetrating");
            Blacksmith.Intersection x = first.intersect();
            if (x.overlaps().size() != 1) fail("swept clash: the first touch's intersect reads " + x);
            for (double[][] loop : x.overlaps().get(0).loops())
                for (double[] p : loop)
                    if (Math.abs(p[0] + 1.0) > 2 * SWEPT_TOL) fail("swept clash: the first touch leaves x = -1: " + Arrays.toString(p));
            System.out.println("swept clash (through): " + r);
        }
        try (Blacksmith.Solid a = Blacksmith.Solid.cuboid(2, 2, 2);
             Blacksmith.Solid b = Blacksmith.Solid.cuboid(2, 2, 2);
             Blacksmith.Collider collider = new Blacksmith.Collider(new Blacksmith.Solid[] {a, b}, SWEPT_TOL, null, null)) {
            // 2. there and back: two intervals, in order
            List<List<double[]>> back = new java.util.ArrayList<>(through());
            back.add(List.of(at(-5, 0), at(0, 0)));
            List<Blacksmith.SweptClash> rows = collider.sweptClash(back);
            if (rows.size() != 1 || rows.get(0).intervals().size() != 2) fail("swept clash: there and back gave " + rows);
            double[][] want = {{0.3, 0.7}, {1.3, 1.7}};
            for (int k = 0; k < 2; k++) {
                double[] span = rows.get(0).intervals().get(k);
                if (Math.abs(span[0] - want[k][0]) > SWEPT_TOL / 10 + 1e-9 || Math.abs(span[1] - want[k][1]) > SWEPT_RES + SWEPT_TOL / 10)
                    fail("swept clash: there and back's interval " + k + " is " + Arrays.toString(span));
            }
            // 3. a miss seen only within the clearance
            List<List<double[]>> passing = List.of(List.of(at(-5, 2.5), at(0, 0)), List.of(at(5, 2.5), at(0, 0)));
            if (!collider.sweptClash(passing, 0.4).isEmpty()) fail("swept clash: clearance 0.4 found rows");
            rows = collider.sweptClash(passing, 0.6);
            if (rows.size() != 1) fail("swept clash: clearance 0.6 gave " + rows);
            Blacksmith.Clash first = rows.get(0).first();
            if (!first.kind().equals("too_close") || first.distance() < 0.5 - SWEPT_TOL || first.distance() > 0.6)
                fail("swept clash: the near miss reads " + first);
            // 4. starting inside: first time 0, the overlap rebuilt there
            rows = collider.sweptClash(List.of(List.of(at(1.75, 0), at(0, 0)), List.of(at(5, 0), at(0, 0))));
            if (rows.size() != 1 || rows.get(0).firstTime() != 0.0 || !rows.get(0).first().kind().equals("penetrating"))
                fail("swept clash: starting inside gave " + rows);
            try (Blacksmith.Solid overlap = rows.get(0).first().solid()) {
                if (Math.abs(overlap.mass(0).volume() - 1.0) > 1e-6) fail("swept clash: the overlap's volume is " + overlap.mass(0).volume());
            }
        }
        // 5. one-shot: two sets index the second set, agree with the collider; one set; allowed
        try (Blacksmith.Solid a0 = Blacksmith.Solid.cuboid(2, 2, 2);
             Blacksmith.Solid cube = Blacksmith.Solid.cuboid(2, 2, 2);
             Blacksmith.Solid a1 = cube.translate(0, 20, 0);
             Blacksmith.Solid b0 = Blacksmith.Solid.cuboid(2, 2, 2);
             Blacksmith.Solid b1 = Blacksmith.Solid.cuboid(2, 2, 2)) {
            List<List<double[]>> still = List.of(List.of(at(0, 0), at(0, 0)), List.of(at(0, 0), at(0, 0)));
            List<List<double[]>> moving = List.of(List.of(at(-5, 0), at(-5, 20)), List.of(at(5, 0), at(5, 20)));
            List<Blacksmith.SweptClash> two = Blacksmith.sweptClash(List.of(a0, a1), still, List.of(b0, b1), moving, 0.0, SWEPT_TOL,
                                                                    1e-3, 100000, null);
            if (two.size() != 2 || two.get(0).a() != 0 || two.get(0).b() != 0 || two.get(1).a() != 1 || two.get(1).b() != 1)
                fail("swept clash: two sets gave " + two);
            for (Blacksmith.SweptClash r : two)
                if (r.first().a() != r.a() || r.first().b() != r.b()) fail("swept clash: a two-set row's first is " + r.first());
            try (Blacksmith.Collider collider = new Blacksmith.Collider(new Blacksmith.Solid[] {a0, a1, b0, b1}, SWEPT_TOL, null, null)) {
                List<List<double[]>> joined = new java.util.ArrayList<>();
                for (int k = 0; k < 2; k++) {
                    List<double[]> pose = new java.util.ArrayList<>(still.get(k));
                    pose.addAll(moving.get(k));
                    joined.add(pose);
                }
                List<Blacksmith.SweptClash> via = collider.sweptClash(joined);
                if (via.size() != two.size()) fail("swept clash: the collider gave " + via + ", the one-shot " + two);
                for (int i = 0; i < via.size(); i++) {
                    Blacksmith.SweptClash v = via.get(i), t = two.get(i);
                    if (v.a() != t.a() || v.b() - 2 != t.b() || v.firstTime() != t.firstTime()
                            || v.intervals().size() != t.intervals().size()
                            || !Arrays.equals(v.intervals().get(0), t.intervals().get(0)))
                        fail("swept clash: the collider's " + v + " is not the one-shot's " + t);
                }
            }
            List<List<double[]>> crossing = List.of(List.of(at(0, 0), at(-5, 0)), List.of(at(0, 0), at(5, 0)));
            List<Blacksmith.SweptClash> one = Blacksmith.sweptClash(List.of(a0, b0), crossing, null, null, 0.0, SWEPT_TOL, 1e-3, 100000, null);
            if (one.size() != 1 || one.get(0).a() != 0 || one.get(0).b() != 1) fail("swept clash: one set gave " + one);
            if (!Blacksmith.sweptClash(List.of(a0, b0), crossing, null, null, 0.0, SWEPT_TOL, 1e-3, 100000, new int[] {0, 1}).isEmpty())
                fail("swept clash: an allowed pair was tested");
        }
        // 6. refusals, by prefix
        try (Blacksmith.Solid a = Blacksmith.Solid.cuboid(2, 2, 2);
             Blacksmith.Solid b = Blacksmith.Solid.cuboid(2, 2, 2)) {
            try (Blacksmith.Collider collider = new Blacksmith.Collider(new Blacksmith.Solid[] {a, b}, SWEPT_TOL, null, null)) {
                sweptPrefix("one pose", () -> collider.sweptClash(through().subList(0, 1)),
                            "collider_swept_clash: 1 poses, at least 2 are needed");
                sweptPrefix("one frame", () -> collider.sweptClash(List.of(List.of(at(0, 0)), List.of(at(0, 0)))),
                            "collider_swept_clash: 1 frames for 2 groups");
                sweptPrefix("a ragged pose", () -> collider.sweptClash(List.of(List.of(at(0, 0), at(0, 0)), List.of(at(0, 0)))),
                            "collider_swept_clash: 1 frames for 2 groups");
                sweptPrefix("resolution 0", () -> collider.sweptClash(through(), 0.0, 0.0, 100000, null, null),
                            "collider_swept_clash: resolution 0");
                sweptPrefix("max_steps 0", () -> collider.sweptClash(through(), 0.0, 1e-3, 0, null, null),
                            "collider_swept_clash: max_steps must be at least 1");
                sweptPrefix("clearance -1", () -> collider.sweptClash(through(), -1.0), "collider_swept_clash: clearance -1");
                sweptPrefix("share (2, 2)", () -> collider.sweptClash(through(), 0.0, 1e-3, 100000, 2, 2),
                            "collider_swept_clash: share (2, 2)");
            }
            List<List<double[]>> still = List.of(List.of(at(0, 0)), List.of(at(0, 0)));
            sweptPrefix("others alone", () -> Blacksmith.sweptClash(List.of(a), still, List.of(b), null),
                        "swept_clash: others and other_poses go together");
            sweptPrefix("other_poses alone", () -> Blacksmith.sweptClash(List.of(a), still, null, still),
                        "swept_clash: others and other_poses go together");
            sweptPrefix("pose counts", () -> Blacksmith.sweptClash(List.of(a), still, List.of(b), still.subList(0, 1)),
                        "swept_clash: 2 poses for set a, 1 for set b");
            sweptPrefix("a pose of b", () -> Blacksmith.sweptClash(List.of(a), still, List.of(b),
                                                                   List.of(List.of(at(0, 0)), List.of(at(0, 0), at(0, 0)))),
                        "swept_clash: pose 1 of set b has 2 frames for 1 parts");
            sweptPrefix("an empty others", () -> Blacksmith.sweptClash(List.of(a), still, List.of(), List.of(List.of(), List.of())),
                        "swept_clash: an empty set");
            List<Blacksmith.Solid> ab = List.of(a, b);
            sweptPrefix("allowed (5, 0)", () -> Blacksmith.sweptClash(ab, through(), null, null, 0.0, 0.05, 1e-3, 100000, new int[] {5, 0}),
                        "swept_clash: allowed pair (5, 0) names a part out of range");
            sweptPrefix("odd allowed", () -> Blacksmith.sweptClash(ab, through(), null, null, 0.0, 0.05, 1e-3, 100000, new int[] {0, 1, 2}),
                        "swept_clash: allowed is 3 numbers, not pairs");
            sweptPrefix("negative allowed", () -> Blacksmith.sweptClash(ab, through(), null, null, 0.0, 0.05, 1e-3, 100000, new int[] {-1, 0}),
                        "swept_clash: allowed pair (-1, 0) is not two indices");
            sweptPrefix("max_steps 0", () -> Blacksmith.sweptClash(ab, through(), null, null, 0.0, 0.05, 1e-3, 0, null),
                        "swept_clash: max_steps must be at least 1");
            sweptPrefix("one pose", () -> Blacksmith.sweptClash(ab, through().subList(0, 1)), "swept_clash: 1 poses, at least 2 are needed");
        }
        System.out.println("swept clash: ok");
    }

    // ---- an assembly's swept clash (swept clash plan 3c) ----------------------------------------
    // Python's _rig and its six test_assembly_* swept tests, trimmed to the marshalling. The rig: a
    // `base` plate on link `ground`; an `arm`, cuboid(3, 0.2, 0.2) from the hinge out along x, on
    // link `arm`, turning on `hinge` (revolute about z through the origin); a `carriage` far out on
    // `slide` (cylindrical, two values); and two cubes in no link, held fixed: `chord` below the
    // hinge, which the chord between the arm's end poses crosses and its arc never does, and
    // `circle` on the arm's circle at 90 degrees.

    private static void rigPlace(Blacksmith.Assembly into, double x, double y, double z, double[] frame, String name) {
        try (Blacksmith.Solid s = Blacksmith.Solid.cuboid(x, y, z)) {
            into.place(s, frame, name);
        }
    }

    private static Blacksmith.Assembly sweptRig(Blacksmith.Assembly hand) {
        Blacksmith.Assembly rig = new Blacksmith.Assembly("rig");
        rigPlace(rig, 1, 1, 0.4, at(0, 0, -1), "base");
        if (hand == null) rigPlace(rig, 3, 0.2, 0.2, at(1.5, 0, 0), "arm");
        else rig.place(hand, at(1.5, 0, 0), "hand");
        rigPlace(rig, 0.4, 0.4, 0.4, at(0, -1.2, 0), "chord");
        rigPlace(rig, 0.4, 0.4, 0.4, at(0, 1.5, 0), "circle");
        rigPlace(rig, 0.4, 0.4, 0.4, at(20, 0, 0), "carriage");
        rig.link("ground", "base");
        rig.link("arm", hand == null ? "arm" : "hand");
        rig.link("carriage", "carriage");
        rig.joint("hinge", "ground", "arm");
        rig.pair("hinge", "revolute", Blacksmith.Frame.xy());
        rig.joint("slide", "ground", "carriage");
        rig.pair("slide", "cylindrical", Blacksmith.Frame.xy());
        rig.base("ground");
        return rig;
    }

    /** A `tip` cube on link `body`, and a `nub` well above it on `nubs`, turning on `turn`. */
    private static Blacksmith.Assembly sweptHand() {
        Blacksmith.Assembly hand = new Blacksmith.Assembly("hand");
        rigPlace(hand, 0.4, 0.4, 0.4, at(0, 0, 0), "tip");
        rigPlace(hand, 0.2, 0.2, 0.2, at(0, 0, 2), "nub");
        hand.link("body", "tip");
        hand.link("nubs", "nub");
        hand.joint("turn", "body", "nubs");
        hand.pair("turn", "revolute", Blacksmith.Frame.xy());
        return hand;
    }

    private static Blacksmith.StateRow jointRow(String joint, double... values) {
        return new Blacksmith.StateRow(joint, values);
    }

    /** The hinge at 0, 90 and 180 degrees, the carriage sliding 0, 0.5, 1 unturned. */
    private static List<List<Blacksmith.StateRow>> swing() {
        return List.of(List.of(jointRow("hinge", 0.0), jointRow("slide", 0.0, 0.0)),
                       List.of(jointRow("hinge", Math.PI / 2), jointRow("slide", 0.5, 0.0)),
                       List.of(jointRow("hinge", Math.PI), jointRow("slide", 1.0, 0.0)));
    }

    /** The time the arm's leading face (y = 0.1 in its own frame) is {@code gap} from the circle
     *  cube's corner (0.2, 1.3), the first point it meets, in the first segment. */
    private static double circleTime(double gap) {
        double r = Math.hypot(1.3, 0.2), phi = Math.atan2(0.2, 1.3);
        return (Math.acos((0.1 + gap) / r) - phi) / (Math.PI / 2);
    }

    /** Each row as "a|b" by the assembly's part names. */
    private static List<String> sweptNames(List<String> names, List<Blacksmith.SweptClash> rows) {
        return rows.stream().map(r -> names.get(r.a()) + "|" + names.get(r.b())).toList();
    }

    /** Each row as "a, b, first time". */
    private static List<String> sweptRows(List<Blacksmith.SweptClash> rows) {
        return rows.stream().map(r -> r.a() + ", " + r.b() + ", " + r.firstTime()).toList();
    }

    private static void assemblySwept(String what, Runnable call, String message) {
        String said = refused(call);
        if (!said.equals(message)) fail("assembly swept clash: " + what + " said '" + said + "', not '" + message + "'");
    }

    private static void assemblySweptClash() {
        // 1. parts: depth first, placements in order, a "/" inside a name escaped
        try (Blacksmith.Assembly sub = new Blacksmith.Assembly("pair");
             Blacksmith.Assembly top = new Blacksmith.Assembly("top");
             Blacksmith.Assembly empty = new Blacksmith.Assembly("empty")) {
            rigPlace(sub, 1, 1, 1, at(0, 0, 0), "x");
            rigPlace(sub, 1, 1, 1, at(2, 0, 0), "y");
            rigPlace(top, 1, 1, 1, at(0, 5, 0), "p");
            top.place(sub, at(0, 0, 0), "a/b");
            rigPlace(top, 1, 1, 1, at(0, 9, 0), "q");
            List<String> parts = top.parts();
            if (!parts.equals(List.of("p", "a\\/b/x", "a\\/b/y", "q"))) fail("assembly swept clash: parts " + parts);
            if (!empty.parts().isEmpty()) fail("assembly swept clash: the empty assembly lists " + empty.parts());
        }
        // 2. the arc, not the chord: catches the values flattened joint-major (the hinge would read
        // the carriage's values and never reach the circle cube) and rows that do not index parts()
        try (Blacksmith.Assembly rig = sweptRig(null)) {
            List<String> names = rig.parts();
            if (!names.equals(List.of("base", "arm", "chord", "circle", "carriage"))) fail("assembly swept clash: rig parts " + names);
            List<Blacksmith.SweptClash> rows = rig.sweptClash(swing(), 0.0, SWEPT_TOL, 1e-3, 100000, null, null, false);
            if (!sweptNames(names, rows).equals(List.of("arm|circle"))) fail("assembly swept clash: the swing gave " + rows);
            Blacksmith.SweptClash r = rows.get(0);
            if (r.first() == null || r.first().a() != r.a() || r.first().b() != r.b()) fail("assembly swept clash: first " + r.first());
            double within = circleTime(SWEPT_TOL), meets = circleTime(0.0);
            if (r.firstTime() < within - 1e-9 || r.firstTime() > meets + 1e-9)
                fail("assembly swept clash: first time " + r.firstTime() + " outside [" + within + ", " + meets + "]");
        }
        // 3. the arm starts at 1.5 rad, already through the circle cube: penetrating at time 0, and
        // the overlap rebuilt from the first row lies inside the arm's box turned 1.5 about z
        try (Blacksmith.Assembly rig = sweptRig(null)) {
            List<Blacksmith.SweptClash> rows = rig.sweptClash(
                    List.of(List.of(jointRow("hinge", 1.5), jointRow("slide", 0.0, 0.0)),
                            List.of(jointRow("hinge", Math.PI), jointRow("slide", 0.0, 0.0))),
                    0.0, SWEPT_TOL, 1e-3, 100000, null, null, false);
            if (!sweptRows(rows).equals(List.of("1, 3, 0.0"))) fail("assembly swept clash: from 1.5 rad gave " + rows);
            double co = Math.cos(1.5), si = Math.sin(1.5);
            try (Blacksmith.Solid got = rows.get(0).first().solid();
                 Blacksmith.Solid arm = Blacksmith.Solid.cuboid(3, 0.2, 0.2);
                 Blacksmith.Solid out = arm.translate(1.5, 0, 0)) {
                Blacksmith.Box g = got.boundsBox(SWEPT_TOL);
                Blacksmith.Box w = out.boundsBox(SWEPT_TOL).moved(new double[] {0, 0, 0, co, si, 0, -si, co, 0, 0, 0, 1});
                for (int k = 0; k < 3; k++) {
                    if (g.lo()[k] < w.lo()[k] - 1e-6 || g.hi()[k] > w.hi()[k] + 1e-6)
                        fail("assembly swept clash: the overlap " + Arrays.toString(g.lo()) + Arrays.toString(g.hi())
                             + " leaves the turned arm " + Arrays.toString(w.lo()) + Arrays.toString(w.hi()));
                }
                if (g.lo()[1] < 1.3 - 4 * SWEPT_TOL || g.hi()[1] > 1.7 + 4 * SWEPT_TOL || !(g.hi()[0] > g.lo()[0]))
                    fail("assembly swept clash: the overlap " + Arrays.toString(g.lo()) + Arrays.toString(g.hi()) + " is not at the circle cube");
            }
        }
        // 4. a pin on the arm's link inside a bore on the ground link, the hinge joining them:
        // catches `joined` dropped on its way to the kernel
        try (Blacksmith.Assembly pinned = new Blacksmith.Assembly("pinned")) {
            rigPlace(pinned, 0.6, 0.6, 0.6, at(0, 0, 0), "bore");
            rigPlace(pinned, 0.2, 0.2, 0.2, at(0, 0, 0), "pin");
            pinned.link("ground", "bore");
            pinned.link("arm", "pin");
            pinned.joint("hinge", "ground", "arm");
            pinned.pair("hinge", "revolute", Blacksmith.Frame.xy());
            List<List<Blacksmith.StateRow>> keys = List.of(List.of(jointRow("hinge", 0.0)), List.of(jointRow("hinge", 1.0)));
            if (!pinned.sweptClash(keys, 0.0, SWEPT_TOL, 1e-3, 100000, null, null, false).isEmpty())
                fail("assembly swept clash: joined links were tested by default");
            List<Blacksmith.SweptClash> rows = pinned.sweptClash(keys, 0.0, SWEPT_TOL, 1e-3, 100000, null, null, true);
            if (!sweptRows(rows).equals(List.of("0, 1, 0.0"))) fail("assembly swept clash: joined gave " + rows);
            if (!pinned.sweptClash(keys, 0.0, SWEPT_TOL, 1e-3, 100000, new int[] {0, 1}, null, true).isEmpty())
                fail("assembly swept clash: an allowed joined pair was tested");
        }
        // 5. a sub-assembly rides its placement's link
        try (Blacksmith.Assembly hand = sweptHand(); Blacksmith.Assembly rig = sweptRig(hand)) {
            List<String> names = rig.parts();
            if (!names.equals(List.of("base", "hand/tip", "hand/nub", "chord", "circle", "carriage")))
                fail("assembly swept clash: hand rig parts " + names);
            List<Blacksmith.SweptClash> rows = rig.sweptClash(swing(), 0.0, SWEPT_TOL, 1e-3, 100000, null, null, false);
            if (!sweptNames(names, rows).equals(List.of("hand/tip|circle"))) fail("assembly swept clash: the hand gave " + rows);
        }
        // 6. refusals, by their exact words: the wrapper's own first, then the kernel's passed on
        try (Blacksmith.Assembly hand = sweptHand(); Blacksmith.Assembly rig = sweptRig(hand)) {
            List<List<Blacksmith.StateRow>> two = List.of(List.of(jointRow("hinge", 0.0)), List.of(jointRow("hinge", 1.0)));
            assemblySwept("keyframe 2 without slide", () -> rig.sweptClash(List.of(
                    List.of(jointRow("hinge", 0.0), jointRow("slide", 0.0, 0.0)),
                    List.of(jointRow("hinge", 1.0), jointRow("slide", 0.0, 0.0)),
                    List.of(jointRow("hinge", 2.0)))),
                    "swept_clash: joint 'slide' is in keyframe 0 and not in keyframe 2");
            assemblySwept("keyframe 1 with slide", () -> rig.sweptClash(List.of(
                    List.of(jointRow("hinge", 0.0)),
                    List.of(jointRow("hinge", 1.0), jointRow("slide", 0.0, 0.0)))),
                    "swept_clash: joint 'slide' is in keyframe 1 and not in keyframe 0");
            assemblySwept("hinge twice", () -> rig.sweptClash(List.of(
                    List.of(jointRow("hinge", 0.0)),
                    List.of(jointRow("hinge", 1.0), jointRow("hinge", 2.0)))),
                    "swept_clash: joint 'hinge' is given twice");
            assemblySwept("value counts", () -> rig.sweptClash(List.of(
                    List.of(jointRow("slide", 0.0, 0.0)), List.of(jointRow("slide", 1.0)))),
                    "swept_clash: joint 'slide' has 2 values in keyframe 0 and 1 in keyframe 1");
            assemblySwept("hand/turn", () -> rig.sweptClash(List.of(
                    List.of(jointRow("hand/turn", 0.0)), List.of(jointRow("hand/turn", 1.0)))),
                    "swept_clash: joint 'hand/turn' is in a sub-assembly; a sweep moves this assembly's own joints");
            assemblySwept("elbow", () -> rig.sweptClash(List.of(
                    List.of(jointRow("elbow", 0.0)), List.of(jointRow("elbow", 1.0)))),
                    "swept_clash: no joint named 'elbow' in assembly 'rig' or under it");
            assemblySwept("hinge with 2 values", () -> rig.sweptClash(List.of(
                    List.of(jointRow("hinge", 0.0, 0.0)), List.of(jointRow("hinge", 1.0, 1.0)))),
                    "swept_clash: joint 'hinge' takes 1 values, but 2 were given");
            assemblySwept("one keyframe", () -> rig.sweptClash(two.subList(0, 1)), "swept_clash: 1 poses, at least 2 are needed");
            String said = refused(() -> rig.sweptClash(two, 0.0, 0.05, 0.0, 100000, null, null, false));
            if (!said.startsWith("swept_clash: resolution 0")) fail("assembly swept clash: resolution 0 said '" + said + "'");
            assemblySwept("max_steps 0", () -> rig.sweptClash(two, 0.0, 0.05, 1e-3, 0, null, null, false),
                          "swept_clash: max_steps must be at least 1");
            assemblySwept("allowed (9, 0)", () -> rig.sweptClash(two, 0.0, 0.05, 1e-3, 100000, new int[] {9, 0}, null, false),
                          "swept_clash: allowed pair (9, 0) names a part out of range");
            assemblySwept("odd allowed", () -> rig.sweptClash(two, 0.0, 0.05, 1e-3, 100000, new int[] {0, 1, 2}, null, false),
                          "swept_clash: allowed is 3 numbers, not pairs");
            assemblySwept("negative allowed", () -> rig.sweptClash(two, 0.0, 0.05, 1e-3, 100000, new int[] {-1, 0}, null, false),
                          "swept_clash: allowed pair (-1, 0) is not two indices");
            assemblySwept("ground wheel", () -> rig.sweptClash(two, 0.0, 0.05, 1e-3, 100000, null, "wheel", false),
                          "swept_clash: assembly 'rig' has no link named 'wheel'");
        }
        System.out.println("assembly swept clash: ok");
    }

    // ---- wall thickness (plan 2b) --------------------------------------------------------------
    // Python's test_thickness_* and test_mesh_thickness_*, trimmed to what proves the marshalling.

    private static void thicknessPrefix(String what, Runnable call, String prefix) {
        String said = refused(call);
        if (!said.startsWith(prefix)) fail("thickness: " + what + " said '" + said + "', not '" + prefix + "...'");
    }

    private static void thicknessExact(String what, Runnable call, String message) {
        String said = refused(call);
        if (!said.equals(message)) fail("thickness: " + what + " said '" + said + "', not '" + message + "'");
    }

    /** The face of body {@code body} whose reading at {@code p} lies at {@code p}. */
    private static int thicknessFaceHolding(Blacksmith.ThicknessGauge g, int faces, int body, double[] p) {
        for (int f = 0; f < faces; f++) {
            Blacksmith.Thickness r = g.thicknessAt(body, f, p, 100.0, 0.5);
            if (r != null && near(r.point(), p[0], p[1], p[2], 1e-9)) return f;
        }
        fail("thickness: no face holds " + Arrays.toString(p));
        return -1;
    }

    private static Blacksmith.Solid thicknessTube() {
        try (Blacksmith.Profile ring = Blacksmith.Profile.circle(5.0).withHole(Blacksmith.Profile.circle(4.0))) {
            return Blacksmith.Solid.extrude(ring, Blacksmith.Frame.xy().toArray(), 10.0);
        }
    }

    private static final Blacksmith.MeshInput THICKNESS_LOWER = new Blacksmith.MeshInput(
            new double[][] {{0, 0, 0}, {0, 1, 0}, {1, 0, 0}}, new int[][] {{0, 1, 2}});
    private static final Blacksmith.MeshInput THICKNESS_UPPER = new Blacksmith.MeshInput(
            new double[][] {{0, 0, 1}, {1, 0, 1}, {0, 1, 1}}, new int[][] {{0, 1, 2}});

    private static void wallThickness() {
        double[] probe = {1.0, 2.0, 1.0};
        // 1. a plate reads two at every cap vertex; every field read
        try (Blacksmith.Solid plate = Blacksmith.Solid.cuboid(10, 10, 2)) {
            List<Blacksmith.Thickness> rows;
            Blacksmith.ThicknessMesh mesh;
            try (Blacksmith.ThicknessGauge g = new Blacksmith.ThicknessGauge(List.of(plate))) {
                if (g.bodyCount() != 1 || g.tolerance() != 0.01) fail("thickness: the gauge reads " + g.bodyCount() + " bodies at " + g.tolerance());
                rows = g.thickness(10.0, 0.5);
                mesh = g.mesh(0);
            }
            int caps = 0;
            for (Blacksmith.Thickness r : rows) {
                if (Math.abs(Math.abs(r.point()[2]) - 1) < 1e-9 && Math.abs(r.opposite()[2] + r.point()[2]) < 1e-9) {
                    caps++;
                    if (Math.abs(r.thickness() - 2) > 1e-9 || Math.abs(r.exactThickness() - 2) > 1e-9)
                        fail("thickness: a cap vertex reads " + r.thickness() + " / " + r.exactThickness());
                    if (Math.abs(r.exactOpposite()[2] + r.point()[2]) > 1e-9) fail("thickness: exactOpposite " + Arrays.toString(r.exactOpposite()));
                    if (r.knife() || r.oppositeBody() != 0) fail("thickness: a cap vertex reads " + r);
                }
            }
            if (caps < 8) fail("thickness: only " + caps + " cap rows of " + rows.size());
            for (Blacksmith.Thickness r : rows) {
                if (r.body() != 0 || r.vertex() == null) fail("thickness: a row reads body " + r.body() + " vertex " + r.vertex());
                if (r.point().length != 3 || r.opposite().length != 3 || r.exactOpposite().length != 3) fail("thickness: a point is not three numbers");
                if (!Arrays.equals(mesh.positions()[r.vertex()], r.point())) fail("thickness: vertex " + r.vertex() + " is not at the mesh's position");
                if (r.sphere() != null && Double.isNaN(r.sphere())) fail("thickness: a NaN sphere survived as a number");
                if (r.oppositeFace() < 0 || r.oppositeFace() >= plate.faces()) fail("thickness: opposite face " + r.oppositeFace());
            }
            // below the wall nothing reads; the sharp angle defaults to 0
            try (Blacksmith.ThicknessGauge g = new Blacksmith.ThicknessGauge(List.of(plate), 0.01)) {
                if (!g.thickness(1.0).isEmpty()) fail("thickness: maximum 1 read something");
                if (g.thickness(10.0).size() != rows.size()) fail("thickness: the default sharp angle changed the rows");
            }
            // 2. the mesh is a copy that matches the readings
            Blacksmith.ThicknessGauge g = new Blacksmith.ThicknessGauge(List.of(plate));
            Blacksmith.ThicknessMesh m = g.mesh(0);
            if (m.faces().length != m.triangles().length || m.triangles().length < 12) fail("thickness: mesh has " + m.triangles().length + " triangles");
            if (m.normals().length != m.positions().length || m.positions().length == 0) fail("thickness: mesh normals do not match its positions");
            for (double[] n : m.normals())
                if (Math.abs(Math.sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]) - 1) > 1e-9) fail("thickness: a normal is not unit");
            for (int[] t : m.triangles())
                for (int k : t) if (k < 0 || k >= m.positions().length) fail("thickness: a triangle names vertex " + k);
            for (int f : m.faces()) if (f < 0 || f >= plate.faces()) fail("thickness: a triangle lies on face " + f);
            List<Blacksmith.Thickness> all = g.thickness(100.0, 0.5);
            if (all.size() != m.positions().length) fail("thickness: " + all.size() + " rows for " + m.positions().length + " vertices");
            for (Blacksmith.Thickness r : all) {
                int t = -1;
                for (int i = 0; i < m.triangles().length && t < 0; i++)
                    for (int k : m.triangles()[i]) if (k == r.vertex()) t = i;
                if (t < 0 || m.faces()[t] != r.face()) fail("thickness: vertex " + r.vertex() + " lies on face " + r.face() + ", its triangle on " + (t < 0 ? -1 : m.faces()[t]));
            }
            thicknessExact("mesh(1)", () -> g.mesh(1), "thickness_gauge_mesh: no body 1 -- there are 1");
            g.close();
            if (m.positions().length != all.size()) fail("thickness: the mesh changed under the closed gauge");
            thicknessExact("mesh on a closed gauge", () -> g.mesh(0), "thickness_gauge: closed");
            // 3. a reading at a point has no vertex
            try (Blacksmith.ThicknessGauge h = new Blacksmith.ThicknessGauge(List.of(plate))) {
                int top = thicknessFaceHolding(h, plate.faces(), 0, probe);
                Blacksmith.Thickness r = h.thicknessAt(0, top, probe, 100.0, 0.5);
                if (r == null || r.vertex() != null) fail("thickness: a point reading has vertex " + (r == null ? "(none: no row)" : r.vertex()));
                if (r.body() != 0 || r.face() != top || r.oppositeBody() != 0) fail("thickness: the point row reads " + r);
                if (!Arrays.equals(r.point(), probe)) fail("thickness: the point row sits at " + Arrays.toString(r.point()));
                if (Math.abs(r.thickness() - 2) > 1e-9 || Math.abs(r.exactThickness() - 2) > 1e-9) fail("thickness: the point row reads " + r.thickness());
                if (Math.abs(r.opposite()[2] + 1) > 1e-9 || Math.abs(r.exactOpposite()[2] + 1) > 1e-9) fail("thickness: the point row's opposite is " + Arrays.toString(r.opposite()));
                if (r.sphere() == null || Math.abs(r.sphere() - 2) > 0.02) fail("thickness: the point row's sphere is " + r.sphere());
                if (h.thicknessAt(0, top, probe, 1.0, 0.5) != null) fail("thickness: maximum 1 read at the point");
                if (h.thicknessAt(0, top, probe, 100.0).thickness() != r.thickness()) fail("thickness: the default sharp angle changed the point row");
                // 4. a face's thickness, and none where nothing is found
                Blacksmith.FaceThickness f = h.thicknessAtFace(0, top, 100.0);
                if (f == null || Math.abs(f.thickness() - 2) > 1e-9 || !f.uniform() || Math.abs(f.min() - 2) > 1e-9 || Math.abs(f.max() - 2) > 1e-9)
                    fail("thickness: the face reads " + f);
                double[] above = {1.0, 2.0, 5.0};
                Blacksmith.FaceThickness a = h.thicknessAtFace(0, top, above, 100.0);
                if (a == null || Math.abs(a.thickness() - 2) > 1e-9 || a.min() != a.max() || !a.uniform()) fail("thickness: the face at a point reads " + a);
                if (h.thicknessAtFace(0, top, 1.0) != null) fail("thickness: maximum 1 found a face thickness");
                if (h.thicknessAtFace(0, top, new double[] {50.0, 2.0, 5.0}, 100.0) != null) fail("thickness: an at off the face found a thickness");
                // the one-body convenience: a gauge of its own
                Blacksmith.FaceThickness s = plate.thicknessAtFace(top, 100.0);
                if (s == null || Math.abs(s.thickness() - 2) > 1e-9 || !s.uniform()) fail("thickness: Solid.thicknessAtFace reads " + s);
                Blacksmith.FaceThickness s2 = plate.thicknessAtFace(top, above, 100.0, 0.05);
                if (s2 == null || Math.abs(s2.thickness() - 2) > 1e-9) fail("thickness: Solid.thicknessAtFace at 0.05 reads " + s2);
                if (plate.thicknessAtFace(top, 1.0) != null) fail("thickness: Solid.thicknessAtFace found a thickness under a maximum of 1");
            }
        }
        // 5. a ball past the maximum is none
        try (Blacksmith.Profile tri = Blacksmith.Profile.polygon(new double[][] {{0, 0}, {10, 0}, {0, 10}});
             Blacksmith.Solid wedge = Blacksmith.Solid.extrude(tri, Blacksmith.Frame.xy().toArray(), 20.0);
             Blacksmith.ThicknessGauge g = new Blacksmith.ThicknessGauge(List.of(wedge))) {
            double[] at = {5.0, 0.0, 10.0};
            int f = thicknessFaceHolding(g, wedge.faces(), 0, at);
            Blacksmith.Thickness wide = g.thicknessAt(0, f, at, 100.0, 0.5);
            if (wide == null || wide.sphere() == null || Math.abs(wide.sphere() - 2 * 5 / (1 + Math.sqrt(2))) > 0.01)
                fail("thickness: the wedge's wide sphere is " + (wide == null ? null : wide.sphere()));
            Blacksmith.Thickness narrow = g.thicknessAt(0, f, at, 4.0, 0.5);
            if (narrow == null || Math.abs(narrow.thickness() - 5 / Math.sqrt(2)) > 1e-9) fail("thickness: the wedge's narrow row is " + narrow);
            if (narrow.sphere() != null) fail("thickness: the wedge's ball past the maximum reads " + narrow.sphere());
        }
        // a tapering face is not uniform, and its figure lies between its extremes: a trapezoid
        // whose top slopes (the right wedge's corners lie on its sloped face's plane, which reads nothing)
        try (Blacksmith.Profile trap = Blacksmith.Profile.polygon(new double[][] {{0, 0}, {10, 0}, {10, 4}, {0, 8}});
             Blacksmith.Solid slab = Blacksmith.Solid.extrude(trap, Blacksmith.Frame.xy().toArray(), 20.0);
             Blacksmith.ThicknessGauge g = new Blacksmith.ThicknessGauge(List.of(slab))) {
            int tapered = 0;
            for (int face = 0; face < slab.faces(); face++) {
                Blacksmith.FaceThickness ft = g.thicknessAtFace(0, face, 100.0);
                if (ft == null) continue;
                if (ft.min() > ft.thickness() + 1e-12 || ft.thickness() > ft.max() + 1e-12) fail("thickness: a face reads " + ft);
                if (!ft.uniform() && ft.max() - ft.min() > 0.5) tapered++;
            }
            if (tapered == 0) fail("thickness: no face of the sloped slab reads as tapering");
        }
        // 6. two bodies read each other, and the one-shot agrees
        try (Blacksmith.Profile quad = Blacksmith.Profile.polygon(new double[][] {{0, 0}, {10, 0}, {10, 3}, {0, 1}});
             Blacksmith.Solid slab = Blacksmith.Solid.extrude(quad, Blacksmith.Frame.xy().toArray(), 4.0);
             Blacksmith.Solid tube = thicknessTube()) {
            List<Blacksmith.Thickness> via;
            try (Blacksmith.ThicknessGauge g = new Blacksmith.ThicknessGauge(List.of(slab, tube))) {
                if (g.bodyCount() != 2) fail("thickness: the pair gauge has " + g.bodyCount() + " bodies");
                via = g.thickness(100.0, 0.5);
            }
            List<Blacksmith.Thickness> one = Blacksmith.thickness(List.of(slab, tube), 100.0, 0.5);
            if (one.size() != via.size()) fail("thickness: the one-shot read " + one.size() + " rows, the gauge " + via.size());
            boolean slabReadsTube = false, tubeReadsSlab = false;
            for (int i = 0; i < one.size(); i++) {
                Blacksmith.Thickness x = one.get(i), y = via.get(i);
                if (x.body() != y.body() || !java.util.Objects.equals(x.vertex(), y.vertex()) || x.face() != y.face()
                        || x.thickness() != y.thickness() || x.oppositeBody() != y.oppositeBody())
                    fail("thickness: the one-shot row " + i + " differs: " + x + " / " + y);
                slabReadsTube |= x.body() == 0 && x.oppositeBody() == 1;
                tubeReadsSlab |= x.body() == 1 && x.oppositeBody() == 0;
            }
            if (!slabReadsTube || !tubeReadsSlab) fail("thickness: the slab and the tube do not read each other");
            if (!Blacksmith.thickness(List.of(slab), 0.001).isEmpty()) fail("thickness: a maximum of 0.001 read something");
            if (Blacksmith.thickness(List.of(slab), 100.0, 0.0, 0.05).isEmpty()) fail("thickness: the one-shot at 0.05 read nothing");
        }
        // 7. mesh_thickness: two triangles one apart read one across
        List<Blacksmith.MeshInput> meshes = List.of(THICKNESS_LOWER, THICKNESS_UPPER);
        List<Blacksmith.MeshThickness> flat = Blacksmith.meshThickness(meshes, 10.0, 0.5);
        if (flat.size() != 6) fail("mesh_thickness: " + flat.size() + " rows");
        for (int i = 0; i < flat.size(); i++) {
            Blacksmith.MeshThickness r = flat.get(i);
            if (r.mesh() != i / 3 || r.vertex() != i % 3) fail("mesh_thickness: row " + i + " is mesh " + r.mesh() + " vertex " + r.vertex());
            if (Math.abs(r.thickness() - 1) > 1e-12 || r.knife()) fail("mesh_thickness: row " + i + " reads " + r.thickness());
            if (r.oppositeMesh() != 1 - r.mesh() || r.oppositeTriangle() != 0) fail("mesh_thickness: row " + i + " opposite " + r.oppositeMesh() + "/" + r.oppositeTriangle());
            if (!Arrays.equals(r.point(), meshes.get(r.mesh()).positions()[r.vertex()])) fail("mesh_thickness: row " + i + " point " + Arrays.toString(r.point()));
            if (Math.abs(r.opposite()[2] - (1 - r.point()[2])) > 1e-12 || r.opposite()[0] != r.point()[0] || r.opposite()[1] != r.point()[1])
                fail("mesh_thickness: row " + i + " opposite " + Arrays.toString(r.opposite()));
        }
        if (!Blacksmith.meshThickness(meshes, 0.5, 0.5).isEmpty()) fail("mesh_thickness: maximum 0.5 read something");
        if (!Blacksmith.meshThickness(List.of(), 1.0).isEmpty()) fail("mesh_thickness: no meshes read something");
        if (Blacksmith.meshThickness(meshes, 10.0).size() != 6) fail("mesh_thickness: the default sharp angle changed the rows");
        // 8. refusals, by prefix
        try (Blacksmith.Solid plate = Blacksmith.Solid.cuboid(10, 10, 2)) {
            List<Blacksmith.Solid> one = List.of(plate);
            thicknessPrefix("tolerance 0", () -> new Blacksmith.ThicknessGauge(one, 0.0).close(),
                            "thickness_gauge_new: the tolerance must be positive and finite");
            Blacksmith.ThicknessGauge g = new Blacksmith.ThicknessGauge(one);
            thicknessPrefix("maximum 0", () -> g.thickness(0.0), "thickness_gauge_measure: the maximum must be positive and finite");
            thicknessPrefix("sharp angle -0.1", () -> g.thickness(10.0, -0.1),
                            "thickness_gauge_measure: the sharp angle must be zero or positive and finite");
            double[] p = {1, 2, 1};
            thicknessExact("at: body 3", () -> g.thicknessAt(3, 0, p, 10.0), "thickness_gauge_at: no body 3 -- there are 1");
            thicknessExact("at: face 99", () -> g.thicknessAt(0, 99, p, 10.0),
                           "thickness_gauge_at: no face 99 -- the solid has 6 (0 to 5)");
            thicknessPrefix("at: NaN point", () -> g.thicknessAt(0, 0, new double[] {1, Double.NaN, 1}, 10.0),
                            "thickness_gauge_at: the point must be finite");
            thicknessExact("at: two numbers", () -> g.thicknessAt(0, 0, new double[] {1, 2}, 10.0),
                           "thickness_gauge_at: a point is 3 numbers, got 2");
            thicknessExact("face: body 2", () -> g.thicknessAtFace(2, 0, 10.0), "thickness_gauge_face: no body 2 -- there are 1");
            thicknessExact("face: face 99", () -> g.thicknessAtFace(0, 99, 10.0),
                           "thickness_gauge_face: no face 99 -- the solid has 6 (0 to 5)");
            thicknessPrefix("face: infinite at", () -> g.thicknessAtFace(0, 0, new double[] {Double.POSITIVE_INFINITY, 0, 1}, 10.0),
                            "thickness_gauge_face: the point must be finite");
            thicknessExact("face: two numbers", () -> g.thicknessAtFace(0, 0, new double[] {1, 2}, 10.0),
                           "thickness_gauge_face: a point is 3 numbers, got 2");
            thicknessPrefix("face: maximum 0", () -> g.thicknessAtFace(0, 0, 0.0),
                            "thickness_gauge_face: the maximum must be positive and finite");
            g.close();
            g.close(); // twice is a no-op
            thicknessExact("measure on a closed gauge", () -> g.thickness(10.0), "thickness_gauge: closed");
            thicknessExact("at on a closed gauge", () -> g.thicknessAt(0, 0, p, 10.0), "thickness_gauge: closed");
            thicknessExact("face on a closed gauge", () -> g.thicknessAtFace(0, 0, 10.0), "thickness_gauge: closed");
            // the conveniences refuse with the gauge call's own prefix
            thicknessPrefix("one-shot maximum -1", () -> Blacksmith.thickness(one, -1.0),
                            "thickness_gauge_measure: the maximum must be positive and finite");
            thicknessPrefix("one-shot tolerance NaN", () -> Blacksmith.thickness(one, 10.0, 0.0, Double.NaN),
                            "thickness_gauge_new: the tolerance must be positive and finite");
            thicknessPrefix("Solid face 99", () -> plate.thicknessAtFace(99, 10.0), "thickness_gauge_face: no face 99");
        }
        // mesh_thickness: the kernel's refusals and the wrapper's own
        thicknessPrefix("mesh maximum 0", () -> Blacksmith.meshThickness(List.of(THICKNESS_LOWER, THICKNESS_UPPER), 0.0),
                        "mesh_thickness: the maximum must be positive and finite");
        thicknessPrefix("mesh sharp angle -0.5", () -> Blacksmith.meshThickness(List.of(THICKNESS_LOWER, THICKNESS_UPPER), 10.0, -0.5),
                        "mesh_thickness: the sharp angle must be zero or positive and finite");
        thicknessPrefix("triangle past the mesh", () -> Blacksmith.meshThickness(List.of(new Blacksmith.MeshInput(
                        new double[][] {{0, 0, 0}, {1, 0, 0}}, new int[][] {{0, 1, 2}})), 10.0),
                        "mesh_thickness: a triangle names a position past the mesh");
        thicknessPrefix("NaN position", () -> Blacksmith.meshThickness(List.of(new Blacksmith.MeshInput(
                        new double[][] {{0, 0, 0}, {1, Double.NaN, 0}, {0, 1, 0}}, new int[][] {{0, 1, 2}})), 10.0),
                        "mesh_thickness: a mesh position is not finite");
        thicknessPrefix("a null mesh", () -> Blacksmith.meshThickness(Arrays.asList(THICKNESS_LOWER, null), 10.0),
                        "mesh_thickness: mesh 1 is not a (positions, triangles) pair");
        thicknessPrefix("a short position", () -> Blacksmith.meshThickness(List.of(new Blacksmith.MeshInput(
                        new double[][] {{0, 0, 0}, {1, 0}}, new int[][] {{0, 1, 2}})), 10.0),
                        "mesh_thickness: mesh 0 position 1 is not three numbers");
        thicknessPrefix("a short triangle", () -> Blacksmith.meshThickness(List.of(new Blacksmith.MeshInput(
                        new double[][] {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}, new int[][] {{0, 1}})), 10.0),
                        "mesh_thickness: mesh 0 triangle 0 is not three indices");
        thicknessPrefix("a negative index", () -> Blacksmith.meshThickness(List.of(new Blacksmith.MeshInput(
                        new double[][] {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}, new int[][] {{0, 1, -2}})), 10.0),
                        "mesh_thickness: mesh 0 triangle 0 is not three indices");
        System.out.println("thickness: ok");
    }

    // ---- oriented box, lengths, containment and closest points (measure plan 3) -----------------
    // Python's test_oriented_box_* .. test_closest_*, trimmed to what proves the marshalling.

    private static boolean near(double[] v, double x, double y, double z, double tol) {
        return Math.abs(v[0] - x) <= tol && Math.abs(v[1] - y) <= tol && Math.abs(v[2] - z) <= tol;
    }

    private static double dist(double[] a, double[] b) {
        return Math.sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));
    }

    private static boolean within(double a, double b, double tol) {
        return Math.abs(a - b) <= tol;
    }

    /** The message a call is refused with, or a marker that it was not refused. */
    private static String refused(Runnable call) {
        try {
            call.run();
            return "(no exception)";
        } catch (Blacksmith.BuildException | IllegalStateException e) {
            return e.getMessage();
        }
    }

    /** The R-tree: Python's test_rtree_*, trimmed to what proves the marshalling (rtree plan 3). */
    private static void rtree() {
        // 1. the grid, packed and inserted one at a time
        List<Blacksmith.RTree.Entry> cells = new java.util.ArrayList<>();
        for (int i = 0; i < 10; i++)
            for (int j = 0; j < 10; j++)
                for (int k = 0; k < 10; k++)
                    cells.add(new Blacksmith.RTree.Entry(100 * i + 10 * j + k, rbox(i, j, k, i + 1, j + 1, k + 1)));
        List<Long> corner = new java.util.ArrayList<>();
        for (int i = 0; i <= 2; i++)
            for (int j = 0; j <= 2; j++)
                for (int k = 0; k <= 2; k++) corner.add((long) (100 * i + 10 * j + k));
        try (Blacksmith.RTree packed = Blacksmith.RTree.fromBoxes(cells);
             Blacksmith.RTree grown = new Blacksmith.RTree()) {
            for (int n = cells.size() - 1; n >= 0; n--) grown.insert(cells.get(n).id(), cells.get(n).box());
            List<List<Blacksmith.RTree.Pair>> answers = new java.util.ArrayList<>();
            for (Blacksmith.RTree tree : List.of(packed, grown)) {
                String name = tree == packed ? "fromBoxes" : "insert";
                if (tree.size() != 1000) fail("rtree " + name + ": size " + tree.size());
                Blacksmith.Box b = tree.bounds().orElse(null);
                if (b == null || !Arrays.equals(b.lo(), new double[] {0, 0, 0}) || !Arrays.equals(b.hi(), new double[] {10, 10, 10}))
                    fail("rtree " + name + ": bounds " + b);
                List<Long> found = tree.search(rbox(0, 0, 0, 2, 2, 2));
                if (!found.equals(corner)) fail("rtree " + name + ": search found " + found);
                List<Blacksmith.RTree.Hit> near = tree.nearest(new double[] {-1, -1, -1}, 1);
                if (near.size() != 1 || near.get(0).id() != 0 || !within(near.get(0).distance(), Math.sqrt(3), 1e-12))
                    fail("rtree " + name + ": nearest " + near);
                List<Blacksmith.RTree.Hit> at = tree.within(new double[] {0, 0, 0}, 0);
                if (!at.equals(List.of(new Blacksmith.RTree.Hit(0, 0)))) fail("rtree " + name + ": within 0 " + at);
                List<Long> four = tree.within(new double[] {-1, -1, -1}, 2.5).stream().map(Blacksmith.RTree.Hit::id).toList();
                if (!four.equals(List.of(0L, 1L, 10L, 100L))) fail("rtree " + name + ": within 2.5 " + four);
                List<Blacksmith.RTree.Pair> pairs = tree.selfOverlaps();
                if (pairs.size() != (28 * 28 * 28 - 1000) / 2 || pairs.stream().anyMatch(p -> p.a() >= p.b()) || !pairsSorted(pairs))
                    fail("rtree " + name + ": self overlaps " + pairs.size() + ", or a pair out of order");
                if (!tree.selfOverlaps(0.5).equals(pairs)) fail("rtree " + name + ": unit gaps paired at slack 0.5");
                answers.add(pairs);
            }
            if (!answers.get(0).equals(answers.get(1))) fail("rtree: the packed and the grown trees disagree");
            // 2. two trees, and the same tree twice
            try (Blacksmith.RTree one = Blacksmith.RTree.fromBoxes(List.of(new Blacksmith.RTree.Entry(7, rbox(4.5, 4.5, 4.5, 5.5, 5.5, 5.5))))) {
                List<Blacksmith.RTree.Pair> cross = packed.overlaps(one);
                List<Blacksmith.RTree.Pair> want = new java.util.ArrayList<>(), back = new java.util.ArrayList<>();
                for (long a : new long[] {444, 445, 454, 455, 544, 545, 554, 555}) {
                    want.add(new Blacksmith.RTree.Pair(a, 7));
                    back.add(new Blacksmith.RTree.Pair(7, a));
                }
                if (!cross.equals(want)) fail("rtree overlaps: " + cross);
                if (!one.overlaps(packed).equals(back)) fail("rtree overlaps: the other way round " + one.overlaps(packed));
            }
            List<Blacksmith.RTree.Pair> twice = packed.overlaps(packed, 0);
            if (twice.size() != 1000 + 2 * 10476 || !pairsSorted(twice)) fail("rtree overlaps: the grid with itself gave " + twice.size());
            // 3. points, insert and remove
            try (Blacksmith.RTree pts = Blacksmith.RTree.fromPoints(List.of(new double[] {0, 0, 0}, new double[] {5, 0, 0}, new double[] {1, 0, 0}, new double[] {0, 3, 0}))) {
                if (!pts.search(rbox(-0.1, -0.1, -0.1, 1.1, 0.1, 0.1)).equals(List.of(0L, 2L))) fail("rtree from points: ids are not the indices");
                List<Blacksmith.RTree.Hit> two = pts.nearest(new double[] {4, 0, 0}, 2);
                if (!two.equals(List.of(new Blacksmith.RTree.Hit(1, 1), new Blacksmith.RTree.Hit(2, 3)))) fail("rtree from points: nearest " + two);
            }
            try (Blacksmith.RTree tree = new Blacksmith.RTree()) {
                Blacksmith.Box cell = rbox(3, 3, 3, 4, 4, 4);
                tree.insert(7, cell);
                tree.insert(7, cell);
                if (!tree.search(cell).equals(List.of(7L, 7L))) fail("rtree insert: one (id, box) twice is two entries");
                if (!tree.remove(7, cell) || !tree.remove(7, cell) || tree.remove(7, cell)) fail("rtree remove: true, true, then false");
                tree.insert(7, cell);
                if (tree.remove(8, cell)) fail("rtree remove: another id took the entry out");
                if (tree.remove(7, rbox(3, 3, 3, 4, 4, 4.5))) fail("rtree remove: another box took the entry out");
                double[] point = {1, 2, 3};
                tree.insert(9, point);
                Blacksmith.Box b = tree.bounds().orElse(null);
                if (tree.size() != 2 || b == null || !Arrays.equals(b.lo(), point) || !Arrays.equals(b.hi(), new double[] {4, 4, 4}))
                    fail("rtree insert: a point, bounds " + b);
                if (!tree.remove(9, point) || !tree.remove(7, cell)) fail("rtree remove: the point or the box stayed");
                if (tree.size() != 0 || tree.bounds().isPresent()) fail("rtree remove: emptied, the tree still has bounds");
                long big = 0xFFFFFFFFL;
                tree.insert(big, point);
                if (!tree.search(rbox(0, 0, 0, 5, 5, 5)).equals(List.of(big))) fail("rtree insert: the largest id did not come back whole");
                if (!tree.remove(big, point)) fail("rtree remove: the largest id stayed");
            }
            // 4. point neighbours against brute force
            long[] state = {5};
            java.util.function.DoubleSupplier next = () -> {
                state[0] = state[0] * 6364136223846793005L + 1442695040888963407L;
                return (state[0] >>> 11) / (double) (1L << 53);
            };
            List<double[]> hay = new java.util.ArrayList<>(), needles = new java.util.ArrayList<>();
            for (int i = 0; i < 30; i++) hay.add(new double[] {10 * next.getAsDouble(), 10 * next.getAsDouble(), 10 * next.getAsDouble()});
            for (int i = 0; i < 5; i++) needles.add(new double[] {10 * next.getAsDouble(), 10 * next.getAsDouble(), 10 * next.getAsDouble()});
            List<List<Long>> close = Blacksmith.closestPoints(hay, needles, 3.0);
            List<List<Long>> knn = Blacksmith.kNeighbors(hay, needles, 4);
            boolean someClose = false, allClose = true;
            for (int n = 0; n < needles.size(); n++) {
                double[] q = needles.get(n);
                List<Long> order = byDistance(hay, q);
                List<Long> inLimit = order.stream().filter(i -> dist(hay.get(i.intValue()), q) <= 3.0).toList();
                if (!close.get(n).equals(inLimit)) fail("closest points: needle " + n + " gave " + close.get(n));
                if (!knn.get(n).equals(order.subList(0, 4))) fail("k neighbors: needle " + n + " gave " + knn.get(n));
                someClose |= !inLimit.isEmpty();
                allClose &= inLimit.size() == hay.size();
            }
            if (close.size() != 5 || !someClose || allClose) fail("closest points: the limit chose nothing or everything");
            List<List<Long>> all = Blacksmith.kNeighbors(hay, needles.subList(0, 2), 500);
            if (all.size() != 2 || !all.get(1).equals(byDistance(hay, needles.get(1)))) fail("k neighbors: k over the hay count is not every point");
            if (!Blacksmith.kNeighbors(List.of(), needles.subList(0, 2), 3).equals(List.of(List.of(), List.of()))) fail("k neighbors: an empty hay found something");
            // 5. refusals, by the call's name
            try (Blacksmith.RTree tree = new Blacksmith.RTree()) {
                String nanBox = refused(() -> tree.insert(1, rbox(0, 0, 0, Double.NaN, 1, 1)));
                if (!nanBox.startsWith("rtree_insert: ") || !nanBox.endsWith("is not a box")) fail("rtree insert: a NaN box gave '" + nanBox + "'");
                String inverted = refused(() -> tree.insert(1, rbox(1, 0, 0, 0, 1, 1)));
                if (!inverted.startsWith("rtree_insert: ") || !inverted.endsWith("is not a box")) fail("rtree insert: an inverted box gave '" + inverted + "'");
                String infPoint = refused(() -> tree.insert(1, new double[] {Double.POSITIVE_INFINITY, 0, 0}));
                if (!infPoint.startsWith("rtree_insert_point: ") || !infPoint.endsWith("is not finite")) fail("rtree insert: an infinite point gave '" + infPoint + "'");
                if (tree.size() != 0) fail("rtree insert: a refused insert changed the tree");
                String badRemove = refused(() -> tree.remove(1, rbox(1, 0, 0, 0, 1, 1)));
                if (!badRemove.startsWith("rtree_remove: ")) fail("rtree remove: an inverted box gave '" + badRemove + "'");
                if (tree.remove(1, rbox(0, 0, 0, 1, 1, 1))) fail("rtree remove: absent right after a refusal read true");
                String nanWithin = refused(() -> tree.within(new double[] {Double.NaN, 0, 0}, 1));
                if (!nanWithin.startsWith("rtree_within: ") || !nanWithin.endsWith("is not finite")) fail("rtree within: a NaN point gave '" + nanWithin + "'");
                String nanNearest = refused(() -> tree.nearest(new double[] {Double.NaN, 0, 0}, 1));
                if (!nanNearest.startsWith("rtree_nearest: ") || !nanNearest.endsWith("is not finite")) fail("rtree nearest: a NaN point gave '" + nanNearest + "'");
                String radius = refused(() -> tree.within(new double[] {0, 0, 0}, -1));
                if (!radius.equals("rtree_within: radius -1 is not a distance")) fail("rtree within: radius -1 gave '" + radius + "'");
                String slack = refused(() -> tree.selfOverlaps(Double.NaN));
                if (!slack.equals("rtree_self_overlaps: slack NaN is not a distance")) fail("rtree self overlaps: slack NaN gave '" + slack + "'");
                String negSlack = refused(() -> tree.overlaps(tree, -0.5));
                if (!negSlack.startsWith("rtree_overlaps: ")) fail("rtree overlaps: slack -0.5 gave '" + negSlack + "'");
                String k = refused(() -> tree.nearest(new double[] {0, 0, 0}, 1_000_001));
                if (!k.equals("rtree_nearest: k 1000001 is not at most 1000000")) fail("rtree nearest: k 1000001 gave '" + k + "'");
                String twoNumbers = refused(() -> tree.within(new double[] {0, 0}, 1));
                if (!twoNumbers.startsWith("rtree_within: ")) fail("rtree within: two numbers gave '" + twoNumbers + "'");
                // ids and k a uint32_t cannot hold, refused before any call
                for (long bad : new long[] {-1, 1L << 32}) {
                    String ins = refused(() -> tree.insert(bad, new double[] {0, 0, 0}));
                    if (!ins.equals("rtree_insert: id is out of range: " + bad)) fail("rtree insert: id " + bad + " gave '" + ins + "'");
                    String rem = refused(() -> tree.remove(bad, rbox(0, 0, 0, 1, 1, 1)));
                    if (!rem.equals("rtree_remove: id is out of range: " + bad)) fail("rtree remove: id " + bad + " gave '" + rem + "'");
                    String bulk = refused(() -> Blacksmith.RTree.fromBoxes(List.of(new Blacksmith.RTree.Entry(bad, rbox(0, 0, 0, 1, 1, 1)))).close());
                    if (!bulk.startsWith("rtree_from_boxes: ") || !bulk.endsWith("is out of range: " + bad)) fail("rtree from boxes: id " + bad + " gave '" + bulk + "'");
                }
                String negK = refused(() -> tree.nearest(new double[] {0, 0, 0}, -1));
                if (!negK.equals("rtree_nearest: k is out of range: -1")) fail("rtree nearest: k -1 gave '" + negK + "'");
                if (tree.size() != 0) fail("rtree: a refused id reached the tree");
            }
            String entry = refused(() -> Blacksmith.RTree.fromBoxes(List.of(new Blacksmith.RTree.Entry(1, rbox(0, 0, 0, 1, 1, 1)),
                    new Blacksmith.RTree.Entry(2, rbox(2, 0, 0, 1, 1, 1)))).close());
            if (!entry.startsWith("rtree_from_boxes: entry 1")) fail("rtree from boxes: a bad entry 1 gave '" + entry + "'");
            String badPoint = refused(() -> Blacksmith.RTree.fromPoints(List.of(new double[] {0, 0, 0}, new double[] {0, Double.NaN, 0})).close());
            if (!badPoint.equals("rtree_from_points: point 1 is not finite")) fail("rtree from points: a NaN point 1 gave '" + badPoint + "'");
            List<double[]> origin = List.of(new double[] {0, 0, 0});
            String limit = refused(() -> Blacksmith.closestPoints(origin, origin, -1));
            if (!limit.equals("closest_points: limit -1 is not a distance")) fail("closest points: limit -1 gave '" + limit + "'");
            // The limit as Rust's {} prints an f64: the shortest round-trip digits, never an exponent.
            Object[][] shownAs = {
                {-1e-7, "-0.0000001"}, {-1e20, "-100000000000000000000"}, {-1.5, "-1.5"}, {-(0.1 + 0.2), "-0.30000000000000004"},
                {Double.NaN, "NaN"}, {Double.NEGATIVE_INFINITY, "-inf"}, {-5e-324, "-0." + "0".repeat(323) + "5"},
                {-1e-323, "-0." + "0".repeat(322) + "1"}, {-1e16, "-10000000000000000"}, {-1.2345678901234568e17, "-123456789012345680"},
                {-1e21, "-1000000000000000000000"}, {-0.000123, "-0.000123"}, {-2.5e-5, "-0.000025"}, {-2e-323, "-0." + "0".repeat(322) + "2"},
            };
            for (Object[] c : shownAs) {
                double bad = (Double) c[0];
                String said = refused(() -> Blacksmith.closestPoints(origin, origin, bad));
                if (!said.equals("closest_points: limit " + c[1] + " is not a distance")) fail("closest points: limit " + bad + " gave '" + said + "'");
            }
            String needle = refused(() -> Blacksmith.closestPoints(origin, List.of(new double[] {Double.NaN, 0, 0}), 1));
            if (!needle.equals("closest_points: needle point 0 is not finite")) fail("closest points: a NaN needle gave '" + needle + "'");
            String hayNan = refused(() -> Blacksmith.kNeighbors(List.of(new double[] {0, 0, 0}, new double[] {Double.POSITIVE_INFINITY, 0, 0}), origin, 1_000_001));
            if (!hayNan.equals("k_neighbors: hay point 1 is not finite")) fail("k neighbors: an infinite hay point before a bad k gave '" + hayNan + "'");
            String bigK = refused(() -> Blacksmith.kNeighbors(origin, origin, 1_000_001));
            if (!bigK.equals("k_neighbors: k 1000001 is not at most 1000000")) fail("k neighbors: k 1000001 gave '" + bigK + "'");
            String knnNeg = refused(() -> Blacksmith.kNeighbors(origin, origin, -1));
            if (!knnNeg.equals("k_neighbors: k is out of range: -1")) fail("k neighbors: k -1 gave '" + knnNeg + "'");
            // 6. lifetime: an empty tree answers nothing; a closed one refuses
            Blacksmith.RTree empty = new Blacksmith.RTree();
            if (empty.size() != 0 || empty.bounds().isPresent() || !empty.search(rbox(0, 0, 0, 1, 1, 1)).isEmpty()
                    || !empty.within(new double[] {0, 0, 0}, 10).isEmpty() || !empty.nearest(new double[] {0, 0, 0}, 3).isEmpty()
                    || !empty.selfOverlaps().isEmpty() || !empty.overlaps(packed).isEmpty())
                fail("rtree: an empty tree answered something");
            empty.close();
            empty.close();
            Map<String, Runnable> calls = new java.util.LinkedHashMap<>();
            calls.put("size", empty::size);
            calls.put("bounds", empty::bounds);
            calls.put("insert", () -> empty.insert(1, new double[] {0, 0, 0}));
            calls.put("search", () -> empty.search(rbox(0, 0, 0, 1, 1, 1)));
            calls.put("nearest", () -> empty.nearest(new double[] {0, 0, 0}, 1));
            calls.put("self overlaps", () -> empty.selfOverlaps());
            calls.put("overlaps", () -> packed.overlaps(empty));
            // closed is said before a bad argument is looked at, as Python says it
            calls.put("insert a bad id", () -> empty.insert(-1, new double[] {0, 0, 0}));
            calls.put("insert a bad id and box", () -> empty.insert(1L << 32, rbox(0, 0, 0, 1, 1, 1)));
            calls.put("insert a bad point", () -> empty.insert(1, new double[] {Double.NaN, 0, 0}));
            calls.put("remove a bad id", () -> empty.remove(-1, rbox(0, 0, 0, 1, 1, 1)));
            calls.put("remove a bad point", () -> empty.remove(1, new double[] {0, 0}));
            calls.put("within a bad point", () -> empty.within(new double[] {Double.NaN, 0, 0}, 1));
            calls.put("nearest a bad k", () -> empty.nearest(new double[] {0, 0, 0}, -1));
            calls.put("nearest a bad point", () -> empty.nearest(new double[] {0, 0}, 1));
            for (Map.Entry<String, Runnable> c : calls.entrySet()) {
                String said = refused(c.getValue());
                if (!said.equals("rtree: closed")) fail("rtree " + c.getKey() + ": a closed tree gave '" + said + "'");
            }
            System.out.println("rtree: grid of " + packed.size() + ", " + answers.get(0).size() + " self pairs, points, neighbours, refusals and lifetime all read back");
        }
    }

    /** The interpolator and the circumscribed polygon: Python's test_interpolator_* and
     *  test_circumscribed_polygon_touches_its_circle, trimmed to what proves the marshalling. */
    private static void interpolator() {
        double[] squares = {0, 1, 4, 9, 16};
        // 1. the squares, every mode, and the closed forms
        try (Blacksmith.Interpolator sq = new Blacksmith.Interpolator(squares)) {
            if (sq.size() != 5 || sq.dimension() != 1 || sq.cyclic()) fail("interpolator: squares read " + sq);
            for (Blacksmith.InterpolatorMode mode : Blacksmith.InterpolatorMode.values()) {
                for (int k = 0; k < squares.length; k++) {
                    double[] v = sq.at(k, mode);
                    if (v.length != 1 || !within(v[0], squares[k], 1e-12)) fail("interpolator " + mode + ": t " + k + " gave " + Arrays.toString(v));
                }
                if (!within(sq.at(-2, mode)[0], 0, 1e-12) || !within(sq.at(7, mode)[0], 16, 1e-12)) fail("interpolator " + mode + ": an open list is not clamped");
            }
            if (sq.nearest(1.5)[0] != 4.0 || sq.nearest(1.49)[0] != 1.0) fail("interpolator nearest: " + sq.nearest(1.5)[0] + ", " + sq.nearest(1.49)[0]);
            if (!within(sq.linear(1.5)[0], 2.5, 1e-12)) fail("interpolator linear: " + sq.linear(1.5)[0]);
            if (!within(sq.cosine(1.5)[0], 2.5, 1e-12) || !within(sq.cosine(1.25)[0], 1 + 3 * (1 - Math.cos(Math.PI / 4)) / 2, 1e-12))
                fail("interpolator cosine: " + sq.cosine(1.5)[0] + ", " + sq.cosine(1.25)[0]);
            if (!within(sq.cubic(1.5)[0], 2.0, 1e-12)) fail("interpolator cubic: " + sq.cubic(1.5)[0]);
            if (!within(sq.catmullRom(1.5)[0], 2.25, 1e-12)) fail("interpolator catmullRom: " + sq.catmullRom(1.5)[0]);
            if (!Arrays.equals(sq.at(1.5), sq.linear(1.5))) fail("interpolator: at is not linear by default");
        }
        try (Blacksmith.Interpolator ring = new Blacksmith.Interpolator(squares, true)) {
            if (!ring.cyclic()) fail("interpolator: a cyclic list reads open");
            if (!within(ring.catmullRom(5)[0], ring.catmullRom(0)[0], 1e-12)) fail("interpolator cyclic: t 5 is not t 0");
            if (!within(ring.linear(-0.5)[0], 8.0, 1e-12)) fail("interpolator cyclic: linear(-0.5) " + ring.linear(-0.5)[0]);
        }
        // 2. points, and sample a loop of at
        double[][] helix = new double[9][];
        for (int k = 0; k < 9; k++) helix[k] = new double[] {Math.cos(0.7 * k), Math.sin(0.7 * k), 0.3 * k};
        try (Blacksmith.Interpolator h = new Blacksmith.Interpolator(helix)) {
            if (h.size() != 9 || h.dimension() != 3) fail("interpolator helix: " + h);
            double[] two = h.at(2);
            for (int c = 0; c < 3; c++) if (!within(two[c], helix[2][c], 1e-12)) fail("interpolator helix: at(2) " + Arrays.toString(two));
            if (h.catmullRom(2.5).length != 3) fail("interpolator helix: catmullRom(2.5) is not 3 numbers");
            double[] ts = new double[50];
            for (int k = 0; k < 50; k++) ts[k] = -1.0 + 10.0 * k / 49;
            for (Blacksmith.InterpolatorMode mode : Blacksmith.InterpolatorMode.values()) {
                double[][] got = h.sample(ts, mode);
                if (got.length != ts.length) fail("interpolator sample " + mode + ": " + got.length + " values");
                for (int k = 0; k < ts.length; k++)
                    if (!Arrays.equals(got[k], h.at(ts[k], mode))) fail("interpolator sample " + mode + ": value " + k + " is not at(t)");
            }
            if (h.sample(new double[0]).length != 0) fail("interpolator: sample of nothing is something");
        }
        double[][] corners = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
        try (Blacksmith.Interpolator square = new Blacksmith.Interpolator(corners, true)) {
            double[] half = square.linear(-0.5);
            if (half.length != 2 || !within(half[0], 0, 1e-12) || !within(half[1], 0.5, 1e-12)) fail("interpolator square: linear(-0.5) " + Arrays.toString(half));
            double[][] two = square.sample(new double[] {0.5, 1.5});
            if (two.length != 2 || !within(two[0][0], 0.5, 1e-12) || !within(two[0][1], 0, 1e-12)
                    || !within(two[1][0], 1, 1e-12) || !within(two[1][1], 0.5, 1e-12))
                fail("interpolator square: sample " + Arrays.deepToString(two));
        }
        // 3. refusals, by the call's name
        Map<String, String> wants = new java.util.LinkedHashMap<>();
        Map<String, Runnable> calls = new java.util.LinkedHashMap<>();
        calls.put("no samples", () -> new Blacksmith.Interpolator(new double[0]).close());
        wants.put("no samples", "interpolator_new: no samples");
        calls.put("no rows", () -> new Blacksmith.Interpolator(new double[0][]).close());
        wants.put("no rows", "interpolator_new: no samples");
        calls.put("a NaN sample", () -> new Blacksmith.Interpolator(new double[] {0, 1, Double.NaN}).close());
        wants.put("a NaN sample", "interpolator_new: sample 2 is not finite");
        calls.put("unequal rows", () -> new Blacksmith.Interpolator(new double[][] {{0, 1}, {2, 3, 4}}).close());
        wants.put("unequal rows", "interpolator: samples differ in length");
        try (Blacksmith.Interpolator sq = new Blacksmith.Interpolator(squares)) {
            calls.put("a NaN t", () -> sq.linear(Double.NaN));
            wants.put("a NaN t", "interpolator_at: t NaN is not finite");
            calls.put("an infinite t", () -> sq.sample(new double[] {0, Double.POSITIVE_INFINITY}));
            wants.put("an infinite t", "interpolator_sample: t 1 (inf) is not finite");
            for (Map.Entry<String, Runnable> c : calls.entrySet()) {
                String said = refused(c.getValue());
                if (!said.startsWith(wants.get(c.getKey()))) fail("interpolator " + c.getKey() + ": gave '" + said + "'");
            }
            sq.close();
            sq.close();
            if (!sq.closed() || !sq.toString().equals("Interpolator(closed)")) fail("interpolator: close did not close");
            for (Runnable r : List.<Runnable>of(() -> sq.linear(1), () -> sq.size(), () -> sq.dimension(), () -> sq.cyclic(),
                    () -> sq.sample(new double[] {1}), () -> sq.sample(new double[0]))) {
                String said = refused(r);
                if (!said.equals("interpolator: closed")) fail("interpolator: a closed one gave '" + said + "'");
            }
        }
        // 4. the circumscribed polygon: its sides touch the circle
        double r = 5, n = 6, cx = 2, cy = -1;
        try (Blacksmith.Profile hex = Blacksmith.Profile.circumscribedPolygon(new double[] {cx, cy}, r, 6, 0.3)) {
            double perimeter = 2 * n * r * Math.tan(Math.PI / n), side = perimeter / n;
            double length = hex.length().length();
            if (Math.abs(length - perimeter) > 1e-9 * perimeter) fail("circumscribed polygon: length " + length + ", not " + perimeter);
            for (int k = 0; k < n; k++) {
                double[] corner = hex.pointAtLength(k * side, 0).point(), mid = hex.pointAtLength((k + 0.5) * side, 0).point();
                double toCorner = Math.hypot(corner[0] - cx, corner[1] - cy), toMid = Math.hypot(mid[0] - cx, mid[1] - cy);
                if (Math.abs(toCorner - r / Math.cos(Math.PI / n)) > 1e-6 * r || Math.abs(toMid - r) > 1e-6 * r)
                    fail("circumscribed polygon: side " + k + "'s corner at " + toCorner + ", midpoint at " + toMid);
            }
        }
        String two = refused(() -> Blacksmith.Profile.circumscribedPolygon(new double[] {0, 0}, 10, 2).close());
        if (!two.startsWith("profile_circumscribed_polygon: a polygon has at least 3 sides, not 2")) fail("circumscribed polygon: 2 sides gave '" + two + "'");
        String negative = refused(() -> Blacksmith.Profile.circumscribedPolygon(new double[] {0, 0}, 10, -1).close());
        if (!negative.startsWith("profile_circumscribed_polygon: a polygon has at least 3 sides, not 0")) fail("circumscribed polygon: -1 sides gave '" + negative + "'");
        System.out.println("interpolator: five modes on the squares, a helix sampled, refusals and lifetime; circumscribed polygon touches its circle");
    }

    /** Merge and regions: Python's test_merge_* and test_a_merged_body_is_refused_*, trimmed to
     *  what proves the marshalling. */
    private static void merge() {
        double tol = 1e-6;
        try (Blacksmith.Solid a = Blacksmith.Solid.cuboid(1, 1, 1);
             Blacksmith.Solid b = a.translate(0.5, 0.5, 0.5);
             Blacksmith.Solid m = a.merge(b, tol)) {
            // 5. two cubes at a corner: the outside and three cells
            if (m.faces() != 18) fail("merge: " + m.faces() + " faces, not 18");
            List<Blacksmith.Region> regions = m.regions();
            if (regions.size() != 4) fail("regions: " + regions.size() + ", not 4");
            int sides = 0;
            Set<Integer> faces = new HashSet<>();
            for (int i = 0; i < regions.size(); i++) {
                Blacksmith.Region g = regions.get(i);
                if (g.index() != i || g.finite() != (i > 0) || g.shells() != 1) fail("regions: region " + i + " reads " + g);
                for (int k = 0; k < g.sides().size(); k++) {
                    Blacksmith.FaceSide s = g.sides().get(k);
                    if (s.sense() != 1 && s.sense() != -1) fail("regions: region " + i + " has a sense " + s.sense());
                    if (s.face() < 0 || s.face() >= 18) fail("regions: region " + i + " names face " + s.face());
                    if (k > 0) {
                        Blacksmith.FaceSide p = g.sides().get(k - 1);
                        if (p.face() > s.face() || (p.face() == s.face() && p.sense() >= s.sense())) fail("regions: region " + i + "'s sides out of order");
                    }
                    if (i > 0) faces.add(s.face());
                }
                sides += g.sides().size();
            }
            if (sides != 2 * 18) fail("regions: " + sides + " sides, not each face's two");
            if (faces.size() != 18) fail("regions: the finite regions bound " + faces.size() + " faces, not 18");
            List<Double> volumes = new java.util.ArrayList<>();
            int small = -1;
            for (int i = 1; i < 4; i++) {
                try (Blacksmith.Solid cell = m.regionSolid(i)) {
                    double v = cell.mass(0).volume();
                    volumes.add(v);
                    if (within(v, 0.125, 1e-6)) small = i;
                }
            }
            List<Double> sorted = volumes.stream().sorted().toList();
            if (!within(sorted.get(0), 0.125, 1e-6) || !within(sorted.get(1), 0.875, 1e-6) || !within(sorted.get(2), 0.875, 1e-6))
                fail("region solids: volumes " + volumes);
            Blacksmith.Region overlap = regions.get(small);
            if (overlap.sides().size() != 6 || overlap.sides().stream().anyMatch(s -> s.sense() != -1)) fail("regions: the overlap reads " + overlap);
            for (int c = 0; c < 3; c++)
                if (!within(overlap.box().lo()[c], 0, 1e-6) || !within(overlap.box().hi()[c], 0.5, 1e-6)) fail("regions: the overlap's box " + overlap.box());
            if (!m.regions().equals(regions)) fail("regions: two reads are not equal");
            try {
                overlap.sides().clear();
                fail("regions: a region's sides can be changed");
            } catch (UnsupportedOperationException expected) {
                // a region is a value
            }
            // 7. the merged body is refused by the manifold verbs; its cells are not
            String join = refused(() -> m.join(a, tol).close());
            if (!join.startsWith("join: the join needs a manifold solid, and this one has edges of three or more faces")) fail("merge: join gave '" + join + "'");
            String mass = refused(() -> m.mass(0));
            if (!mass.startsWith("mass_properties: the mass needs a manifold solid")) fail("merge: mass gave '" + mass + "'");
            String zero = refused(() -> m.regionSolid(0).close());
            if (!zero.equals("region_solid: region 0 is the infinite region")) fail("region solid 0: gave '" + zero + "'");
            String four = refused(() -> m.regionSolid(4).close());
            if (!four.equals("region_solid: region 4 is not below 4")) fail("region solid 4: gave '" + four + "'");
            String minus = refused(() -> m.regionSolid(-1).close());
            if (!minus.equals("region_solid: region is out of range: -1")) fail("region solid -1: gave '" + minus + "'");
            String flat = refused(() -> a.merge(a, 0).close());
            if (!flat.startsWith("merge: tolerance must be positive and finite")) fail("merge at tolerance 0: gave '" + flat + "'");
            try (Blacksmith.Solid cell = m.regionSolid(1); Blacksmith.Solid joined = cell.join(a, tol)) {
                if (joined.faces() <= 0) fail("region solid: a cell does not join");
            }
            // an ordinary solid: the outside in front of every face, the inside behind
            List<Blacksmith.Region> two = a.regions();
            if (two.size() != 2 || two.get(0).sides().stream().anyMatch(s -> s.sense() != 1) || two.get(1).sides().stream().anyMatch(s -> s.sense() != -1)
                    || two.get(0).sides().size() != 6 || two.get(1).sides().size() != 6)
                fail("regions: a cube reads " + two);
        }
        // 6. a ball in a box: a box cell with a void
        try (Blacksmith.Solid box = Blacksmith.Solid.cuboid(1, 1, 1);
             Blacksmith.Solid ball = Blacksmith.Solid.sphere(0.3);
             Blacksmith.Solid m = box.merge(ball, tol)) {
            List<Blacksmith.Region> regions = m.regions();
            if (regions.size() != 3) fail("merge ball: " + regions.size() + " regions, not 3");
            double want = 4.0 / 3.0 * Math.PI * 0.3 * 0.3 * 0.3;
            double[] v = new double[3];
            for (int i = 1; i < 3; i++) {
                try (Blacksmith.Solid cell = m.regionSolid(i)) {
                    v[i] = cell.mass(0).volume();
                }
            }
            int big = v[1] > v[2] ? 1 : 2;
            if (!within(v[big], 1 - want, 1e-6) || !within(v[3 - big], want, 1e-6)) fail("merge ball: volumes " + Arrays.toString(v));
            if (regions.get(big).shells() != 2 || regions.get(3 - big).shells() != 1) fail("merge ball: shells " + regions);
        }
        System.out.println("merge: two cubes are the outside and three cells, a ball in a box a cell with a void, refusals by name");
    }

    private static String hitsText(List<Blacksmith.RTree.Hit> hs) {
        return hs.toString();
    }

    private static List<Blacksmith.RTree.Hit> hitList(double... idT) {
        List<Blacksmith.RTree.Hit> out = new java.util.ArrayList<>();
        for (int i = 0; i < idT.length; i += 2) out.add(new Blacksmith.RTree.Hit((long) idT[i], idT[i + 1]));
        return out;
    }

    /** Rays, triangle trees and a solid's face tree: Python's tests, trimmed (rtree plan 6). */
    private static void rtreeRays() {
        List<Blacksmith.RTree.Entry> row = new java.util.ArrayList<>();
        for (int i = 0; i < 10; i++) row.add(new Blacksmith.RTree.Entry(i, rbox(i, 0, 0, i + 1, 1, 1)));
        try (Blacksmith.RTree tree = Blacksmith.RTree.fromBoxes(row)) {
            List<Blacksmith.RTree.Hit> along = tree.ray(new double[] {-1, 0.5, 0.5}, new double[] {1, 0, 0});
            List<Blacksmith.RTree.Hit> want = new java.util.ArrayList<>();
            for (int i = 0; i < 10; i++) want.add(new Blacksmith.RTree.Hit(i, i + 1.0));
            if (!along.equals(want)) fail("rtree ray: the row gave " + hitsText(along));
            List<Blacksmith.RTree.Hit> scaled = tree.ray(new double[] {-1, 0.5, 0.5}, new double[] {2, 0, 0}, 1.0);
            if (!scaled.equals(hitList(0, 0.5, 1, 1.0))) fail("rtree ray: t is not in units of the direction: " + hitsText(scaled));
            List<Blacksmith.RTree.Hit> cut = tree.ray(new double[] {-1, 0.5, 0.5}, new double[] {1, 0, 0}, 3);
            if (!cut.equals(hitList(0, 1, 1, 2, 2, 3))) fail("rtree ray: max_t 3 gave " + hitsText(cut));
            List<Blacksmith.RTree.Hit> inside = tree.ray(new double[] {2.5, 0.5, 0.5}, new double[] {1, 0, 0}, 1);
            if (!inside.equals(hitList(2, 0, 3, 0.5))) fail("rtree ray: from inside gave " + hitsText(inside));
            List<Blacksmith.RTree.Hit> back = tree.ray(new double[] {11, 0.5, 0.5}, new double[] {-1, 0, 0}, 2);
            if (!back.equals(hitList(9, 1, 8, 2))) fail("rtree ray: backwards gave " + hitsText(back));
            if (tree.ray(new double[] {-1, 1, 0.5}, new double[] {1, 0, 0}).size() != 10) fail("rtree ray: grazing the top face missed");
            if (!tree.ray(new double[] {-1, 1 + 1e-12, 0.5}, new double[] {1, 0, 0}).isEmpty()) fail("rtree ray: a ray above the row met it");
            String zero = refused(() -> tree.ray(new double[] {0, 0, 0}, new double[] {0, 0, 0}));
            if (!zero.equals("rtree_ray: direction (0, 0, 0) is not a direction")) fail("rtree ray: a zero direction gave '" + zero + "'");
            String negative = refused(() -> tree.ray(new double[] {0, 0, 0}, new double[] {1, 0, 0}, -1));
            if (!negative.equals("rtree_ray: max_t -1 is not a distance")) fail("rtree ray: max_t -1 gave '" + negative + "'");
            String nanT = refused(() -> tree.ray(new double[] {0, 0, 0}, new double[] {1, 0, 0}, Double.NaN));
            if (!nanT.equals("rtree_ray: max_t NaN is not a distance")) fail("rtree ray: max_t NaN gave '" + nanT + "'");
            String nanOrigin = refused(() -> tree.ray(new double[] {Double.NaN, 0, 0}, new double[] {1, 0, 0}));
            if (!nanOrigin.equals("rtree_ray: origin (NaN, 0, 0) is not finite")) fail("rtree ray: a NaN origin gave '" + nanOrigin + "'");
            String shortOrigin = refused(() -> tree.ray(new double[] {0, 0}, new double[] {1, 0, 0}));
            if (!shortOrigin.startsWith("rtree_ray: ")) fail("rtree ray: two numbers gave '" + shortOrigin + "'");
        }
        List<double[]> positions = List.of(new double[] {0, 0, 0}, new double[] {2, 0, 0}, new double[] {0, 3, 0},
                new double[] {Double.NaN, 0, 0}, new double[] {5, 1, 4});
        try (Blacksmith.RTree tris = Blacksmith.RTree.fromTriangles(positions, List.of(new long[] {0, 1, 2}, new long[] {1, 4, 1}))) {
            Blacksmith.Box b = tris.bounds().orElse(null);
            if (tris.size() != 2 || b == null || !near(b.lo(), new double[] {0, 0, 0}, 0) || !near(b.hi(), new double[] {5, 3, 4}, 0))
                fail("rtree from triangles: count " + tris.size() + ", bounds " + b);
            if (!tris.search(rbox(1, 1, 0, 1, 1, 0)).equals(List.of(0L)) || !tris.search(rbox(4, 0.5, 2, 4, 0.5, 2)).equals(List.of(1L)))
                fail("rtree from triangles: ids are not the triangle indices");
            List<Blacksmith.RTree.Hit> through = tris.ray(new double[] {-1, 0.5, 0}, new double[] {1, 0, 0});
            if (!through.equals(hitList(0, 1, 1, 3))) fail("rtree from triangles: a ray gave " + hitsText(through));
        }
        try (Blacksmith.RTree none = Blacksmith.RTree.fromTriangles(List.of(), List.of())) {
            if (none.size() != 0) fail("rtree from triangles: none gave entries");
        }
        List<double[]> four = List.of(new double[] {0, 0, 0}, new double[] {0, 0, 0}, new double[] {0, 0, 0}, new double[] {0, 0, 0});
        String past = refused(() -> Blacksmith.RTree.fromTriangles(four, List.of(new long[] {0, 1, 2}, new long[] {0, 4, 1})).close());
        if (!past.equals("rtree_from_triangles: triangle 1 names point 4 of 4")) fail("rtree from triangles: an index past the points gave '" + past + "'");
        String infCorner = refused(() -> Blacksmith.RTree.fromTriangles(List.of(new double[] {0, 0, 0}, new double[] {0, Double.POSITIVE_INFINITY, 0}),
                List.<long[]>of(new long[] {0, 1, 0})).close());
        if (!infCorner.equals("rtree_from_triangles: triangle 0 point 1 is not finite")) fail("rtree from triangles: an infinite corner gave '" + infCorner + "'");
        String twoIndices = refused(() -> Blacksmith.RTree.fromTriangles(four, List.<long[]>of(new long[] {0, 0})).close());
        if (!twoIndices.startsWith("rtree_from_triangles: triangle 0 is not 3 indices")) fail("rtree from triangles: two indices gave '" + twoIndices + "'");
        for (long bad : new long[] {-1, 1L << 32}) {
            String index = refused(() -> Blacksmith.RTree.fromTriangles(four, List.<long[]>of(new long[] {0, bad, 0})).close());
            if (!index.equals("rtree_from_triangles: triangle 0's index is out of range: " + bad)) fail("rtree from triangles: index " + bad + " gave '" + index + "'");
        }
        try (Blacksmith.Solid cuboid = Blacksmith.Solid.cuboid(3, 4, 5); Blacksmith.RTree faces = cuboid.faceTree()) {
            double grow = 5 * 1e-3;
            Blacksmith.Box fb = faces.bounds().orElse(null);
            if (faces.size() != 6 || fb == null || !near(fb.lo(), new double[] {-1.5 - grow, -2 - grow, -2.5 - grow}, 1e-9)
                    || !near(fb.hi(), new double[] {1.5 + grow, 2 + grow, 2.5 + grow}, 1e-9))
                fail("face tree: count " + faces.size() + ", bounds " + fb);
            if (faces.search(rbox(1.4, 1.9, 2.4, 1.6, 2.1, 2.6)).size() != 3) fail("face tree: a corner is not three faces");
            List<Blacksmith.RTree.Hit> shot = faces.ray(new double[] {10, 0, 0}, new double[] {-1, 0, 0});
            if (shot.size() != 2 || !within(shot.get(0).distance(), 8.5 - grow, 1e-9) || !within(shot.get(1).distance(), 11.5 - grow, 1e-9))
                fail("face tree: a ray gave " + hitsText(shot));
            double[] frame = cuboid.faceFrame((int) shot.get(0).id());
            if (!near(java.util.Arrays.copyOfRange(frame, 9, 12), new double[] {1, 0, 0}, 1e-9)) fail("face tree: the first face met is not the +x face");
        }
        Blacksmith.RTree gone = new Blacksmith.RTree();
        gone.close();
        String closed = refused(() -> gone.ray(new double[] {0, 0}, new double[] {1, 0, 0}, -1));
        if (!closed.equals("rtree: closed")) fail("rtree ray: a closed tree gave '" + closed + "'");
        System.out.println("rtree: rays, triangle trees and a cuboid's face tree all read back");
    }

    private static Blacksmith.Box rbox(double x0, double y0, double z0, double x1, double y1, double z1) {
        return new Blacksmith.Box(new double[] {x0, y0, z0}, new double[] {x1, y1, z1});
    }

    private static boolean pairsSorted(List<Blacksmith.RTree.Pair> ps) {
        for (int i = 1; i < ps.size(); i++) {
            Blacksmith.RTree.Pair p = ps.get(i - 1), q = ps.get(i);
            if (p.a() > q.a() || (p.a() == q.a() && p.b() > q.b())) return false;
        }
        return true;
    }

    private static List<Long> byDistance(List<double[]> hay, double[] q) {
        List<Long> order = new java.util.ArrayList<>();
        for (long i = 0; i < hay.size(); i++) order.add(i);
        order.sort(Comparator.<Long>comparingDouble(i -> dist(hay.get(i.intValue()), q)).thenComparingLong(i -> i));
        return order;
    }

    private static void measure() {
        // 1. the oriented box of a turned cuboid
        try (Blacksmith.Solid base = Blacksmith.Solid.cuboid(2, 3, 4);
             Blacksmith.Solid turned = base.rotate(new double[] {0, 0, 0, 0, 0, 1}, Math.PI / 6)) {
            Blacksmith.OrientedBox ob = turned.orientedBox(1e-9);
            double[] want = {1.0, 1.5, 2.0};
            double[] sorted = ob.half().clone();
            Arrays.sort(sorted);
            for (int i = 0; i < 3; i++)
                if (!(sorted[i] >= want[i] - 1e-9 && sorted[i] <= want[i] + 1e-3))
                    fail("oriented box: half " + Arrays.toString(ob.half()) + " is not (1, 1.5, 2)");
            for (double c : ob.centre())
                if (Math.abs(c) > 1e-3) fail("oriented box: centre " + Arrays.toString(ob.centre()) + " is not the origin");
            if (ob.centre().length != 3 || ob.axes().length != 3 || Arrays.stream(ob.axes()).anyMatch(r -> r.length != 3))
                fail("oriented box: axes are not three rows of three");
            for (int i = 0; i < 3; i++)
                for (int j = 0; j < 3; j++) {
                    double[] a = ob.axes()[i], b = ob.axes()[j];
                    double dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
                    if (!within(dot, i == j ? 1 : 0, 1e-9)) fail("oriented box: axes " + i + "." + j + " = " + dot);
                }
        }
        // 2. defaults and errors
        try (Blacksmith.Solid cyl = Blacksmith.Solid.cylinder(1, 2)) {
            Blacksmith.OrientedBox a0 = cyl.orientedBox(0), aNeg = cyl.orientedBox(-1), aDef = cyl.orientedBox(1e-5);
            for (Blacksmith.OrientedBox other : new Blacksmith.OrientedBox[] {a0, aNeg})
                if (!Arrays.equals(other.half(), aDef.half()) || !Arrays.equals(other.centre(), aDef.centre())
                        || !Arrays.deepEquals(other.axes(), aDef.axes()))
                    fail("oriented box: accuracy 0 or -1 is not the default 1e-5");
            double grown = 1 + 3.125e-5 * Math.sqrt(12);
            for (double h : aDef.half())
                if (!within(h, grown, 1e-12)) fail("oriented box: half " + Arrays.toString(aDef.half()) + " is not the grown figure " + grown);
            String nan = refused(() -> cyl.orientedBox(Double.NaN));
            if (!nan.startsWith("oriented_box: ") || !nan.contains("is not an accuracy")) fail("oriented box: NaN accuracy gave '" + nan + "'");
            try (Blacksmith.Solid sheet = Blacksmith.Solid.cuboid(1, 2, 3).faceSheet(0)) {
                String open = refused(() -> sheet.orientedBox());
                if (!open.startsWith("oriented_box: ")) fail("oriented box: an open sheet gave '" + open + "'");
            }
        }
        // 3. edge length
        try (Blacksmith.Solid cyl = Blacksmith.Solid.cylinder(2.5, 4);
             Blacksmith.Solid cube = Blacksmith.Solid.cuboid(1, 1, 1)) {
            int circles = 0;
            for (Blacksmith.Edge e : cyl.edges()) {
                if (!e.kind().equals("circle")) continue;
                circles++;
                Blacksmith.Length len = cyl.edgeLength(e.index(), 1e-9);
                if (len.error() < 0 || len.error() > 1e-6 * len.length() || !within(len.length(), 5 * Math.PI, Math.max(len.error(), 1e-9)) || !len.accuracyMet() || len.fromPolyline())
                    fail("edge length: circle " + e.index() + " reads " + len);
            }
            if (circles == 0) fail("edge length: the cylinder has no circle edge");
            String past = refused(() -> cube.edgeLength(cube.edges().size()));
            if (!past.startsWith("edge_length: ")) fail("edge length: an edge past the end gave '" + past + "'");
        }
        // 4. profile length
        try (Blacksmith.Profile slot = Blacksmith.Profile.slot(new double[] {0, 0}, 8, 1)) {
            Blacksmith.Length len = slot.length(1e-9);
            if (len.error() < 0 || len.error() > 1e-6 * len.length() || !within(len.length(), 12 + 2 * Math.PI, Math.max(len.error(), 1e-9)) || !len.accuracyMet())
                fail("profile length: the slot reads " + len);
            String nan = refused(() -> slot.length(Double.NaN));
            if (!nan.startsWith("profile_length: ")) fail("profile length: NaN accuracy gave '" + nan + "'");
        }
        // 4b. arc-length sampling
        try (Blacksmith.Solid cyl = Blacksmith.Solid.cylinder(2.5, 4)) {
            int rims = 0;
            for (Blacksmith.Edge e : cyl.edges()) {
                if (!e.kind().equals("circle")) continue;
                rims++;
                Blacksmith.Curve c = e.curve();
                Blacksmith.At start = cyl.edgePointAtLength(e.index(), 0);
                if (start.parameter() != c.t0()) fail("point at length: edge " + e.index() + " starts at parameter " + start.parameter() + ", not " + c.t0());
                Blacksmith.At q = cyl.edgePointAtLength(e.index(), 2.5 * Math.PI / 2);
                if (!within(q.parameter(), c.t0() + Math.PI / 2, 1e-9)) fail("point at length: a quarter turn reads parameter " + q.parameter());
                if (!within(dist(q.point(), c.origin()), 2.5, 1e-9)) fail("point at length: the quarter point is off the circle: " + Arrays.toString(q.point()));
                if (!within(dist(q.tangent(), new double[] {0, 0, 0}), 1, 1e-12)) fail("point at length: the tangent is not unit: " + Arrays.toString(q.tangent()));
                if (q.segment() != null || q.fromPolyline() || !(q.error() >= 0) || Double.isInfinite(q.error()))
                    fail("point at length: segment, polyline or error wrong: " + q);
                List<Blacksmith.At> four = cyl.edgeDivideByCount(e.index(), 4);
                if (four.size() != 4) fail("divide by count: a rim gave " + four.size() + " samples");
                for (int k = 0; k < 4; k++)
                    if (!within(dist(four.get(k).point(), four.get((k + 1) % 4).point()), 2.5 * Math.sqrt(2), 1e-9))
                        fail("divide by count: the chord " + k + " is off");
                if (!near(four.get(0).point(), start.point(), 1e-12)) fail("divide by count: the first sample is not the start");
                List<Blacksmith.At> bylen = cyl.edgeDivideByLength(e.index(), 2.5 * Math.PI / 2);
                if (bylen.size() != 4) fail("divide by length: a rim gave " + bylen.size() + " samples");
            }
            if (rims < 2) fail("arc length: the cylinder has fewer than two circle edges");
            String past = refused(() -> cyl.edgePointAtLength(cyl.edges().size(), 0));
            if (!past.startsWith("edge_point_at_length: ")) fail("point at length: an edge past the end gave '" + past + "'");
            int rim = cyl.edges().stream().filter(e -> e.kind().equals("circle")).findFirst().orElseThrow().index();
            String neg = refused(() -> cyl.edgePointAtLength(rim, -1));
            if (!neg.startsWith("edge_point_at_length: ")) fail("point at length: -1 gave '" + neg + "'");
            String far = refused(() -> cyl.edgePointAtLength(rim, 100));
            if (!far.startsWith("edge_point_at_length: ")) fail("point at length: 100 gave '" + far + "'");
            String zero = refused(() -> cyl.edgeDivideByCount(rim, 0));
            if (!zero.startsWith("edge_divide_by_count: ") || !zero.contains("not at least 1")) fail("divide by count: 0 gave '" + zero + "'");
            String huge = refused(() -> cyl.edgeDivideByCount(rim, 1_000_001));
            if (!huge.startsWith("edge_divide_by_count: ") || !huge.contains("not at most 1000000")) fail("divide by count: 1000001 gave '" + huge + "'");
            String minus = refused(() -> cyl.edgeDivideByCount(rim, -1));
            if (!minus.equals("edge_divide_by_count: n is out of range: -1")) fail("divide by count: -1 gave '" + minus + "'");
            String wrap = refused(() -> cyl.edgeDivideByCount(rim, (1L << 32) + 4));
            if (!wrap.equals("edge_divide_by_count: n is out of range: " + ((1L << 32) + 4))) fail("divide by count: 2^32 + 4 gave '" + wrap + "'");
            String nostep = refused(() -> cyl.edgeDivideByLength(rim, 0));
            if (!nostep.startsWith("edge_divide_by_length: ")) fail("divide by length: 0 gave '" + nostep + "'");
            String nan = refused(() -> cyl.edgePointAtLength(rim, 1, Double.NaN));
            if (!nan.startsWith("edge_point_at_length: ") || !nan.contains("is not an accuracy")) fail("point at length: NaN accuracy gave '" + nan + "'");
        }
        try (Blacksmith.Solid box = Blacksmith.Solid.cuboid(2, 3, 4)) {
            Blacksmith.Edge line = box.edges().stream()
                    .filter(e -> e.kind().equals("line") && within(box.edgeLength(e.index()).length(), 4, 1e-9)).findFirst().orElseThrow();
            Blacksmith.Curve c = line.curve();
            List<Blacksmith.At> five = box.edgeDivideByCount(line.index(), 4);
            if (five.size() != 5) fail("divide by count: an open edge gave " + five.size() + " samples");
            for (int k = 0; k < 5; k++)
                if (!within(dist(five.get(k).point(), five.get(0).point()), k, 1e-9)) fail("divide by count: sample " + k + " is not " + k + " from the start");
            if (five.get(0).parameter() != c.t0() || five.get(4).parameter() != c.t1()) fail("divide by count: the ends' parameters are not the curve's range");
            List<Blacksmith.At> by = box.edgeDivideByLength(line.index(), 1.5);
            if (by.size() != 3) fail("divide by length: an open edge gave " + by.size() + " samples");
            for (int k = 0; k < 3; k++)
                if (!within(dist(by.get(k).point(), by.get(0).point()), 1.5 * k, 1e-9)) fail("divide by length: sample " + k + " is off");
        }
        try (Blacksmith.Profile slot = Blacksmith.Profile.slot(new double[] {0, 0}, 8, 1)) {
            Blacksmith.At at = slot.pointAtLength(6 + Math.PI / 2);
            if (!near(at.point(), 4, 0, 0, 1e-9) || at.segment() == null || at.segment() != 1) fail("profile point at length: the slot's far end reads " + at);
            List<Blacksmith.At> eight = slot.divideByCount(8);
            if (eight.size() != 8 || eight.stream().anyMatch(a -> a.segment() == null || a.segment() < 0 || a.segment() > 4))
                fail("profile divide by count: 8 samples, each on a side 0..4");
            List<Blacksmith.At> by = slot.divideByLength(3);
            if (by.size() != (int) Math.floor((12 + 2 * Math.PI) / 3) + 1) fail("profile divide by length: " + by.size() + " samples");
            for (int k = 0; k < by.size(); k++) {
                Blacksmith.At one = slot.pointAtLength(3.0 * k);
                if (!near(by.get(k).point(), one.point(), 1e-12) || !java.util.Objects.equals(by.get(k).segment(), one.segment()))
                    fail("profile divide by length: sample " + k + " is not the point at " + 3 * k);
            }
            if (dist(by.get(by.size() - 1).point(), by.get(0).point()) <= 0.1) fail("profile divide by length: the last sample repeats the start");
            String neg = refused(() -> slot.pointAtLength(-1));
            if (!neg.startsWith("profile_point_at_length: ")) fail("profile point at length: -1 gave '" + neg + "'");
            String zero = refused(() -> slot.divideByCount(0));
            if (!zero.startsWith("profile_divide_by_count: ")) fail("profile divide by count: 0 gave '" + zero + "'");
            String minus = refused(() -> slot.divideByCount(-1));
            if (!minus.equals("profile_divide_by_count: n is out of range: -1")) fail("profile divide by count: -1 gave '" + minus + "'");
            String wrap = refused(() -> slot.divideByCount((1L << 32) + 4));
            if (!wrap.equals("profile_divide_by_count: n is out of range: " + ((1L << 32) + 4))) fail("profile divide by count: 2^32 + 4 gave '" + wrap + "'");
            String badStep = refused(() -> slot.divideByLength(-1));
            if (!badStep.startsWith("profile_divide_by_length: ")) fail("profile divide by length: -1 gave '" + badStep + "'");
            Blacksmith.At def = slot.pointAtLength(5);
            for (double acc : new double[] {0, -1}) {
                Blacksmith.At other = slot.pointAtLength(5, acc);
                if (!Arrays.equals(other.point(), def.point()) || !Arrays.equals(other.tangent(), def.tangent()) || other.parameter() != def.parameter()
                        || !java.util.Objects.equals(other.segment(), def.segment()) || other.error() != def.error() || other.fromPolyline() != def.fromPolyline())
                    fail("profile point at length: accuracy " + acc + " is not the default");
            }
        }
        System.out.println("arc length: points, divides by count and length, refusals all read back");
        // 5. containment, one-shot and classifier
        try (Blacksmith.Solid box = Blacksmith.Solid.cuboid(2, 3, 4)) {
            if (!box.contains(new double[] {0, 0, 0}).equals("inside") || !box.contains(new double[] {5, 0, 0}).equals("outside")
                    || !box.contains(new double[] {0, 0, 2}).equals("on"))
                fail("contains: the box's inside, outside and on points read wrong");
            try (Blacksmith.Classifier cls = box.classifier()) {
                double[][] points = {{0, 0, 0}, {0.99, 0, 0}, {1, 0, 0}, {1.2, 0, 0}, {0, 1.6, 0}, {0, 0, -2}};
                for (double[] p : points)
                    if (!cls.contains(p).equals(box.contains(p))) fail("classifier: disagrees with contains at " + Arrays.toString(p));
            }
        }
        try (Blacksmith.Solid ball = Blacksmith.Solid.sphere(1.5);
             Blacksmith.Classifier cls = ball.classifier(1e-3)) {
            double[] xs = {-2.0, -1.4, -0.5, 0, 0.5, 1.4, 2};
            String[] expected = {"outside", "inside", "inside", "inside", "inside", "inside", "outside"};
            for (int i = 0; i < xs.length; i++) {
                String got = cls.contains(new double[] {xs[i], 0, 0});
                if (!got.equals(expected[i])) fail("classifier: sphere at x=" + xs[i] + " reads " + got);
            }
            if (!cls.contains(new double[] {1.5, 0, 0}).equals("on") || !cls.contains(new double[] {0, 0, -1.5}).equals("on"))
                fail("classifier: the sphere's surface does not read on");
        }
        // 6. the classifier outlives its solid
        Blacksmith.Classifier orphan;
        {
            Blacksmith.Solid ball = Blacksmith.Solid.sphere(1.0);
            orphan = ball.classifier(1e-3);
            ball.close();
            System.gc();
        }
        if (!orphan.contains(new double[] {0, 0, 0}).equals("inside") || !orphan.contains(new double[] {2, 0, 0}).equals("outside")
                || !orphan.contains(new double[] {1, 0, 0}).equals("on"))
            fail("classifier: it stopped answering once its solid was freed");
        // 7. containment errors, and a closed classifier
        try (Blacksmith.Solid box = Blacksmith.Solid.cuboid(2, 3, 4)) {
            double[] nanPoint = {Double.NaN, 0, 0};
            String e1 = refused(() -> box.contains(nanPoint));
            if (!e1.startsWith("contains: ") || !e1.contains("not finite")) fail("contains: a NaN point gave '" + e1 + "'");
            String e2 = refused(() -> orphan.contains(nanPoint));
            if (!e2.startsWith("classifier_contains: ") || !e2.contains("not finite")) fail("classifier: a NaN point gave '" + e2 + "'");
            String e3 = refused(() -> box.contains(new double[] {0, 0, 0}, 0));
            if (!e3.startsWith("contains: ") || !e3.contains("positive and finite")) fail("contains: tolerance 0 gave '" + e3 + "'");
            String e4 = refused(() -> box.classifier(0));
            if (!e4.startsWith("classifier_new: ") || !e4.contains("positive and finite")) fail("classifier: tolerance 0 gave '" + e4 + "'");
        }
        orphan.close();
        orphan.close();
        String closed = refused(() -> orphan.contains(new double[] {0, 0, 0}));
        if (!closed.equals("classifier: closed")) fail("classifier: a closed classifier gave '" + closed + "'");
        // 8. the closest points of two spheres
        try (Blacksmith.Solid s1 = Blacksmith.Solid.sphere(1);
             Blacksmith.Solid s2 = Blacksmith.Solid.sphere(1).translate(5, 0, 0)) {
            Blacksmith.Closest c = s1.closest(s2, 1e-3);
            if (!within(c.distance(), 3, 6e-9) || !c.refined()) fail("closest: the spheres read " + c);
            if (!c.kindA().equals("face") || !c.kindB().equals("face") || c.edgeA() != null || c.edgeB() != null)
                fail("closest: the spheres' kinds or edges read " + c);
            if (!near(c.onA(), 1, 0, 0, 1e-6) || !near(c.onB(), 4, 0, 0, 1e-6)) fail("closest: the spheres' points read " + c);
            Blacksmith.Closest back = s2.closest(s1, 1e-3);
            if (!near(back.onA(), c.onB()[0], c.onB()[1], c.onB()[2], 1e-9) || !near(back.onB(), c.onA()[0], c.onA()[1], c.onA()[2], 1e-9)
                    || !within(back.distance(), c.distance(), 1e-12))
                fail("closest: swapping the solids did not swap the points: " + back);
        }
        // 9. a filletable edge
        try (Blacksmith.Solid box = Blacksmith.Solid.cuboid(2, 3, 4);
             Blacksmith.Solid ball = Blacksmith.Solid.sphere(1).translate(3, 0, 4)) {
            Blacksmith.Closest c = box.closest(ball, 1e-3);
            if (!within(c.distance(), 2 * Math.sqrt(2) - 1, 2e-3)) fail("closest: the box and ball read " + c);
            if (!c.kindA().equals("edge") || c.edgeA() == null || !c.kindB().equals("face") || c.edgeB() != null)
                fail("closest: the box and ball name " + c);
            try (Blacksmith.Solid rounded = box.fillet(new int[] {c.edgeA()}, 0.2)) {
                if (rounded.faces() != box.faces() + 1)
                    fail("closest: filleting the named edge gave " + rounded.faces() + " faces from " + box.faces());
            }
        }
        // 10. closest errors
        try (Blacksmith.Solid s1 = Blacksmith.Solid.sphere(1);
             Blacksmith.Solid s2 = Blacksmith.Solid.sphere(1).translate(5, 0, 0)) {
            String zero = refused(() -> s1.closest(s2, 0));
            if (!zero.startsWith("closest: ")) fail("closest: tolerance 0 gave '" + zero + "'");
        }
        System.out.println("measure: oriented box, lengths, containment and closest points all read back");
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
            // subdivide: whole, one face, a bad face.
            try (Blacksmith.Subd kiln = Blacksmith.Subd.cuboid(new double[] {2, 2, 2}, new int[] {2, 2, 2});
                 Blacksmith.Subd whole = kiln.subdivide();
                 Blacksmith.Subd one = kiln.subdivide(new int[] {1})) {
                if (whole.faces().length != 96) fail("subd: subdivide() has " + whole.faces().length + " faces, not 96");
                if (one.faces().length != 27) fail("subd: subdivide([1]) has " + one.faces().length + " faces, not 27");
                if (one.selection().orElseThrow().kind() != Blacksmith.SubdElements.FACES
                        || one.selection().orElseThrow().ids().length != 4) fail("subd: subdivide([1]) selects " + one.selection());
                subdRefused("subdivide([999])", () -> kiln.subdivide(new int[] {999}), null, "subdivide: face 999 is not in the cage", null);
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

    // ---- the 2D constraint sketcher: Python's test_a_sketch_* one for one (sketch constraints, plan 4)

    private static Blacksmith.BuildException skRefused(Runnable call) {
        try {
            call.run();
            return null;
        } catch (Blacksmith.BuildException e) {
            return e;
        }
    }

    private static boolean skNear(double a, double b, double tolerance) {
        return Math.abs(a - b) <= tolerance;
    }

    private static int[] sorted(int... v) {
        int[] c = v.clone();
        Arrays.sort(c);
        return c;
    }

    // geometry readers for the every-method test
    private static double skDist(Blacksmith.Sketch s, int a, int b) {
        double[] p = s.point(a), q = s.point(b);
        return Math.hypot(p[0] - q[0], p[1] - q[1]);
    }

    private static double[] skDir(Blacksmith.Sketch s, int line) {
        int[] e = s.ends(line);
        double[] a = s.point(e[0]), b = s.point(e[1]);
        return new double[] {b[0] - a[0], b[1] - a[1]};
    }

    private static double skLen(Blacksmith.Sketch s, int line) {
        double[] d = skDir(s, line);
        return Math.hypot(d[0], d[1]);
    }

    private static double skCross(Blacksmith.Sketch s, int l, int m) {
        double[] a = skDir(s, l), b = skDir(s, m);
        return (a[0] * b[1] - a[1] * b[0]) / (skLen(s, l) * skLen(s, m));
    }

    private static double skDot(Blacksmith.Sketch s, int l, int m) {
        double[] a = skDir(s, l), b = skDir(s, m);
        return (a[0] * b[0] + a[1] * b[1]) / (skLen(s, l) * skLen(s, m));
    }

    /** The signed distance of a point from a line's infinite extension. */
    private static double skOff(Blacksmith.Sketch s, int line, int point) {
        double[] a = s.point(s.ends(line)[0]), d = skDir(s, line), p = s.point(point);
        return ((p[0] - a[0]) * d[1] - (p[1] - a[1]) * d[0]) / Math.hypot(d[0], d[1]);
    }

    private static void sketch() {
        double[] xy = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
        // S1: a plate, dimensioned, solved, diagnosed and extruded
        try (Blacksmith.Sketch s = new Blacksmith.Sketch()) {
            Blacksmith.SketchRect rect = s.addRect(new double[] {0, 0}, new double[] {40, 30});
            int[] corners = rect.corners(), sides = rect.sides();
            if (corners.length != 4 || sides.length != 4) fail("sketch: add_rect is not 4 corners and 4 sides");
            s.fix(corners[0]);
            int width = s.length(sides[0], 60);
            s.length(sides[1], 30);
            int hole = s.addCircle(s.addPoint(30, 15), 5);
            s.radiusOf(hole, 5);
            Blacksmith.SolveReport report = s.solve();
            if (!report.converged() || !report.status().equals("converged") || report.ids().length != 0)
                fail("sketch: the plate did not converge: " + report);
            double[] corner = s.point(corners[1]);
            if (!skNear(corner[0], 60, 1e-9) || !skNear(corner[1], 0, 1e-9)) fail("sketch: the plate's second corner is " + Arrays.toString(corner));
            if (!s.constraintKind(width).equals("length") || s.constraintValue(width).orElse(Double.NaN) != 60.0)
                fail("sketch: the width reads back wrong");
            Blacksmith.Dof dof = s.diagnose();
            if (dof.free() != 2 || !dof.state().equals("under")) fail("sketch: the plate's dof is " + dof);
            List<Blacksmith.Profile> profiles = s.profiles(1e-9);
            try {
                if (profiles.size() != 1) fail("sketch: the plate has " + profiles.size() + " profiles");
                try (Blacksmith.Solid body = Blacksmith.Solid.extrude(profiles.get(0), xy, 10)) {
                    if (!(body.mass(0).volume() > 0)) fail("sketch: the extruded plate has no volume");
                }
            } finally {
                for (Blacksmith.Profile p : profiles) p.close();
            }
        }
        // S2: a conflict refused with its ids, a point in use, a plain refusal with none, a closed sketch
        {
            Blacksmith.Sketch s = new Blacksmith.Sketch();
            Blacksmith.SketchRect rect = s.addRect(new double[] {0, 0}, new double[] {40, 30});
            int[] corners = rect.corners(), sides = rect.sides();
            s.fix(corners[0]);
            s.length(sides[0], 40);
            s.length(sides[1], 30);
            Blacksmith.BuildException clash = skRefused(() -> s.distance(corners[0], corners[2], 10));
            if (clash == null || !clash.getMessage().startsWith("sketch_constrain: over-constrained"))
                fail("sketch: the conflict gave '" + (clash == null ? null : clash.getMessage()) + "'");
            else if (!Arrays.equals(clash.ids(), new int[] {0, 1, 5, 6})) fail("sketch: the conflict's ids are " + Arrays.toString(clash.ids()));
            if (s.constraints().length != 7) fail("sketch: the refused constraint was kept");
            Blacksmith.BuildException inUse = skRefused(() -> s.removeEntity(corners[0]));
            if (inUse == null || !inUse.getMessage().startsWith("sketch_remove_entity: point"))
                fail("sketch: removing a used point gave '" + (inUse == null ? null : inUse.getMessage()) + "'");
            else if (!Arrays.equals(sorted(inUse.ids()), sorted(sides[0], sides[3])))
                fail("sketch: the point's users are " + Arrays.toString(inUse.ids()));
            Blacksmith.BuildException unknown = skRefused(() -> s.kind(9999));
            if (unknown == null || !unknown.getMessage().contains("sketch_kind"))
                fail("sketch: kind(9999) gave '" + (unknown == null ? null : unknown.getMessage()) + "'");
            else if (unknown.ids().length != 0) fail("sketch: kind(9999) carried the ids " + Arrays.toString(unknown.ids()));
            s.close();
            s.close();
            try {
                s.solve();
                fail("sketch: solve after close did not fail");
            } catch (IllegalStateException e) {
                if (!"sketch: closed".equals(e.getMessage())) fail("sketch: solve after close reads \"" + e.getMessage() + "\"");
            }
        }
        // S3: dragging a point
        try (Blacksmith.Sketch s = new Blacksmith.Sketch()) {
            int[] corners = s.addRect(new double[] {0, 0}, new double[] {40, 30}).corners();
            Blacksmith.SolveReport r = s.drag(Map.of(corners[0], new double[] {5, 5}));
            if (!r.converged() || r.ids().length != 0) fail("sketch: the drag gave " + r);
            double[] p = s.point(corners[0]);
            if (!skNear(p[0], 5, 1e-9) || !skNear(p[1], 5, 1e-9)) fail("sketch: the dragged corner is " + Arrays.toString(p));
            if (!skNear(s.point(corners[1])[1], 5, 1e-9)) fail("sketch: the dragged side did not stay level");
            Blacksmith.BuildException three = skRefused(() -> s.drag(Map.of(corners[0], new double[] {1, 2, 3})));
            if (three == null || !three.getMessage().contains("sketch_drag"))
                fail("sketch: a 3-number drag target gave '" + (three == null ? null : three.getMessage()) + "'");
            int start = s.addPoint(0, 0);
            Blacksmith.BuildException one = skRefused(() -> s.addNurbs(start, new double[][] {{1}}, new double[] {0, 1}));
            if (one == null || !one.getMessage().contains("sketch_add_nurbs"))
                fail("sketch: a one-number nurbs point gave '" + (one == null ? null : one.getMessage()) + "'");
        }
        // S4: a reference follows its source
        try (Blacksmith.Sketch plate = new Blacksmith.Sketch(); Blacksmith.Sketch boss = new Blacksmith.Sketch()) {
            Blacksmith.SketchRect rect = plate.addRect(new double[] {0, 0}, new double[] {40, 30});
            plate.fix(rect.corners()[0]);
            int width = plate.length(rect.sides()[0], 40);
            plate.length(rect.sides()[1], 30);
            int edge = boss.reference(plate, rect.sides()[1]);
            if (!boss.isReference(edge) || !boss.isConstruction(edge)) fail("sketch: a reference is not a construction reference");
            int o = boss.addPoint(130, 15);
            int hole = boss.addCircle(o, 12);
            boss.radiusOf(hole, 12);
            boss.pointLineDistance(o, edge, 100);
            if (!skNear(boss.point(o)[0], 140, 1e-9)) fail("sketch: the boss starts at " + Arrays.toString(boss.point(o)));
            List<Blacksmith.Profile> bossProfiles = boss.profiles(1e-9);
            if (bossProfiles.size() != 1) fail("sketch: the reference is part of a profile");
            for (Blacksmith.Profile p : bossProfiles) p.close();
            if (!plate.setValue(width, 60).converged()) fail("sketch: widening the plate did not converge");
            Blacksmith.SolveReport r = boss.updateReference(edge, plate);
            if (!r.converged() || r.ids().length != 0) fail("sketch: update_reference gave " + r);
            if (!skNear(boss.point(o)[0], 160, 1e-9)) fail("sketch: the boss did not follow the plate: " + Arrays.toString(boss.point(o)));
            Blacksmith.BuildException notRef = skRefused(() -> boss.updateReference(o, plate));
            if (notRef == null || !notRef.getMessage().startsWith("sketch_update_reference: entity") || notRef.ids().length != 0)
                fail("sketch: update_reference of a plain point gave '" + (notRef == null ? null : notRef.getMessage()) + "'");
            Blacksmith.BuildException itself = skRefused(() -> boss.reference(boss, o));
            if (itself == null || !itself.getMessage().contains("cannot reference itself"))
                fail("sketch: referencing itself gave '" + (itself == null ? null : itself.getMessage()) + "'");
        }
        // S5: from a profile, keeping its tangent joints
        try (Blacksmith.Profile slot = Blacksmith.Profile.slot(new double[] {0, 0}, 60, 8);
             Blacksmith.Sketch s = Blacksmith.Sketch.fromProfile(slot, true, 1e-9)) {
            int tangents = 0;
            for (int c : s.constraints()) {
                if (s.constraintKind(c).equals("tangent")) {
                    tangents++;
                    if (!s.isJointTangent(c)) fail("sketch: a slot tangent is not a joint");
                }
            }
            if (tangents != 4) fail("sketch: the slot has " + tangents + " tangents");
            if (s.diagnose().free() != 4) fail("sketch: the slot's dof is not 4");
        }
        // S6: reads back what it holds
        try (Blacksmith.Sketch s = new Blacksmith.Sketch()) {
            int a = s.addPoint(0, 0), b = s.addPoint(10, 0);
            int line = s.addLine(a, b);
            if (!s.kind(a).equals("point") || !s.kind(line).equals("line")) fail("sketch: kinds of a point and a line");
            if (!Arrays.equals(s.entities(), sorted(a, b, line)) || !Arrays.equals(s.ends(line), new int[] {a, b})) fail("sketch: entities or ends");
            int c = s.addCircle(s.addPoint(0, 20), 3);
            if (!s.kind(c).equals("circle") || s.radius(c) != 3.0 || !s.kind(s.centre(c)).equals("point")) fail("sketch: the circle reads back wrong");
            s.setRadius(c, 4);
            if (s.radius(c) != 4.0) fail("sketch: set_radius");
            s.setPoint(b, 12, 0);
            if (!Arrays.equals(s.point(b), new double[] {12, 0})) fail("sketch: set_point");
            s.setConstruction(c);
            if (!s.isConstruction(c) || s.isReference(c)) fail("sketch: set_construction");
            int h = s.horizontal(a, b);
            if (!s.constraintKind(h).equals("horizontal") || !Arrays.equals(s.constraintRefs(h), new int[] {a, b})) fail("sketch: the horizontal reads back wrong");
            if (s.constraintValue(h).isPresent() || s.constraintDriving(h) || !s.constraintSense(h).equals("auto"))
                fail("sketch: a horizontal has a value, driving or a sense");
            int d = s.distance(a, b, 15, false);
            if (s.constraintValue(d).orElse(Double.NaN) != 15.0 || s.constraintDriving(d) || !skNear(s.measure(d), 12, 1e-12))
                fail("sketch: the reporting distance reads back wrong");
            Blacksmith.SolveReport r = s.setDriving(d, true);
            if (!r.converged() || !s.constraintDriving(d) || s.constraintValue(d).orElse(Double.NaN) != 12.0) fail("sketch: set_driving gave " + r);
            r = s.setValue(d, 20);
            if (!r.converged() || !skNear(s.measure(d), 20, 1e-9)) fail("sketch: set_value gave " + r);
            r = s.drag(Map.of(b, new double[] {25, 5}));
            if (!List.of("converged", "conflicting", "diverged").contains(r.status()) || r.ids() == null) fail("sketch: drag gave " + r);
            if (!Arrays.equals(s.constraints(), sorted(h, d))) fail("sketch: constraints");
            s.remove(h);
            if (!Arrays.equals(s.constraints(), new int[] {d})) fail("sketch: remove");
            if (!Arrays.equals(s.removeEntity(line), new int[] {d})) fail("sketch: remove_entity did not name the distance");
            if (Arrays.stream(s.entities()).anyMatch(e -> e == a) || s.constraints().length != 0) fail("sketch: remove_entity left its ends or constraints");
            int bez = s.addBezier(s.addPoint(0, 0), new double[] {1, 1}, new double[] {2, 1}, new double[] {3, 0});
            if (!s.kind(bez).equals("free_curve") || s.ends(bez).length != 4) fail("sketch: the bezier reads back wrong");
            List<Blacksmith.Profile> open = s.openChains(1e-9);
            if (open.size() != 1) fail("sketch: open_chains");
            for (Blacksmith.Profile p : open) p.close();
            Blacksmith.BuildException bad = skRefused(() -> s.kind(9999));
            if (bad == null || !bad.getMessage().contains("sketch_kind")) fail("sketch: kind(9999) was not refused");
            if (s.isConstruction(999) || s.isReference(999) || s.isJointTangent(999)) fail("sketch: an unknown id reads as construction, reference or joint tangent");
            Blacksmith.BuildException sideways = skRefused(() -> s.tangent(bez, c, "sideways"));
            if (sideways == null || !sideways.getMessage().contains("sense"))
                fail("sketch: a sideways tangent gave '" + (sideways == null ? null : sideways.getMessage()) + "'");
            // S10 (b): an unknown constraint id is refused by the readers whose failure is ambiguous
            Blacksmith.BuildException noValue = skRefused(() -> s.constraintValue(999));
            if (noValue == null || !noValue.getMessage().contains("sketch_constraint_value") || noValue.ids().length != 0)
                fail("sketch: constraint_value(999) gave '" + (noValue == null ? null : noValue.getMessage()) + "'");
            Blacksmith.BuildException noDriving = skRefused(() -> s.constraintDriving(999));
            if (noDriving == null || !noDriving.getMessage().contains("sketch_constraint_driving"))
                fail("sketch: constraint_driving(999) gave '" + (noDriving == null ? null : noDriving.getMessage()) + "'");
        }
        // S10 (a): the sense of a signed distance puts the point on opposite sides of the line
        for (String name : new String[] {"positive", "negative"}) {
            double expectY = name.equals("positive") ? 3.0 : -3.0;
            try (Blacksmith.Sketch s = new Blacksmith.Sketch()) {
                int la = s.addPoint(0, 0), lb = s.addPoint(10, 0);
                int ln = s.addLine(la, lb);
                s.fix(la);
                s.fix(lb);
                int pt = s.addPoint(5, 1);
                int dc = s.pointLineDistance(pt, ln, 3, true, name);
                if (!s.constraintSense(dc).equals(name)) fail("sketch: the " + name + " sense reads back as " + s.constraintSense(dc));
                if (!s.solve().converged() || !skNear(s.point(pt)[1], expectY, 1e-6))
                    fail("sketch: the " + name + " sense put the point at " + Arrays.toString(s.point(pt)));
            }
        }
        // S7: tangent_at_end reads its end back
        try (Blacksmith.Sketch s = new Blacksmith.Sketch()) {
            int a = s.addPoint(0, 0), b = s.addPoint(4, 0);
            int line = s.addLine(a, b);
            int bez = s.addBezier(b, new double[] {5, 0}, new double[] {6, 1}, new double[] {7, 1});
            if (!s.constraintEnd(s.tangentAtEnd(bez, line, "end")).equals("end")) fail("sketch: tangent_at_end(end) reads back wrong");
            if (!s.constraintEnd(s.tangentAtEnd(bez, line)).equals("start")) fail("sketch: tangent_at_end default is not start");
            if (!s.constraintEnd(s.length(line, 4)).equals("start")) fail("sketch: a length has an end");
            Blacksmith.BuildException none = skRefused(() -> s.constraintEnd(999));
            if (none == null || !none.getMessage().contains("sketch_constraint_end: no constraint 999"))
                fail("sketch: constraint_end(999) gave '" + (none == null ? null : none.getMessage()) + "'");
        }
        // S8: nurbs weights and finite points
        try (Blacksmith.Sketch s = new Blacksmith.Sketch()) {
            int start = s.addPoint(0, 0);
            double[][] points = {{1, 2}, {3, 2}, {4, 0}};
            double[] knots = {0, 0, 0, 0.5, 1, 1, 1};
            Blacksmith.BuildException few = skRefused(() -> s.addNurbs(start, points, knots, 2, new double[] {1, 1, 1}));
            if (few == null || !few.getMessage().contains("sketch_add_nurbs"))
                fail("sketch: too few weights gave '" + (few == null ? null : few.getMessage()) + "'");
            int curve = s.addNurbs(start, points, knots, 2, new double[] {1, 0.5, 0.5, 1});
            int[] ends = s.ends(curve);
            if (!s.kind(curve).equals("free_curve") || ends.length != 4 || ends[0] != start) fail("sketch: the nurbs reads back wrong");
        }
        try (Blacksmith.Sketch s = new Blacksmith.Sketch()) {
            Blacksmith.BuildException nan = skRefused(() -> s.addPoint(Double.NaN, 0));
            if (nan == null || !nan.getMessage().contains("sketch_add_point: the coordinates must be finite"))
                fail("sketch: a NaN point gave '" + (nan == null ? null : nan.getMessage()) + "'");
            if (s.entities().length != 0) fail("sketch: a refused point was kept");
            // the bindings the facts above skip
            int conic = s.addConic(s.addPoint(0, 0), new double[] {1, 1}, new double[] {2, 0}, 0.7);
            int arc = s.addArc(s.addPoint(0, 0), s.addPoint(1, 0), s.addPoint(0, 1));
            if (!s.kind(conic).equals("free_curve") || !s.kind(arc).equals("arc")) fail("sketch: conic or arc kinds");
            Blacksmith.Dof dof = s.diagnose();
            if (dof.parts().isEmpty() || dof.parts().get(0).params() == 0) fail("sketch: diagnose has no parts: " + dof);
            // a negative id is refused before the call, naming the argument
            Blacksmith.BuildException neg = skRefused(() -> s.kind(-1));
            if (neg == null || !neg.getMessage().startsWith("sketch_kind: id must not be negative")) fail("sketch: a negative id gave '" + (neg == null ? null : neg.getMessage()) + "'");
        }
        // S11: the diagnosis names the redundant and the conflicting ones (a swapped code table fails here)
        try (Blacksmith.Sketch s = new Blacksmith.Sketch()) {
            Blacksmith.SketchRect rr = s.addRect(new double[] {0, 0}, new double[] {40, 30});
            int[] rc = rr.corners(), rs = rr.sides();
            s.fix(rc[0]);
            s.length(rs[0], 40);
            s.length(rs[1], 30);
            int h = s.horizontal(rc[3], rc[2]);
            if (h != 7) fail("sketch: the redundant horizontal is constraint " + h + ", not 7");
            Blacksmith.Dof dof = s.diagnose();
            if (dof.free() != 0 || !dof.state().equals("full") || !Arrays.equals(dof.redundant(), new int[] {7})
                    || dof.conflicting().length != 0 || dof.parts().size() != 1)
                fail("sketch: the redundant diagnosis reads " + dof + " " + Arrays.toString(dof.redundant()) + Arrays.toString(dof.conflicting()));
            Blacksmith.PartDof pd = dof.parts().get(0);
            if (pd.free() != 0 || !pd.state().equals("full") || !Arrays.equals(pd.redundant(), new int[] {7}) || pd.conflicting().length != 0
                    || !Arrays.equals(pd.constraints(), new int[] {0, 1, 2, 3, 5, 6, 7}))
                fail("sketch: the redundant part reads " + pd + " " + Arrays.toString(pd.constraints()));
        }
        // S12: a diverged edit is refused with the text and the ids [2, 0, 1], and the sketch still solves
        try (Blacksmith.Sketch s = new Blacksmith.Sketch()) {
            int a = s.addPoint(0, 0), b = s.addPoint(1, 0), c = s.addPoint(0, 1);
            s.distance(a, b, 1);
            s.distance(b, c, 1);
            int d3 = s.distance(a, c, 1);
            Blacksmith.BuildException diverged = skRefused(() -> s.setValue(d3, 10));
            if (diverged == null || !diverged.getMessage().startsWith("sketch_set_value: the solve did not converge"))
                fail("sketch: the diverged set_value gave '" + (diverged == null ? null : diverged.getMessage()) + "'");
            if (!Arrays.equals(diverged.ids(), new int[] {2, 0, 1})) fail("sketch: the diverged set_value's ids are " + Arrays.toString(diverged.ids()));
            if (!s.solve().converged()) fail("sketch: the sketch does not solve after a refused edit");
        }
        // every constraint method on a fixture none refuses: kind, refs in order, value for the dimensions, and what the
        // solved geometry shows (a swapped kind table round-trips by name, so the geometry is the witness)
        {
            record Case(String kind, java.util.function.BiFunction<Blacksmith.Sketch, int[], Integer> make, int[] refs, Double value,
                        java.util.function.BiFunction<Blacksmith.Sketch, int[], double[]> effect) {
            }
            java.util.function.BiFunction<Blacksmith.Sketch, int[], double[]> none = null;
            Case[] cases = {
                new Case("coincident", (s, i) -> s.coincident(i[0], i[2]), new int[] {0, 2}, null, (s, i) -> new double[] {skDist(s, i[0], i[2]), 0}),
                new Case("point_on_line", (s, i) -> s.pointOnLine(i[2], i[4]), new int[] {2, 4}, null, (s, i) -> new double[] {skOff(s, i[4], i[2]), 0}),
                new Case("point_on_circle", (s, i) -> s.pointOnCircle(i[2], i[6]), new int[] {2, 6}, null,
                    (s, i) -> new double[] {skDist(s, i[2], s.centre(i[6])), s.radius(i[6])}),
                new Case("horizontal", (s, i) -> s.horizontal(i[0], i[1]), new int[] {0, 1}, null,
                    (s, i) -> new double[] {s.point(i[0])[1] - s.point(i[1])[1], 0}),
                new Case("vertical", (s, i) -> s.vertical(i[1], i[0]), new int[] {1, 0}, null,
                    (s, i) -> new double[] {s.point(i[1])[0] - s.point(i[0])[0], 0}),
                new Case("parallel", (s, i) -> s.parallel(i[4], i[5]), new int[] {4, 5}, null, (s, i) -> new double[] {skCross(s, i[4], i[5]), 0}),
                new Case("perpendicular", (s, i) -> s.perpendicular(i[4], i[5]), new int[] {4, 5}, null, (s, i) -> new double[] {skDot(s, i[4], i[5]), 0}),
                new Case("collinear", (s, i) -> s.collinear(i[4], i[5]), new int[] {4, 5}, null,
                    (s, i) -> new double[] {skCross(s, i[4], i[5]) + skOff(s, i[4], s.ends(i[5])[0]), 0}),
                new Case("tangent", (s, i) -> s.tangent(i[4], i[6]), new int[] {4, 6}, null,
                    (s, i) -> new double[] {Math.abs(skOff(s, i[4], s.centre(i[6]))), s.radius(i[6])}),
                new Case("tangent_at_end", (s, i) -> s.tangentAtEnd(i[9], i[4]), new int[] {9, 4}, null, none),
                new Case("concentric", (s, i) -> s.concentric(i[6], i[7]), new int[] {6, 7}, null,
                    (s, i) -> new double[] {skDist(s, s.centre(i[6]), s.centre(i[7])), 0}),
                new Case("equal_length", (s, i) -> s.equalLength(i[4], i[5]), new int[] {4, 5}, null,
                    (s, i) -> new double[] {skLen(s, i[4]) - skLen(s, i[5]), 0}),
                new Case("equal_radius", (s, i) -> s.equalRadius(i[6], i[7]), new int[] {6, 7}, null,
                    (s, i) -> new double[] {s.radius(i[6]) - s.radius(i[7]), 0}),
                new Case("midpoint", (s, i) -> s.midpoint(i[2], i[4]), new int[] {2, 4}, null, (s, i) -> {
                    double[] e0 = s.point(s.ends(i[4])[0]), e1 = s.point(s.ends(i[4])[1]), p = s.point(i[2]);
                    return new double[] {Math.hypot(p[0] - (e0[0] + e1[0]) / 2, p[1] - (e0[1] + e1[1]) / 2), 0};
                }),
                new Case("symmetric", (s, i) -> s.symmetric(i[2], i[3], i[4]), new int[] {2, 3, 4}, null,
                    (s, i) -> new double[] {skOff(s, i[4], i[2]) + skOff(s, i[4], i[3]), 0}),
                new Case("fix", (s, i) -> s.fix(i[0]), new int[] {0}, null, none),
                new Case("distance", (s, i) -> s.distance(i[0], i[2], 5), new int[] {0, 2}, 5.0, (s, i) -> new double[] {skDist(s, i[0], i[2]), 5}),
                new Case("point_line_distance", (s, i) -> s.pointLineDistance(i[2], i[4], 3), new int[] {2, 4}, 3.0,
                    (s, i) -> new double[] {Math.abs(skOff(s, i[4], i[2])), 3}),
                new Case("line_distance", (s, i) -> s.lineDistance(i[4], i[5], 2), new int[] {4, 5}, 2.0, none),
                new Case("circle_line_distance", (s, i) -> s.circleLineDistance(i[6], i[4], 2), new int[] {6, 4}, 2.0, none),
                new Case("circle_distance", (s, i) -> s.circleDistance(i[6], i[7], 5), new int[] {6, 7}, 5.0, none),
                new Case("horizontal_distance", (s, i) -> s.horizontalDistance(i[0], i[2], 4), new int[] {0, 2}, 4.0,
                    (s, i) -> new double[] {Math.abs(s.point(i[2])[0] - s.point(i[0])[0]), 4}),
                new Case("vertical_distance", (s, i) -> s.verticalDistance(i[0], i[2], 4), new int[] {0, 2}, 4.0,
                    (s, i) -> new double[] {Math.abs(s.point(i[2])[1] - s.point(i[0])[1]), 4}),
                new Case("length", (s, i) -> s.length(i[4], 9), new int[] {4}, 9.0, (s, i) -> new double[] {skLen(s, i[4]), 9}),
                new Case("angle", (s, i) -> s.angle(i[4], i[5], 0.5), new int[] {4, 5}, 0.5,
                    (s, i) -> new double[] {Math.abs(Math.atan2(skCross(s, i[4], i[5]), skDot(s, i[4], i[5]))), 0.5}),
                new Case("radius", (s, i) -> s.radiusOf(i[6], 2.5), new int[] {6}, 2.5, (s, i) -> new double[] {s.radius(i[6]), 2.5}),
                new Case("diameter", (s, i) -> s.diameter(i[6], 7), new int[] {6}, 7.0, (s, i) -> new double[] {s.radius(i[6]), 3.5}),
            };
            if (cases.length != 27 || Arrays.stream(cases).map(Case::kind).distinct().count() != 27)
                fail("sketch: the every-method table is not 27 distinct kinds");
            for (Case cs : cases) {
                try (Blacksmith.Sketch s = new Blacksmith.Sketch()) {
                    // 0..3 points, 4 and 5 lines, 6 and 7 circles, 8 an arc, 9 a free curve
                    int p0 = s.addPoint(0, 0), p1 = s.addPoint(10, 2), p2 = s.addPoint(3, 7), p3 = s.addPoint(12, 9);
                    int l1 = s.addLine(p0, p1), l2 = s.addLine(p2, p3);
                    int c1 = s.addCircle(s.addPoint(20, 20), 3), c2 = s.addCircle(s.addPoint(30, 22), 4);
                    int arc = s.addArc(s.addPoint(0, 30), s.addPoint(5, 30), s.addPoint(0, 35));
                    int curve = s.addBezier(s.addPoint(40, 0), new double[] {41, 1}, new double[] {42, 1}, new double[] {43, 0});
                    int[] ids = {p0, p1, p2, p3, l1, l2, c1, c2, arc, curve};
                    int id = 0;
                    try {
                        id = cs.make().apply(s, ids);
                    } catch (Blacksmith.BuildException e) {
                        fail("sketch: " + cs.kind() + " was refused: " + e.getMessage());
                    }
                    if (!s.constraintKind(id).equals(cs.kind())) fail("sketch: " + cs.kind() + " reads back as " + s.constraintKind(id));
                    int[] want = Arrays.stream(cs.refs()).map(r -> ids[r]).toArray();
                    if (!Arrays.equals(s.constraintRefs(id), want)) fail("sketch: " + cs.kind() + "'s refs read " + Arrays.toString(s.constraintRefs(id)));
                    java.util.OptionalDouble got = s.constraintValue(id);
                    if (cs.value() == null ? got.isPresent() : !got.isPresent() || got.getAsDouble() != cs.value())
                        fail("sketch: " + cs.kind() + "'s value reads " + got);
                    if (cs.effect() != null) {
                        if (!s.solve().converged()) fail("sketch: " + cs.kind() + " does not solve");
                        double[] gw = cs.effect().apply(s, ids);
                        if (Math.abs(gw[0] - gw[1]) > 1e-6) fail("sketch: " + cs.kind() + " left " + gw[0] + " where " + gw[1] + " was meant");
                    }
                }
            }
            try (Blacksmith.Sketch k = new Blacksmith.Sketch()) {
                int arcId = k.addArc(k.addPoint(0, 0), k.addPoint(1, 0), k.addPoint(0, 1));
                int conicId = k.addConic(k.addPoint(5, 5), new double[] {6, 7}, new double[] {8, 5}, 0.7);
                if (!k.kind(arcId).equals("arc") || !k.kind(conicId).equals("free_curve")) fail("sketch: add_arc or add_conic kind");
            }
        }
        // the drag rule: ascending id order to the library (a map holds each id once, so a repeat cannot be said)
        {
            Map<Integer, double[]> shuffled = new java.util.LinkedHashMap<>();
            shuffled.put(9, new double[] {1, 2});
            shuffled.put(2, new double[] {3, 4});
            shuffled.put(5, new double[] {5, 6});
            if (!Arrays.equals(Blacksmith.Sketch.dragOrder(shuffled), new int[] {2, 5, 9}))
                fail("sketch: drag order is " + Arrays.toString(Blacksmith.Sketch.dragOrder(shuffled)));
            try (Blacksmith.Sketch s = new Blacksmith.Sketch()) {
                int[] rc = s.addRect(new double[] {0, 0}, new double[] {40, 30}).corners();
                Map<Integer, double[]> back = new java.util.LinkedHashMap<>();
                back.put(rc[2], new double[] {45, 35});
                back.put(rc[0], new double[] {5, 5});
                Blacksmith.SolveReport r = s.drag(back);
                if (!List.of("converged", "conflicting", "diverged").contains(r.status())) fail("sketch: a two-point drag gave " + r);
            }
        }
        // report numbers convert exactly (a NaN or a fraction is an error naming the call, never a code)
        {
            if (Blacksmith.Sketch.exact(7, "sketch_solve") != 7 || Blacksmith.Sketch.exact(-3, "sketch_solve") != -3) fail("sketch: exact of a whole number");
            for (double bad : new double[] {Double.NaN, 1.5, 3e9, -3e9, Double.POSITIVE_INFINITY}) {
                Blacksmith.BuildException e = skRefused(() -> Blacksmith.Sketch.exact(bad, "sketch_diagnose"));
                if (e == null || !e.getMessage().startsWith("sketch_diagnose:")) fail("sketch: exact(" + bad + ") gave '" + (e == null ? null : e.getMessage()) + "'");
            }
        }
        // ids refused before the call name sketch_constrain; a closed sketch is reported as closed whatever the arguments;
        // a closed other sketch; a bad end name; the records hand out copies; the nurbs overload without weights
        {
            try (Blacksmith.Sketch s = new Blacksmith.Sketch()) {
                Blacksmith.BuildException neg = skRefused(() -> s.coincident(-1, 0));
                if (neg == null || !neg.getMessage().startsWith("sketch_constrain: entity id must not be negative"))
                    fail("sketch: a negative constraint id gave '" + (neg == null ? null : neg.getMessage()) + "'");
                Blacksmith.BuildException negKind = skRefused(() -> s.kind(-1));
                if (negKind == null || !negKind.getMessage().startsWith("sketch_kind: id must not be negative"))
                    fail("sketch: a negative id gave '" + (negKind == null ? null : negKind.getMessage()) + "'");
                int a = s.addPoint(0, 0);
                int line = s.addLine(a, s.addPoint(4, 0));
                int curve = s.addBezier(s.addPoint(5, 0), new double[] {6, 0}, new double[] {7, 1}, new double[] {8, 1});
                Blacksmith.BuildException middle = skRefused(() -> s.tangentAtEnd(curve, line, "middle"));
                if (middle == null || !middle.getMessage().contains("end must be one of"))
                    fail("sketch: a bad end name gave '" + (middle == null ? null : middle.getMessage()) + "'");
                int[] dofRedundant = s.diagnose().redundant();
                if (dofRedundant.length != 0) fail("sketch: a fresh sketch has redundant constraints");
                Blacksmith.SketchRect rr = s.addRect(new double[] {0, 10}, new double[] {4, 14});
                rr.corners()[0] = 12345;
                if (rr.corners()[0] == 12345) fail("sketch: a record handed out its own array");
                int plain = s.addNurbs(a, new double[][] {{1, 2}, {3, 2}, {4, 0}}, new double[] {0, 0, 0, 0.5, 1, 1, 1}, 2);
                if (!s.kind(plain).equals("free_curve")) fail("sketch: addNurbs without weights");
                Blacksmith.Sketch other = new Blacksmith.Sketch();
                other.addPoint(1, 1);
                other.close();
                try {
                    s.reference(other, 0);
                    fail("sketch: referencing a closed sketch did not fail");
                } catch (IllegalStateException e) {
                    if (!"sketch: closed".equals(e.getMessage())) fail("sketch: a closed other reads \"" + e.getMessage() + "\"");
                }
            }
            Blacksmith.Sketch closed = new Blacksmith.Sketch();
            closed.close();
            try {
                closed.kind(-1);
                fail("sketch: a closed sketch with a bad id did not fail");
            } catch (IllegalStateException e) {
                if (!"sketch: closed".equals(e.getMessage())) fail("sketch: a closed sketch with a bad id reads \"" + e.getMessage() + "\"");
            }
            try {
                closed.addRect(new double[] {0, 0}, new double[] {1});
                fail("sketch: a closed addRect with a bad point did not fail");
            } catch (IllegalStateException e) {
                if (!"sketch: closed".equals(e.getMessage())) fail("sketch: a closed addRect reads \"" + e.getMessage() + "\"");
            }
        }
        System.out.println("sketch: entities, constraints, solves, diagnosis, references and refusals with ids");
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

    // Solid.withMaterial and Solid.styled with their readers, at parity with the Python
    // reference's test_a_material_and_an_outside_style_ride_operations_and_reach_step.
    private static void materials() {
        try (Blacksmith.Solid cube = Blacksmith.Solid.cuboid(1, 1, 1);
             Blacksmith.Solid made = cube.withMaterial("Steel");
             Blacksmith.Solid steel = made.styled("materials/steel.mtlx", "BrushedSteel");
             Blacksmith.Solid tool = cube.translate(0.5, 0.5, 0.5);
             Blacksmith.Solid cut = steel.cut(tool);
             Blacksmith.Solid only = cube.styled(null, "BrushedSteel")) {
            if (cube.material() != null) fail("material: a fresh cuboid has a material");
            if (!"Steel".equals(steel.material()) || !"materials/steel.mtlx".equals(steel.styleLocation())
                    || !"BrushedSteel".equals(steel.styleIdentification()))
                fail("material: read back " + steel.material() + ", " + steel.styleLocation() + ", " + steel.styleIdentification());
            if (!"Steel".equals(cut.material())) fail("material: a cut is made of " + cut.material() + ", not its target's Steel");
            if (only.styleLocation() != null) fail("material: a style given no location has one");
            String text = steel.stepText();
            if (!text.contains("MATERIAL_DESIGNATION('Steel'") || !text.contains("EXTERNALLY_DEFINED_STYLE(IDENTIFIER('BrushedSteel')"))
                fail("material: STEP is missing the material or the style");
            boolean refused = false;
            try { cube.withMaterial(" ").close(); } catch (Blacksmith.BuildException e) { refused = true; }
            if (!refused) fail("material: a blank material was accepted");
            refused = false;
            try { cube.styled(null, null).close(); } catch (Blacksmith.BuildException e) { refused = true; }
            if (!refused) fail("material: a style naming nothing was accepted");
        }
        System.out.println("kernel material: read back, kept by a cut, written to STEP");
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

    // ---- value geometry (plan B3): Python's TestInterval, TestFrameVerbs, TestCurveValues,
    // TestSurfaceValues and TestCuboidValue, figure for figure, with the Rhino records from
    // crates/cadaclysm/tests/fixtures/rhino/value_vectors.txt. Its path comes from the system
    // property cadaclysm.value_vectors (build.sh prints the run line that sets it), never from
    // the working directory, and a missing file fails the smoke. The SDK's copy has no records:
    // run without the property, these checks are SKIPPED, as the reader health checks are.

    private static final double[] XY = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
    /** Right-handed and exact: x = world y, y = world z, z = world x, off the origin. */
    private static final double[] YZX = {1, 2, 3, 0, 1, 0, 0, 0, 1, 1, 0, 0};
    private static final double EXACT = 1e-12;
    private static final double NURBS_FOOT = 1e-7;

    private static void values() throws IOException {
        if (System.getProperty("cadaclysm.value_vectors") == null) {
            System.out.println("values: -Dcadaclysm.value_vectors not set (the records are only in the source checkout), value checks SKIPPED");
            return;
        }
        Map<String, String[]> r = valueVectors();
        intervals(r);
        frameVerbs(r);
        curveValues(r);
        surfaceValues(r);
        cuboidValues(r);
        System.out.println("values: " + r.size() + " Rhino records read; interval, frame verbs, curves, surfaces, boxes ok");
    }

    private static Map<String, String[]> valueVectors() throws IOException {
        String path = System.getProperty("cadaclysm.value_vectors");
        if (path == null) fail("values: -Dcadaclysm.value_vectors is not set (build.sh prints the run line that sets it)");
        Path file = Path.of(path);
        if (!Files.isRegularFile(file)) fail("values: the Rhino vectors file " + file + " is missing");
        Map<String, String[]> records = new java.util.HashMap<>();
        for (String raw : Files.readAllLines(file)) {
            String line = raw.strip();
            if (line.contains("ERROR")) fail("values: an ERROR line in the vectors file: " + line);
            if (line.isEmpty() || line.startsWith("#")) continue;
            String[] words = line.split("\\s+");
            String key = words[0] + " " + words[1];
            if (records.put(key, Arrays.copyOfRange(words, 2, words.length)) != null) fail("values: " + key + " twice in the vectors file");
        }
        return records;
    }

    private static double[] nums(Map<String, String[]> r, String c, String what) {
        String[] words = r.get(c + " " + what);
        if (words == null) fail("values: no record " + c + " " + what);
        double[] out = new double[words.length];
        for (int i = 0; i < words.length; i++) out[i] = Double.parseDouble(words[i]);
        return out;
    }

    private static void vCheck(boolean ok, String what) {
        if (!ok) fail("values: " + what);
    }

    private static void vClose(String label, double[] got, double[] want, double tol) {
        boolean ok = got != null && got.length == want.length;
        for (int i = 0; ok && i < want.length; i++) ok = Math.abs(got[i] - want[i]) <= tol;
        if (!ok) fail("values: " + label + " is " + Arrays.toString(got) + ", not " + Arrays.toString(want));
    }

    /** Element-wise ==, as Python's tuple equality (so -0.0 equals 0.0). */
    private static boolean same(double[] got, double... want) {
        if (got == null || got.length != want.length) return false;
        for (int i = 0; i < want.length; i++) if (got[i] != want[i]) return false;
        return true;
    }

    private static void vRefused(String what, Runnable call, String exact) {
        String said = refused(call);
        if (!said.equals(exact)) fail("values: " + what + " said '" + said + "', not '" + exact + "'");
    }

    private static double[] cat3(double[] head, double... tail) {
        double[] out = Arrays.copyOf(head, head.length + tail.length);
        System.arraycopy(tail, 0, out, head.length, tail.length);
        return out;
    }

    private static double[][] points3(double[] flat) {
        double[][] out = new double[flat.length / 3][];
        for (int k = 0; k < out.length; k++) out[k] = Arrays.copyOfRange(flat, 3 * k, 3 * k + 3);
        return out;
    }

    /** Python's float {@code a % m}: the sign of {@code m}. */
    private static double pyMod(double a, double m) {
        double rem = a % m;
        if (rem != 0 && (rem < 0) != (m < 0)) rem += m;
        return rem;
    }

    private static double dist3(double[] a, double[] b) {
        return Math.sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));
    }

    private static String q2(int i) {
        return String.format("%02d", i);
    }

    /** A foot Rhino found by iteration on a NURBS form: the distance to 1e-12, never beaten by
     *  Rhino's, the point to 1e-7 -- as B1's nurbs_foot. */
    private static void nurbsFoot(String label, double[] q, double[] ours, double[] rhino) {
        double d = dist3(q, ours), dr = dist3(q, rhino);
        vCheck(d <= dr + EXACT && Math.abs(d - dr) <= EXACT, label + ": distance " + d + " against Rhino's " + dr);
        vClose(label, ours, rhino, NURBS_FOOT);
    }

    private static boolean approx(double got, double want) {
        return Math.abs(got - want) <= Math.max(1e-6 * Math.abs(want), 1e-12);
    }

    private static void intervals(Map<String, String[]> r) {
        Blacksmith.Interval up = new Blacksmith.Interval(2, 6), down = new Blacksmith.Interval(6, 2);
        // the measures keep the orientation
        vCheck(up.length() == 4.0 && down.length() == -4.0, "interval lengths " + up.length() + " " + down.length());
        vCheck(up.mid() == 4.0 && down.mid() == 4.0, "interval mids");
        vCheck(up.min() == 2.0 && up.max() == 6.0 && down.min() == 2.0 && down.max() == 6.0, "interval min/max");
        vCheck(up.isIncreasing() && !down.isIncreasing() && !new Blacksmith.Interval(3, 3).isIncreasing(), "isIncreasing");
        vCheck(new Blacksmith.Interval(3, 3).isSingleton() && !up.isSingleton(), "isSingleton");
        vCheck(up.swapped().equals(down) && down.swapped().equals(up), "swapped");
        vCheck(same(down.toArray(), 6, 2) && down.t0() == 6.0 && down.t1() == 2.0, "the decreasing interval's ends");
        // the set operations answer increasing, and touching is a singleton
        vCheck(up.grown(9).equals(iv(2, 9)) && down.grown(-1).equals(iv(-1, 6)) && down.grown(3).equals(up), "grown");
        vCheck(up.union(iv(8, 7)).equals(iv(2, 8)) && down.union(iv(1, 3)).equals(iv(1, 6)), "union");
        vCheck(down.intersect(iv(9, 4)).equals(java.util.Optional.of(iv(4, 6))) && up.intersect(iv(3, 5)).equals(java.util.Optional.of(iv(3, 5))), "intersect");
        vCheck(up.intersect(iv(7, 9)).isEmpty() && down.intersect(iv(1, 1.5)).isEmpty(), "intersect apart");
        vCheck(iv(0, 1).intersect(iv(1, 2)).equals(java.util.Optional.of(iv(1, 1)))
            && iv(2, 1).intersect(iv(0, 1)).equals(java.util.Optional.of(iv(1, 1))), "touching intervals intersect in a singleton");
        for (Blacksmith.Interval x : List.of(up, down)) {
            vCheck(x.contains(2) && x.contains(6) && x.contains(4.5), x + " contains its range");
            vCheck(!x.contains(1.999) && !x.contains(6.001), x + " contains nothing past its ends");
        }
        // the parameters round trip
        vCheck(up.parameterAt(0.25) == 3.0 && down.parameterAt(0.25) == 5.0, "parameterAt");
        for (Blacksmith.Interval x : List.of(up, down, iv(-1.5, 0.7)))
            for (double s : new double[] {-0.5, 0.0, 0.3, 1.0, 2.0})
                vCheck(Math.abs(x.normalizedParameterAt(x.parameterAt(s)).getAsDouble() - s) <= 1e-15, x + " round trips " + s);
        vCheck(iv(3, 3).normalizedParameterAt(3).isEmpty(), "a singleton has no normalized parameter");
        // a value, equal and hashed by its numbers
        Blacksmith.Interval a = iv(1, 2);
        vCheck(a.equals(iv(1.0, 2.0)) && a.hashCode() == iv(1.0, 2.0).hashCode() && new HashSet<>(List.of(a, iv(1, 2))).size() == 1, "interval equality");
        vCheck(iv(-0.0, 1).equals(iv(0.0, 1)), "-0.0 is 0.0");
        vCheck(a.toString().equals("Interval(1.0, 2.0)"), "interval reads " + a);
        vCheck(Blacksmith.Interval.of(new double[] {1, 2}).equals(a), "Interval.of");
        vRefused("a NaN interval", () -> iv(Double.NaN, 1), "Interval: not finite");
        vRefused("an infinite interval", () -> iv(0, Double.POSITIVE_INFINITY), "Interval: not finite");
        vRefused("three numbers", () -> Blacksmith.Interval.of(new double[3]), "Interval: an interval is 2 numbers, got 3");
        // matches Rhino
        for (String name : new String[] {"apart", "dec_dec", "inc_dec", "inc_inc", "touch"}) {
            String c = "interval_" + name;
            double[] args = nums(r, c, "args");
            Blacksmith.Interval x = iv(args[0], args[1]), y = iv(args[2], args[3]);
            vCheck(same(x.union(y).toArray(), nums(r, c, "union")), c + " union " + x.union(y));
            java.util.Optional<Blacksmith.Interval> got = x.intersect(y);
            if (r.get(c + " intersection").length == 1 && r.get(c + " intersection")[0].equals("none")) vCheck(got.isEmpty(), c + " intersects");
            else vCheck(got.isPresent() && same(got.get().toArray(), nums(r, c, "intersection")), c + " intersection " + got);
        }
        for (String name : new String[] {"inc_inside", "inc_out", "dec_low", "dec_inside"}) {
            double[] args = nums(r, "grow_" + name, "args");
            vCheck(same(iv(args[0], args[1]).grown(args[2]).toArray(), nums(r, "grow_" + name, "grown")), "grow_" + name);
        }
        for (String name : new String[] {"inc", "dec"})
            for (int k = 0; k < 4; k++) {
                String c = "param_" + name + "_" + k;
                double[] args = nums(r, c, "args");
                Blacksmith.Interval x = iv(args[0], args[1]);
                double t = args[2];
                vClose(c, new double[] {x.parameterAt(t)}, nums(r, c, "parameter_at"), EXACT);
                vClose(c, new double[] {x.normalizedParameterAt(2.5 + t).getAsDouble()}, nums(r, c, "normalized_at"), EXACT);
            }
    }

    private static Blacksmith.Interval iv(double t0, double t1) {
        return new Blacksmith.Interval(t0, t1);
    }

    private static void frameVerbs(Map<String, String[]> r) {
        Blacksmith.Frame p = Blacksmith.Frame.of(nums(r, "plane", "frame"));
        vClose("flip", p.flipped().toArray(), nums(r, "plane", "flip"), EXACT);
        vClose("rotate", p.rotated(0.6, new double[] {1, -1, 0.5}).toArray(), nums(r, "plane", "rotate"), EXACT);
        for (int i = 0; i < 12; i++) {
            String c = "plane_" + q2(i);
            double[] q = nums(r, c, "query");
            vClose(c + " remap", p.toLocal(q), nums(r, c, "remap"), EXACT);
            vClose(c + " closest", p.closestPoint(q), nums(r, c, "closest"), EXACT);
            vClose(c + " distance", new double[] {p.distanceTo(q)}, nums(r, c, "distance"), EXACT);
        }
        vRefused("a two-number point", () -> p.toLocal(new double[2]), "to_local: a point is 3 numbers, got 2");

        double[][] pts = points3(nums(r, "fit", "points"));
        Blacksmith.Frame.Fit fit = Blacksmith.Frame.fit(pts);
        Blacksmith.Frame got = fit.frame(), want = Blacksmith.Frame.of(nums(r, "fit", "frame"));
        double[] gz = got.z(), wz = want.z();
        double sign = gz[0] * wz[0] + gz[1] * wz[1] + gz[2] * wz[2] < 0 ? -1.0 : 1.0;
        vClose("fit normal", new double[] {sign * gz[0], sign * gz[1], sign * gz[2]}, wz, EXACT);
        vClose("fit origins", new double[] {want.distanceTo(got.origin()), got.distanceTo(want.origin())}, new double[] {0, 0}, EXACT);
        vClose("fit deviation", new double[] {fit.deviation()}, nums(r, "fit", "deviation"), EXACT);
        vRefused("two points", () -> Blacksmith.Frame.fit(Arrays.copyOf(pts, 2)), "frame_fit: needs three points");
        vRefused("points on a line", () -> Blacksmith.Frame.fit(new double[][] {{0, 0, 0}, {1, 1, 1}, {2, 2, 2}}),
            "frame_fit: the points lie on one line");
        vRefused("a two-number fit point", () -> Blacksmith.Frame.fit(new double[][] {{0, 0, 0}, {1, 0}, {0, 1, 0}}),
            "frame_fit: a point is 3 numbers, got 2");
    }

    private static void curveValues(Map<String, String[]> r) {
        // a bad value is refused by value_check
        vRefused("a zero radius", () -> new Blacksmith.Circle(XY, 0), "value_check: the radius must be positive");
        vRefused("a line of no length", () -> new Blacksmith.Line(new double[] {1, 1, 1}, new double[] {1, 1, 1}), "value_check: the line has no length");
        vRefused("an arc past a turn", () -> new Blacksmith.Arc(XY, 1, iv(0, 7)), "value_check: the angle must increase by at most a full turn");
        vRefused("a decreasing arc", () -> new Blacksmith.Arc(XY, 1, iv(1, 0)), "value_check: the angle must increase by at most a full turn");
        vRefused("a negative r2", () -> new Blacksmith.Ellipse(XY, 3, -1), "value_check: the second radius must be positive");
        vRefused("a skew frame", () -> new Blacksmith.Circle(new double[] {0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1}, 1),
            "value_check: the frame is not right-handed and orthonormal");
        vRefused("12 numbers for a circle", () -> Blacksmith.Circle.fromArray(new double[12]), "value_check: a circle is 13 numbers, got 12");
        vRefused("a two-number end", () -> new Blacksmith.Line(new double[2], new double[] {1, 0, 0}), "Line: a point is 3 numbers, got 2");
        // 1e-7 off square is squared up, not refused
        Blacksmith.Circle near = new Blacksmith.Circle(new double[] {0, 0, 0, 1, 1e-7, 0, 0, 1, 0, 0, 0, 1}, 1);
        double[] nx = near.frame().x(), ny = near.frame().y();
        vCheck(Math.abs(nx[0] * ny[0] + nx[1] * ny[1] + nx[2] * ny[2]) < 1e-15 && nx[1] != 0, "a near-square frame is squared up");

        // each call answers B1's figures
        Blacksmith.Circle unit = new Blacksmith.Circle(XY, 1);
        vClose("unit point", unit.pointAt(Math.PI / 2), new double[] {0, 1, 0}, 1e-15);
        vClose("unit tangent", unit.tangentAt(0), new double[] {0, 1, 0}, 1e-15);
        Blacksmith.Line line = new Blacksmith.Line(new double[] {0, 0, 0}, new double[] {1, 2, 3});
        vCheck(same(line.pointAt(0.5), 0.5, 1.0, 1.5) && line.length() == Math.sqrt(14), "line point and length");
        vCheck(same(line.start(), 0, 0, 0) && same(line.end(), 1, 2, 3), "line ends");
        double s14 = Math.sqrt(14);
        vClose("line tangent", line.tangentAt(0), new double[] {1 / s14, 2 / s14, 3 / s14}, 1e-15);
        Blacksmith.Arc quarter = new Blacksmith.Arc(XY, 2, iv(0, Math.PI / 2));
        vCheck(quarter.length() == Math.PI && quarter.angle().equals(iv(0, Math.PI / 2)), "quarter arc length and angle");
        vClose("arc start", quarter.start(), new double[] {2, 0, 0}, 1e-15);
        vClose("arc end", quarter.end(), new double[] {0, 2, 0}, 1e-15);
        vClose("arc mid", quarter.mid(), new double[] {Math.sqrt(2), Math.sqrt(2), 0}, 1e-15);
        // on the axis the foot is a pick: t = 0, not unique
        Blacksmith.CurveFoot off = unit.closestPoint(new double[] {2, 0, 5}), axis = unit.closestPoint(new double[] {0, 0, 5});
        vCheck(off.t() == 0 && same(off.point(), 1, 0, 0) && off.unique(), "the unit circle's foot from (2, 0, 5) is " + off);
        vCheck(axis.t() == 0 && same(axis.point(), 1, 0, 0) && !axis.unique(), "the unit circle's foot from its axis is " + axis);
        vCheck(off.equals(new Blacksmith.CurveFoot(0.0, new double[] {1, 0, 0}, true)), "a CurveFoot is a value");
        vCheck(approx(unit.distanceTo(new double[] {2, 0, 5}), Math.sqrt(26)), "distanceTo");
        Blacksmith.Bounds lb = new Blacksmith.Line(new double[] {1, 5, 0}, new double[] {0, 2, 3}).bounds();
        vCheck(same(lb.min(), 0, 2, 0) && same(lb.max(), 1, 5, 3), "line bounds");
        vCheck(Math.abs(new Blacksmith.Ellipse(XY, 3, 1).length() - 13.364893220555258) <= 1e-12 * 13.364893220555258, "ellipse length");
        vRefused("a two-number query", () -> unit.closestPoint(new double[2]), "curve_value_closest_point: a point is 3 numbers, got 2");

        // the constructors and transforms
        double[] a = {1, 0, 0}, b = {0, 1, 0}, c = {-1, 0, 0};
        Blacksmith.Circle circle = Blacksmith.Circle.through(a, b, c);
        vClose("circle through", circle.values(), cat3(XY, 1), 1e-15);
        vClose("arc through", Blacksmith.Arc.through(a, b, c).values(), cat3(XY, 1, 0, Math.PI), 1e-15);
        vClose("arc from start tangent end", Blacksmith.Arc.fromStartTangentEnd(a, new double[] {0, 1, 0}, c).values(), cat3(XY, 1, 0, Math.PI), 1e-15);
        vRefused("a coincident circle", () -> Blacksmith.Circle.through(a, a, c), "circle_through: the points are coincident or collinear");
        vRefused("a zero tangent", () -> Blacksmith.Arc.fromStartTangentEnd(a, new double[3], c),
            "arc_from_start_tangent_end: the tangent is zero or the end lies on the tangent line");
        vRefused("a two-number through point", () -> Blacksmith.Circle.through(new double[2], b, c), "circle_through: a point is 3 numbers, got 2");
        vCheck(Blacksmith.Ellipse.fromCircle(new Blacksmith.Circle(XY, 2)).equals(new Blacksmith.Ellipse(XY, 2, 2)), "fromCircle");
        vCheck(new Blacksmith.Circle(XY, 1).transform(Blacksmith.Transform.scale(new double[3], 2)).equals(new Blacksmith.Circle(XY, 2)), "a scaled circle");
        Blacksmith.Transform stretch = Blacksmith.Transform.scaleXyz(Blacksmith.Frame.xy(), 1, 3, 1);
        vRefused("a stretched circle", () -> new Blacksmith.Circle(XY, 1).transform(stretch),
            "value_transform: a circle takes only a similarity (use ellipse_from_circle)");
        Blacksmith.Ellipse e = Blacksmith.Ellipse.fromCircle(new Blacksmith.Circle(XY, 1)).transform(stretch.rows());
        vCheck(Math.abs(e.r1() - 3) <= 1e-15 && Math.abs(e.r2() - 1) <= 1e-15, "a stretched ellipse " + e);
        Blacksmith.Line moved = new Blacksmith.Line(new double[] {0, 0, 0}, new double[] {1, 0, 0}).transform(Blacksmith.Transform.translation(new double[] {0, 0, 2}));
        vCheck(moved.equals(new Blacksmith.Line(new double[] {0, 0, 2}, new double[] {1, 0, 2})), "a moved line " + moved);

        // values are immutable, hashable, and hold their array
        Blacksmith.Circle cy = new Blacksmith.Circle(YZX, 2);
        vCheck(Arrays.equals(cy.values(), cat3(YZX, 2)) && cy.radius() == 2.0 && cy.frame().equals(Blacksmith.Frame.of(YZX)), "a circle's fields");
        vCheck(cy.equals(new Blacksmith.Circle(Blacksmith.Frame.of(YZX), 2.0)) && cy.hashCode() == new Blacksmith.Circle(YZX, 2).hashCode(), "circle equality");
        vCheck(!cy.equals(new Blacksmith.Sphere(YZX, 2)), "a circle equals a sphere of the same numbers");
        vCheck(new HashSet<Object>(List.of(cy, new Blacksmith.Circle(YZX, 2), new Blacksmith.Sphere(YZX, 2))).size() == 2, "the set of two circles and a sphere");
        vCheck(Blacksmith.Circle.fromArray(cy.values()).equals(cy), "fromArray(values()) round trips");
        vCheck(cy.toString().startsWith("Circle(frame=Frame(origin=[1.0, 2.0, 3.0]") && cy.toString().endsWith("radius=2.0)"), "a circle reads " + cy);
        double[] mine = cy.values();
        mine[12] = 9;
        vCheck(cy.radius() == 2.0, "values() hands out the circle's own array");

        // lines, circles and arcs match Rhino
        double[] ends = nums(r, "line", "ends");
        Blacksmith.Line rl = new Blacksmith.Line(Arrays.copyOfRange(ends, 0, 3), Arrays.copyOfRange(ends, 3, 6));
        vClose("line length", new double[] {rl.length()}, nums(r, "line", "length"), EXACT);
        vClose("line tangent", rl.tangentAt(0.5), nums(r, "line", "tangent"), EXACT);
        for (int k = 0; k < 5; k++) {
            double[] n = nums(r, "line_at_" + k, "point");
            vClose("line_at_" + k, rl.pointAt(n[0]), Arrays.copyOfRange(n, 1, n.length), EXACT);
        }
        for (int i = 0; i < 12; i++) {
            String cs = "line_" + q2(i);
            vClose(cs, rl.closestPoint(nums(r, cs, "query")).point(), nums(r, cs, "closest"), EXACT);
        }
        Blacksmith.Circle rc = new Blacksmith.Circle(nums(r, "circle", "frame"), nums(r, "circle", "radius")[0]);
        vClose("circle length", new double[] {rc.length()}, nums(r, "circle", "length"), EXACT);
        for (int k = 0; k < 5; k++) {
            double[] n = nums(r, "circle_at_" + k, "point");
            vClose("circle_at_" + k, rc.pointAt(n[0]), Arrays.copyOfRange(n, 1, 4), EXACT);
            vClose("circle_at_" + k + " tangent", rc.tangentAt(n[0]), Arrays.copyOfRange(n, 4, 7), EXACT);
        }
        for (int i = 0; i < 12; i++) {
            String cs = "circle_" + q2(i);
            double[] want = nums(r, cs, "closest");
            Blacksmith.CurveFoot foot = rc.closestPoint(nums(r, cs, "query"));
            vCheck(foot.unique(), cs + " is not unique");
            vClose(cs + " t", new double[] {foot.t()}, new double[] {pyMod(want[0], 2 * Math.PI)}, EXACT);
            vClose(cs, foot.point(), Arrays.copyOfRange(want, 1, want.length), EXACT);
        }
        Blacksmith.Arc ra = new Blacksmith.Arc(nums(r, "arc", "frame"), nums(r, "arc", "radius")[0], Blacksmith.Interval.of(nums(r, "arc", "angle")));
        vClose("arc length", new double[] {ra.length()}, nums(r, "arc", "length"), EXACT);
        for (int k = 0; k < 4; k++) {
            double[] n = nums(r, "arc_at_" + k, "point");
            vClose("arc_at_" + k, ra.pointAt(n[0]), Arrays.copyOfRange(n, 1, 4), EXACT);
            vClose("arc_at_" + k + " tangent", ra.tangentAt(n[0]), Arrays.copyOfRange(n, 4, 7), EXACT);
        }
        for (int i = 0; i < 12; i++) {
            String cs = "arc_" + q2(i);
            double[] want = nums(r, cs, "closest");
            Blacksmith.CurveFoot foot = ra.closestPoint(nums(r, cs, "query"));
            vClose(cs + " t", new double[] {foot.t()}, Arrays.copyOfRange(want, 0, 1), EXACT);
            vClose(cs, foot.point(), Arrays.copyOfRange(want, 1, want.length), EXACT);
        }

        edgeCurveValues();
    }

    private static Set<String> rounded9(double[]... points) {
        Set<String> out = new HashSet<>();
        for (double[] p : points) {
            StringBuilder key = new StringBuilder();
            for (double v : p) key.append(Math.round(v * 1e9) / 1e9 + 0.0).append(',');
            out.add(key.toString());
        }
        return out;
    }

    // test_an_edges_curve_is_its_value
    private static void edgeCurveValues() {
        try (Blacksmith.Solid can = Blacksmith.Solid.cylinder(5, 3)) {
            int rims = 0;
            for (Blacksmith.Edge rim : can.edges()) {
                if (!rim.kind().equals("circle")) continue;
                rims++;
                Blacksmith.CurveValue v = rim.curve().value().orElseThrow();
                vCheck(v instanceof Blacksmith.Circle, "a cylinder rim's value is " + v);
                Blacksmith.Circle c = (Blacksmith.Circle) v;
                double z = c.frame().origin()[2];
                vCheck(approx(c.radius(), 5) && (Math.abs(z) <= 1e-12 || approx(z, 3)), "a cylinder rim reads " + c);
            }
            vCheck(rims > 0, "the cylinder has no circle edges");
        }
        try (Blacksmith.Solid box = Blacksmith.Solid.cuboid(2, 4, 6)) {
            for (Blacksmith.Edge e : box.edges()) {
                Blacksmith.CurveValue v = e.curve().value().orElseThrow();
                vCheck(v instanceof Blacksmith.Line, "a box edge's value is " + v);
                Blacksmith.Line l = (Blacksmith.Line) v;
                Set<String> segEnds = new HashSet<>();
                for (Blacksmith.Edge.Segment seg : e.segments()) segEnds.addAll(rounded9(seg.a(), seg.b()));
                vCheck(segEnds.containsAll(rounded9(l.start(), l.end())), "a box edge's line " + l + " ends off its segments");
            }
        }
        try (Blacksmith.Solid cube = Blacksmith.Solid.cuboid(10, 10, 10)) {
            List<Blacksmith.Edge> upright = cube.edges().stream()
                .filter(e -> e.direction() != null && Math.abs(Math.abs(e.direction()[2]) - 1) < 1e-9).toList();
            try (Blacksmith.Solid rounded = cube.fillet(upright.subList(0, 1), 2.0)) {
                List<Blacksmith.Edge> arcs = rounded.edges().stream().filter(e -> e.kind().equals("circle")).toList();
                vCheck(arcs.size() == 2, "the filleted cube has " + arcs.size() + " circle edges");
                for (Blacksmith.Edge e : arcs) {
                    Blacksmith.CurveValue v = e.curve().value().orElseThrow();
                    vCheck(v instanceof Blacksmith.Arc, "a fillet edge's value is " + v);
                    Blacksmith.Arc arc = (Blacksmith.Arc) v;
                    vCheck(approx(arc.radius(), 2) && approx(arc.angle().length(), Math.PI / 2), "a fillet arc reads " + arc);
                    Blacksmith.Edge.Segment[] segs = e.segments();
                    double[][] vertices = {segs[0].a(), segs[segs.length - 1].b()};
                    boolean startOn = false, endOn = false;
                    for (double[] p : vertices) {
                        startOn |= dist3(arc.start(), p) < 1e-9;
                        endOn |= dist3(arc.end(), p) < 1e-9;
                    }
                    vCheck(startOn && endOn, "a fillet arc's ends are off the edge's vertices: " + arc);
                }
            }
        }
        try (Blacksmith.Profile spline = Blacksmith.Profile.spline(new double[][] {{0, 0}, {10, 0}, {10, 10}, {0, 10}}, 3, null, true);
             Blacksmith.Solid body = Blacksmith.Solid.extrude(spline, Blacksmith.Frame.xy().toArray(), 2)) {
            int nurbs = 0;
            for (Blacksmith.Edge e : body.edges()) {
                if (!e.kind().equals("nurbs")) continue;
                nurbs++;
                vCheck(e.curve().value().isEmpty(), "a spline edge has a value");
            }
            vCheck(nurbs > 0, "the spline body has no nurbs edges");
        }
    }

    private static void surfaceValues(Map<String, String[]> r) {
        vRefused("a decreasing height", () -> new Blacksmith.Cylinder(XY, 1, iv(2, 1)), "value_check: the height must increase");
        vRefused("a fat torus", () -> new Blacksmith.Torus(XY, 1, 1), "value_check: the minor radius must be less than the major");
        vRefused("a flat cone", () -> new Blacksmith.Cone(XY, 1, 0), "value_check: the height must be positive");
        vRefused("a NaN sphere", () -> new Blacksmith.Sphere(XY, Double.NaN), "value_check: not finite");

        Blacksmith.Sphere sphere = new Blacksmith.Sphere(XY, 2);
        vClose("sphere point", sphere.pointAt(0, Math.PI / 2), new double[] {0, 0, 2}, 1e-15);
        Blacksmith.Cylinder cyl = new Blacksmith.Cylinder(XY, 1, iv(-1, 2));
        vCheck(cyl.height().equals(iv(-1, 2)), "cylinder height");
        vClose("cylinder normal", cyl.normalAt(Math.PI / 2, 0), new double[] {0, 1, 0}, 1e-15);
        vClose("torus point", new Blacksmith.Torus(XY, 3, 1).pointAt(0, 0), new double[] {4, 0, 0}, 1e-15);
        Blacksmith.SurfaceFoot foot = sphere.closestPoint(new double[] {0, 0, 5});
        vCheck(foot.unique(), "the sphere's foot from (0, 0, 5) is not unique");
        vClose("sphere foot", cat3(new double[] {foot.u(), foot.v()}, foot.point()), new double[] {0, Math.PI / 2, 0, 0, 2}, 1e-15);
        vCheck(!sphere.closestPoint(new double[] {0, 0, 0}).unique(), "the centre is a pick");
        vCheck(approx(sphere.distanceTo(new double[] {0, 0, 5}), 3), "sphere distanceTo");
        vCheck(cyl.domain().equals(new Blacksmith.SurfaceValue.Domain(iv(0, 2 * Math.PI), iv(-1, 2))), "cylinder domain " + cyl.domain());
        vCheck(new Blacksmith.Cone(XY, 1, 2).domain().equals(new Blacksmith.SurfaceValue.Domain(iv(0, 2 * Math.PI), iv(0, 2))), "cone domain");
        vCheck(Math.abs(sphere.volume() - 32 * Math.PI / 3) < 1e-13 && Math.abs(sphere.area() - 16 * Math.PI) < 1e-13, "sphere volume and area");
        vCheck(new Blacksmith.Torus(XY, 3, 1).contains(new double[] {3, 0, 0.5}) && !sphere.contains(new double[] {0, 0, 2.5}), "contains");
        vCheck(sphere.contains(new double[] {0, 0, 2.5}, 0.5), "contains within a tolerance");
        vRefused("a negative tolerance", () -> sphere.contains(new double[3], -1), "solid_value_contains: the tolerance must be finite and not negative");
        Blacksmith.Bounds sb = sphere.bounds();
        vCheck(same(sb.min(), -2, -2, -2) && same(sb.max(), 2, 2, 2), "sphere bounds");
        vRefused("a stretched sphere", () -> sphere.transform(Blacksmith.Transform.scaleXyz(Blacksmith.Frame.xy(), 1, 3, 1)),
            "value_transform: a sphere takes only a similarity");
        vCheck(sphere.transform(Blacksmith.Transform.translation(new double[] {1, 0, 0}))
            .equals(new Blacksmith.Sphere(Blacksmith.Frame.xy(new double[] {1, 0, 0}), 2)), "a moved sphere");
        try (Blacksmith.Solid sheet = cyl.toNurbsSheet()) {
            vCheck(sheet.faces() == 1, "the cylinder's sheet has " + sheet.faces() + " faces");
        }

        // each shape becomes a solid of its volume
        Object[][] shapes = {
            {new Blacksmith.Sphere(XY, 2), 32 * Math.PI / 3}, {new Blacksmith.Cylinder(XY, 1, iv(-1, 2)), 3 * Math.PI},
            {new Blacksmith.Cone(XY, 1, 2), 2 * Math.PI / 3}, {new Blacksmith.Torus(XY, 3, 1), 6 * Math.PI * Math.PI},
            {new Blacksmith.Cuboid(YZX, iv(0, 1), iv(0, 2), iv(0, 3)), 6.0}};
        for (Object[] row : shapes) {
            Blacksmith.SolidValue shape = (Blacksmith.SolidValue) row[0];
            double volume = (Double) row[1];
            try (Blacksmith.Solid solid = shape.toSolid()) {
                double got = solid.mass(1e-9).volume();
                vCheck(Math.abs(got - volume) <= 1e-6 * volume, shape + " becomes a solid of volume " + got);
            }
            vCheck(Math.abs(shape.volume() - volume) <= 1e-12 * volume, shape + " has volume " + shape.volume());
        }

        // spheres, tori, cylinders and cones match Rhino
        Blacksmith.Sphere rs = new Blacksmith.Sphere(nums(r, "sphere", "frame"), nums(r, "sphere", "radius")[0]);
        for (int i = 0; i < 12; i++) {
            String c = "sphere_" + q2(i);
            double[] want = nums(r, c, "closest");
            Blacksmith.SurfaceFoot f = rs.closestPoint(nums(r, c, "query"));
            vClose(c + " uv", new double[] {f.u(), f.v()}, new double[] {pyMod(want[0], 2 * Math.PI), want[1]}, EXACT);
            vClose(c, f.point(), Arrays.copyOfRange(want, 2, want.length), EXACT);
        }
        double[] radii = nums(r, "torus", "radii");
        Blacksmith.Torus rt = new Blacksmith.Torus(nums(r, "torus", "frame"), radii[0], radii[1]);
        for (int i = 0; i < 12; i++) {
            String c = "torus_" + q2(i);
            double[] q = nums(r, c, "query");
            Blacksmith.SurfaceFoot f = rt.closestPoint(q);
            vCheck(f.unique(), c + " is not unique");
            nurbsFoot(c, q, f.point(), nums(r, c, "closest"));
        }
        Blacksmith.Cylinder rcyl = new Blacksmith.Cylinder(nums(r, "cylinder", "frame"), nums(r, "cylinder", "radius")[0],
            Blacksmith.Interval.of(nums(r, "cylinder", "height")));
        for (int i = 0; i < 12; i++) {
            String c = "cylinder_" + q2(i);
            double[] q = nums(r, c, "query");
            nurbsFoot(c, q, rcyl.closestPoint(q).point(), nums(r, c, "closest"));
        }
        double[] size = nums(r, "cone", "size");
        Blacksmith.Cone rcone = new Blacksmith.Cone(nums(r, "cone", "frame"), size[0], size[1]);
        for (int i = 0; i < 12; i++) {
            String c = "cone_" + q2(i);
            double[] q = nums(r, c, "query");
            nurbsFoot(c, q, rcone.closestPoint(q).point(), nums(r, c, "closest"));
        }
    }

    private static void cuboidValues(Map<String, String[]> r) {
        Blacksmith.Cuboid box = new Blacksmith.Cuboid(YZX, iv(0, 1), iv(0, 2), iv(0, 3));
        vCheck(box.x().equals(iv(0, 1)) && box.y().equals(iv(0, 2)) && box.z().equals(iv(0, 3)), "the box's ranges");
        // x along world y (0..1), y along world z (0..2), z along world x (0..3), from (1, 2, 3)
        Blacksmith.Bounds bb = box.bounds();
        vCheck(same(bb.min(), 1, 2, 3) && same(bb.max(), 4, 3, 5), "the box's bounds");
        vCheck(Blacksmith.Cuboid.fromBounds(new double[] {0, 0, 0}, new double[] {1, 2, 3})
            .equals(new Blacksmith.Cuboid(XY, iv(0, 1), iv(0, 2), iv(0, 3))), "fromBounds");
        vRefused("flat bounds", () -> Blacksmith.Cuboid.fromBounds(new double[] {0, 0, 0}, new double[] {1, 0, 3}),
            "cuboid_from_bounds: the bounds must increase along every axis");
        vRefused("an empty y range", () -> new Blacksmith.Cuboid(XY, iv(0, 1), iv(2, 2), iv(0, 1)), "value_check: the y range must increase");
        double[][] pts = {{0, 0, 0}, {1, 2, 3}, {0.5, -1, 0.25}};
        vCheck(Blacksmith.Cuboid.around(Blacksmith.Frame.xy(), pts).equals(new Blacksmith.Cuboid(XY, iv(0, 1), iv(-1, 2), iv(0, 3))), "around");
        vRefused("flat points", () -> Blacksmith.Cuboid.around(XY, new double[][] {{0, 0, 0}, {1, 1, 0}}),
            "cuboid_around: the points are flat along an axis of the frame");
        vRefused("no points", () -> Blacksmith.Cuboid.around(XY, new double[0][]), "cuboid_around: no points");
        vRefused("a two-number box point", () -> Blacksmith.Cuboid.around(XY, new double[][] {{0, 0}}), "cuboid_around: a point is 3 numbers, got 2");

        Blacksmith.Cuboid unit = new Blacksmith.Cuboid(XY, iv(0, 1), iv(0, 2), iv(0, 3));
        vCheck(unit.area() == 22.0 && unit.volume() == 6.0, "the box's area and volume");
        vCheck(unit.contains(new double[] {0.5, 0.5, 0.5}) && !unit.contains(new double[] {1.5, 0.5, 0.5}, 0.4)
            && unit.contains(new double[] {1.5, 0.5, 0.5}, 0.5), "the box contains");
        vCheck(same(box.closestPoint(new double[] {9, 9, 9}), 4, 3, 5), "the tilted box's closest point");
        vClose("the tilted box's middle", box.pointAt(0.5, 0.5, 0.5), new double[] {2.5, 2.5, 4}, 1e-15);
        double[][] corners = unit.corners();
        vCheck(corners.length == 8 && same(corners[0], 0, 0, 0) && same(corners[2], 1, 2, 0) && same(corners[6], 1, 2, 3),
            "the box's corners " + Arrays.deepToString(corners));
        Blacksmith.Cuboid moved = unit.transform(Blacksmith.Transform.translation(new double[] {0, 0, 1}));
        Blacksmith.Bounds mb = moved.bounds();
        vCheck(same(mb.min(), 0, 0, 1) && same(mb.max(), 1, 2, 4), "the moved box");

        // boxes match Rhino
        double[] ranges = nums(r, "box", "ranges");
        Blacksmith.Cuboid rb = new Blacksmith.Cuboid(nums(r, "box", "frame"), iv(ranges[0], ranges[1]), iv(ranges[2], ranges[3]), iv(ranges[4], ranges[5]));
        double[] rcorners = nums(r, "box", "corners");
        double[][] got = rb.corners();
        for (int k = 0; k < 8; k++) vClose("corner " + k, got[k], Arrays.copyOfRange(rcorners, 3 * k, 3 * k + 3), EXACT);
        for (int k = 0; k < 4; k++) {
            double[] n = nums(r, "box_at_" + k, "point");
            vClose("box_at_" + k, rb.pointAt(n[0], n[1], n[2]), Arrays.copyOfRange(n, 3, 6), EXACT);
        }
        for (int i = 0; i < 12; i++) {
            String c = "box_" + q2(i);
            vClose(c, rb.closestPoint(nums(r, c, "query")), nums(r, c, "closest"), EXACT);
        }
    }

    // Transforms (plan A4): Python's test_a_transform_is_sixteen_numbers... through
    // test_a_profile_turns_scales_mirrors_and_maps, figure for figure. Java has no operators:
    // `a.compose(b)` is Python's `a @ b`, `p.multiply(q)` its `p * q`.
    private static void transforms() {
        transformRowsAndComposition();
        transformConstructors();
        transformsToldAndSplit();
        quaternions();
        quaternionsFarFromUnit();
        solidTransform();
        mappedSolidKeepsColoursAndName();
        nurbsLevels();
        profileTransforms();
        System.out.println("transforms: ok");
    }

    private static void tfNear(String what, double[] got, double tol, double... want) {
        boolean ok = got != null && got.length == want.length;
        for (int i = 0; ok && i < want.length; i++) ok = Math.abs(got[i] - want[i]) <= tol;
        if (!ok) fail("transforms: " + what + " is " + Arrays.toString(got) + ", not " + Arrays.toString(want));
    }

    private static void tfRefused(String what, Runnable call, String prefix) {
        String said = refused(call);
        if (!said.startsWith(prefix)) fail("transforms: " + what + " said '" + said + "', not '" + prefix + "...'");
    }

    private static double[] p3(double x, double y, double z) {
        return new double[] {x, y, z};
    }

    private static double det3(Blacksmith.Transform t) {
        double[] r = t.rows();
        return r[0] * (r[5] * r[10] - r[6] * r[9]) - r[1] * (r[4] * r[10] - r[6] * r[8])
                + r[2] * (r[4] * r[9] - r[5] * r[8]);
    }

    // 1. Rows and composition.
    private static void transformRowsAndComposition() {
        Blacksmith.Transform t = Blacksmith.Transform.translation(p3(1, 2, 3));
        if (!Arrays.equals(t.rows(), new double[] {1, 0, 0, 1, 0, 1, 0, 2, 0, 0, 1, 3, 0, 0, 0, 1}))
            fail("transforms: translation rows " + Arrays.toString(t.rows()));
        Blacksmith.Transform s = Blacksmith.Transform.scale(p3(0, 0, 0), 2);
        tfNear("(t . s)(1,1,1)", t.compose(s).point(p3(1, 1, 1)), 1e-12, 3, 4, 5);
        tfNear("(s . t)(1,1,1)", s.compose(t).point(p3(1, 1, 1)), 1e-12, 4, 6, 8);
        tfNear("inverse . map", t.compose(s).inverse().compose(t.compose(s)).point(p3(3, -4, 5)), 1e-12, 3, -4, 5);
        if (!Blacksmith.Transform.fromRows(t.rows()).equals(t)) fail("transforms: fromRows(t.rows()) != t");
        if (!new Blacksmith.Transform().equals(Blacksmith.Transform.identity())) fail("transforms: Transform() != identity()");
        double[] r = t.rows();
        if (!new Blacksmith.Transform(new double[][] {Arrays.copyOfRange(r, 0, 4), Arrays.copyOfRange(r, 4, 8),
                Arrays.copyOfRange(r, 8, 12), Arrays.copyOfRange(r, 12, 16)}).equals(t))
            fail("transforms: four rows of four != t");
        tfRefused("a bad bottom row", () -> new Blacksmith.Transform(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1),
                "Transform: the bottom row must be 0 0 0 1");
        tfRefused("15 numbers", () -> new Blacksmith.Transform(new double[15]), "Transform: a matrix is 16 numbers, got 15");
        tfRefused("a NaN", () -> new Blacksmith.Transform(Double.NaN, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1), "Transform: not finite");
        tfRefused("a singular inverse", () -> Blacksmith.Transform.scaleXyz(Blacksmith.Frame.xy(), 1, 1, 0).inverse(),
                "transform_inverse: the map is singular");
    }

    // 2. Constructors against their closed forms.
    private static void transformConstructors() {
        Blacksmith.Frame xy = Blacksmith.Frame.xy();
        tfNear("rotation", Blacksmith.Transform.rotation(p3(1, 0, 0), p3(0, 0, 1), Math.PI / 2).point(p3(2, 0, 0)), 1e-12, 1, 1, 0);
        tfNear("mirror", Blacksmith.Transform.mirror(Blacksmith.Frame.xy(p3(0, 0, 5))).point(p3(1, 2, 3)), 1e-12, 1, 2, 7);
        tfNear("scaleXyz", Blacksmith.Transform.scaleXyz(xy, 2, 3, 4).point(p3(1, 1, 1)), 1e-12, 2, 3, 4);
        tfNear("scale", Blacksmith.Transform.scale(p3(1, 2, 3), 2).point(p3(2, 2, 3)), 1e-12, 3, 2, 3);
        tfNear("scale's centre", Blacksmith.Transform.scale(p3(1, 2, 3), 2).point(p3(1, 2, 3)), 1e-12, 1, 2, 3);
        tfNear("shear", Blacksmith.Transform.shear(xy, p3(5, 0, 0), 0.5).point(p3(0, 0, 2)), 1e-12, 1, 0, 2);
        tfNear("planarProjection", Blacksmith.Transform.planarProjection(xy).point(p3(1, 2, 3)), 1e-12, 1, 2, 0);
        tfNear("projectAlong", Blacksmith.Transform.projectAlong(xy, p3(1, 0, 1)).point(p3(0, 0, 2)), 1e-12, -2, 0, 0);
        Blacksmith.Frame b = Blacksmith.Frame.xy(p3(1, 2, 3));
        tfNear("planeToPlane", Blacksmith.Transform.planeToPlane(xy, b).point(p3(0, 0, 0)), 1e-12, 1, 2, 3);
        tfNear("changeBasis", Blacksmith.Transform.changeBasis(b, xy).point(p3(0, 0, 0)), 1e-12, 1, 2, 3);
        tfRefused("a shear off the plane", () -> Blacksmith.Transform.shear(xy, p3(0, 0, 1), 0.5),
                "transform_shear: the shear direction must lie in the plane");
        // Raw twelve numbers: Frame's own constructor squares and refuses this one first.
        double[] skew = {0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1};
        tfRefused("a skew mirror", () -> Blacksmith.Transform.mirror(skew),
                "transform_mirror: the frame is not right-handed and orthonormal");
    }

    // 3. Told and split.
    private static void transformsToldAndSplit() {
        Blacksmith.Frame xy = Blacksmith.Frame.xy();
        Blacksmith.Transform turn = Blacksmith.Transform.rotation(p3(1, 2, 3), p3(1, 1, 0), 0.7);
        if (!turn.isRigid() || Math.abs(turn.isSimilarity().orElse(-1) - 1) > 1e-9) fail("transforms: a turn is not rigid");
        Blacksmith.Transform big = Blacksmith.Transform.scale(p3(0, 0, 0), 2.5).compose(turn);
        if (big.isRigid() || Math.abs(big.isSimilarity().orElse(-1) - 2.5) > 1e-9) fail("transforms: big is " + big.isSimilarity());
        Blacksmith.Transform.Similarity bs = big.decomposeSimilarity().orElseThrow();
        if (Math.abs(bs.k() - 2.5) > 1e-9 || !bs.orthogonal().isRigid()) fail("transforms: big's split k " + bs.k());
        Blacksmith.Transform.Similarity sc = Blacksmith.Transform.scale(p3(1, 2, 3), 2).decomposeSimilarity().orElseThrow();
        tfNear("scale's translation", sc.translation(), 1e-9, -1, -2, -3);
        if (Math.abs(sc.k() - 2) > 1e-9 || !sc.orthogonal().equals(new Blacksmith.Transform())) fail("transforms: scale's split " + sc.k() + " " + sc.orthogonal());
        Blacksmith.Transform.Rigid rr = turn.decomposeRigid().orElseThrow();
        double[] tr = turn.rows();
        tfNear("turn's translation", rr.translation(), 1e-9, tr[3], tr[7], tr[11]);
        if (!rr.orthogonal().isRigid()) fail("transforms: turn's orthogonal part is not rigid");
        Blacksmith.Transform stretch = Blacksmith.Transform.scaleXyz(xy, 1, 2, 3);
        if (stretch.isSimilarity().isPresent() || stretch.decomposeRigid().isPresent() || stretch.decomposeSimilarity().isPresent())
            fail("transforms: a stretch reads as a similarity");
        Blacksmith.Transform.Affine af = Blacksmith.Transform.mirror(xy).compose(stretch).decomposeAffine().orElseThrow();
        tfNear("stretch", af.stretch(), 1e-9, 3, 2, 1);
        if (!af.axes().isRigid() || !af.rotation().isRigid()) fail("transforms: the affine split's parts are not rigid");
        if (Math.abs(det3(af.rotation()) + 1) > 1e-9 || Math.abs(det3(af.axes()) - 1) > 1e-9)
            fail("transforms: det(rotation) " + det3(af.rotation()) + ", det(axes) " + det3(af.axes()));
        if (Blacksmith.Transform.planarProjection(xy).decomposeAffine().isPresent()) fail("transforms: a projection has an affine split");
        tfRefused("isRigid(-1)", () -> turn.isRigid(-1), "transform_is_rigid: the tolerance must be finite and not negative");
        tfRefused("isSimilarity(-1)", () -> turn.isSimilarity(-1), "transform_is_similarity: ");
    }

    // 4. Quaternions.
    private static void quaternions() {
        Blacksmith.Quaternion q = Blacksmith.Quaternion.fromAxisAngle(p3(0, 0, 2), Math.PI / 2);
        tfNear("q", q.toArray(), 1e-12, Math.cos(Math.PI / 4), 0, 0, Math.sin(Math.PI / 4));
        if (Math.abs(q.angle() - Math.PI / 2) > 1e-12) fail("transforms: q's angle " + q.angle());
        tfNear("q's axis", q.axis().orElseThrow(), 1e-12, 0, 0, 1);
        tfNear("q about (1,0,0)", q.toTransform(p3(1, 0, 0)).point(p3(2, 0, 0)), 1e-12, 1, 1, 0);
        tfNear("2q", new Blacksmith.Quaternion(2 * q.w(), 2 * q.x(), 2 * q.y(), 2 * q.z()).toTransform().point(p3(1, 0, 0)), 1e-12, 0, 1, 0);
        tfNear("fromTransform", Blacksmith.Quaternion.fromTransform(q.toTransform()).toArray(), 1e-12, q.toArray());
        double slerped = Blacksmith.Quaternion.slerp(new Blacksmith.Quaternion(), q, 0.25).angle();
        if (Math.abs(slerped - Math.PI / 8) > 1e-12) fail("transforms: slerp's angle " + slerped);
        tfNear("q q*", q.multiply(q.conjugate()).toArray(), 1e-12, 1, 0, 0, 0);
        if (!new Blacksmith.Quaternion(0, 0, 0, 2).normalized().equals(new Blacksmith.Quaternion(0, 0, 0, 1)))
            fail("transforms: (0,0,0,2).normalized()");
        tfRefused("a zero quaternion's transform", () -> new Blacksmith.Quaternion(0, 0, 0, 0).toTransform(),
                "quaternion_to_transform: the quaternion is zero");
        tfRefused("a mirror's quaternion", () -> Blacksmith.Quaternion.fromTransform(Blacksmith.Transform.mirror(Blacksmith.Frame.xy())),
                "quaternion_from_transform: ");
        Blacksmith.Quaternion qx = Blacksmith.Quaternion.fromAxisAngle(p3(1, 0, 0), Math.PI / 2);
        Blacksmith.Quaternion qy = Blacksmith.Quaternion.fromAxisAngle(p3(0, 1, 0), Math.PI / 2);
        tfNear("qx qy", qx.multiply(qy).toArray(), 1e-12, 0.5, 0.5, 0.5, 0.5);
        // Every component non-zero, so each of the sixteen terms' signs shows (the figures above
        // multiply some terms by zero): the Hamilton product (1,2,3,4)(5,6,7,8).
        tfNear("(1,2,3,4)(5,6,7,8)", new Blacksmith.Quaternion(1, 2, 3, 4).multiply(new Blacksmith.Quaternion(5, 6, 7, 8)).toArray(), 0, -60, 12, 30, 24);
        tfRefused("Quaternion(NaN)", () -> new Blacksmith.Quaternion(Double.NaN, 0, 0, 0), "Quaternion: not finite");
    }

    // 5. Far from unit length.
    private static void quaternionsFarFromUnit() {
        double h = Math.sqrt(0.5);
        for (double k : new double[] {1e200, 1e-170}) {
            if (!new Blacksmith.Quaternion(k, 0, 0, 0).normalized().equals(new Blacksmith.Quaternion(1, 0, 0, 0)))
                fail("transforms: (" + k + ",0,0,0).normalized()");
            if (!new Blacksmith.Quaternion(0, 0, 0, -k).normalized().equals(new Blacksmith.Quaternion(0, 0, 0, -1)))
                fail("transforms: (0,0,0,-" + k + ").normalized()");
            Blacksmith.Quaternion kk = new Blacksmith.Quaternion(k, k, 0, 0);
            tfNear("(k,k,0,0).normalized()", kk.normalized().toArray(), 1e-12, h, h, 0, 0);
            if (!(Math.abs(kk.length() - k * Math.sqrt(2)) <= 1e-15 * k * Math.sqrt(2))) fail("transforms: (k,k,0,0).length " + kk.length());
            if (Math.abs(kk.angle() - Math.PI / 2) > 1e-12) fail("transforms: (k,k,0,0).angle " + kk.angle());
            tfNear("(0,k,k,0).axis", new Blacksmith.Quaternion(0, k, k, 0).axis().orElseThrow(), 1e-12, h, h, 0);
        }
        tfRefused("a zero quaternion normalized", () -> new Blacksmith.Quaternion(0, 0, 0, 0).normalized(),
                "Quaternion.normalized: the quaternion is zero");
    }

    // 6. A solid takes any affine map.
    private static void solidTransform() {
        Blacksmith.Frame xy = Blacksmith.Frame.xy();
        try (Blacksmith.Solid box = Blacksmith.Solid.cuboid(1, 2, 3);
             Blacksmith.Solid stretched = box.transform(Blacksmith.Transform.scaleXyz(xy, 2, 3, 0.5));
             Blacksmith.Solid moved = box.transform(Blacksmith.Transform.translation(p3(1, 0, 0)).rows());
             Blacksmith.Solid can = Blacksmith.Solid.cylinder(1, 2);
             Blacksmith.Solid sheared = can.transform(Blacksmith.Transform.shear(xy, p3(1, 0, 0), 0.5))) {
            if (box.inexactTrims() != 0) fail("transforms: a built box has inexactTrims " + box.inexactTrims());
            Blacksmith.Bounds b = stretched.boundsAt(0.05);
            tfNear("stretched extents", new double[] {b.max()[0] - b.min()[0], b.max()[1] - b.min()[1], b.max()[2] - b.min()[2]}, 1e-9, 2, 6, 1.5);
            if (stretched.inexactTrims() != 0 || moved.inexactTrims() != 0) fail("transforms: a mapped box lost trims");
            Blacksmith.Bounds mb = moved.boundsAt(0.05);
            tfNear("moved min", mb.min(), 1e-9, 0.5, -1, -1.5);
            double v = sheared.mass(1e-7).volume();
            if (!relClose(v, 2 * Math.PI, 1e-6)) fail("transforms: sheared volume " + v);
            boolean nurbs = false;
            for (int i = 0; i < sheared.faces(); i++) nurbs |= sheared.faceKind(i).equals("nurbs");
            if (!nurbs) fail("transforms: a sheared cylinder has no nurbs face");
            tfRefused("a singular solid map", () -> box.transform(Blacksmith.Transform.scaleXyz(xy, 1, 1, 0)),
                    "solid_transform: a singular map flattens the solid");
        }
    }

    // 7. Colours and name kept.
    private static void mappedSolidKeepsColoursAndName() {
        try (Blacksmith.Solid c0 = Blacksmith.Solid.cylinder(1, 2);
             Blacksmith.Solid c1 = c0.coloured("#808080");
             Blacksmith.Solid c2 = c1.named("can")) {
            int side = -1;
            for (int i = 0; i < c2.faces(); i++) if (side < 0 && c2.faceKind(i).equals("cylinder")) side = i;
            if (side < 0) fail("transforms: a cylinder has no cylinder face");
            int sideFace = side;
            try (Blacksmith.Solid can = c2.coloured(sideFace, 0.2, 0.4, 1.0);
                 Blacksmith.Solid sheared = can.transform(Blacksmith.Transform.shear(Blacksmith.Frame.xy(), p3(1, 0, 0), 0.5));
                 Blacksmith.Solid converted = can.convertToNurbs()) {
                for (Blacksmith.Solid out : List.of(sheared, converted)) {
                    if (out.faces() != can.faces()) fail("transforms: a mapped can has " + out.faces() + " faces, not " + can.faces());
                    if (!Arrays.equals(out.faceColour(sideFace), new double[] {0.2, 0.4, 1.0}))
                        fail("transforms: the side's colour " + Arrays.toString(out.faceColour(sideFace)));
                    for (int i = 0; i < out.faces(); i++) {
                        if (i != sideFace && !Arrays.equals(out.faceColour(i), can.colour()))
                            fail("transforms: face " + i + "'s colour " + Arrays.toString(out.faceColour(i)));
                    }
                    if (!"can".equals(out.name())) fail("transforms: a mapped can is named '" + out.name() + "'");
                }
            }
        }
    }

    // 8. Levels.
    private static void nurbsLevels() {
        try (Blacksmith.Solid can = Blacksmith.Solid.cylinder(1, 2);
             Blacksmith.Solid every = can.convertToNurbs();
             Blacksmith.Solid analytic = can.convertToNurbs("analytic")) {
            Set<String> kinds = new HashSet<>();
            for (int i = 0; i < every.faces(); i++) kinds.add(every.faceKind(i));
            if (!kinds.equals(Set.of("nurbs")) || every.inexactTrims() != 0) fail("transforms: convertToNurbs() kinds " + kinds);
            Set<String> akinds = new HashSet<>();
            for (int i = 0; i < analytic.faces(); i++) akinds.add(analytic.faceKind(i));
            if (!akinds.containsAll(Set.of("plane", "nurbs"))) fail("transforms: convertToNurbs(analytic) kinds " + akinds);
            tfRefused("a bad level", () -> can.convertToNurbs("some"),
                    "convert_to_nurbs: level 'some' is not \"procedural\", \"analytic\" or \"all\"");
        }
    }

    // 9. Profiles. Java's Profile has no polylines call, so each outline is measured as the
    // bounds of the flat face it bounds on the XY frame: planar, so exact.
    private static double[] outlineBox(Blacksmith.Profile p) {
        try (Blacksmith.Solid face = Blacksmith.Solid.face(p, Blacksmith.Frame.xy().toArray())) {
            Blacksmith.Bounds b = face.boundsAt(0.01);
            return new double[] {b.max()[0] - b.min()[0], b.max()[1] - b.min()[1],
                    (b.max()[0] + b.min()[0]) / 2, (b.max()[1] + b.min()[1]) / 2};
        }
    }

    private static void profileTransforms() {
        try (Blacksmith.Profile rect = Blacksmith.Profile.rect(80, 40);
             Blacksmith.Profile turned = rect.rotate(new double[] {0, 0}, Math.PI / 2);
             Blacksmith.Profile scaled = rect.scale(new double[] {0, 0}, 0.5, 2);
             Blacksmith.Profile turnedOff = rect.rotate(new double[] {10, 20}, Math.PI / 2);
             Blacksmith.Profile scaledOff = rect.scale(new double[] {10, 0}, 0.5, 2);
             Blacksmith.Profile mirrored = rect.mirror(new double[] {100, 0}, new double[] {0, 1});
             Blacksmith.Profile slanted = rect.transform2d(new double[] {1, 0.5, 0, 0, 1, 0})) {
            double[] r = outlineBox(rect);
            double rx = r[2], ry = r[3];
            double[] t = outlineBox(turned), s = outlineBox(scaled);
            tfNear("rotate's spans", new double[] {t[0], t[1]}, 1e-3, 40, 80);
            tfNear("scale's spans", new double[] {s[0], s[1]}, 1e-3, 40, 80);
            double[] to = outlineBox(turnedOff), so = outlineBox(scaledOff);
            tfNear("rotate's centre", new double[] {to[2], to[3]}, 1e-3, 10 - (ry - 20), 20 + (rx - 10));
            tfNear("scale's centre", new double[] {so[2], so[3]}, 1e-3, 10 + 0.5 * (rx - 10), 2 * ry);
            tfNear("mirror's x-centre", new double[] {outlineBox(mirrored)[2]}, 1e-3, 200);
            tfNear("transform2d's x-span", new double[] {outlineBox(slanted)[0]}, 1e-3, 100);
            tfRefused("a singular 2D map", () -> rect.transform2d(new double[] {1, 2, 0, 2, 4, 0}),
                    "profile_transform2d: the 2D map is singular");
        }
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
    // Health and healing on the kernel (healing in the other wrappers, 2026-10-29): Python's
    // test_health_* / test_healed_* figures on a cuboid, its open rim, a thin plate and a tiny
    // body, and its two distinct-rows decoder tests on Blacksmith's own report types.
    private static void kernelHealth() {
        // 1. A closed cuboid: nothing free or small, cracks only on request, the figures that
        // scale with the extent.
        try (Blacksmith.Solid box = Blacksmith.Solid.cuboid(10, 10, 10)) {
            Blacksmith.HealthReport r = box.health();
            if (!r.freeEdges().isEmpty() || !r.wires().isEmpty() || !r.small().isEmpty() || r.cracks() != null)
                fail("health (kernel): the cuboid reads " + r);
            if (!relClose(r.extent(), 10 * Math.sqrt(3), 1e-12) || !relClose(r.rounding(), 1e-7 * r.extent(), 1e-12)
                    || !relClose(r.tolerance(), 1e-4 * r.extent(), 1e-12))
                fail("health (kernel): the cuboid's extent/rounding/tolerance read " + r.extent() + "/" + r.rounding() + "/" + r.tolerance());
            if (r.looseEdges() != 0 || r.worstLoose() != 0 || r.sewPairs() != 0 || r.sewRefused() != 0 || r.sewWorstGap() != 0)
                fail("health (kernel): the cuboid has loose or sew figures: " + r);
            Blacksmith.Cracks c = box.health(null, true).cracks();
            if (c == null || !c.watertight() || c.open() != 0 || c.folded() != 0 || c.crossings() != 0 || !c.edges().isEmpty())
                fail("health (kernel): the cuboid's meshed cracks read " + c);
            if (box.health(0.5, false).tolerance() != 0.5) fail("health (kernel): tolerance 0.5 was not used");
            if (box.health(-1.0, false).tolerance() != r.tolerance()) fail("health (kernel): tolerance -1 did not take the default");

            // 5. Healed: a new solid, nothing done, every edge exact.
            Blacksmith.Healed healedPair = box.healed();
            try (Blacksmith.Solid healed = healedPair.solid()) {
                Blacksmith.HealReport h = healedPair.report();
                if (healed == box || healed.handle().address() == box.handle().address()) fail("healed (kernel): not a new solid");
                if (!h.fixes().isEmpty() || !h.refused().isEmpty() || h.guarded()) fail("healed (kernel): the cuboid reads " + h);
                if (h.smallBefore() != 0 || h.smallAfter() != 0 || h.freeBefore() != 0 || h.freeAfter() != 0
                        || !h.closedBefore() || !h.closedAfter() || h.nonmanifoldBefore() != 0 || h.nonmanifoldAfter() != 0)
                    fail("healed (kernel): the cuboid's before/after read " + h);
                if (!relClose(h.tolerance(), r.tolerance(), 1e-12) || h.moved() != 0) fail("healed (kernel): tolerance/moved " + h);
                if (healed.faces() != 6 || !relClose(healed.mass(1e-6).volume(), 1000, 1e-6))
                    fail("healed (kernel): " + healed.faces() + " faces, not the cuboid's 6 and 1000");
                for (int e = 0; e < 12; e++) {
                    Double t = healed.edgeTolerance(e);
                    if (t == null || t != 0.0) fail("edgeTolerance (kernel): edge " + e + " reads " + t + ", not 0");
                }
                if (healed.edgeTolerance(0xFFFFFFF0) != null) fail("edgeTolerance (kernel): an id no trim names is not null");
            }
            Blacksmith.Healed wide = box.healed(0.5);
            try (Blacksmith.Solid ignored = wide.solid()) {
                if (wide.report().tolerance() != 0.5) fail("healed (kernel): tolerance 0.5 was not used");
            }
        }

        // 2. The cuboid without a face: one closed wire of four free edges round the hole.
        try (Blacksmith.Solid cube = Blacksmith.Solid.cuboid(10, 10, 10); Blacksmith.Solid hole = cube.dropFaces(new int[] {0})) {
            Blacksmith.HealthReport r = hole.health();
            if (r.freeEdges().size() != 4 || r.wires().size() != 1) fail("health (kernel): the rim reads " + r);
            Blacksmith.FreeWire wire = r.wires().get(0);
            if (wire.first() != 0 || wire.count() != 4 || !wire.closed() || !within(wire.length(), 40, 1e-9))
                fail("health (kernel): the rim's wire reads " + wire);
            if (!r.wireEdges(0).equals(r.freeEdges())) fail("health (kernel): wireEdges(0) is not the four rows");
            int[][] want = {{4, 3, 1, 2}, {16, 2, 4, 3}, {11, 1, 2, 0}, {15, 0, 3, 1}};
            for (int i = 0; i < 4; i++) {
                Blacksmith.FreeEdge e = r.freeEdges().get(i);
                if (e.trim() != want[i][0] || e.edge() == null || e.edge() != want[i][1] || e.face() != want[i][2]
                        || e.partner() == null || e.partner() != want[i][3])
                    fail("health (kernel): rim row " + i + " reads " + e);
                if (e.wire() != 0 || e.sharedEnds() != 0 || !within(e.length(), 10, 1e-9) || !within(e.gap(), 10, 1e-9))
                    fail("health (kernel): rim row " + i + " reads " + e);
                if (r.freeEdges().get(e.partner()).partner() != i) fail("health (kernel): rim row " + i + "'s partner is not mutual");
            }
            if (!within(r.worstGap(), 10, 1e-9)) fail("health (kernel): the rim's worst gap is " + r.worstGap());
            if (r.sewPairs() != 0 || r.sewRefused() != 0 || r.sewWorstGap() != 0 || r.looseEdges() != 0)
                fail("health (kernel): the rim has sew or loose figures: " + r);
            Blacksmith.Cracks c = hole.health(null, true).cracks();
            if (c == null || c.watertight() || c.open() != 0 || c.folded() != 0 || c.crossings() != 0 || !c.edges().isEmpty())
                fail("health (kernel): the rim's meshed cracks read " + c);
        }

        // 3. A thin plate at 0.01: its four thickness edges, then its four side faces.
        try (Blacksmith.Solid plate = Blacksmith.Solid.cuboid(10, 10, 0.001)) {
            List<Blacksmith.SmallFeature> small = plate.health(0.01, false).small();
            String got = small.stream().map(s -> s.kind() + " " + s.index()).toList().toString();
            if (!got.equals("[short_edge 8, short_edge 9, short_edge 10, short_edge 11, sliver_face 2, sliver_face 3, sliver_face 4, sliver_face 5]"))
                fail("health (kernel): the plate's small features read " + got);
            for (int i = 0; i < 4; i++) if (!relClose(small.get(i).size(), 0.001, 1e-6)) fail("health (kernel): plate " + small.get(i));
            for (int i = 4; i < 8; i++) if (!relClose(small.get(i).size(), 0.0009999, 1e-3)) fail("health (kernel): plate " + small.get(i));

            // 6. Every kind off: nothing healed, each refused as toggled; all on: nothing toggled.
            Blacksmith.Healed off = plate.healed(0.01, false, false, false);
            try (Blacksmith.Solid ignored = off.solid()) {
                Blacksmith.HealReport h = off.report();
                if (!h.fixes().isEmpty() || h.smallBefore() != 8 || h.smallAfter() != 8) fail("healed (kernel): all off reads " + h);
                String refused = h.refused().stream().map(x -> x.kind() + " " + x.index() + " " + x.why() + " " + x.figure()).toList().toString();
                if (!refused.equals("[short_edge 8 toggled 0.0, short_edge 9 toggled 0.0, short_edge 10 toggled 0.0, short_edge 11 toggled 0.0, "
                        + "sliver_face 2 toggled 0.0, sliver_face 3 toggled 0.0, sliver_face 4 toggled 0.0, sliver_face 5 toggled 0.0]"))
                    fail("healed (kernel): all off refused " + refused);
            }
            Blacksmith.Healed on = plate.healed(0.01);
            try (Blacksmith.Solid ignored = on.solid()) {
                Blacksmith.HealReport h = on.report();
                if (h.smallBefore() != 8) fail("healed (kernel): all on reads " + h);
                for (Blacksmith.HealRefusal x : h.refused()) {
                    if (x.why().equals("toggled")) fail("healed (kernel): all on refused " + x + " as toggled");
                    if (h.guarded() && !x.why().equals("body_guard")) fail("healed (kernel): guarded, but refused " + x);
                }
            }
        }
        // The flag bits each switch maps to: 1 edges, 2 faces, 4 holes.
        if (Blacksmith.healFlags(true, false, false) != 1 || Blacksmith.healFlags(false, true, false) != 2
                || Blacksmith.healFlags(false, false, true) != 4 || Blacksmith.healFlags(true, true, true) != 7)
            fail("healed (kernel): the switches are not the flag bits 1, 2, 4");

        // 4. A tiny body at 0.01: twelve short edges, six tiny faces, one tiny body.
        try (Blacksmith.Solid tiny = Blacksmith.Solid.cuboid(0.0005, 0.0005, 0.0005)) {
            List<Blacksmith.SmallFeature> small = tiny.health(0.01, false).small();
            List<Blacksmith.SmallFeature> faces = small.stream().filter(s -> s.kind().equals("tiny_face")).toList();
            List<Blacksmith.SmallFeature> bodies = small.stream().filter(s -> s.kind().equals("tiny_body")).toList();
            long edges = small.stream().filter(s -> s.kind().equals("short_edge")).count();
            if (edges != 12 || faces.size() != 6 || bodies.size() != 1 || small.size() != 19)
                fail("health (kernel): the tiny body's small features read " + small);
            for (int i = 0; i < 6; i++)
                if (faces.get(i).index() != i || !relClose(faces.get(i).size(), 2.5e-7, 1e-6)) fail("health (kernel): tiny " + faces.get(i));
            if (bodies.get(0).index() != 0 || !relClose(bodies.get(0).size(), 0.0005 * Math.sqrt(3), 1e-9))
                fail("health (kernel): tiny " + bodies.get(0));
        }

        // 7. A closed solid: each call throws with the solid's "closed" message.
        Blacksmith.Solid gone = Blacksmith.Solid.cuboid(1, 1, 1);
        gone.close();
        for (Runnable call : List.<Runnable>of(() -> gone.health(), () -> gone.healed(), () -> gone.edgeTolerance(0))) {
            String why = refused(call);
            if (!why.contains("closed")) fail("health (kernel): a closed solid's call gave " + why);
        }

        // The decoders, on Python's literal rows: every figure different, so a swapped column
        // cannot read back the same.
        int none = 0xFFFFFFFF;
        Blacksmith.HealthReport d = Blacksmith.HealthReport.of(
                new int[] {2, 1, 1, 2, 1, 0, 0, 1, 0, 3, 4, 5, 1, 0, 11, 12, 13, 2},
                new double[] {0.5, 0.25, 9.0, 7.5, 6.5, 5.5, 4.5, 3.5},
                new int[] {10, 20, 30, 40, 1, 2, 11, none, 31, 41, none, 0}, new double[] {1.5, 2.5, 3.5, Double.POSITIVE_INFINITY},
                new int[] {0, 2, 1}, new double[] {8.5, 2.5}, new int[] {1, 77, 4, 99}, new double[] {0.125, 0.0625}, new int[] {5, 6});
        if (d.tolerance() != 0.5 || d.rounding() != 0.25 || d.extent() != 9.0 || d.worstGap() != 7.5
                || d.looseEdges() != 3 || d.worstLoose() != 6.5 || d.sewPairs() != 4 || d.sewRefused() != 5 || d.sewWorstGap() != 5.5)
            fail("health decoder (kernel): the summary reads " + d);
        if (!d.freeEdges().equals(List.of(new Blacksmith.FreeEdge(10, 20, 30, 40, 1, 2, 1.5, 2.5),
                new Blacksmith.FreeEdge(11, null, 31, 41, null, 0, 3.5, Double.POSITIVE_INFINITY))))
            fail("health decoder (kernel): the free edges read " + d.freeEdges());
        if (!d.wires().equals(List.of(new Blacksmith.FreeWire(0, 2, true, 8.5, 2.5)))) fail("health decoder (kernel): the wires read " + d.wires());
        if (!d.small().equals(List.of(new Blacksmith.SmallFeature("collapsed_edge", 77, 0.125), new Blacksmith.SmallFeature("tiny_body", 99, 0.0625))))
            fail("health decoder (kernel): the small features read " + d.small());
        if (!new Blacksmith.Cracks(false, 11, 12, 13, List.of(5, 6)).equals(d.cracks())) fail("health decoder (kernel): the cracks read " + d.cracks());
        Blacksmith.HealReport hd = Blacksmith.HealReport.of(new int[] {2, 3, 1, 9, 8, 7, 6, 1, 0, 5, 4}, new double[] {0.5, 0.25},
                new int[] {5, 11, 0, 12}, new double[] {1.5, 0.125, 2.5, 0.0625},
                new int[] {3, 21, 9, 4, 22, 3, 2, 23, 10}, new double[] {0.0, 7.5, 0.0});
        if (hd.tolerance() != 0.5 || hd.moved() != 0.25 || !hd.guarded() || hd.smallBefore() != 9 || hd.smallAfter() != 8
                || hd.freeBefore() != 7 || hd.freeAfter() != 6 || !hd.closedBefore() || hd.closedAfter()
                || hd.nonmanifoldBefore() != 5 || hd.nonmanifoldAfter() != 4)
            fail("heal decoder (kernel): the summary reads " + hd);
        if (!hd.fixes().equals(List.of(new Blacksmith.HealFix("small_hole", 11, 1.5, 0.125), new Blacksmith.HealFix("short_edge", 12, 2.5, 0.0625))))
            fail("heal decoder (kernel): the fixes read " + hd.fixes());
        if (!hd.refused().equals(List.of(new Blacksmith.HealRefusal("tiny_face", 21, "toggled", 0.0),
                new Blacksmith.HealRefusal("tiny_body", 22, "chain", 7.5), new Blacksmith.HealRefusal("sliver_face", 23, "unsupported", 0.0))))
            fail("heal decoder (kernel): the refusals read " + hd.refused());
        System.out.println("health (kernel): cuboid, rim, plate, tiny body, healed, toggled, closed and both decoders ok");
    }

    // Health and healing on the reader: Python's test_brep_health_* / test_brep_healed_* on
    // st203-bapl.stp's body 1 (the 188-free-edge one; body 0 takes minutes), skipped when the
    // sample is not to hand (SAMPLE_DIR, else the working directory), and its two
    // distinct-rows decoder tests on Cad's own report types, which always run.
    private static void readerHealth() {
        int none = 0xFFFFFFFF;
        Cad.HealthReport d = Cad.HealthReport.of(
                new int[] {2, 1, 1, 2, 1, 0, 0, 1, 0, 3, 4, 5, 1, 0, 11, 12, 13, 2},
                new double[] {0.5, 0.25, 9.0, 7.5, 6.5, 5.5, 4.5, 3.5},
                new int[] {10, 20, 30, 40, 1, 2, 11, none, 31, 41, none, 0}, new double[] {1.5, 2.5, 3.5, Double.POSITIVE_INFINITY},
                new int[] {0, 2, 1}, new double[] {8.5, 2.5}, new int[] {1, 77, 4, 99}, new double[] {0.125, 0.0625}, new int[] {5, 6});
        if (d.tolerance() != 0.5 || d.rounding() != 0.25 || d.extent() != 9.0 || d.worstGap() != 7.5
                || d.looseEdges() != 3 || d.worstLoose() != 6.5 || d.sewPairs() != 4 || d.sewRefused() != 5 || d.sewWorstGap() != 5.5)
            fail("health decoder (reader): the summary reads " + d);
        if (!d.freeEdges().equals(List.of(new Cad.FreeEdge(10, 20, 30, 40, 1, 2, 1.5, 2.5),
                new Cad.FreeEdge(11, null, 31, 41, null, 0, 3.5, Double.POSITIVE_INFINITY))))
            fail("health decoder (reader): the free edges read " + d.freeEdges());
        if (!d.wires().equals(List.of(new Cad.FreeWire(0, 2, true, 8.5, 2.5)))) fail("health decoder (reader): the wires read " + d.wires());
        if (!d.small().equals(List.of(new Cad.SmallFeature("collapsed_edge", 77, 0.125), new Cad.SmallFeature("tiny_body", 99, 0.0625))))
            fail("health decoder (reader): the small features read " + d.small());
        if (!new Cad.Cracks(false, 11, 12, 13, List.of(5, 6)).equals(d.cracks())) fail("health decoder (reader): the cracks read " + d.cracks());
        Cad.HealReport hd = Cad.HealReport.of(new int[] {2, 3, 1, 9, 8, 7, 6, 1, 0, 5, 4}, new double[] {0.5, 0.25},
                new int[] {5, 11, 0, 12}, new double[] {1.5, 0.125, 2.5, 0.0625},
                new int[] {3, 21, 9, 4, 22, 3, 2, 23, 10}, new double[] {0.0, 7.5, 0.0});
        if (hd.tolerance() != 0.5 || hd.moved() != 0.25 || !hd.guarded() || hd.smallBefore() != 9 || hd.smallAfter() != 8
                || hd.freeBefore() != 7 || hd.freeAfter() != 6 || !hd.closedBefore() || hd.closedAfter()
                || hd.nonmanifoldBefore() != 5 || hd.nonmanifoldAfter() != 4)
            fail("heal decoder (reader): the summary reads " + hd);
        if (!hd.fixes().equals(List.of(new Cad.HealFix("small_hole", 11, 1.5, 0.125), new Cad.HealFix("short_edge", 12, 2.5, 0.0625))))
            fail("heal decoder (reader): the fixes read " + hd.fixes());
        if (!hd.refused().equals(List.of(new Cad.HealRefusal("tiny_face", 21, "toggled", 0.0),
                new Cad.HealRefusal("tiny_body", 22, "chain", 7.5), new Cad.HealRefusal("sliver_face", 23, "unsupported", 0.0))))
            fail("heal decoder (reader): the refusals read " + hd.refused());
        if (Cad.healFlags(true, false, false) != 1 || Cad.healFlags(false, true, false) != 2
                || Cad.healFlags(false, false, true) != 4 || Cad.healFlags(true, true, true) != 7)
            fail("healed (reader): the switches are not the flag bits 1, 2, 4");
        System.out.println("health (reader): both decoders ok");

        String dir = System.getenv("SAMPLE_DIR");
        Path st203 = Path.of(dir == null ? "." : dir, "st203-bapl.stp");
        if (!Files.exists(st203)) {
            System.out.println("health (reader): " + st203 + " not to hand, st203 checks SKIPPED");
            return;
        }
        try (Cad.Scene scene = Cad.open(st203.toString())) {
            List<Cad.Brep> breps = new java.util.ArrayList<>();
            for (Cad.Node n : scene.nodes()) {
                Cad.Brep b = n.brep();
                if (b != null) breps.add(b);
            }
            Cad.Brep body = breps.get(1);
            // 8. Health: 188 free edges in 45 wires, the first row read off the C rows.
            Cad.HealthReport r = body.health();
            if (r.freeEdges().size() != 188 || r.wires().size() != 45 || r.wires().stream().mapToInt(Cad.FreeWire::count).sum() != 188)
                fail("health (reader): st203 reads " + r.freeEdges().size() + " free edges in " + r.wires().size() + " wires");
            List<Cad.FreeEdge> first = r.wireEdges(0);
            if (!first.equals(r.freeEdges().subList(0, r.wires().get(0).count())) || first.stream().anyMatch(e -> e.wire() != 0))
                fail("health (reader): wireEdges(0) is not the first wire's rows");
            Cad.FreeEdge e0 = r.freeEdges().get(0);
            if (e0.trim() != 0 || e0.edge() == null || e0.edge() != 41363 || e0.face() != 0 || e0.wire() != 0
                    || e0.partner() == null || e0.partner() != 67 || e0.sharedEnds() != 0 || !relClose(e0.gap(), 95.01496054, 1e-6))
                fail("health (reader): st203's free edge 0 reads " + e0);
            for (Cad.FreeEdge e : r.freeEdges())
                if (e.partner() == null && e.gap() != Double.POSITIVE_INFINITY) fail("health (reader): " + e + " has no partner but a gap");
            if (!relClose(r.extent(), 253.66439715552204, 1e-12) || !relClose(r.rounding(), 1e-7 * r.extent(), 1e-12)
                    || !relClose(r.tolerance(), 1e-4 * r.extent(), 1e-12) || r.cracks() != null)
                fail("health (reader): st203's extent/rounding/tolerance/cracks read " + r.extent() + "/" + r.rounding() + "/" + r.tolerance() + "/" + r.cracks());
            if (body.health(Double.NaN, false).tolerance() != r.tolerance()) fail("health (reader): NaN did not take the default");
            if (r.looseEdges() != 0 || r.worstLoose() != 0) fail("health (reader): st203 has loose edges: " + r.looseEdges());
            Cad.Sewn sewn = body.sewed(null, null);
            sewn.brep().close();
            if (r.sewPairs() != sewn.report().pairs() || r.sewRefused() != 4 || sewn.report().refused() != 4
                    || !relClose(r.sewWorstGap(), sewn.report().worstGap(), 1e-12) || !(r.sewWorstGap() > 0))
                fail("health (reader): st203's sew figures " + r.sewPairs() + "/" + r.sewRefused() + "/" + r.sewWorstGap() + " against " + sewn.report());
            Cad.Cracks c = body.health(null, true).cracks();
            if (c == null || c.watertight() || c.open() != 0 || c.folded() != 0 || c.crossings() != 166 || !c.edges().isEmpty())
                fail("health (reader): st203's meshed cracks read " + c);
            List<Cad.SmallFeature> wideSmall = body.health(5.0, false).small();
            java.util.Set<String> kinds = new HashSet<>();
            for (Cad.SmallFeature s : wideSmall) kinds.add(s.kind());
            if (wideSmall.size() != 96 || !kinds.equals(Set.of("short_edge", "sliver_face", "tiny_face")))
                fail("health (reader): st203 at 5 reads " + wideSmall.size() + " small features of kinds " + kinds);
            Cad.SmallFeature edge = wideSmall.stream().filter(s -> s.kind().equals("short_edge")).findFirst().orElseThrow();
            if (edge.index() != 41550 || !relClose(edge.size(), 3.1622776616321775, 1e-9)) fail("health (reader): st203's first short edge reads " + edge);

            // 9. Healed: the default heals nothing; at 5, 28 fixes and eight uneven slivers left.
            Cad.Healed same = body.healed();
            try (Cad.Brep sameBrep = same.brep()) {
                Cad.HealReport h = same.report();
                if (sameBrep.pointer().address() == body.pointer().address() || h.smallBefore() != 0 || h.freeBefore() != 188
                        || h.freeAfter() > 188 || !relClose(h.tolerance(), 1e-4 * r.extent(), 1e-12))
                    fail("healed (reader): st203 at the default reads " + h);
            }
            Cad.Healed healedPair = body.healed(5.0);
            try (Cad.Brep healed = healedPair.brep()) {
                Cad.HealReport h = healedPair.report();
                if (h.tolerance() != 5.0 || h.smallBefore() != 96 || h.fixes().size() != 28 || h.smallAfter() != 8
                        || h.freeBefore() != 188 || h.freeAfter() != 88)
                    fail("healed (reader): st203 at 5 reads " + h.fixes().size() + " fixes, small " + h.smallBefore() + " -> " + h.smallAfter()
                            + ", free " + h.freeBefore() + " -> " + h.freeAfter());
                if (h.refused().size() != 8 || h.refused().stream().anyMatch(x -> !x.kind().equals("sliver_face") || !x.why().equals("uneven")))
                    fail("healed (reader): st203 at 5 refused " + h.refused());
                if (h.closedBefore() || h.closedAfter() || h.nonmanifoldBefore() != 0 || h.nonmanifoldAfter() != 0)
                    fail("healed (reader): st203 at 5's closed/non-manifold read " + h);
                if (h.smallAfter() != healed.health(5.0, false).small().size()) fail("healed (reader): small after is not the result's own");
                if (body.health(5.0, false).small().size() != 96) fail("healed (reader): the input was changed");
                if (!relClose(h.moved(), 1.581138831332503, 1e-9)
                        || !relClose(h.fixes().stream().mapToDouble(Cad.HealFix::moved).max().orElse(-1), 1.8248105306211464, 1e-9))
                    fail("healed (reader): st203 at 5 moved " + h.moved() + ", the largest fix " + h.fixes());
                Cad.HealFix fix = h.fixes().stream().filter(x -> x.kind().equals("short_edge")).findFirst().orElseThrow();
                if (fix.index() != 41550 || !relClose(fix.size(), 3.1622776616321775, 1e-9)) fail("healed (reader): st203's first short-edge fix " + fix);
                Double before = body.edgeTolerance(fix.index());
                Double kept = healed.edgeTolerance(41363);
                if (before == null || before != 0.0 || healed.edgeTolerance(fix.index()) != null || kept == null || kept != 0.0
                        || healed.edgeTolerance(0xFFFFFFF0) != null)
                    fail("edgeTolerance (reader): " + before + ", " + healed.edgeTolerance(fix.index()) + ", " + kept + ", " + healed.edgeTolerance(0xFFFFFFF0));
            }
            Cad.Healed off = body.healed(5.0, false, false, false);
            try (Cad.Brep ignored = off.brep()) {
                Cad.HealReport h = off.report();
                if (!h.fixes().isEmpty() || h.refused().size() != 96 || h.freeAfter() != h.freeBefore()
                        || h.refused().stream().anyMatch(x -> !x.why().equals("toggled") || x.figure() != 0.0))
                    fail("healed (reader): st203 with every kind off reads " + h.fixes().size() + " fixes, " + h.refused().size() + " refused");
                int[] per = new int[3];
                String[] which = {"short_edge", "sliver_face", "tiny_face"};
                for (Cad.HealRefusal x : h.refused()) for (int k = 0; k < 3; k++) if (x.kind().equals(which[k])) per[k]++;
                if (per[0] != 64 || per[1] != 26 || per[2] != 6) fail("healed (reader): st203 toggled per kind " + Arrays.toString(per));
            }
            for (Cad.Brep b : breps) b.close();
            for (Runnable call : List.<Runnable>of(() -> body.health(), () -> body.healed(), () -> body.edgeTolerance(0))) {
                String why;
                try {
                    call.run();
                    why = "(no exception)";
                } catch (Cad.CadaclysmException | IllegalStateException x) {
                    why = x.getMessage();
                }
                if (!why.contains("released")) fail("health (reader): a released brep's call gave " + why);
            }
            System.out.println("health (reader): st203-bapl.stp body 1: 188 free edges in 45 wires, healed at 5: 28 fixes, 188 -> 88 free");
        }
    }

    private static boolean relClose(double a, double b, double rel) {
        return Math.abs(a - b) <= rel * Math.abs(b);
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
