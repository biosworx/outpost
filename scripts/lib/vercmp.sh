# shellcheck shell=bash
#
# pkg_vercmp A B: print -1, 0 or 1 like pacman's vercmp(8).
#
# Uses the real vercmp when installed. Otherwise falls back to a Bash port of
# libalpm's alpm_pkg_vercmp()/rpmvercmp() (lib/libalpm/version.c), so jobs on
# runners without pacman (ubuntu-slim) compare versions identically. The port
# mirrors the C line by line; keep it that way if you touch it.

pkg_vercmp() {
  if command -v vercmp >/dev/null 2>&1; then
    vercmp "$1" "$2"
  else
    _vercmp_bash "$1" "$2"
  fi
}

# parseEVR(): split [epoch:]version[-release] into _evr_e/_evr_v/_evr_r;
# _evr_has_r is 0 when there is no release (NULL in the C code).
_vercmp_parse_evr() {
  local evr="$1" digits rest
  digits="${evr%%[!0-9]*}"
  rest="${evr:${#digits}}"
  _evr_has_r=0 _evr_r=""
  if [[ "$rest" == *-* ]]; then
    _evr_has_r=1
    _evr_r="${rest##*-}"
    evr="${evr%-*}"
    rest="${rest%-*}"
  fi
  if [[ "$rest" == :* ]]; then
    _evr_e="${digits:-0}"
    _evr_v="${rest:1}"
  else
    _evr_e="0"
    _evr_v="$evr"
  fi
}

_vercmp_bash() {
  local a="$1" b="$2"
  if [[ "$a" == "$b" ]]; then echo 0; return; fi

  local e1 v1 r1 h1 e2 v2 r2 h2 ret
  _vercmp_parse_evr "$a"; e1="$_evr_e" v1="$_evr_v" r1="$_evr_r" h1="$_evr_has_r"
  _vercmp_parse_evr "$b"; e2="$_evr_e" v2="$_evr_v" r2="$_evr_r" h2="$_evr_has_r"

  ret="$(_rpmvercmp "$e1" "$e2")"
  if [[ "$ret" == 0 ]]; then
    ret="$(_rpmvercmp "$v1" "$v2")"
    if [[ "$ret" == 0 && "$h1" == 1 && "$h2" == 1 ]]; then
      ret="$(_rpmvercmp "$r1" "$r2")"
    fi
  fi
  echo "$ret"
}

# rpmvercmp(): segment-wise comparison. i/j play the role of one/two, p1/p2
# of ptr1/ptr2. Character classes are ASCII, as in the C locale.
_rpmvercmp() {
  local LC_ALL=C
  local a="$1" b="$2"
  if [[ "$a" == "$b" ]]; then echo 0; return; fi

  local la=${#a} lb=${#b} i=0 j=0 p1=0 p2=0 isnum s1 s2 c1 c2
  while (( i < la && j < lb )); do
    while (( i < la )) && [[ "${a:i:1}" != [A-Za-z0-9] ]]; do i=$((i + 1)); done
    while (( j < lb )) && [[ "${b:j:1}" != [A-Za-z0-9] ]]; do j=$((j + 1)); done

    # Ran to the end of either: done with the loop.
    (( i < la && j < lb )) || break

    # Different separator lengths decide it.
    if (( i - p1 != j - p2 )); then
      if (( i - p1 < j - p2 )); then echo -1; else echo 1; fi
      return
    fi

    p1=$i p2=$j
    # Grab a completely numeric or completely alpha segment.
    if [[ "${a:p1:1}" == [0-9] ]]; then
      while (( p1 < la )) && [[ "${a:p1:1}" == [0-9] ]]; do p1=$((p1 + 1)); done
      while (( p2 < lb )) && [[ "${b:p2:1}" == [0-9] ]]; do p2=$((p2 + 1)); done
      isnum=1
    else
      while (( p1 < la )) && [[ "${a:p1:1}" == [A-Za-z] ]]; do p1=$((p1 + 1)); done
      while (( p2 < lb )) && [[ "${b:p2:1}" == [A-Za-z] ]]; do p2=$((p2 + 1)); done
      isnum=0
    fi

    # Segments of different types: numeric is newer than alpha.
    if (( j == p2 )); then
      if (( isnum )); then echo 1; else echo -1; fi
      return
    fi

    s1="${a:i:p1-i}" s2="${b:j:p2-j}"
    if (( isnum )); then
      while [[ "$s1" == 0* ]]; do s1="${s1#0}"; done
      while [[ "$s2" == 0* ]]; do s2="${s2#0}"; done
      if (( ${#s1} > ${#s2} )); then echo 1; return; fi
      if (( ${#s2} > ${#s1} )); then echo -1; return; fi
    fi
    if [[ "$s1" < "$s2" ]]; then echo -1; return; fi
    if [[ "$s1" > "$s2" ]]; then echo 1; return; fi

    i=$p1 j=$p2
  done

  # All segments equal but separators differed.
  if (( i >= la && j >= lb )); then echo 0; return; fi

  # The final showdown: a remaining alpha string never beats an empty one.
  c1="${a:i:1}" c2="${b:j:1}"
  if { (( i >= la )) && [[ "$c2" != [A-Za-z] ]]; } || [[ "$c1" == [A-Za-z] ]]; then
    echo -1
  else
    echo 1
  fi
}
