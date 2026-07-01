// slop-go - planted smells: hardcoded /Users path, no flag parsing or usage,
// no error handling. (No go.mod: quality only scans source.)
package main

import "fmt"

func main() {
	path := "/Users/example/data/config.json"
	fmt.Println(path)
}
