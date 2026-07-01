#!/usr/bin/env python3
# Planted smells for the quality scanner:
#   1) hardcoded absolute /Users path
#   2) bare except clause (no exception type)
#   3) leftover debug print() of a bare variable
#   4) entry point parses no flags and offers no usage banner
CONFIG = "/Users/example/data/config.json"


def load():
    try:
        with open(CONFIG) as handle:
            return handle.read()
    except:
        return ""


def main():
    data = load()
    print(data)


main()
