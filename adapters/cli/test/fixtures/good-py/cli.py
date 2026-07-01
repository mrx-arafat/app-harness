#!/usr/bin/env python3
"""goodpy - a tiny example CLI with subcommands (standard library only)."""
import argparse
import sys
import time


def build_parser():
    parser = argparse.ArgumentParser(prog="goodpy", description="a tiny example CLI")
    parser.add_argument("--version", action="version", version="goodpy 1.0.0")
    sub = parser.add_subparsers(dest="command")
    greet = sub.add_parser("greet", help="print a greeting")
    greet.add_argument("name", nargs="?", default="world")
    add = sub.add_parser("add", help="print the sum of two integers")
    add.add_argument("a", type=int)
    add.add_argument("b", type=int)
    sub.add_parser("quiet", help="print nothing")
    sub.add_parser("sleep", help="sleep briefly")
    return parser


def run(ns):
    if ns.command == "greet":
        sys.stdout.write("Hello, {}!\n".format(ns.name))
        return 0
    if ns.command == "add":
        sys.stdout.write("{}\n".format(ns.a + ns.b))
        return 0
    if ns.command == "quiet":
        return 0
    if ns.command == "sleep":
        time.sleep(5)
        sys.stdout.write("awake\n")
        return 0
    sys.stderr.write("error: no command given (try --help)\n")
    return 1


def main(argv):
    parser = build_parser()
    ns = parser.parse_args(argv[1:])
    try:
        return run(ns)
    except Exception as exc:  # defensive: never leak a stack trace
        sys.stderr.write("error: {}\n".format(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
