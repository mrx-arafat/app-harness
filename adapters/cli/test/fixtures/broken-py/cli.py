#!/usr/bin/env python3
"""broken-py - a deliberate syntax error so the gate build (py_compile) fails."""
import sys


def main(argv):
    # Invalid function signature: a bare ':' after the parameter list.
    def handler(:
        return 0
    return handler()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
