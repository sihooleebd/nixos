#!/usr/bin/env bash
# Side dock: floating windows tagged 'dock' live on a right-edge panel as a
# CASCADE STACK. The front window sits at the panel base (full opacity + raised); the
# rest fan out behind it toward the lower-left (dimmed to ~0.62, peeking their edges).
# Opacity is per-position and multiplies each app's own alpha (glass stays glass). One
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
  # The dock lives on the RIGHTMOST edge of the WHOLE desktop -- the monitor whose logical
  # right edge (x + width/scale) is furthest right -- so with multiple displays it's one fixed
  # spot, not wherever focus happens to be. `monitors -j` reports PHYSICAL width/height plus a
  # `scale`; Hyprland positions/sizes windows in LOGICAL coords = physical / scale (a 1920x1080
  # panel at scale 0.8 is a 2400x1350 logical viewport). Divide by scale (jq does the float
  # math -- awk/bc aren't on the wrapper PATH) so the dock tracks resolution AND scale changes.
  # x/y are already logical. max_by picks the rightmost monitor; nothing is hardcoded to 1920.
  read -r W H X0 Y0 < <($HC monitors -j | $J -r 'max_by(.x + (.width/(.scale//1)))|"\(.width/(.scale//1)|round) \(.height/(.scale//1)|round) \(.x) \(.y)"')
  [ -n "${W:-}" ] && [ "$W" -gt 0 ] 2>/dev/null || { W=1920; H=1080; X0=0; Y0=0; }   # fallback
  # Waybar footprint, classified by ORIENTATION (hakuspace ships horizontal AND vertical layouts).
  # A horizontal bar (wide + short) offsets the dock vertically; a VERTICAL bar (tall + narrow) must
  # NOT be read as a top offset -- its .h is the WHOLE display height, which drove DOCK_H negative and
  # broke the dock entirely. A vertical bar on the RIGHT instead insets the pile horizontally; one on
  # the left doesn't touch the right-edge dock. (Layer geom is logical, same frame as W/H.)
  read -r BW BH BX BY < <($HC layers -j | $J -r \
    '[.[].levels|to_entries[].value[]|select(.namespace=="waybar")]|(max_by(.w*.h)//{})|"\(.w//0) \(.h//0) \(.x//0) \(.y//0)"')
  barTop=0; barBottom=0; barRight=0
  if [ "${BH:-0}" -gt 0 ] 2>/dev/null; then
    if [ "$BH" -lt $((H*3/4)) ]; then
      if [ "$BY" -lt $((Y0 + H/2)) ]; then barTop=$BH; else barBottom=$BH; fi   # horizontal: top vs bottom
    elif [ "$BX" -ge $((X0 + W/2)) ]; then barRight=$BW; fi                      # vertical bar on the right edge
  fi
  # panel width scales with the viewport (~1/3 of the logical width -> 640 on a 1920 view,
  # 800 on a 2400 view), clamped so cards stay usable on very small / very large screens.
  DW=$((W/3)); [ "$DW" -lt 420 ] && DW=420; [ "$DW" -gt 900 ] && DW=900
  # Margins + cascade steps also scale with the viewport (were fixed 14/48/18/14 on a 1920
  # view). HGAP=0 -> the front card sits FLUSH to the right screen edge (no gap/trim).
  HGAP=$((W/60))                     # RIGHT INSET: how far the pile sits IN from the right
                                     # edge (~40 logical on a 2400 view ~= 0.5cm physical).
                                     # Divisor DOWN = more inset (W/30 ~1cm), UP = less.
  VGAP=$((H/28))                     # top/bottom margin (~48 on a 1350-tall view)
  # CASCADE DEPTH ("floating stack, receding"): back cards SHRINK by SHRINK% per depth and
  # their CENTER stays on the front card's midline (NO diagonal-down) -- they only drift a
  # little LEFT by DLEFT, so the pile reads as cards going back into the distance.
  DLEFT=$((DW/30))                   # per-depth LEFT drift of the card center (slight)
  SHRINK=9; MAXD=3                   # per-depth size shrink (%); deepest visible depth
  STAGGER=0.035                      # seconds between cards on show/park -> a bit of "feel"
  DOCK_Y=$((Y0 + barTop + VGAP))
  DOCK_H=$((H - barTop - barBottom - 2*VGAP))
  SHOWN_X=$((X0 + W - DW - HGAP - barRight))   # front (depth 0) x; a vertical right-edge bar insets it
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
# A "dock card" for the CASCADE = tagged dock but NOT pip. A PiP (my.sidedock keystone PiP)
# is tagged dock too (so it gets the keystone look/shadow/input for free) but pip excludes it
# from the pile, so it floats standalone wherever pip_make parked it.
order()    { $J -r --arg ex "$EXCLUDE" '[.[]|select((.tags|any(rtrimstr("*")=="dock")) and (.tags|any(rtrimstr("*")=="pip")|not) and .address != $ex)|.address]|sort|.[]' <<<"$CLIENTS"; }
# Current front = the on-screen dock window nearest the base (largest x).
curfront() { $J -r --argjson px "$PARKED_X" '[.[]|select((.tags|any(rtrimstr("*")=="dock")) and (.tags|any(rtrimstr("*")=="pip")|not) and (.at[0] < $px))]|max_by(.at[0])?|.address // ""' <<<"$CLIENTS"; }
shownany() { $J -r --argjson px "$PARKED_X" 'any(.[]; (.tags|any(rtrimstr("*")=="dock")) and (.tags|any(rtrimstr("*")=="pip")|not) and (.at[0] < $px))' <<<"$CLIENTS"; }
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
# is depth 0, places each window at its depth (front at base, full opacity; the rest
# fanned+dimmed), raises deepest->front so the front lands on top, then focuses
# the front. All placement is by address; only the final focus touches focus.
render() {
  local front="$1" stagger="${2:-0}" nofocus="${3:-0}" i d dd x y cw ch cx cy op ov scp tg tgwant
  local -a ord rot MX MY
  mapfile -t ord < <(order)
  [ ${#ord[@]} -eq 0 ] && return 1
  local fi=0
  for i in "${!ord[@]}"; do [ "${ord[$i]}" = "$front" ] && fi=$i && break; done
  for ((i=0; i<${#ord[@]}; i++)); do rot+=("${ord[$(( (fi+i) % ${#ord[@]} ))]}"); done
  # Floating is a prerequisite AND a toggle, so it can't go in the batch; dock
  # windows are already floating, so this is normally a no-op.
  local a; for a in "${rot[@]}"; do ensure_float "$a"; done
  # Front card vertical CENTRE -- back cards keep this SAME midline (no diagonal-down);
  # they only shrink and step a little LEFT, so their left edge peeks out to the left.
  local CY0=$(( DOCK_Y + DOCK_H/2 ))
  # ONE atomic batch (size, opacity, pin, focusability, z-order, focus) so nothing flashes
  # to the top mid-shuffle. The MOVE is in the batch ONLY when not staggering; on show it
  # is done per-card with a small delay below (the "feel"). NB back cards are ACTUAL smaller
  # windows (min==max lock) -- the app reflows to that size; that's the cost of real shrink.
  local batch=""
  for ((i=0; i<${#rot[@]}; i++)); do
    d=$i; dd=$(( d < MAXD ? d : MAXD )); a="${rot[$i]}"
    scp=$(( 100 - dd*SHRINK )); [ "$scp" -lt 55 ] && scp=55     # depth shrink (% of front, floored)
    cw=$(( DW*scp/100 )); ch=$(( DOCK_H*scp/100 ))
    x=$(( SHOWN_X - dd*DLEFT ))                                 # LEFT edge steps slightly left (peek)
    y=$(( CY0 - ch/2 ))                                         # vertically CENTERED on the front midline
    MX[$i]=$x; MY[$i]=$y
    if [ "$d" -eq 0 ]; then op="1.0 1.0"; else ov=$(( 60 - (dd-1)*14 )); [ "$ov" -lt 30 ] && ov=30; op="0.$ov 0.$ov"; fi
    # Two per-card tags the compositor (trapezoid.patch) reads, applied BEFORE the resize/move:
    #  dockd<depth>      front=0 -> this card gets its OWN move curve overshooting by
    #                    keystone_bounce * keystone_bounce_decay^depth (updateDockMoveAnimation).
    #  dockbox<cw>x<ch>  this card's INTENDED box (logical px). fitTransform() uses it as the
    #                    target box so SCALE-TO-FIT engages even when an X11/Wine client (KakaoTalk)
    #                    resists the resize and its live size stays at its own min -> it's drawn
    #                    shrunk into the card instead of overflowing. Wayland cards that comply have
    #                    box == card so it's a no-op for them.
    # Drop any STALE dockd/dockbox tags first (only those NOT in the wanted set).
    tgwant="dockd$d dockbox${cw}x${ch}"
    while read -r tg; do
      [ -n "$tg" ] && [[ " $tgwant " != *" $tg "* ]] && batch+="dispatch hl.dsp.window.tag({tag=\"-$tg\", window=\"address:$a\"}) ; "
    done < <($J -r --arg a "$a" 'first(.[]|select(.address==$a)).tags[]? | rtrimstr("*") | select(test("^dock(d[0-9]+|box[0-9]+x[0-9]+)$"))' <<<"$CLIENTS")
    for tg in $tgwant; do batch+="dispatch hl.dsp.window.tag({tag=\"+$tg\", window=\"address:$a\"}) ; "; done
    batch+="dispatch hl.dsp.window.set_prop({prop=\"max_size\", value=\"$cw $ch\", window=\"address:$a\"}) ; "
    batch+="dispatch hl.dsp.window.set_prop({prop=\"min_size\", value=\"$cw $ch\", window=\"address:$a\"}) ; "
    batch+="dispatch hl.dsp.window.resize({x=$cw, y=$ch, window=\"address:$a\"}) ; "
    batch+="dispatch hl.dsp.window.pin({action=\"on\", window=\"address:$a\"}) ; "
    batch+="dispatch hl.dsp.window.set_prop({prop=\"opacity\", value=\"$op\", window=\"address:$a\"}) ; "
    if [ "$d" -eq 0 ]; then batch+="dispatch hl.dsp.window.set_prop({prop=\"no_focus\", value=\"false\", window=\"address:$a\"}) ; "
    else                   batch+="dispatch hl.dsp.window.set_prop({prop=\"no_focus\", value=\"true\", window=\"address:$a\"}) ; "; fi
    [ "$stagger" != 1 ] && batch+="dispatch hl.dsp.window.move({x=$x, y=$y, window=\"address:$a\"}) ; "
  done
  # Raise deepest -> front so the front lands on top (all within the one frame).
  for ((i=${#rot[@]}-1; i>=0; i--)); do
    batch+="dispatch hl.dsp.window.alter_zorder({mode=\"top\", window=\"address:${rot[$i]}\"}) ; "
  done
  # The final focus is SKIPPED in nofocus mode (the workspace-change 'rehome': re-home the
  # pile to its monitor without yanking focus off the workspace you just switched to).
  [ "$nofocus" != 1 ] && batch+="dispatch hl.dsp.focus({window=\"address:${rot[0]}\"})"
  $HC --batch "$batch" >/dev/null 2>&1
  # Staggered slide-in (show): front leads, each next card follows STAGGER later, so the
  # pile fans in with a bit of feel instead of snapping as one block. (Sizes/z were set
  # atomically above; only the visible position is staggered, so there is no flicker.)
  if [ "$stagger" = 1 ]; then
    for ((i=0; i<${#rot[@]}; i++)); do
      d "hl.dsp.window.move({x=${MX[$i]}, y=${MY[$i]}, window=\"address:${rot[$i]}\"})"
      [ "$i" -lt $(( ${#rot[@]} - 1 )) ] && sleep "$STAGGER" 2>/dev/null
    done
  fi
  printf '%s' "${rot[0]}" >"$STATE"
}

park_all() {
  # UNPIN as part of hiding: a pinned window follows every workspace, and Hyprland pulls a
  # pinned off-screen window back on-screen when the workspace changes -- so a hidden-but-
  # pinned dock would "reopen" on the next workspace switch. Unpinned + parked it stays put;
  # render() re-pins on show.
  local -a o rot; mapfile -t o < <(order)
  [ ${#o[@]} -eq 0 ] && return 0
  # Depth order (front first): order() is ADDRESS-sorted, NOT depth-sorted, so rotate it
  # around the current front to recover the on-screen stacking before touching z.
  local cur fi=0 i a; cur="$(curfront)"; { [ -z "$cur" ] || ! exists "$cur"; } && cur="${o[0]}"
  for i in "${!o[@]}"; do [ "${o[$i]}" = "$cur" ] && fi=$i && break; done
  for ((i=0; i<${#o[@]}; i++)); do rot+=("${o[$(( (fi+i) % ${#o[@]} ))]}"); done
  # Z-ORDER FIX (close mixup): unpinning a pinned window re-inserts it into the workspace
  # stack, and doing the unpins one-at-a-time with the stagger sleeps flashed each card to
  # the TOP as it was released -- cards popping over each other on close. So unpin them ALL
  # in one atomic frame, then raise deepest->front (front on top) in the SAME batch, so the
  # pile stays correctly stacked. The slide-out below only MOVES (never reorders), so z holds.
  local batch=""
  for a in "${rot[@]}"; do ensure_float "$a"; batch+="dispatch hl.dsp.window.pin({action=\"off\", window=\"address:$a\"}) ; "; done
  for ((i=${#rot[@]}-1; i>=0; i--)); do batch+="dispatch hl.dsp.window.alter_zorder({mode=\"top\", window=\"address:${rot[$i]}\"}) ; "; done
  $HC --batch "$batch" >/dev/null 2>&1
  # Slide out BACK-to-FRONT with a small stagger so the pile ripples out (matches slide-IN).
  for ((i=${#rot[@]}-1; i>=0; i--)); do
    mv "${rot[$i]}" "$PARKED_X" "$DOCK_Y"
    [ "$i" -gt 0 ] && sleep "$STAGGER" 2>/dev/null
  done
}
# Show the pile at the remembered front (falling back to the first window).
show_pile() {
  local -a o; mapfile -t o < <(order); [ ${#o[@]} -eq 0 ] && return 1
  panelbus open dock 2>/dev/null || true   # dock is becoming visible -> close the other special panels
  local want=""; [ -f "$STATE" ] && want="$(cat "$STATE" 2>/dev/null)"
  { [ -z "$want" ] || ! exists "$want"; } && want="${o[0]}"
  render "$want" 1
}
active() { $J -r '.address // ""' < <($HC activewindow -j); }
is_dock() { $J -e --arg a "$1" 'any(.[]; .address==$a and (.tags|any(rtrimstr("*")=="dock")))' <<<"$CLIENTS" >/dev/null 2>&1; }
is_pip()  { $J -e --arg a "$1" 'any(.[]; .address==$a and (.tags|any(rtrimstr("*")=="pip")))'  <<<"$CLIENTS" >/dev/null 2>&1; }
dock_send() {  # give a window the dock shape + tag, then lay it out as the front
  local a="$1"
  panelbus open dock 2>/dev/null || true   # docking shows the pile -> close the other special panels
  ensure_float "$a"
  d "hl.dsp.window.tag({tag=\"+dock\", window=\"address:$a\"})"
  # (size + lock is applied by render(), from the live geometry -- not here.)
  # Match the auto-route rule's chrome removal: BORDER + SHADOW render at the flat box
  # (their own passes, not through the keystone) so they'd box the trapezoid -- strip
  # them (decorate=false covers both). BLUR is deliberately LEFT ON: the frosted layer
  # is drawn by renderTextureInternal, which the keystone hook warps, so the frost
  # follows the trapezoid and a glass window reads as GLASS. The RULE strips chrome for
  # cfg.apps; a manually-sent window (dolphin, a terminal) never hit it, so do it here.
  d "hl.dsp.window.set_prop({prop=\"decorate\", value=\"false\", window=\"address:$a\"})"
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
  # Restore corner ROUNDING. The dock route-rule (sidedock/home.nix) pins rounding=0 so the
  # keystone SHADER owns the corners while docked; that per-window override survives undock,
  # leaving the window square in the tiling area. Re-apply the live GLOBAL rounding so it
  # rounds like every other window (read it, don't hardcode, so it tracks decoration:rounding).
  local grnd; grnd=$($HC getoption decoration:rounding -j 2>/dev/null | $J -r '.int // 10')
  d "hl.dsp.window.set_prop({prop=\"rounding\", value=$grnd, window=\"address:$a\"})"
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

pip_make() {  # turn $1 into a keystone PiP: a standalone, pinned, tilted mini-card, bottom-right.
  local a="$1"
  ensure_float "$a"
  d "hl.dsp.window.tag({tag=\"+dock\", window=\"address:$a\"})"  # +dock => keystone tilt/shadow/input, all free
  d "hl.dsp.window.tag({tag=\"+pip\", window=\"address:$a\"})"   # +pip  => the cascade (order/curfront/shownany) skips it
  # strip chrome like dock_send: border/shadow are flat-box passes, the keystone owns the look
  d "hl.dsp.window.set_prop({prop=\"decorate\", value=\"false\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"no_shadow\", value=\"true\", window=\"address:$a\"})"
  # ~1/3 of the viewport wide, KEEPING the window's current aspect, parked bottom-right (right
  # edge inset by HGAP so the keystone's flush right edge sits just off the screen edge).
  local cw ch pw ph px py mw mh
  read -r cw ch < <($J -r --arg a "$a" 'first(.[]|select(.address==$a))|"\(.size[0]) \(.size[1])"' <<<"$CLIENTS")
  { [ -n "${cw:-}" ] && [ "$cw" -gt 0 ] 2>/dev/null; } || { cw=16; ch=9; }
  # Fit the window's aspect INSIDE a small max box (~1/3 of the viewport each way) so a PiP is
  # always a MINI card. Capping width alone left a tall window near full-height (= a dock card).
  # min(mw/cw, mh/ch) via cross-multiply: whichever dimension is the tighter fit wins.
  mw=$((W/3)); mh=$((H/3))
  if [ $(( mw * ch )) -le $(( mh * cw )) ]; then pw=$mw; ph=$(( mw * ch / cw ));
  else                                          ph=$mh; pw=$(( mh * cw / ch )); fi
  px=$(( X0 + W - pw - HGAP )); py=$(( Y0 + H - ph - VGAP ))
  # Clear the min FIRST (a prior dock/pip lock could be larger than the new PiP size, which would
  # clamp the resize), then set max, resize down, and re-lock min == max at the PiP size.
  d "hl.dsp.window.set_prop({prop=\"min_size\", value=\"0 0\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"max_size\", value=\"$pw $ph\", window=\"address:$a\"})"
  d "hl.dsp.window.resize({x=$pw, y=$ph, window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"min_size\", value=\"$pw $ph\", window=\"address:$a\"})"
  pin "$a" on
  mv "$a" "$px" "$py"
  ztop "$a"
  # If $a was a pile member (SUPER+U straight from the dock = the "pin clears dock" half), the
  # cascade now has a gap -- re-flow the survivors (order() already excludes this +pip window),
  # then hand focus back to the PiP.
  snap
  if [ "$(shownany)" = "true" ]; then
    local -a o; mapfile -t o < <(order)
    [ ${#o[@]} -gt 0 ] && render "${o[0]}"
  fi
  d "hl.dsp.focus({window=\"address:$a\"})"
}
unpip() {  # return a PiP to the tiling area -- drop the pip tag, then reuse undock's full restore
  local a="$1"
  d "hl.dsp.window.tag({tag=\"-pip\", window=\"address:$a\"})"
  undock "$a"
}
dock_from_pip() {  # SUPER+SHIFT+D on a PiP: fold it into the cascade pile instead of undocking it.
  # pin and dock are mutually exclusive, so docking a pinned window clears the pin. Drop the
  # standalone `pip` marker + its mini size-lock, but KEEP the `dock` tag (= the keystone look)
  # and the pin-on; then let render() resize it to the pile card size as the new front. Without
  # this, SUPER+SHIFT+D hit undock() (a PiP carries `dock` too) and stranded it out of the pile,
  # still pip-tagged + mini-sized -- the limbo this whole change removes.
  local a="$1"
  d "hl.dsp.window.tag({tag=\"-pip\", window=\"address:$a\"})"
  panelbus open dock 2>/dev/null || true   # folding into the dock makes it visible -> close the notif centre
  d "hl.dsp.window.set_prop({prop=\"min_size\", value=\"0 0\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"max_size\", value=\"99999 99999\", window=\"address:$a\"})"
  snap; render "$a"
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
  show)     # directional gesture (3-finger swipe toward the dock): reveal the pile.
            # Idempotent -- a no-op if it is already shown, so repeated swipes don't flicker.
    [ "$(shownany)" = "true" ] || show_pile ;;
  hide)     # directional gesture (3-finger swipe away): hide the pile. Remembers the front
            # (like toggle) so the next show restores it. No-op if already hidden.
    if [ "$(shownany)" = "true" ]; then
      cur="$(curfront)"; [ -n "$cur" ] && printf '%s' "$cur" >"$STATE"
      park_all
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
  gesture-move)  # gestures:dock_swipe_exec (trapezoid.patch): RELEASE of the continuous 4-finger move
                 # gesture after it began on a pile card. The compositor already slid the card LIVE
                 # under the finger; it hands $2 = l/r/none (finger direction; none = too short to
                 # cycle) and $3 = the front card's address at swipe start. EITHER direction (left OR
                 # right) sinks the front card to the bottom and moves the rest up one -- Benjamin
                 # wants any 4-finger swipe on the pile to cycle the same way; none springs back.
                 # render() animates from where the finger left the card. A 4-finger drag NOT on a
                 # pile card is moved by the compositor (normal window move) and never reaches here.
    mapfile -t ORD < <(order); [ ${#ORD[@]} -eq 0 ] && exit 0
    cur="${3:-}"; { [ -n "$cur" ] && exists "$cur"; } || cur="$(curfront)"
    [ -z "$cur" ] && cur="${ORD[0]}"
    ci=0; for i in "${!ORD[@]}"; do [ "${ORD[$i]}" = "$cur" ] && ci=$i && break; done
    case "${2:-}" in
      l|r|next|prev) render "${ORD[$(( (ci+1) % ${#ORD[@]} ))]}" ;;  # EITHER direction: sink the front to the bottom, the rest move up one
      *) render "$cur" ;;                                            # too short / none: spring back, no cycle
    esac ;;
  gesture-pile)  # gestures:dock_pile_exec (trapezoid.patch): RELEASE of the continuous 3-finger pile
                 # show/hide. CDockPileTrackpadGesture already slid EVERY pile card live; it hands
                 # $2 = l|r|none (l = reveal, r = hide, none = too short -> spring back) and $3 = 1 if
                 # the pile was shown at swipe start else 0. show_pile / park_all animate the pile from
                 # wherever the fingers left it. (The 3-finger VERTICAL swipe is the workspace switch,
                 # a different axis, so the two never collide.)
    case "${2:-}" in
      l) show_pile ;;
      r) cur="$(curfront)"; [ -n "$cur" ] && printf '%s' "$cur" >"$STATE"; park_all ;;
      *) if [ "${3:-0}" = "1" ]; then show_pile; else park_all; fi ;;
    esac ;;
  dock-toggle)   # SUPER+SHIFT+D: toggle the focused window's DOCK membership. pin and dock are
                 # mutually exclusive: a PiP (pin) folds into the pile (clearing the pin); a pile
                 # window undocks; a normal window docks. Check pip FIRST -- a PiP also carries the
                 # `dock` tag (for the keystone), so is_dock would otherwise catch it and undock it
                 # into limbo (out of the pile but still pip-tagged + mini-sized -- the old bug).
    a="$(active)"; [ -z "$a" ] && exit 0
    if   is_pip  "$a"; then dock_from_pip "$a"
    elif is_dock "$a"; then undock "$a"
    else                    dock_send "$a"; fi ;;
  pip-toggle)    # SUPER+U: toggle the focused window as a keystone picture-in-picture / "pin" --
                 # a standalone, pinned, tilted mini-card bottom-right -- or return it to the layout
                 # if already pinned. pip_make clears pile membership (the "pin clears dock" half).
    a="$(active)"; [ -z "$a" ] && exit 0
    if is_pip "$a"; then unpip "$a"; else pip_make "$a"; fi ;;
  adopt)   # a dock-class window ($2) just OPENED. The Lua handler recognises it by
           # CLASS (the auto-route rule no longer tags -- see sidedock/home.nix), so
           # give it the DYNAMIC dock tag here: a rule tag renders as "dock*" and
           # CANNOT be removed by the tag dispatcher, so undock could never release a
           # route-tagged window (it stayed docked + keystoned with its border back).
           # A dispatcher tag ("dock") is removable, so undock works like a sent window.
           # Re-snapshot after tagging so order() sees it, then cascade it to the front.
    exists "$2" || exit 0
    d "hl.dsp.window.tag({tag=\"+dock\", window=\"address:$2\"})"
    snap
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
  relayout)  # the monitor layout/scale changed (e.g. wdisplays) -> re-apply the CURRENT
             # geometry in place from the fresh geom(), so a live resolution/scale change
             # auto-adjusts the pile with no keypress. Shown -> re-cascade at the new size/
             # position; parked -> re-park at the new (logical) off-screen x.
    if [ "$(shownany)" = "true" ]; then
      cur="$(curfront)"; { [ -z "$cur" ] || ! exists "$cur"; } && cur="$(order | head -1)"
      [ -n "$cur" ] && render "$cur"
    else
      park_all
    fi ;;
  rehome)  # a workspace became active (hl.on workspace.active, features/sidedock). The pile is
           # PINNED, and Hyprland's pin follows the active workspace across ALL monitors -- so
           # switching a workspace on ANOTHER screen drags the dock off its home monitor ("flies
           # across screens"). If the pile is up and has drifted onto the wrong monitor, re-home it
           # by re-rendering on the rightmost monitor (geom() always targets it) -- in NOFOCUS mode
           # so it does NOT yank focus off the workspace you just switched to. No-op when the dock
           # is hidden or already on its home monitor (so a home-monitor switch, which pin handles
           # correctly, does nothing here).
    [ "$(shownany)" = "true" ] || exit 0
    cur="$(curfront)"; { [ -z "$cur" ] || ! exists "$cur"; } && exit 0
    homeid=$($HC monitors -j | $J -r 'max_by(.x + (.width/(.scale//1))).id')
    curmon=$($J -r --arg a "$cur" 'first(.[]|select(.address==$a)).monitor' <<<"$CLIENTS")
    [ "$curmon" = "$homeid" ] && exit 0   # already home -> leave it (pin kept it correct)
    render "$cur" 0 1 ;;                   # re-home to the rightmost monitor, no focus steal
esac
