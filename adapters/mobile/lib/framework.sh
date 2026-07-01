# shellcheck shell=bash
# framework.sh — adapter-owned mobile framework / package-manager detection.
#
# Single source of truth for the predicates that detect.sh, gate.sh, run.sh and
# verify.sh all need. Previously each of those four scripts carried its own
# near-verbatim copy of pkg_has_dep / appjson_has_expo / pubspec_is_flutter /
# ios_signal / detect_framework / detect_pm — ~150 lines of drift-prone duplication.
# They now all `source` this file and call the mob_* helpers.
#
# EVERY function takes an explicit <dir> argument (detect.sh scans two candidate
# dirs, so a $APPDIR-global design would not fit). Portable to bash 3.2 (macOS):
# no associative arrays, no `local -n`, no GNU-only flags. JSON parsing via node
# (always present in the harness env; no jq dependency).
#
# Framework confidence values are the frozen detect.sh contract (§10):
#   expo=90  react-native=88  flutter=90  ios=85  unknown=0

# Does <dir>/package.json declare <dep> in dependencies/devDependencies/peerDependencies?
mob_pkg_has_dep() {  # <dir> <dep>
  _mphd_dir="$1"; _mphd_dep="$2"
  [ -f "$_mphd_dir/package.json" ] || return 1
  node -e '
    var fs=require("fs");
    try{var p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      var d=Object.assign({},p.dependencies,p.devDependencies,p.peerDependencies);
      process.exit(d[process.argv[2]]?0:1);}catch(e){process.exit(1);}
  ' "$_mphd_dir/package.json" "$_mphd_dep" 2>/dev/null
}

# Does <dir>/app.json carry a top-level "expo" object?
mob_appjson_has_expo() {  # <dir>
  _mahe_dir="$1"
  [ -f "$_mahe_dir/app.json" ] || return 1
  node -e '
    var fs=require("fs");
    try{var p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      process.exit(p&&typeof p==="object"&&p.expo?0:1);}catch(e){process.exit(1);}
  ' "$_mahe_dir/app.json" 2>/dev/null
}

# Is <dir> a Flutter project (top-level `flutter:` section or `sdk: flutter`)?
mob_pubspec_is_flutter() {  # <dir>
  _mpif_dir="$1"
  [ -f "$_mpif_dir/pubspec.yaml" ] || return 1
  grep -qE '^[[:space:]]*flutter:[[:space:]]*$|sdk:[[:space:]]*flutter' "$_mpif_dir/pubspec.yaml" 2>/dev/null
}

# Does <dir> carry a native-iOS signal (*.xcworkspace / *.xcodeproj / Package.swift)?
mob_ios_signal() {  # <dir>
  _mis_dir="$1"
  for _mis_x in "$_mis_dir"/*.xcworkspace "$_mis_dir"/*.xcodeproj; do
    [ -d "$_mis_x" ] && return 0
  done
  [ -f "$_mis_dir/Package.swift" ] && return 0
  return 1
}

# Echo the framework for <dir>: expo | react-native | flutter | ios | unknown.
# Order matters: expo before react-native (expo apps also depend on react-native).
mob_detect_framework() {  # <dir>
  _mdf_dir="$1"
  if mob_appjson_has_expo "$_mdf_dir" || mob_pkg_has_dep "$_mdf_dir" expo; then echo expo; return; fi
  if mob_pkg_has_dep "$_mdf_dir" react-native; then echo react-native; return; fi
  if mob_pubspec_is_flutter "$_mdf_dir"; then echo flutter; return; fi
  if mob_ios_signal "$_mdf_dir"; then echo ios; return; fi
  echo unknown
}

# Echo the frozen detection confidence for a framework name.
mob_framework_confidence() {  # <framework>
  case "$1" in
    expo)         echo 90 ;;
    react-native) echo 88 ;;
    flutter)      echo 90 ;;
    ios)          echo 85 ;;
    *)            echo 0  ;;
  esac
}

# Echo the JS package manager for <dir> (bun|pnpm|yarn|npm). Reuses the shared
# hp_detect_pm when the shared lib has been sourced; otherwise a lockfile fallback.
mob_detect_pm() {  # <dir>
  _mdpm_dir="$1"
  if command -v hp_detect_pm >/dev/null 2>&1; then
    hp_detect_pm "$_mdpm_dir" 2>/dev/null || echo npm
  else
    if   [ -f "$_mdpm_dir/bun.lockb" ] || [ -f "$_mdpm_dir/bun.lock" ]; then echo bun
    elif [ -f "$_mdpm_dir/pnpm-lock.yaml" ]; then echo pnpm
    elif [ -f "$_mdpm_dir/yarn.lock" ];      then echo yarn
    else echo npm
    fi
  fi
}

# Echo the native-iOS package manager for <dir>: cocoapods | spm | "".
mob_ios_pm() {  # <dir>
  _mipm_dir="$1"
  if   [ -f "$_mipm_dir/Podfile" ];       then echo "cocoapods"
  elif [ -f "$_mipm_dir/Package.swift" ]; then echo "spm"
  else echo ""
  fi
}
