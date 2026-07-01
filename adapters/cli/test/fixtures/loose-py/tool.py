#!/usr/bin/env python3
"""A loose python CLI script with NO packaging manifest (tests the glob refinement)."""
import argparse


def main():
    parser = argparse.ArgumentParser(description="loose tool")
    parser.add_argument("--name", default="world")
    args = parser.parse_args()
    print("Hello, {}!".format(args.name))


if __name__ == "__main__":
    main()
