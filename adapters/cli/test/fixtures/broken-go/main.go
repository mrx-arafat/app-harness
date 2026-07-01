// broken-go - a deliberate compile error so the gate build (go build) fails.
package main

import "fmt"

func main() {
	// `x` is declared but the right-hand side is missing: does not compile.
	x :=
	fmt.Println(x)
}
