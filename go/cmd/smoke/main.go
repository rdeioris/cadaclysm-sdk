// Open one file through the Go binding and check what comes back. The exit code is
// the verdict: the release pipeline runs this against every library it ships.
package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/rdeioris/cadaclysm-sdk/go/cadaclysm"
)

func main() {
	path := "samples/cube.scad"
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	if len(os.Args) > 2 && !cadaclysm.LicenseSet(os.Args[2]) {
		fail("license: " + cadaclysm.LastError())
	}
	fmt.Printf("cadaclysm %s built %s\n", cadaclysm.Version(), cadaclysm.BuildDate())
	if info, ok := cadaclysm.LicenseInfo(); ok {
		fmt.Println("license:", info)
	} else {
		fmt.Println("license: none (" + cadaclysm.LastError() + ")")
	}
	scene, ok := cadaclysm.Open(path, "", cadaclysm.Native)
	if !ok {
		fail(path + ": " + cadaclysm.LastError())
	}
	defer scene.Close()
	min, max := scene.Bounds()
	fmt.Printf("bounds min=(%g,%g,%g) max=(%g,%g,%g)\n", min[0], min[1], min[2], max[0], max[1], max[2])
	var triangles int
	for part := uint32(0); part < scene.PartCount(); part++ {
		if !scene.CanMesh(part) {
			continue
		}
		_, _, _, idx := scene.Mesh(part)
		triangles += len(idx) / 3
	}
	fmt.Printf("triangles=%d\n", triangles)
	// All six bounds values, not just the three the brief's own draft checked: a bug that
	// only flips the Y axis (min/max swapped, or Y left at zero on both ends) still passes
	// min[0]/max[0]/max[2]/triangles alone, so every component of both corners is compared.
	if strings.HasSuffix(path, "cube.scad") &&
		(min != [3]float64{0, 0, 0} || max != [3]float64{20, 20, 20} || triangles != 12) {
		fail("the cube did not come back as a 20-unit cube of 12 triangles")
	}
}

func fail(why string) {
	fmt.Fprintln(os.Stderr, why)
	os.Exit(1)
}
