#!/usr/bin/env bash
# Side dock: floating windows tagged 'dock' live on a right-edge panel as a
# CASCADE STACK. The front window sits at the panel base (opaque + raised); the
# rest fan out behind it toward the lower-left (dimmed, peeking their edges). One
# keybind SHIFTS the pile -- the front rotates to the back and everything slides
# one step, which Hyprland animates. Hiding parks the whole pile off the right
# edge but remembers which window was in front, so the next cycle restores it.
#
# Every placement is done BY ADDRESS (move/opacity/z-order/float all take a
# `window=`), never by focusing, so main-area windows are never disturbed; only
# the front window is focused at the end, for typing.
#
# Verbs:  cycle  show the pile / shift to the next window (wraps)
#         hide   park the whole pile off-screen (remembers the front)
#         send   push the focused window into the dock
#         pull   return the front window to the main tiling area
set -uo pipefail
export HYPRLAND_INSTANCE_SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE:-$(ls "${XDG_RUNTIME_DIR:-/run/user/1000}/hypr/" 2>/dev/null | head -1)}"
HC=hyprctl; J=jq
STATE="${XDG_RUNTIME_DIR:-/run/user/1000}/sidedock.front"   # remembers the front across hide

geom() {
  read -r W H X0 Y0 < <($HC monitors -j | $J -r '.[]|select(.focused)|"\(.width) \(.height) \(.x) \(.y)"')
  # top-bar (waybar) height on this monitor, so the dock always clears it
  barH=$($HC layers -j | $J -r '[.[].levels|to_entries[].value[]|select(.namespace=="waybar")|.h]|max // 0')
  HGAP=14; VGAP=48; DW=640           # right inset; top/bottom margin; panel width
  DX=18; DY=14; MAXD=3               # cascade peek step (left,down) per depth; max visible depth
  DOCK_Y=$((Y0 + barH + VGAP))
  DOCK_H=$((H - barH - 2*VGAP))
  SHOWN_X=$((X0 + W - DW - HGAP))     # front (depth 0) x
  PARKED_X=$((X0 + W))                # fully off the right edge
}

# One clients snapshot per run; all reads parse it (positions are read before any
# move, so a single snapshot is consistent for the whole placement pass).
snap() { CLIENTS=$($HC clients -j); }
# A window being removed can still appear in the snapshot; EXCLUDE drops it from
# the layout (set by 'orphan' on window.close). Empty = exclude nothing.
EXCLUDE=""
# Dock-tagged windows: a rule tag renders as 'dock*', a dispatcher tag as 'dock';
# rtrimstr collapses both. Sorted by address for a stable cycle order.
order()    { $J -r --arg ex "$EXCLUDE" '[.[]|select((.tags|any(rtrimstr("*")=="dock")) and .address != $ex)|.address]|sort|.[]' <<<"$CLIENTS"; }
# Current front = the on-screen dock window nearest the base (largest x).
curfront() { $J -r --argjson px "$PARKED_X" '[.[]|select((.tags|any(rtrimstr("*")=="dock")) and (.at[0] < $px))]|max_by(.at[0])?|.address // ""' <<<"$CLIENTS"; }
shownany() { $J -r --argjson px "$PARKED_X" 'any(.[]; (.tags|any(rtrimstr("*")=="dock")) and (.at[0] < $px))' <<<"$CLIENTS"; }
isfloat()  { $J -r --arg a "$1" 'first(.[]|select(.address==$a)).floating // false' <<<"$CLIENTS"; }
exists()   { $J -e --arg a "$1" 'any(.[]; .address==$a)' <<<"$CLIENTS" >/dev/null 2>&1; }

d() { $HC dispatch "$1" >/dev/null 2>&1; }   # fire a Lua dispatcher, ignore chatter
mv()   { d "hl.dsp.window.move({x=$2, y=$3, window=\"address:$1\"})"; }
op()   { d "hl.dsp.window.set_prop({prop=\"opacity\", value=\"$2\", window=\"address:$1\"})"; }
ztop() { d "hl.dsp.window.alter_zorder({mode=\"top\", window=\"address:$1\"})"; }
# Pin = show on EVERY workspace, so the dock follows whatever workspace is live
# instead of staying stuck on the one it opened on. on when it joins the dock,
# off when it leaves.
pin()  { d "hl.dsp.window.pin({action=\"$2\", window=\"address:$1\"})"; }
# no_focus on the BACK windows: clicking a peeking window then can't focus/raise
# it (which would jump it to the front out of turn). Only the front is focusable.
nofocus() { d "hl.dsp.window.set_prop({prop=\"no_focus\", value=\"$2\", window=\"address:$1\"})"; }
ensure_float() { [ "$(isfloat "$1")" = "false" ] && d "hl.dsp.window.float({window=\"address:$1\"})"; }

