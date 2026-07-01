// Command goodgo is a tiny example CLI (standard library only).
package main

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"
)

const version = "goodgo 1.0.0"

const help = `goodgo - a tiny example CLI

Usage: goodgo [command] [options]

Commands:
  greet <name>   Print a greeting
  add <a> <b>    Print the sum of two integers
  quiet          Print nothing and exit 0
  sleep          Sleep briefly (for timeout testing)

Options:
  -h, --help     Show this help and exit
  --version      Print version and exit
`

func run(args []string) error {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		fmt.Print(help)
		return nil
	}
	switch args[0] {
	case "--version":
		fmt.Println(version)
		return nil
	case "greet":
		name := "world"
		if len(args) > 1 {
			name = args[1]
		}
		fmt.Printf("Hello, %s!\n", name)
		return nil
	case "add":
		if len(args) < 3 {
			return errors.New("add needs two integers")
		}
		a, err := strconv.Atoi(args[1])
		if err != nil {
			return err
		}
		b, err := strconv.Atoi(args[2])
		if err != nil {
			return err
		}
		fmt.Println(a + b)
		return nil
	case "quiet":
		return nil
	case "sleep":
		time.Sleep(5 * time.Second)
		fmt.Println("awake")
		return nil
	default:
		return fmt.Errorf("unknown command: %s", args[0])
	}
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