# Lay out the cascade with $1 as the front. Rotates the stable order so the front
# is depth 0, places each window at its depth (front at base+opaque, the rest
# fanned+dimmed), raises deepest->front so the front lands on top, then focuses
# the front. All placement is by address; only the final focus touches focus.
render() {
  local front="$1" i d dd x y
  local -a ord rot
  mapfile -t ord < <(order)
  [ ${#ord[@]} -eq 0 ] && return 1
  local fi=0
  for i in "${!ord[@]}"; do [ "${ord[$i]}" = "$front" ] && fi=$i && break; done
  for ((i=0; i<${#ord[@]}; i++)); do rot+=("${ord[$(( (fi+i) % ${#ord[@]} ))]}"); done
  # Floating is a prerequisite AND a toggle, so it can't go in the batch; dock
  # windows are already floating, so this is normally a no-op.
  local a; for a in "${rot[@]}"; do ensure_float "$a"; done
  # Build ONE atomic batch (pin, move, opacity, focusability, then z-order, then
  # focus). Sent as a single `hyprctl --batch`, the compositor commits it all in one
  # frame -- so no window flashes to the top mid-shuffle. Doing the z-order raises as
  # separate calls (a render between each) is what caused the collision flicker.
  local batch=""
  for ((i=0; i<${#rot[@]}; i++)); do
    d=$i; dd=$(( d < MAXD ? d : MAXD ))
    x=$(( SHOWN_X - dd*DX )); y=$(( DOCK_Y + dd*DY )); a="${rot[$i]}"
    batch+="dispatch hl.dsp.window.pin({action=\"on\", window=\"address:$a\"}) ; "
    batch+="dispatch hl.dsp.window.move({x=$x, y=$y, window=\"address:$a\"}) ; "
    if [ "$d" -eq 0 ]; then
      batch+="dispatch hl.dsp.window.set_prop({prop=\"opacity\", value=\"1.0 1.0\", window=\"address:$a\"}) ; "
      batch+="dispatch hl.dsp.window.set_prop({prop=\"no_focus\", value=\"false\", window=\"address:$a\"}) ; "
    else
      batch+="dispatch hl.dsp.window.set_prop({prop=\"opacity\", value=\"0.62 0.62\", window=\"address:$a\"}) ; "
      batch+="dispatch hl.dsp.window.set_prop({prop=\"no_focus\", value=\"true\", window=\"address:$a\"}) ; "
    fi
  done
  # Raise deepest -> front so the front lands on top (all within the one frame).
  for ((i=${#rot[@]}-1; i>=0; i--)); do
    batch+="dispatch hl.dsp.window.alter_zorder({mode=\"top\", window=\"address:${rot[$i]}\"}) ; "
  done
  batch+="dispatch hl.dsp.focus({window=\"address:${rot[0]}\"})"
  $HC --batch "$batch" >/dev/null 2>&1
  printf '%s' "${rot[0]}" >"$STATE"
}

park_all() {
  # UNPIN as part of hiding: a pinned window follows every workspace, and Hyprland
  # pulls a pinned off-screen window back on-screen when the workspace changes -- so
  # a hidden-but-pinned dock would "reopen" on the next workspace switch. Unpinned +
  # parked, it stays put and out of sight; render() re-pins on show.
  local a
  while read -r a; do [ -n "$a" ] || continue
    ensure_float "$a"; pin "$a" off; mv "$a" "$PARKED_X" "$DOCK_Y"
  done < <(order)
}
# Show the pile at the remembered front (falling back to the first window).
show_pile() {
  local -a o; mapfile -t o < <(order); [ ${#o[@]} -eq 0 ] && return 1
  local want=""; [ -f "$STATE" ] && want="$(cat "$STATE" 2>/dev/null)"
  { [ -z "$want" ] || ! exists "$want"; } && want="${o[0]}"
  render "$want"
}
active() { $J -r '.address // ""' < <($HC activewindow -j); }
is_dock() { $J -e --arg a "$1" 'any(.[]; .address==$a and (.tags|any(rtrimstr("*")=="dock")))' <<<"$CLIENTS" >/dev/null 2>&1; }
dock_send() {  # give a window the dock shape + tag, then lay it out as the front
  local a="$1"
  ensure_float "$a"
  d "hl.dsp.window.tag({tag=\"+dock\", window=\"address:$a\"})"
  d "hl.dsp.window.resize({x=$DW, y=$DOCK_H, window=\"address:$a\"})"   # absolute fit
  d "hl.dsp.window.set_prop({prop=\"min_size\", value=\"$DW $DOCK_H\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"max_size\", value=\"$DW $DOCK_H\", window=\"address:$a\"})"
  # Match the auto-route rule's chrome removal (border/shadow/blur render at the
  # rectangular box, not the trapezoid, so they must be off): the RULE sets these
  # for cfg.apps, but a manually-sent window (dolphin, a terminal) never hit it.
  d "hl.dsp.window.set_prop({prop=\"decorate\", value=\"false\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"no_blur\", value=\"true\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"no_shadow\", value=\"true\", window=\"address:$a\"})"
  snap; render "$a"
}
undock() {  # strip the dock shape/tag and return a window to the tiling area
  local a="$1"
  # Clear the size LOCK first (so the window can retile freely): zero the min and
  # blow the max wide open -- no_max_size alone left the rule's 640x928 max in
  # force, which is the "no resize / janky" state. Then drop pin/dim/tag.
  d "hl.dsp.window.set_prop({prop=\"min_size\", value=\"0 0\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"max_size\", value=\"99999 99999\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"no_max_size\", value=\"true\", window=\"address:$a\"})"
  pin "$a" off
  nofocus "$a" false
  d "hl.dsp.window.set_prop({prop=\"opacity\", value=\"1.0 1.0\", window=\"address:$a\"})"
  # restore the chrome dock_send stripped
  d "hl.dsp.window.set_prop({prop=\"decorate\", value=\"true\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"no_blur\", value=\"false\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"no_shadow\", value=\"false\", window=\"address:$a\"})"
  d "hl.dsp.window.tag({tag=\"-dock\", window=\"address:$a\"})"
  # Tile it: read LIVE float state (not the pre-undock snapshot) and unfloat if
  # still floating, so it joins the layout like any normal app.
  [ "$($HC clients -j | $J -r --arg a "$a" 'first(.[]|select(.address==$a)).floating // false')" = "true" ] \
    && d "hl.dsp.window.float({window=\"address:$a\"})"
  snap
  # Re-lay whatever remains (only if the pile is on-screen), then hand focus back
  # to the just-freed window -- you pulled it out to use it.
  if [ "$(shownany)" = "true" ]; then
    local -a o; mapfile -t o < <(order)
    [ ${#o[@]} -gt 0 ] && render "${o[0]}"
  fi
  d "hl.dsp.focus({window=\"address:$a\"})"
}

geom; snap
case "${1:-toggle}" in
  toggle)   # SUPER+D: show the pile if hidden, park it if shown
    if [ "$(shownany)" = "true" ]; then
      cur="$(curfront)"; [ -n "$cur" ] && printf '%s' "$cur" >"$STATE"
      park_all
    else
      show_pile
    fi ;;
  next|prev)   # SUPER+right / SUPER+left while focused on the dock: shift the pile
    mapfile -t ORD < <(order)
    [ ${#ORD[@]} -eq 0 ] && exit 0
    [ "$(shownany)" != "true" ] && { show_pile; exit 0; }   # not shown -> just show it
    [ ${#ORD[@]} -eq 1 ] && exit 0                          # safeguard: nothing to shift
    cur="$(curfront)"; ci=0
    for i in "${!ORD[@]}"; do [ "${ORD[$i]}" = "$cur" ] && ci=$i && break; done
    if [ "$1" = "next" ]; then ni=$(( (ci+1) % ${#ORD[@]} )); else ni=$(( (ci-1+${#ORD[@]}) % ${#ORD[@]} )); fi
    render "${ORD[$ni]}" ;;
  dock-toggle)   # SUPER+SHIFT+D: dock the focused window, or undock it if docked
    a="$(active)"; [ -z "$a" ] && exit 0
    if is_dock "$a"; then undock "$a"; else dock_send "$a"; fi ;;
  adopt)   # a dock window ($2) just OPENED: bring it to the front and re-cascade
    is_dock "$2" || exit 0
    render "$2" ;;
  orphan)  # a dock window ($2) just CLOSED: re-flow the survivors (if the pile is up)
    EXCLUDE="$2"; snap
    mapfile -t ORD < <(order)
    [ ${#ORD[@]} -eq 0 ] && { : >"$STATE"; exit 0; }   # dock now empty
    # Keep the remembered front if it survives; otherwise take the first.
    want=""; [ -f "$STATE" ] && want="$(cat "$STATE" 2>/dev/null)"
    if [ -z "$want" ] || [ "$want" = "$EXCLUDE" ] || ! printf '%s\n' "${ORD[@]}" | grep -qxF "$want"; then want="${ORD[0]}"; fi
    [ "$(shownany)" = "true" ] && render "$want"
    printf '%s' "$want" >"$STATE" ;;
esac
