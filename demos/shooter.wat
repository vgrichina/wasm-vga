(module
  (import "env" "memory" (memory 4))
  (import "env" "sfx" (func $sfx (param i32)))
  (import "env" "note" (func $note (param i32 i32 i32 i32)))
  (import "env" "music" (func $music (param i32)))

  ;; ============================================================
  ;; STELLAR ASSAULT — Side-scrolling space shooter
  ;; ============================================================
  ;; Control block (harness):
  ;;   0x00: frame_counter (u32)
  ;;   0x04: mouse_x (u16), 0x06: mouse_y (u16)
  ;;   0x08: mouse_buttons (u8, bit0=left)
  ;;   0x0C: tick_ms (u32)
  ;; Palette: 0x0040 (768 bytes)
  ;; Framebuffer: 0x0340 (64000 bytes)
  ;;
  ;; Guest memory layout:
  ;;   0x10340  game state (32 bytes)
  ;;   0x10360  player (16 bytes)
  ;;   0x10370  player bullets (32 * 8 = 256 bytes)
  ;;   0x10470  enemies (32 * 16 = 512 bytes)
  ;;   0x10670  enemy bullets (48 * 8 = 384 bytes)
  ;;   0x107F0  particles (96 * 8 = 768 bytes)
  ;;   0x10AF0  powerups (4 * 8 = 32 bytes)
  ;;   0x10B10  stars layer 1 (40 * 4 = 160)
  ;;   0x10BB0  stars layer 2 (40 * 4 = 160)
  ;;   0x10C50  stars layer 3 (40 * 4 = 160)
  ;;   0x10CF0  sin table (256 bytes)
  ;;   0x10DF0  PRNG state (4 bytes)
  ;;   0x10E00  font data (96 * 8 = 768 bytes)
  ;;   0x11100  story text lines (512 bytes)
  ;;   0x11300  wave table (32 * 8 = 256 bytes)
  ;;   0x11400  fire buffer (80 * 50 = 4000 bytes)
  ;;   0x12388  title text
  ;; ============================================================

  ;; --- Constants ---
  ;; Game state offsets at 0x10340
  ;; +0: phase (u8): 0=story,1=planet,2=ship,3=title,4=press_fire,5=play,6=game_over
  ;; +2: phase_timer (u16)
  ;; +4: score (u32)
  ;; +8: lives (u8)
  ;; +9: power_level (u8)
  ;; +10: wave_idx (u8)
  ;; +11: wave_timer (u8)
  ;; +12: boss_active (u8)
  ;; +13: boss_hp (u8)
  ;; +14: boss_x (u16)
  ;; +16: boss_y (u16)
  ;; +18: boss_phase (u8)
  ;; +19: boss_timer (u8)
  ;; +20: shake_timer (u8)
  ;; +21: hit_msg_idx (u8)
  ;; +22: music_state (u8)
  ;; +23: prev_btn (u8)
  ;; +24: prev_keys (u8)
  ;; +26: prev_mouse_x (u16)
  ;; +28: prev_mouse_y (u16)

  ;; --- SFX helper: look up address from table and call $sfx ---
  (func $play_sfx (param $id i32)
    (call $sfx (i32.load (i32.add (i32.const 0x12BE0) (i32.mul (local.get $id) (i32.const 4)))))
  )

  ;; --- PRNG (xorshift32) ---
  (func $rand (result i32)
    (local $s i32)
    (local.set $s (i32.load (i32.const 0x10DF0)))
    (if (i32.eqz (local.get $s)) (then (local.set $s (i32.const 314159265))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 13))))
    (local.set $s (i32.xor (local.get $s) (i32.shr_u (local.get $s) (i32.const 17))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 5))))
    (i32.store (i32.const 0x10DF0) (local.get $s))
    (local.get $s)
  )

  ;; --- Sin table lookup (0-255 -> 0-255, center=128) ---
  (func $sin_tab (param $idx i32) (result i32)
    (i32.load8_u (i32.add (i32.const 0x10CF0) (i32.and (local.get $idx) (i32.const 255))))
  )

  ;; --- Sin approx for init ---
  (func $sin_approx (param $x f64) (result f64)
    (local $x2 f64) (local $x3 f64) (local $x5 f64) (local $x7 f64)
    (local.set $x (f64.sub (local.get $x)
      (f64.mul (f64.floor (f64.div (local.get $x) (f64.const 6.283185307))) (f64.const 6.283185307))))
    (if (f64.gt (local.get $x) (f64.const 3.141592653))
      (then (local.set $x (f64.sub (local.get $x) (f64.const 6.283185307)))))
    (local.set $x2 (f64.mul (local.get $x) (local.get $x)))
    (local.set $x3 (f64.mul (local.get $x2) (local.get $x)))
    (local.set $x5 (f64.mul (local.get $x3) (local.get $x2)))
    (local.set $x7 (f64.mul (local.get $x5) (local.get $x2)))
    (f64.sub (f64.add (local.get $x) (f64.div (local.get $x5) (f64.const 120.0)))
      (f64.add (f64.div (local.get $x3) (f64.const 6.0)) (f64.div (local.get $x7) (f64.const 5040.0))))
  )

  ;; --- put_pixel (x, y, color) - bounds checked ---
  (func $put_pixel (param $x i32) (param $y i32) (param $c i32)
    (if (i32.and
          (i32.and (i32.ge_s (local.get $x) (i32.const 0)) (i32.lt_s (local.get $x) (i32.const 320)))
          (i32.and (i32.ge_s (local.get $y) (i32.const 0)) (i32.lt_s (local.get $y) (i32.const 200))))
      (then
        (i32.store8
          (i32.add (i32.const 0x0340) (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x)))
          (local.get $c))
      )
    )
  )

  ;; --- draw_rect (x, y, w, h, color) ---
  (func $draw_rect (param $x i32) (param $y i32) (param $w i32) (param $h i32) (param $c i32)
    (local $dx i32) (local $dy i32)
    (local.set $dy (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_s (local.get $dy) (local.get $h)))
      (local.set $dx (i32.const 0))
      (block $done2 (loop $lp2
        (br_if $done2 (i32.ge_s (local.get $dx) (local.get $w)))
        (call $put_pixel
          (i32.add (local.get $x) (local.get $dx))
          (i32.add (local.get $y) (local.get $dy))
          (local.get $c))
        (local.set $dx (i32.add (local.get $dx) (i32.const 1)))
        (br $lp2)))
      (local.set $dy (i32.add (local.get $dy) (i32.const 1)))
      (br $lp)))
  )

  ;; --- Font pixel: char c, row r (0-7), col k (0-7) -> 0 or 1 ---
  (func $font_pixel (param $c i32) (param $r i32) (param $k i32) (result i32)
    (local $addr i32) (local $row_byte i32)
    ;; i64.store is little-endian: MSB of constant goes to byte 7, so row 0 = byte 7 = offset (7-r)
    (local.set $addr (i32.add (i32.const 0x10E00)
      (i32.add (i32.mul (i32.sub (local.get $c) (i32.const 32)) (i32.const 8)) (i32.sub (i32.const 7) (local.get $r)))))
    (local.set $row_byte (i32.load8_u (local.get $addr)))
    (i32.and (i32.shr_u (local.get $row_byte) (i32.sub (i32.const 7) (local.get $k))) (i32.const 1))
  )

  ;; --- draw_char at (x, y) with color, scale ---
  (func $draw_char (param $ch i32) (param $x i32) (param $y i32) (param $color i32) (param $scale i32)
    (local $r i32) (local $k i32) (local $sx i32) (local $sy i32)
    (if (i32.lt_s (local.get $ch) (i32.const 32)) (then (return)))
    (if (i32.gt_s (local.get $ch) (i32.const 127)) (then (return)))
    (local.set $r (i32.const 0))
    (block $rd (loop $rl
      (br_if $rd (i32.ge_u (local.get $r) (i32.const 8)))
      (local.set $k (i32.const 0))
      (block $kd (loop $kl
        (br_if $kd (i32.ge_u (local.get $k) (i32.const 8)))
        (if (call $font_pixel (local.get $ch) (local.get $r) (local.get $k))
          (then
            ;; draw scale x scale block
            (local.set $sy (i32.const 0))
            (block $syd (loop $syl
              (br_if $syd (i32.ge_s (local.get $sy) (local.get $scale)))
              (local.set $sx (i32.const 0))
              (block $sxd (loop $sxl
                (br_if $sxd (i32.ge_s (local.get $sx) (local.get $scale)))
                (call $put_pixel
                  (i32.add (local.get $x) (i32.add (i32.mul (local.get $k) (local.get $scale)) (local.get $sx)))
                  (i32.add (local.get $y) (i32.add (i32.mul (local.get $r) (local.get $scale)) (local.get $sy)))
                  (local.get $color))
                (local.set $sx (i32.add (local.get $sx) (i32.const 1)))
                (br $sxl)))
              (local.set $sy (i32.add (local.get $sy) (i32.const 1)))
              (br $syl)))
          )
        )
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $kl)))
      (local.set $r (i32.add (local.get $r) (i32.const 1)))
      (br $rl)))
  )

  ;; --- draw_string at addr, len, (x, y), color, scale ---
  (func $draw_string (param $addr i32) (param $len i32) (param $x i32) (param $y i32) (param $color i32) (param $scale i32)
    (local $i i32) (local $ch i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
      (local.set $ch (i32.load8_u (i32.add (local.get $addr) (local.get $i))))
      (if (local.get $ch)
        (then
          (call $draw_char (local.get $ch)
            (i32.add (local.get $x) (i32.mul (local.get $i) (i32.mul (i32.const 8) (local.get $scale))))
            (local.get $y) (local.get $color) (local.get $scale))
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; --- draw_number: render decimal at (x,y) ---
  (func $draw_number (param $n i32) (param $x i32) (param $y i32) (param $color i32) (param $scale i32)
    (local $digits i32) (local $tmp i32) (local $d i32) (local $px i32)
    ;; count digits
    (local.set $digits (i32.const 1))
    (local.set $tmp (local.get $n))
    (block $done (loop $lp
      (local.set $tmp (i32.div_u (local.get $tmp) (i32.const 10)))
      (br_if $done (i32.eqz (local.get $tmp)))
      (local.set $digits (i32.add (local.get $digits) (i32.const 1)))
      (br $lp)))
    ;; draw from right to left
    (local.set $tmp (local.get $n))
    (local.set $d (local.get $digits))
    (block $done2 (loop $lp2
      (br_if $done2 (i32.eqz (local.get $d)))
      (local.set $d (i32.sub (local.get $d) (i32.const 1)))
      (local.set $px (i32.add (local.get $x) (i32.mul (local.get $d) (i32.mul (i32.const 8) (local.get $scale)))))
      (call $draw_char
        (i32.add (i32.const 48) (i32.rem_u (local.get $tmp) (i32.const 10)))
        (local.get $px) (local.get $y) (local.get $color) (local.get $scale))
      (local.set $tmp (i32.div_u (local.get $tmp) (i32.const 10)))
      (br $lp2)))
  )

  ;; --- clear framebuffer to color ---
  (func $clear_fb (param $c i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 64000)))
      (i32.store8 (i32.add (i32.const 0x0340) (local.get $i)) (local.get $c))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; ============================================================
  ;; STARFIELD — 3 parallax layers
  ;; ============================================================
  ;; Each star: x(u16), y(u8), speed(u8) = 4 bytes
  ;; Layer 1: 0x10B10, Layer 2: 0x10BB0, Layer 3: 0x10C50
  ;; 40 stars per layer

  (func $init_stars
    (local $i i32) (local $addr i32)
    ;; Layer 1 (slow, dim)
    (local.set $i (i32.const 0))
    (block $d1 (loop $l1
      (br_if $d1 (i32.ge_u (local.get $i) (i32.const 40)))
      (local.set $addr (i32.add (i32.const 0x10B10) (i32.mul (local.get $i) (i32.const 4))))
      (i32.store16 (local.get $addr) (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFF)) (i32.const 320)))
      (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (i32.rem_u (i32.and (call $rand) (i32.const 0xFF)) (i32.const 200)))
      (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 1))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l1)))
    ;; Layer 2 (medium)
    (local.set $i (i32.const 0))
    (block $d2 (loop $l2
      (br_if $d2 (i32.ge_u (local.get $i) (i32.const 40)))
      (local.set $addr (i32.add (i32.const 0x10BB0) (i32.mul (local.get $i) (i32.const 4))))
      (i32.store16 (local.get $addr) (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFF)) (i32.const 320)))
      (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (i32.rem_u (i32.and (call $rand) (i32.const 0xFF)) (i32.const 200)))
      (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 2))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l2)))
    ;; Layer 3 (fast, bright)
    (local.set $i (i32.const 0))
    (block $d3 (loop $l3
      (br_if $d3 (i32.ge_u (local.get $i) (i32.const 40)))
      (local.set $addr (i32.add (i32.const 0x10C50) (i32.mul (local.get $i) (i32.const 4))))
      (i32.store16 (local.get $addr) (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFF)) (i32.const 320)))
      (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (i32.rem_u (i32.and (call $rand) (i32.const 0xFF)) (i32.const 200)))
      (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 4))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l3)))
  )

  (func $update_and_draw_stars
    (local $layer i32) (local $i i32) (local $base i32) (local $addr i32)
    (local $x i32) (local $y i32) (local $spd i32) (local $color i32)
    (local.set $layer (i32.const 0))
    (block $ld (loop $ll
      (br_if $ld (i32.ge_u (local.get $layer) (i32.const 3)))
      (local.set $base (i32.add (i32.const 0x10B10) (i32.mul (local.get $layer) (i32.const 160))))
      ;; color: layer 0=dim(5), 1=med(8), 2=bright(15)
      (local.set $color (select (i32.const 5)
        (select (i32.const 8) (i32.const 15) (i32.eq (local.get $layer) (i32.const 1)))
        (i32.eqz (local.get $layer))))
      (local.set $i (i32.const 0))
      (block $sd (loop $sl
        (br_if $sd (i32.ge_u (local.get $i) (i32.const 40)))
        (local.set $addr (i32.add (local.get $base) (i32.mul (local.get $i) (i32.const 4))))
        (local.set $x (i32.load16_u (local.get $addr)))
        (local.set $y (i32.load8_u (i32.add (local.get $addr) (i32.const 2))))
        (local.set $spd (i32.load8_u (i32.add (local.get $addr) (i32.const 3))))
        ;; move left
        (local.set $x (i32.sub (local.get $x) (local.get $spd)))
        (if (i32.lt_s (local.get $x) (i32.const 0))
          (then
            (local.set $x (i32.const 319))
            (local.set $y (i32.rem_u (i32.and (call $rand) (i32.const 0xFF)) (i32.const 200)))
          )
        )
        (i32.store16 (local.get $addr) (local.get $x))
        (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $y))
        ;; draw
        (call $put_pixel (local.get $x) (local.get $y) (local.get $color))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $sl)))
      (local.set $layer (i32.add (local.get $layer) (i32.const 1)))
      (br $ll)))
  )

  ;; ============================================================
  ;; PLAYER
  ;; ============================================================
  ;; 0x10360: px(u16), py(u16), fire_cooldown(u8), invuln(u8), anim(u8)

  (func $update_player
    (local $mx i32) (local $my i32) (local $btn i32) (local $keys i32)
    (local $px i32) (local $py i32) (local $cd i32) (local $inv i32)
    ;; read input
    (local.set $mx (i32.load16_u (i32.const 0x04)))
    (local.set $my (i32.load16_u (i32.const 0x06)))
    (local.set $btn (i32.load8_u (i32.const 0x08)))
    (local.set $keys (i32.load8_u (i32.const 0x10)))
    ;; current position
    (local.set $px (i32.load16_u (i32.const 0x10360)))
    (local.set $py (i32.load16_u (i32.const 0x10362)))
    ;; keyboard movement (3px/frame) — takes priority when any direction is held
    (if (i32.and (local.get $keys) (i32.const 0x0F))  ;; any direction key?
      (then
        ;; up (bit0)
        (if (i32.and (local.get $keys) (i32.const 1))
          (then (local.set $py (i32.sub (local.get $py) (i32.const 3)))))
        ;; down (bit1)
        (if (i32.and (local.get $keys) (i32.const 2))
          (then (local.set $py (i32.add (local.get $py) (i32.const 3)))))
        ;; left (bit2)
        (if (i32.and (local.get $keys) (i32.const 4))
          (then (local.set $px (i32.sub (local.get $px) (i32.const 3)))))
        ;; right (bit3)
        (if (i32.and (local.get $keys) (i32.const 8))
          (then (local.set $px (i32.add (local.get $px) (i32.const 3)))))
      )
      (else
        ;; no keys held — lerp toward mouse only if mouse has moved since last frame
        (local.set $mx (i32.load16_u (i32.const 0x04)))
        (local.set $my (i32.load16_u (i32.const 0x06)))
        (if (i32.or
              (i32.ne (local.get $mx) (i32.load16_u (i32.const 0x1035A)))
              (i32.ne (local.get $my) (i32.load16_u (i32.const 0x1035C))))
          (then
            (if (i32.lt_s (local.get $mx) (i32.const 8)) (then (local.set $mx (i32.const 8))))
            (if (i32.gt_s (local.get $mx) (i32.const 280)) (then (local.set $mx (i32.const 280))))
            (if (i32.lt_s (local.get $my) (i32.const 16)) (then (local.set $my (i32.const 16))))
            (if (i32.gt_s (local.get $my) (i32.const 190)) (then (local.set $my (i32.const 190))))
            (local.set $px (i32.add (local.get $px) (i32.shr_s (i32.sub (local.get $mx) (local.get $px)) (i32.const 2))))
            (local.set $py (i32.add (local.get $py) (i32.shr_s (i32.sub (local.get $my) (local.get $py)) (i32.const 2))))
          )
        )
      )
    )
    ;; clamp position
    (if (i32.lt_s (local.get $px) (i32.const 8)) (then (local.set $px (i32.const 8))))
    (if (i32.gt_s (local.get $px) (i32.const 280)) (then (local.set $px (i32.const 280))))
    (if (i32.lt_s (local.get $py) (i32.const 16)) (then (local.set $py (i32.const 16))))
    (if (i32.gt_s (local.get $py) (i32.const 190)) (then (local.set $py (i32.const 190))))
    (i32.store16 (i32.const 0x10360) (local.get $px))
    (i32.store16 (i32.const 0x10362) (local.get $py))
    ;; fire cooldown
    (local.set $cd (i32.load8_u (i32.const 0x10364)))
    (if (i32.gt_u (local.get $cd) (i32.const 0))
      (then (local.set $cd (i32.sub (local.get $cd) (i32.const 1)))))
    ;; click/space/enter to fire
    (if (i32.eqz (local.get $cd))
      (then
        (if (i32.or (i32.and (local.get $btn) (i32.const 1))
                    (i32.and (local.get $keys) (i32.const 48)))
          (then
            (call $spawn_player_bullet (local.get $px) (local.get $py))
            (call $play_sfx (i32.const 0))
            ;; power level 1+ = double shot
            (if (i32.ge_u (i32.load8_u (i32.const 0x10349)) (i32.const 1))
              (then
                (call $spawn_player_bullet (local.get $px) (i32.sub (local.get $py) (i32.const 6)))
                (call $spawn_player_bullet (local.get $px) (i32.add (local.get $py) (i32.const 6)))
              )
            )
            (local.set $cd (i32.const 6))
          )
        )
      )
    )
    (i32.store8 (i32.const 0x10364) (local.get $cd))
    ;; invulnerability timer
    (local.set $inv (i32.load8_u (i32.const 0x10365)))
    (if (i32.gt_u (local.get $inv) (i32.const 0))
      (then (i32.store8 (i32.const 0x10365) (i32.sub (local.get $inv) (i32.const 1)))))
  )

  (func $draw_player
    (local $px i32) (local $py i32) (local $inv i32) (local $frame i32)
    (local.set $px (i32.load16_u (i32.const 0x10360)))
    (local.set $py (i32.load16_u (i32.const 0x10362)))
    (local.set $inv (i32.load8_u (i32.const 0x10365)))
    (local.set $frame (i32.load (i32.const 0)))
    ;; blink when invulnerable
    (if (i32.and (i32.gt_u (local.get $inv) (i32.const 0)) (i32.and (local.get $frame) (i32.const 2)))
      (then (return)))
    ;; === Player ship (pointing right, vertically symmetrical) ===
    ;; Nose cone
    (call $put_pixel (i32.add (local.get $px) (i32.const 9)) (local.get $py) (i32.const 15))
    (call $put_pixel (i32.add (local.get $px) (i32.const 8)) (local.get $py) (i32.const 14))
    (call $put_pixel (i32.add (local.get $px) (i32.const 8)) (i32.sub (local.get $py) (i32.const 1)) (i32.const 11))
    (call $put_pixel (i32.add (local.get $px) (i32.const 8)) (i32.add (local.get $py) (i32.const 1)) (i32.const 11))
    ;; Fuselage (main body)
    (call $draw_rect (i32.sub (local.get $px) (i32.const 1)) (i32.sub (local.get $py) (i32.const 2)) (i32.const 10) (i32.const 5) (i32.const 11))
    ;; Body taper at rear
    (call $draw_rect (i32.sub (local.get $px) (i32.const 3)) (i32.sub (local.get $py) (i32.const 1)) (i32.const 2) (i32.const 3) (i32.const 11))
    ;; Cockpit canopy (bright highlight)
    (call $put_pixel (i32.add (local.get $px) (i32.const 5)) (local.get $py) (i32.const 15))
    (call $put_pixel (i32.add (local.get $px) (i32.const 6)) (local.get $py) (i32.const 14))
    (call $put_pixel (i32.add (local.get $px) (i32.const 4)) (local.get $py) (i32.const 14))
    ;; Wing roots (connect body to wings at ±3)
    (call $draw_rect (i32.sub (local.get $px) (i32.const 2)) (i32.sub (local.get $py) (i32.const 3)) (i32.const 5) (i32.const 1) (i32.const 9))
    (call $draw_rect (i32.sub (local.get $px) (i32.const 2)) (i32.add (local.get $py) (i32.const 3)) (i32.const 5) (i32.const 1) (i32.const 9))
    ;; Wings (symmetrical top/bottom — body is py-2..py+2, wings at ±4,±5)
    (call $draw_rect (i32.sub (local.get $px) (i32.const 2)) (i32.sub (local.get $py) (i32.const 5)) (i32.const 7) (i32.const 2) (i32.const 9))
    (call $draw_rect (i32.sub (local.get $px) (i32.const 2)) (i32.add (local.get $py) (i32.const 4)) (i32.const 7) (i32.const 2) (i32.const 9))
    ;; Wing tips
    (call $put_pixel (i32.add (local.get $px) (i32.const 5)) (i32.sub (local.get $py) (i32.const 5)) (i32.const 11))
    (call $put_pixel (i32.add (local.get $px) (i32.const 5)) (i32.add (local.get $py) (i32.const 5)) (i32.const 11))
    ;; Engine pods (symmetrical — at wing inner edge ±3,±4)
    (call $draw_rect (i32.sub (local.get $px) (i32.const 4)) (i32.sub (local.get $py) (i32.const 4)) (i32.const 3) (i32.const 2) (i32.const 9))
    (call $draw_rect (i32.sub (local.get $px) (i32.const 4)) (i32.add (local.get $py) (i32.const 3)) (i32.const 3) (i32.const 2) (i32.const 9))
    ;; Engine glow (animated, symmetrical)
    (call $put_pixel (i32.sub (local.get $px) (i32.const 5)) (i32.sub (local.get $py) (i32.const 4))
      (select (i32.const 40) (i32.const 36) (i32.and (local.get $frame) (i32.const 4))))
    (call $put_pixel (i32.sub (local.get $px) (i32.const 5)) (i32.add (local.get $py) (i32.const 4))
      (select (i32.const 40) (i32.const 36) (i32.and (local.get $frame) (i32.const 4))))
    (call $put_pixel (i32.sub (local.get $px) (i32.const 6)) (i32.sub (local.get $py) (i32.const 4))
      (select (i32.const 36) (i32.const 32) (i32.and (local.get $frame) (i32.const 4))))
    (call $put_pixel (i32.sub (local.get $px) (i32.const 6)) (i32.add (local.get $py) (i32.const 4))
      (select (i32.const 36) (i32.const 32) (i32.and (local.get $frame) (i32.const 4))))
    ;; Center engine glow
    (call $put_pixel (i32.sub (local.get $px) (i32.const 4)) (local.get $py)
      (select (i32.const 38) (i32.const 34) (i32.and (local.get $frame) (i32.const 2))))
    (call $put_pixel (i32.sub (local.get $px) (i32.const 5)) (local.get $py)
      (select (i32.const 36) (i32.const 32) (i32.and (local.get $frame) (i32.const 2))))
  )

  ;; ============================================================
  ;; PLAYER BULLETS
  ;; ============================================================
  ;; 32 entries at 0x10370, each 8 bytes: active(u8), pad(u8), x(u16), y(u16), dx(i8), dy(i8)

  (func $spawn_player_bullet (param $x i32) (param $y i32)
    (local $i i32) (local $addr i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 32)))
      (local.set $addr (i32.add (i32.const 0x10370) (i32.mul (local.get $i) (i32.const 8))))
      (if (i32.eqz (i32.load8_u (local.get $addr)))
        (then
          (i32.store8 (local.get $addr) (i32.const 1))
          (i32.store16 (i32.add (local.get $addr) (i32.const 2)) (i32.add (local.get $x) (i32.const 10)))
          (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $y))
          (i32.store8 (i32.add (local.get $addr) (i32.const 6)) (i32.const 6))  ;; dx
          (i32.store8 (i32.add (local.get $addr) (i32.const 7)) (i32.const 0))  ;; dy
          (return)
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  (func $update_player_bullets
    (local $i i32) (local $addr i32) (local $x i32) (local $y i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 32)))
      (local.set $addr (i32.add (i32.const 0x10370) (i32.mul (local.get $i) (i32.const 8))))
      (if (i32.load8_u (local.get $addr))
        (then
          (local.set $x (i32.add (i32.load16_u (i32.add (local.get $addr) (i32.const 2)))
            (i32.extend8_s (i32.load8_s (i32.add (local.get $addr) (i32.const 6))))))
          (local.set $y (i32.add (i32.load16_u (i32.add (local.get $addr) (i32.const 4)))
            (i32.extend8_s (i32.load8_s (i32.add (local.get $addr) (i32.const 7))))))
          (if (i32.gt_s (local.get $x) (i32.const 325))
            (then (i32.store8 (local.get $addr) (i32.const 0)))
            (else
              (i32.store16 (i32.add (local.get $addr) (i32.const 2)) (local.get $x))
              (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $y))
            )
          )
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  (func $draw_player_bullets
    (local $i i32) (local $addr i32) (local $x i32) (local $y i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 32)))
      (local.set $addr (i32.add (i32.const 0x10370) (i32.mul (local.get $i) (i32.const 8))))
      (if (i32.load8_u (local.get $addr))
        (then
          (local.set $x (i32.load16_u (i32.add (local.get $addr) (i32.const 2))))
          (local.set $y (i32.load16_u (i32.add (local.get $addr) (i32.const 4))))
          ;; 4x2 yellow bullet
          (call $put_pixel (local.get $x) (local.get $y) (i32.const 44))
          (call $put_pixel (i32.add (local.get $x) (i32.const 1)) (local.get $y) (i32.const 46))
          (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (local.get $y) (i32.const 46))
          (call $put_pixel (i32.add (local.get $x) (i32.const 3)) (local.get $y) (i32.const 44))
          (call $put_pixel (local.get $x) (i32.add (local.get $y) (i32.const 1)) (i32.const 44))
          (call $put_pixel (i32.add (local.get $x) (i32.const 1)) (i32.add (local.get $y) (i32.const 1)) (i32.const 46))
          (call $put_pixel (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 1)) (i32.const 46))
          (call $put_pixel (i32.add (local.get $x) (i32.const 3)) (i32.add (local.get $y) (i32.const 1)) (i32.const 44))
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; ============================================================
  ;; ENEMIES
  ;; ============================================================
  ;; 32 entries at 0x10470, each 16 bytes:
  ;; +0: active(u8), +1: type(u8), +2: hp(u8), +3: anim(u8)
  ;; +4: x(u16), +6: y(u16), +8: base_y(u16), +10: wave_phase(u16)
  ;; +12: fire_timer(u8), +13: pad(3)

  (func $spawn_enemy (param $type i32) (param $x i32) (param $y i32)
    (local $i i32) (local $addr i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 32)))
      (local.set $addr (i32.add (i32.const 0x10470) (i32.mul (local.get $i) (i32.const 16))))
      (if (i32.eqz (i32.load8_u (local.get $addr)))
        (then
          (i32.store8 (local.get $addr) (i32.const 1))           ;; active
          (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $type))
          ;; hp based on type: 0=1hp, 1=2hp, 2=3hp
          (i32.store8 (i32.add (local.get $addr) (i32.const 2))
            (i32.add (local.get $type) (i32.const 1)))
          (i32.store8 (i32.add (local.get $addr) (i32.const 3)) (i32.const 0))
          (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $x))
          (i32.store16 (i32.add (local.get $addr) (i32.const 6)) (local.get $y))
          (i32.store16 (i32.add (local.get $addr) (i32.const 8)) (local.get $y))  ;; base_y
          (i32.store16 (i32.add (local.get $addr) (i32.const 10))
            (i32.and (call $rand) (i32.const 255)))  ;; random wave phase
          (i32.store8 (i32.add (local.get $addr) (i32.const 12))
            (i32.add (i32.const 30) (i32.and (call $rand) (i32.const 31))))  ;; fire timer
          (return)
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  (func $update_enemies
    (local $i i32) (local $addr i32) (local $x i32) (local $y i32) (local $type i32)
    (local $base_y i32) (local $phase i32) (local $wave_y i32) (local $ft i32)
    (local $frame i32)
    (local.set $frame (i32.load (i32.const 0)))
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 32)))
      (local.set $addr (i32.add (i32.const 0x10470) (i32.mul (local.get $i) (i32.const 16))))
      (if (i32.load8_u (local.get $addr))
        (then
          (local.set $type (i32.load8_u (i32.add (local.get $addr) (i32.const 1))))
          (local.set $x (i32.load16_u (i32.add (local.get $addr) (i32.const 4))))
          (local.set $base_y (i32.load16_u (i32.add (local.get $addr) (i32.const 8))))
          (local.set $phase (i32.load16_u (i32.add (local.get $addr) (i32.const 10))))
          ;; move left: type 0=1px, type 1=2px, type 2=1px (heavy)
          (local.set $x (i32.sub (local.get $x)
            (select (i32.const 2) (i32.const 1) (i32.eq (local.get $type) (i32.const 1)))))
          ;; sine wave y
          (local.set $wave_y (i32.sub
            (i32.shr_u (call $sin_tab (i32.add (local.get $phase) (i32.mul (local.get $frame) (i32.const 2)))) (i32.const 2))
            (i32.const 32)))
          (local.set $y (i32.add (local.get $base_y) (local.get $wave_y)))
          ;; clamp y
          (if (i32.lt_s (local.get $y) (i32.const 10)) (then (local.set $y (i32.const 10))))
          (if (i32.gt_s (local.get $y) (i32.const 190)) (then (local.set $y (i32.const 190))))
          ;; deactivate if off screen left
          (if (i32.lt_s (local.get $x) (i32.const -16))
            (then (i32.store8 (local.get $addr) (i32.const 0)))
            (else
              (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $x))
              (i32.store16 (i32.add (local.get $addr) (i32.const 6)) (local.get $y))
              ;; fire timer
              (local.set $ft (i32.load8_u (i32.add (local.get $addr) (i32.const 12))))
              (if (i32.gt_u (local.get $ft) (i32.const 0))
                (then
                  (i32.store8 (i32.add (local.get $addr) (i32.const 12)) (i32.sub (local.get $ft) (i32.const 1)))
                )
                (else
                  ;; fire!
                  (if (i32.and (i32.ge_s (local.get $x) (i32.const 0)) (i32.lt_s (local.get $x) (i32.const 320)))
                    (then (call $spawn_enemy_bullet (local.get $x) (local.get $y))))
                  (i32.store8 (i32.add (local.get $addr) (i32.const 12))
                    (i32.add (i32.const 40) (i32.and (call $rand) (i32.const 31))))
                )
              )
            )
          )
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  (func $draw_enemies
    (local $i i32) (local $addr i32) (local $x i32) (local $y i32) (local $type i32) (local $c i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 32)))
      (local.set $addr (i32.add (i32.const 0x10470) (i32.mul (local.get $i) (i32.const 16))))
      (if (i32.load8_u (local.get $addr))
        (then
          (local.set $type (i32.load8_u (i32.add (local.get $addr) (i32.const 1))))
          (local.set $x (i32.load16_u (i32.add (local.get $addr) (i32.const 4))))
          (local.set $y (i32.load16_u (i32.add (local.get $addr) (i32.const 6))))
          ;; type 0: red fighter — diamond with swept wings
          (if (i32.eqz (local.get $type))
            (then
              ;; Diamond core
              (call $draw_rect (i32.sub (local.get $x) (i32.const 1)) (i32.sub (local.get $y) (i32.const 2)) (i32.const 5) (i32.const 5) (i32.const 22))
              (call $draw_rect (i32.sub (local.get $x) (i32.const 4)) (i32.sub (local.get $y) (i32.const 1)) (i32.const 3) (i32.const 3) (i32.const 24))
              ;; Nose spike
              (call $put_pixel (i32.sub (local.get $x) (i32.const 5)) (local.get $y) (i32.const 24))
              (call $put_pixel (i32.sub (local.get $x) (i32.const 6)) (local.get $y) (i32.const 20))
              ;; Swept wings (symmetrical)
              (call $draw_rect (i32.add (local.get $x) (i32.const 1)) (i32.sub (local.get $y) (i32.const 4)) (i32.const 4) (i32.const 2) (i32.const 20))
              (call $draw_rect (i32.add (local.get $x) (i32.const 1)) (i32.add (local.get $y) (i32.const 3)) (i32.const 4) (i32.const 2) (i32.const 20))
              ;; Wing tips
              (call $put_pixel (i32.add (local.get $x) (i32.const 5)) (i32.sub (local.get $y) (i32.const 5)) (i32.const 24))
              (call $put_pixel (i32.add (local.get $x) (i32.const 5)) (i32.add (local.get $y) (i32.const 5)) (i32.const 24))
              ;; Cockpit
              (call $put_pixel (i32.sub (local.get $x) (i32.const 2)) (local.get $y) (i32.const 15))
              (call $put_pixel (i32.sub (local.get $x) (i32.const 3)) (local.get $y) (i32.const 44))
            )
          )
          ;; type 1: green interceptor — sleek with angled fins
          (if (i32.eq (local.get $type) (i32.const 1))
            (then
              ;; Fuselage
              (call $draw_rect (i32.sub (local.get $x) (i32.const 5)) (i32.sub (local.get $y) (i32.const 1)) (i32.const 10) (i32.const 3) (i32.const 28))
              ;; Nose
              (call $put_pixel (i32.sub (local.get $x) (i32.const 6)) (local.get $y) (i32.const 26))
              (call $put_pixel (i32.sub (local.get $x) (i32.const 7)) (local.get $y) (i32.const 28))
              ;; Wider mid-section
              (call $draw_rect (i32.sub (local.get $x) (i32.const 2)) (i32.sub (local.get $y) (i32.const 2)) (i32.const 6) (i32.const 5) (i32.const 26))
              ;; Angled fins (symmetrical)
              (call $draw_rect (i32.add (local.get $x) (i32.const 2)) (i32.sub (local.get $y) (i32.const 5)) (i32.const 2) (i32.const 3) (i32.const 28))
              (call $draw_rect (i32.add (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 3)) (i32.const 2) (i32.const 3) (i32.const 28))
              (call $put_pixel (i32.add (local.get $x) (i32.const 4)) (i32.sub (local.get $y) (i32.const 6)) (i32.const 26))
              (call $put_pixel (i32.add (local.get $x) (i32.const 4)) (i32.add (local.get $y) (i32.const 6)) (i32.const 26))
              ;; Engine glow
              (call $put_pixel (i32.add (local.get $x) (i32.const 5)) (local.get $y) (i32.const 36))
              ;; Cockpit
              (call $put_pixel (i32.sub (local.get $x) (i32.const 4)) (local.get $y) (i32.const 15))
            )
          )
          ;; type 2: purple heavy cruiser — wide armored body
          (if (i32.eq (local.get $type) (i32.const 2))
            (then
              ;; Outer hull
              (call $draw_rect (i32.sub (local.get $x) (i32.const 6)) (i32.sub (local.get $y) (i32.const 5)) (i32.const 14) (i32.const 11) (i32.const 30))
              ;; Inner armor
              (call $draw_rect (i32.sub (local.get $x) (i32.const 4)) (i32.sub (local.get $y) (i32.const 3)) (i32.const 10) (i32.const 7) (i32.const 31))
              ;; Nose wedge
              (call $draw_rect (i32.sub (local.get $x) (i32.const 7)) (i32.sub (local.get $y) (i32.const 2)) (i32.const 2) (i32.const 5) (i32.const 31))
              (call $put_pixel (i32.sub (local.get $x) (i32.const 8)) (local.get $y) (i32.const 30))
              ;; Gun turrets (symmetrical)
              (call $draw_rect (i32.sub (local.get $x) (i32.const 8)) (i32.sub (local.get $y) (i32.const 4)) (i32.const 3) (i32.const 2) (i32.const 22))
              (call $draw_rect (i32.sub (local.get $x) (i32.const 8)) (i32.add (local.get $y) (i32.const 3)) (i32.const 3) (i32.const 2) (i32.const 22))
              ;; Gun barrels
              (call $put_pixel (i32.sub (local.get $x) (i32.const 9)) (i32.sub (local.get $y) (i32.const 3)) (i32.const 44))
              (call $put_pixel (i32.sub (local.get $x) (i32.const 9)) (i32.add (local.get $y) (i32.const 3)) (i32.const 44))
              ;; Bridge eyes (symmetrical)
              (call $put_pixel (i32.sub (local.get $x) (i32.const 2)) (i32.sub (local.get $y) (i32.const 1)) (i32.const 15))
              (call $put_pixel (i32.sub (local.get $x) (i32.const 2)) (i32.add (local.get $y) (i32.const 1)) (i32.const 15))
              ;; Engine blocks (symmetrical)
              (call $draw_rect (i32.add (local.get $x) (i32.const 6)) (i32.sub (local.get $y) (i32.const 4)) (i32.const 3) (i32.const 3) (i32.const 22))
              (call $draw_rect (i32.add (local.get $x) (i32.const 6)) (i32.add (local.get $y) (i32.const 2)) (i32.const 3) (i32.const 3) (i32.const 22))
            )
          )
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; ============================================================
  ;; ENEMY BULLETS
  ;; ============================================================
  ;; 48 entries at 0x10670, each 8 bytes: active(u8), pad(u8), x(u16), y(u16), dx(i8), dy(i8)

  (func $spawn_enemy_bullet (param $x i32) (param $y i32)
    (local $i i32) (local $addr i32) (local $dy i32)
    ;; aim slightly toward player
    (local.set $dy (i32.shr_s (i32.sub (i32.load16_u (i32.const 0x10362)) (local.get $y)) (i32.const 4)))
    (if (i32.gt_s (local.get $dy) (i32.const 3)) (then (local.set $dy (i32.const 3))))
    (if (i32.lt_s (local.get $dy) (i32.const -3)) (then (local.set $dy (i32.const -3))))
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 48)))
      (local.set $addr (i32.add (i32.const 0x10670) (i32.mul (local.get $i) (i32.const 8))))
      (if (i32.eqz (i32.load8_u (local.get $addr)))
        (then
          (i32.store8 (local.get $addr) (i32.const 1))
          (i32.store16 (i32.add (local.get $addr) (i32.const 2)) (local.get $x))
          (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $y))
          (i32.store8 (i32.add (local.get $addr) (i32.const 6)) (i32.const 252))  ;; dx = -4 (signed byte)
          (i32.store8 (i32.add (local.get $addr) (i32.const 7)) (local.get $dy))
          (return)
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  (func $update_enemy_bullets
    (local $i i32) (local $addr i32) (local $x i32) (local $y i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 48)))
      (local.set $addr (i32.add (i32.const 0x10670) (i32.mul (local.get $i) (i32.const 8))))
      (if (i32.load8_u (local.get $addr))
        (then
          (local.set $x (i32.add (i32.load16_u (i32.add (local.get $addr) (i32.const 2)))
            (i32.extend8_s (i32.load8_s (i32.add (local.get $addr) (i32.const 6))))))
          (local.set $y (i32.add (i32.load16_u (i32.add (local.get $addr) (i32.const 4)))
            (i32.extend8_s (i32.load8_s (i32.add (local.get $addr) (i32.const 7))))))
          (if (i32.or (i32.lt_s (local.get $x) (i32.const -5))
                (i32.or (i32.gt_s (local.get $y) (i32.const 205)) (i32.lt_s (local.get $y) (i32.const -5))))
            (then (i32.store8 (local.get $addr) (i32.const 0)))
            (else
              (i32.store16 (i32.add (local.get $addr) (i32.const 2)) (local.get $x))
              (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $y))
            )
          )
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  (func $draw_enemy_bullets
    (local $i i32) (local $addr i32) (local $x i32) (local $y i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 48)))
      (local.set $addr (i32.add (i32.const 0x10670) (i32.mul (local.get $i) (i32.const 8))))
      (if (i32.load8_u (local.get $addr))
        (then
          (local.set $x (i32.load16_u (i32.add (local.get $addr) (i32.const 2))))
          (local.set $y (i32.load16_u (i32.add (local.get $addr) (i32.const 4))))
          ;; 3x3 red bullet
          (call $draw_rect (local.get $x) (local.get $y) (i32.const 3) (i32.const 3) (i32.const 36))
          (call $put_pixel (i32.add (local.get $x) (i32.const 1)) (i32.add (local.get $y) (i32.const 1)) (i32.const 40))
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; ============================================================
  ;; PARTICLES
  ;; ============================================================
  ;; 96 entries at 0x107F0, each 8 bytes: active(u8), color(u8), x(u16), y(u16), dx(i8), dy(i8)

  (func $spawn_explosion (param $x i32) (param $y i32) (param $count i32)
    (local $n i32) (local $i i32) (local $addr i32) (local $dx i32) (local $dy i32)
    (local.set $n (i32.const 0))
    (block $ndone (loop $nlp
      (br_if $ndone (i32.ge_u (local.get $n) (local.get $count)))
      ;; find free slot
      (local.set $i (i32.const 0))
      (block $done (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 96)))
        (local.set $addr (i32.add (i32.const 0x107F0) (i32.mul (local.get $i) (i32.const 8))))
        (if (i32.eqz (i32.load8_u (local.get $addr)))
          (then
            (i32.store8 (local.get $addr) (i32.add (i32.const 15) (i32.and (call $rand) (i32.const 31))))  ;; lifetime as "active"
            (i32.store8 (i32.add (local.get $addr) (i32.const 1))
              (i32.add (i32.const 32) (i32.and (call $rand) (i32.const 15))))  ;; color (fire range)
            (i32.store16 (i32.add (local.get $addr) (i32.const 2)) (local.get $x))
            (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $y))
            ;; random velocity -3..3
            (local.set $dx (i32.sub (i32.and (call $rand) (i32.const 7)) (i32.const 3)))
            (local.set $dy (i32.sub (i32.and (call $rand) (i32.const 7)) (i32.const 3)))
            (i32.store8 (i32.add (local.get $addr) (i32.const 6)) (local.get $dx))
            (i32.store8 (i32.add (local.get $addr) (i32.const 7)) (local.get $dy))
            (local.set $i (i32.const 96))  ;; break
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
      (local.set $n (i32.add (local.get $n) (i32.const 1)))
      (br $nlp)))
  )

  ;; Spawn green/cyan burst for powerup collect
  (func $spawn_powerup_burst (param $x i32) (param $y i32) (param $count i32)
    (local $n i32) (local $i i32) (local $addr i32) (local $dx i32) (local $dy i32)
    (local.set $n (i32.const 0))
    (block $ndone (loop $nlp
      (br_if $ndone (i32.ge_u (local.get $n) (local.get $count)))
      (local.set $i (i32.const 0))
      (block $done (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 96)))
        (local.set $addr (i32.add (i32.const 0x107F0) (i32.mul (local.get $i) (i32.const 8))))
        (if (i32.eqz (i32.load8_u (local.get $addr)))
          (then
            (i32.store8 (local.get $addr) (i32.add (i32.const 20) (i32.and (call $rand) (i32.const 31))))
            ;; green/cyan color range 64-79
            (i32.store8 (i32.add (local.get $addr) (i32.const 1))
              (i32.add (i32.const 64) (i32.and (call $rand) (i32.const 15))))
            (i32.store16 (i32.add (local.get $addr) (i32.const 2)) (local.get $x))
            (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $y))
            ;; wider velocity spread -4..4
            (local.set $dx (i32.sub (i32.and (call $rand) (i32.const 7)) (i32.const 4)))
            (local.set $dy (i32.sub (i32.and (call $rand) (i32.const 7)) (i32.const 4)))
            (i32.store8 (i32.add (local.get $addr) (i32.const 6)) (local.get $dx))
            (i32.store8 (i32.add (local.get $addr) (i32.const 7)) (local.get $dy))
            (local.set $i (i32.const 96))
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
      (local.set $n (i32.add (local.get $n) (i32.const 1)))
      (br $nlp)))
  )

  (func $update_and_draw_particles
    (local $i i32) (local $addr i32) (local $life i32) (local $x i32) (local $y i32) (local $c i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 96)))
      (local.set $addr (i32.add (i32.const 0x107F0) (i32.mul (local.get $i) (i32.const 8))))
      (local.set $life (i32.load8_u (local.get $addr)))
      (if (local.get $life)
        (then
          ;; decrement life
          (local.set $life (i32.sub (local.get $life) (i32.const 1)))
          (i32.store8 (local.get $addr) (local.get $life))
          (if (local.get $life)
            (then
              ;; move
              (local.set $x (i32.add (i32.load16_u (i32.add (local.get $addr) (i32.const 2)))
                (i32.extend8_s (i32.load8_s (i32.add (local.get $addr) (i32.const 6))))))
              (local.set $y (i32.add (i32.load16_u (i32.add (local.get $addr) (i32.const 4)))
                (i32.extend8_s (i32.load8_s (i32.add (local.get $addr) (i32.const 7))))))
              (i32.store16 (i32.add (local.get $addr) (i32.const 2)) (local.get $x))
              (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $y))
              ;; draw
              (local.set $c (i32.load8_u (i32.add (local.get $addr) (i32.const 1))))
              (call $put_pixel (local.get $x) (local.get $y) (local.get $c))
            )
          )
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; ============================================================
  ;; POWERUPS
  ;; ============================================================
  ;; 4 entries at 0x10AF0, each 8 bytes: active(u8), type(u8), x(u16), y(u16), pad(2)

  (func $spawn_powerup (param $x i32) (param $y i32)
    (local $i i32) (local $addr i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 4)))
      (local.set $addr (i32.add (i32.const 0x10AF0) (i32.mul (local.get $i) (i32.const 8))))
      (if (i32.eqz (i32.load8_u (local.get $addr)))
        (then
          (i32.store8 (local.get $addr) (i32.const 1))
          (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (i32.const 0))  ;; power type
          (i32.store16 (i32.add (local.get $addr) (i32.const 2)) (local.get $x))
          (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $y))
          (return)
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  (func $update_and_draw_powerups
    (local $i i32) (local $addr i32) (local $x i32) (local $y i32) (local $frame i32)
    (local.set $frame (i32.load (i32.const 0)))
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 4)))
      (local.set $addr (i32.add (i32.const 0x10AF0) (i32.mul (local.get $i) (i32.const 8))))
      (if (i32.load8_u (local.get $addr))
        (then
          (local.set $x (i32.sub (i32.load16_u (i32.add (local.get $addr) (i32.const 2))) (i32.const 1)))
          (local.set $y (i32.load16_u (i32.add (local.get $addr) (i32.const 4))))
          (if (i32.lt_s (local.get $x) (i32.const -10))
            (then (i32.store8 (local.get $addr) (i32.const 0)))
            (else
              (i32.store16 (i32.add (local.get $addr) (i32.const 2)) (local.get $x))
              ;; sparkle trail — spawn 1 green particle every 4 frames
              (if (i32.eqz (i32.and (local.get $frame) (i32.const 3)))
                (then (call $spawn_powerup_burst (local.get $x) (local.get $y) (i32.const 1))))
              ;; draw: pulsing "P" icon with green glow
              (call $draw_rect (i32.sub (local.get $x) (i32.const 6)) (i32.sub (local.get $y) (i32.const 6))
                (i32.const 13) (i32.const 13)
                (i32.add (i32.const 64) (i32.and (i32.shr_u (local.get $frame) (i32.const 2)) (i32.const 7))))
              (call $draw_rect (i32.sub (local.get $x) (i32.const 4)) (i32.sub (local.get $y) (i32.const 4))
                (i32.const 9) (i32.const 9)
                (select (i32.const 74) (i32.const 70) (i32.and (local.get $frame) (i32.const 8))))
              (call $draw_char (i32.const 80) ;; 'P'
                (i32.sub (local.get $x) (i32.const 3)) (i32.sub (local.get $y) (i32.const 3))
                (i32.const 15) (i32.const 1))
            )
          )
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; ============================================================
  ;; COLLISION DETECTION
  ;; ============================================================

  ;; Player bullets vs enemies
  (func $check_bullet_enemy
    (local $bi i32) (local $ei i32) (local $baddr i32) (local $eaddr i32)
    (local $bx i32) (local $by i32) (local $ex i32) (local $ey i32)
    (local $hp i32) (local $score i32) (local $type i32)
    (local.set $bi (i32.const 0))
    (block $bd (loop $bl
      (br_if $bd (i32.ge_u (local.get $bi) (i32.const 32)))
      (local.set $baddr (i32.add (i32.const 0x10370) (i32.mul (local.get $bi) (i32.const 8))))
      (if (i32.load8_u (local.get $baddr))
        (then
          (local.set $bx (i32.load16_u (i32.add (local.get $baddr) (i32.const 2))))
          (local.set $by (i32.load16_u (i32.add (local.get $baddr) (i32.const 4))))
          (local.set $ei (i32.const 0))
          (block $ed (loop $el
            (br_if $ed (i32.ge_u (local.get $ei) (i32.const 32)))
            (local.set $eaddr (i32.add (i32.const 0x10470) (i32.mul (local.get $ei) (i32.const 16))))
            (if (i32.load8_u (local.get $eaddr))
              (then
                (local.set $ex (i32.load16_u (i32.add (local.get $eaddr) (i32.const 4))))
                (local.set $ey (i32.load16_u (i32.add (local.get $eaddr) (i32.const 6))))
                ;; AABB: bullet 4x2 vs enemy ~12x10
                (if (i32.and
                      (i32.and (i32.lt_s (i32.sub (local.get $bx) (local.get $ex)) (i32.const 8))
                               (i32.gt_s (i32.sub (local.get $bx) (local.get $ex)) (i32.const -8)))
                      (i32.and (i32.lt_s (i32.sub (local.get $by) (local.get $ey)) (i32.const 6))
                               (i32.gt_s (i32.sub (local.get $by) (local.get $ey)) (i32.const -6))))
                  (then
                    ;; hit! deactivate bullet
                    (i32.store8 (local.get $baddr) (i32.const 0))
                    ;; damage enemy
                    (local.set $hp (i32.sub (i32.load8_u (i32.add (local.get $eaddr) (i32.const 2))) (i32.const 1)))
                    (if (i32.le_s (local.get $hp) (i32.const 0))
                      (then
                        ;; enemy destroyed
                        (i32.store8 (local.get $eaddr) (i32.const 0))
                        (call $spawn_explosion (local.get $ex) (local.get $ey) (i32.const 12))
                        (call $play_sfx (i32.const 1))
                        ;; score: type+1 * 100
                        (local.set $type (i32.load8_u (i32.add (local.get $eaddr) (i32.const 1))))
                        (local.set $score (i32.load (i32.const 0x10344)))
                        (i32.store (i32.const 0x10344)
                          (i32.add (local.get $score) (i32.mul (i32.add (local.get $type) (i32.const 1)) (i32.const 100))))
                        ;; maybe spawn powerup (1 in 8 chance)
                        (if (i32.eqz (i32.and (call $rand) (i32.const 7)))
                          (then (call $spawn_powerup (local.get $ex) (local.get $ey))))
                        ;; screen shake
                        (i32.store8 (i32.const 0x10354) (i32.const 4))
                      )
                      (else
                        (i32.store8 (i32.add (local.get $eaddr) (i32.const 2)) (local.get $hp))
                        ;; small hit spark
                        (call $spawn_explosion (local.get $bx) (local.get $by) (i32.const 3))
                      )
                    )
                    ;; break inner loop
                    (local.set $ei (i32.const 32))
                  )
                )
              )
            )
            (local.set $ei (i32.add (local.get $ei) (i32.const 1)))
            (br $el)))
        )
      )
      (local.set $bi (i32.add (local.get $bi) (i32.const 1)))
      (br $bl)))
  )

  ;; Enemy bullets vs player
  (func $check_enemy_player
    (local $i i32) (local $addr i32) (local $bx i32) (local $by i32)
    (local $px i32) (local $py i32) (local $lives i32)
    ;; skip if invulnerable
    (if (i32.gt_u (i32.load8_u (i32.const 0x10365)) (i32.const 0)) (then (return)))
    (local.set $px (i32.load16_u (i32.const 0x10360)))
    (local.set $py (i32.load16_u (i32.const 0x10362)))
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 48)))
      (local.set $addr (i32.add (i32.const 0x10670) (i32.mul (local.get $i) (i32.const 8))))
      (if (i32.load8_u (local.get $addr))
        (then
          (local.set $bx (i32.load16_u (i32.add (local.get $addr) (i32.const 2))))
          (local.set $by (i32.load16_u (i32.add (local.get $addr) (i32.const 4))))
          ;; AABB: bullet 3x3 vs player ~16x10
          (if (i32.and
                (i32.and (i32.lt_s (i32.sub (local.get $bx) (local.get $px)) (i32.const 10))
                         (i32.gt_s (i32.sub (local.get $bx) (local.get $px)) (i32.const -10)))
                (i32.and (i32.lt_s (i32.sub (local.get $by) (local.get $py)) (i32.const 7))
                         (i32.gt_s (i32.sub (local.get $by) (local.get $py)) (i32.const -7))))
            (then
              ;; hit!
              (i32.store8 (local.get $addr) (i32.const 0))
              ;; massive explosion centered on player
              (call $spawn_explosion (local.get $px) (local.get $py) (i32.const 48))
              (call $spawn_explosion (i32.sub (local.get $px) (i32.const 12)) (i32.sub (local.get $py) (i32.const 10)) (i32.const 16))
              (call $spawn_explosion (i32.add (local.get $px) (i32.const 8)) (i32.add (local.get $py) (i32.const 10)) (i32.const 16))
              (call $spawn_explosion (i32.sub (local.get $px) (i32.const 6)) (i32.add (local.get $py) (i32.const 12)) (i32.const 12))
              (call $spawn_explosion (i32.add (local.get $px) (i32.const 10)) (i32.sub (local.get $py) (i32.const 8)) (i32.const 12))
              (call $play_sfx (i32.const 3))
              (call $play_sfx (i32.const 1))  ;; layer explosion sfx on top
              (i32.store8 (i32.const 0x10365) (i32.const 90))  ;; invuln for 1.5s
              (i32.store8 (i32.const 0x10354) (i32.const 20))  ;; massive shake
              ;; pick a random hit message (0-2) and store index at 0x10355
              (i32.store8 (i32.const 0x10355) (i32.rem_u (i32.and (call $rand) (i32.const 0xFF)) (i32.const 3)))
              ;; lose life
              (local.set $lives (i32.load8_u (i32.const 0x10348)))
              (if (i32.gt_u (local.get $lives) (i32.const 0))
                (then
                  (i32.store8 (i32.const 0x10348) (i32.sub (local.get $lives) (i32.const 1)))
                  ;; reset power
                  (i32.store8 (i32.const 0x10349) (i32.const 0))
                )
                (else
                  ;; game over
                  (call $music (i32.const 0x12600))
                  (i32.store8 (i32.const 0x10340) (i32.const 6))
                  (i32.store16 (i32.const 0x10342) (i32.const 0))
                )
              )
              (return)
            )
          )
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; Enemy ships vs player
  (func $check_ship_player
    (local $i i32) (local $addr i32) (local $ex i32) (local $ey i32)
    (local $px i32) (local $py i32) (local $lives i32)
    ;; skip if invulnerable
    (if (i32.gt_u (i32.load8_u (i32.const 0x10365)) (i32.const 0)) (then (return)))
    (local.set $px (i32.load16_u (i32.const 0x10360)))
    (local.set $py (i32.load16_u (i32.const 0x10362)))
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 32)))
      (local.set $addr (i32.add (i32.const 0x10470) (i32.mul (local.get $i) (i32.const 16))))
      (if (i32.load8_u (local.get $addr))
        (then
          (local.set $ex (i32.load16_u (i32.add (local.get $addr) (i32.const 4))))
          (local.set $ey (i32.load16_u (i32.add (local.get $addr) (i32.const 6))))
          ;; AABB: enemy ~12x10 vs player ~16x10
          (if (i32.and
                (i32.and (i32.lt_s (i32.sub (local.get $ex) (local.get $px)) (i32.const 14))
                         (i32.gt_s (i32.sub (local.get $ex) (local.get $px)) (i32.const -14)))
                (i32.and (i32.lt_s (i32.sub (local.get $ey) (local.get $py)) (i32.const 10))
                         (i32.gt_s (i32.sub (local.get $ey) (local.get $py)) (i32.const -10))))
            (then
              ;; destroy enemy
              (i32.store8 (local.get $addr) (i32.const 0))
              ;; explosion on both
              (call $spawn_explosion (local.get $ex) (local.get $ey) (i32.const 32))
              (call $spawn_explosion (local.get $px) (local.get $py) (i32.const 48))
              (call $spawn_explosion (i32.sub (local.get $px) (i32.const 12)) (i32.sub (local.get $py) (i32.const 10)) (i32.const 16))
              (call $spawn_explosion (i32.add (local.get $px) (i32.const 8)) (i32.add (local.get $py) (i32.const 10)) (i32.const 16))
              (call $play_sfx (i32.const 3))
              (call $play_sfx (i32.const 1))
              (i32.store8 (i32.const 0x10365) (i32.const 90))  ;; invuln 1.5s
              (i32.store8 (i32.const 0x10354) (i32.const 20))  ;; screen shake
              (i32.store8 (i32.const 0x10355) (i32.rem_u (i32.and (call $rand) (i32.const 0xFF)) (i32.const 3)))
              ;; lose life
              (local.set $lives (i32.load8_u (i32.const 0x10348)))
              (if (i32.gt_u (local.get $lives) (i32.const 0))
                (then
                  (i32.store8 (i32.const 0x10348) (i32.sub (local.get $lives) (i32.const 1)))
                  (i32.store8 (i32.const 0x10349) (i32.const 0))  ;; reset power
                )
                (else
                  (call $music (i32.const 0x12600))
                  (i32.store8 (i32.const 0x10340) (i32.const 6))
                  (i32.store16 (i32.const 0x10342) (i32.const 0))
                )
              )
              (return)
            )
          )
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; Powerup vs player
  (func $check_powerup_player
    (local $i i32) (local $addr i32) (local $ux i32) (local $uy i32)
    (local $px i32) (local $py i32) (local $pl i32)
    (local.set $px (i32.load16_u (i32.const 0x10360)))
    (local.set $py (i32.load16_u (i32.const 0x10362)))
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 4)))
      (local.set $addr (i32.add (i32.const 0x10AF0) (i32.mul (local.get $i) (i32.const 8))))
      (if (i32.load8_u (local.get $addr))
        (then
          (local.set $ux (i32.load16_u (i32.add (local.get $addr) (i32.const 2))))
          (local.set $uy (i32.load16_u (i32.add (local.get $addr) (i32.const 4))))
          (if (i32.and
                (i32.and (i32.lt_s (i32.sub (local.get $ux) (local.get $px)) (i32.const 14))
                         (i32.gt_s (i32.sub (local.get $ux) (local.get $px)) (i32.const -14)))
                (i32.and (i32.lt_s (i32.sub (local.get $uy) (local.get $py)) (i32.const 10))
                         (i32.gt_s (i32.sub (local.get $uy) (local.get $py)) (i32.const -10))))
            (then
              (i32.store8 (local.get $addr) (i32.const 0))
              (call $play_sfx (i32.const 2))
              ;; power up
              (local.set $pl (i32.load8_u (i32.const 0x10349)))
              (if (i32.lt_u (local.get $pl) (i32.const 3))
                (then (i32.store8 (i32.const 0x10349) (i32.add (local.get $pl) (i32.const 1)))))
              ;; bonus score
              (i32.store (i32.const 0x10344)
                (i32.add (i32.load (i32.const 0x10344)) (i32.const 500)))
              ;; big green burst + white flash particles
              (call $spawn_powerup_burst (local.get $px) (local.get $py) (i32.const 24))
              (call $spawn_explosion (local.get $px) (local.get $py) (i32.const 6))
              ;; screen shake (small, positive)
              (i32.store8 (i32.const 0x10354) (i32.const 3))
            )
          )
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; Player bullets vs boss
  (func $check_bullet_boss
    (local $bi i32) (local $baddr i32) (local $bx i32) (local $by i32)
    (local $boss_x i32) (local $boss_y i32) (local $hp i32)
    (if (i32.eqz (i32.load8_u (i32.const 0x1034C))) (then (return)))
    (local.set $boss_x (i32.load16_u (i32.const 0x1034E)))
    (local.set $boss_y (i32.load16_u (i32.const 0x10350)))
    (local.set $bi (i32.const 0))
    (block $bd (loop $bl
      (br_if $bd (i32.ge_u (local.get $bi) (i32.const 32)))
      (local.set $baddr (i32.add (i32.const 0x10370) (i32.mul (local.get $bi) (i32.const 8))))
      (if (i32.load8_u (local.get $baddr))
        (then
          (local.set $bx (i32.load16_u (i32.add (local.get $baddr) (i32.const 2))))
          (local.set $by (i32.load16_u (i32.add (local.get $baddr) (i32.const 4))))
          ;; boss hitbox ~32x24
          (if (i32.and
                (i32.and (i32.lt_s (i32.sub (local.get $bx) (local.get $boss_x)) (i32.const 18))
                         (i32.gt_s (i32.sub (local.get $bx) (local.get $boss_x)) (i32.const -18)))
                (i32.and (i32.lt_s (i32.sub (local.get $by) (local.get $boss_y)) (i32.const 14))
                         (i32.gt_s (i32.sub (local.get $by) (local.get $boss_y)) (i32.const -14))))
            (then
              (i32.store8 (local.get $baddr) (i32.const 0))
              (call $spawn_explosion (local.get $bx) (local.get $by) (i32.const 3))
              (local.set $hp (i32.sub (i32.load8_u (i32.const 0x1034D)) (i32.const 1)))
              (if (i32.le_s (local.get $hp) (i32.const 0))
                (then
                  ;; boss destroyed!
                  (call $play_sfx (i32.const 4))
                  (call $play_sfx (i32.const 1))
                  (i32.store8 (i32.const 0x1034C) (i32.const 0))
                  (call $spawn_explosion (local.get $boss_x) (local.get $boss_y) (i32.const 30))
                  (call $spawn_explosion (i32.add (local.get $boss_x) (i32.const 10)) (i32.sub (local.get $boss_y) (i32.const 8)) (i32.const 20))
                  (call $spawn_explosion (i32.sub (local.get $boss_x) (i32.const 10)) (i32.add (local.get $boss_y) (i32.const 8)) (i32.const 20))
                  (i32.store (i32.const 0x10344) (i32.add (i32.load (i32.const 0x10344)) (i32.const 5000)))
                  (i32.store8 (i32.const 0x10354) (i32.const 15))  ;; big shake
                  ;; go to game over (victory)
                  (call $music (i32.const 0x12600))
                  (i32.store8 (i32.const 0x10340) (i32.const 6))
                  (i32.store16 (i32.const 0x10342) (i32.const 0))
                )
                (else
                  (i32.store8 (i32.const 0x1034D) (local.get $hp))
                )
              )
            )
          )
        )
      )
      (local.set $bi (i32.add (local.get $bi) (i32.const 1)))
      (br $bl)))
  )

  ;; ============================================================
  ;; BOSS
  ;; ============================================================

  (func $update_boss
    (local $x i32) (local $y i32) (local $phase i32) (local $timer i32) (local $frame i32)
    (if (i32.eqz (i32.load8_u (i32.const 0x1034C))) (then (return)))
    (local.set $x (i32.load16_u (i32.const 0x1034E)))
    (local.set $y (i32.load16_u (i32.const 0x10350)))
    (local.set $phase (i32.load8_u (i32.const 0x10352)))
    (local.set $timer (i32.load8_u (i32.const 0x10353)))
    (local.set $frame (i32.load (i32.const 0)))
    ;; entrance: slide in from right
    (if (i32.gt_s (local.get $x) (i32.const 260))
      (then
        (i32.store16 (i32.const 0x1034E) (i32.sub (local.get $x) (i32.const 1)))
        (return)
      )
    )
    ;; bob up and down
    (local.set $y (i32.add (i32.const 100)
      (i32.sub (i32.shr_u (call $sin_tab (i32.mul (local.get $frame) (i32.const 1))) (i32.const 2)) (i32.const 32))))
    (i32.store16 (i32.const 0x10350) (local.get $y))
    ;; fire every 20 frames from two turrets
    (if (i32.eqz (i32.rem_u (local.get $frame) (i32.const 20)))
      (then
        (call $spawn_enemy_bullet (i32.sub (local.get $x) (i32.const 16)) (i32.sub (local.get $y) (i32.const 10)))
        (call $spawn_enemy_bullet (i32.sub (local.get $x) (i32.const 16)) (i32.add (local.get $y) (i32.const 10)))
      )
    )
    ;; spread fire every 60 frames
    (if (i32.eqz (i32.rem_u (local.get $frame) (i32.const 60)))
      (then
        (call $spawn_enemy_bullet (i32.sub (local.get $x) (i32.const 10)) (i32.sub (local.get $y) (i32.const 5)))
        (call $spawn_enemy_bullet (i32.sub (local.get $x) (i32.const 10)) (local.get $y))
        (call $spawn_enemy_bullet (i32.sub (local.get $x) (i32.const 10)) (i32.add (local.get $y) (i32.const 5)))
      )
    )
  )

  (func $draw_boss
    (local $x i32) (local $y i32) (local $hp i32) (local $frame i32)
    (if (i32.eqz (i32.load8_u (i32.const 0x1034C))) (then (return)))
    (local.set $x (i32.load16_u (i32.const 0x1034E)))
    (local.set $y (i32.load16_u (i32.const 0x10350)))
    (local.set $hp (i32.load8_u (i32.const 0x1034D)))
    (local.set $frame (i32.load (i32.const 0)))
    ;; Main hull (symmetrical)
    (call $draw_rect (i32.sub (local.get $x) (i32.const 14)) (i32.sub (local.get $y) (i32.const 10))
      (i32.const 28) (i32.const 21)
      (select (i32.const 30) (i32.const 31) (i32.gt_u (local.get $hp) (i32.const 15))))
    ;; Inner hull
    (call $draw_rect (i32.sub (local.get $x) (i32.const 10)) (i32.sub (local.get $y) (i32.const 7))
      (i32.const 20) (i32.const 15) (i32.const 24))
    ;; Nose wedge
    (call $draw_rect (i32.sub (local.get $x) (i32.const 16)) (i32.sub (local.get $y) (i32.const 4))
      (i32.const 4) (i32.const 9) (i32.const 31))
    (call $draw_rect (i32.sub (local.get $x) (i32.const 18)) (i32.sub (local.get $y) (i32.const 2))
      (i32.const 3) (i32.const 5) (i32.const 30))
    ;; Central eye (pulsing)
    (call $draw_rect (i32.sub (local.get $x) (i32.const 4)) (i32.sub (local.get $y) (i32.const 3))
      (i32.const 8) (i32.const 7)
      (select (i32.const 36) (i32.const 40) (i32.and (local.get $frame) (i32.const 8))))
    (call $draw_rect (i32.sub (local.get $x) (i32.const 2)) (i32.sub (local.get $y) (i32.const 1))
      (i32.const 4) (i32.const 3) (i32.const 15))
    ;; Turret pods (symmetrical top/bottom)
    (call $draw_rect (i32.sub (local.get $x) (i32.const 18)) (i32.sub (local.get $y) (i32.const 14))
      (i32.const 10) (i32.const 4) (i32.const 22))
    (call $draw_rect (i32.sub (local.get $x) (i32.const 18)) (i32.add (local.get $y) (i32.const 11))
      (i32.const 10) (i32.const 4) (i32.const 22))
    ;; Turret gun barrels
    (call $draw_rect (i32.sub (local.get $x) (i32.const 21)) (i32.sub (local.get $y) (i32.const 12))
      (i32.const 5) (i32.const 2) (i32.const 44))
    (call $draw_rect (i32.sub (local.get $x) (i32.const 21)) (i32.add (local.get $y) (i32.const 11))
      (i32.const 5) (i32.const 2) (i32.const 44))
    ;; Engine blocks (symmetrical)
    (call $draw_rect (i32.add (local.get $x) (i32.const 10)) (i32.sub (local.get $y) (i32.const 8))
      (i32.const 5) (i32.const 5) (i32.const 22))
    (call $draw_rect (i32.add (local.get $x) (i32.const 10)) (i32.add (local.get $y) (i32.const 4))
      (i32.const 5) (i32.const 5) (i32.const 22))
    ;; Engine glow (symmetrical, animated)
    (call $put_pixel (i32.add (local.get $x) (i32.const 15)) (i32.sub (local.get $y) (i32.const 6))
      (select (i32.const 40) (i32.const 36) (i32.and (local.get $frame) (i32.const 4))))
    (call $put_pixel (i32.add (local.get $x) (i32.const 15)) (i32.add (local.get $y) (i32.const 6))
      (select (i32.const 40) (i32.const 36) (i32.and (local.get $frame) (i32.const 4))))
    ;; HP bar above boss
    (call $draw_rect (i32.sub (local.get $x) (i32.const 15)) (i32.sub (local.get $y) (i32.const 18))
      (local.get $hp) (i32.const 2) (i32.const 36))
  )

  ;; ============================================================
  ;; WAVE SPAWNER
  ;; ============================================================

  (func $spawn_wave
    (local $wave_idx i32) (local $timer i32) (local $frame i32)
    (local $type i32) (local $count i32) (local $j i32) (local $y i32)
    ;; don't spawn during boss
    (if (i32.load8_u (i32.const 0x1034C)) (then (return)))
    (local.set $wave_idx (i32.load8_u (i32.const 0x1034A)))
    (local.set $timer (i32.load8_u (i32.const 0x1034B)))
    (local.set $frame (i32.load (i32.const 0)))
    ;; timer countdown
    (if (i32.gt_u (local.get $timer) (i32.const 0))
      (then
        (i32.store8 (i32.const 0x1034B) (i32.sub (local.get $timer) (i32.const 1)))
        (return)
      )
    )
    ;; spawn wave based on wave_idx
    (if (i32.ge_u (local.get $wave_idx) (i32.const 15))
      (then
        ;; all waves done, spawn boss
        (if (i32.eqz (i32.load8_u (i32.const 0x1034C)))
          (then
            (call $music (i32.const 0x12700))  ;; boss fight music!
            (i32.store8 (i32.const 0x1034C) (i32.const 1))    ;; boss active
            (i32.store8 (i32.const 0x1034D) (i32.const 30))   ;; boss HP
            (i32.store16 (i32.const 0x1034E) (i32.const 350)) ;; boss x (offscreen right)
            (i32.store16 (i32.const 0x10350) (i32.const 100)) ;; boss y
          )
        )
        (return)
      )
    )
    ;; determine wave params from index
    ;; type cycles: 0,1,0,2,0,1,2,0,1,2,1,2,2,1,0
    (local.set $type (i32.rem_u (local.get $wave_idx) (i32.const 3)))
    ;; count: 3-6 enemies per wave, increasing
    (local.set $count (i32.add (i32.const 3) (i32.shr_u (local.get $wave_idx) (i32.const 2))))
    (if (i32.gt_u (local.get $count) (i32.const 6)) (then (local.set $count (i32.const 6))))
    ;; spawn enemies in formation
    (local.set $j (i32.const 0))
    (block $jd (loop $jl
      (br_if $jd (i32.ge_u (local.get $j) (local.get $count)))
      (local.set $y (i32.add (i32.const 30)
        (i32.mul (i32.div_u (i32.const 140) (i32.add (local.get $count) (i32.const 1)))
          (i32.add (local.get $j) (i32.const 1)))))
      (call $spawn_enemy (local.get $type)
        (i32.add (i32.const 330) (i32.mul (local.get $j) (i32.const 20)))
        (local.get $y))
      (local.set $j (i32.add (local.get $j) (i32.const 1)))
      (br $jl)))
    ;; next wave
    (i32.store8 (i32.const 0x1034A) (i32.add (local.get $wave_idx) (i32.const 1)))
    (i32.store8 (i32.const 0x1034B) (i32.const 120))  ;; 2 second delay
  )

  ;; ============================================================
  ;; HUD
  ;; ============================================================

  (func $draw_hud
    (local $score i32) (local $lives i32) (local $i i32)
    ;; dark bar at top
    (call $draw_rect (i32.const 0) (i32.const 0) (i32.const 320) (i32.const 12) (i32.const 1))
    ;; score
    (call $draw_string (i32.const 0x12388) (i32.const 4) (i32.const 4) (i32.const 2) (i32.const 15) (i32.const 1))
    ;; "SC:" at 0x12388
    (local.set $score (i32.load (i32.const 0x10344)))
    (call $draw_number (local.get $score) (i32.const 36) (i32.const 2) (i32.const 46) (i32.const 1))
    ;; lives: draw small ships
    (local.set $lives (i32.load8_u (i32.const 0x10348)))
    (local.set $i (i32.const 0))
    (block $ld (loop $ll
      (br_if $ld (i32.ge_u (local.get $i) (local.get $lives)))
      (call $draw_rect (i32.add (i32.const 260) (i32.mul (local.get $i) (i32.const 12))) (i32.const 3) (i32.const 8) (i32.const 5) (i32.const 11))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $ll)))
  )

  ;; ============================================================
  ;; FIRE EFFECT (for title card, 80x50 buffer at 0x11400)
  ;; ============================================================

  (func $update_fire_buffer
    (local $x i32) (local $y i32) (local $src i32) (local $avg i32)
    (local $below i32) (local $belowL i32) (local $belowR i32) (local $below2 i32)
    ;; seed bottom row with random hot values
    (local.set $x (i32.const 0))
    (block $sd (loop $sl
      (br_if $sd (i32.ge_u (local.get $x) (i32.const 80)))
      (i32.store8
        (i32.add (i32.const 0x11400) (i32.add (i32.mul (i32.const 49) (i32.const 80)) (local.get $x)))
        (i32.sub (i32.const 255) (i32.and (call $rand) (i32.const 31))))
      (local.set $x (i32.add (local.get $x) (i32.const 1)))
      (br $sl)))
    ;; propagate upward
    (local.set $y (i32.const 0))
    (block $yd (loop $yl
      (br_if $yd (i32.ge_u (local.get $y) (i32.const 49)))
      (local.set $x (i32.const 0))
      (block $xd (loop $xl
        (br_if $xd (i32.ge_u (local.get $x) (i32.const 80)))
        (local.set $below (i32.load8_u (i32.add (i32.const 0x11400)
          (i32.add (i32.mul (i32.add (local.get $y) (i32.const 1)) (i32.const 80)) (local.get $x)))))
        (local.set $belowL (i32.load8_u (i32.add (i32.const 0x11400)
          (i32.add (i32.mul (i32.add (local.get $y) (i32.const 1)) (i32.const 80))
            (select (i32.sub (local.get $x) (i32.const 1)) (i32.const 0) (i32.gt_u (local.get $x) (i32.const 0)))))))
        (local.set $belowR (i32.load8_u (i32.add (i32.const 0x11400)
          (i32.add (i32.mul (i32.add (local.get $y) (i32.const 1)) (i32.const 80))
            (select (i32.add (local.get $x) (i32.const 1)) (i32.const 79) (i32.lt_u (local.get $x) (i32.const 79)))))))
        (local.set $below2 (i32.load8_u (i32.add (i32.const 0x11400)
          (i32.add (i32.mul
            (select (i32.add (local.get $y) (i32.const 2)) (i32.const 49) (i32.lt_u (local.get $y) (i32.const 48)))
            (i32.const 80)) (local.get $x)))))
        (local.set $avg (i32.shr_u
          (i32.add (i32.add (local.get $below) (local.get $belowL))
            (i32.add (local.get $belowR) (local.get $below2)))
          (i32.const 2)))
        ;; decay
        (local.set $avg (i32.sub (local.get $avg) (i32.add (i32.const 2) (i32.and (call $rand) (i32.const 1)))))
        (if (i32.lt_s (local.get $avg) (i32.const 0)) (then (local.set $avg (i32.const 0))))
        (i32.store8 (i32.add (i32.const 0x11400) (i32.add (i32.mul (local.get $y) (i32.const 80)) (local.get $x)))
          (local.get $avg))
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br $xl)))
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br $yl)))
  )

  ;; Blit fire buffer to screen centered, 2x scale
  ;; Screen area: x=80..240 (160px), y=50..150 (100px)
  (func $draw_fire_to_screen
    (local $x i32) (local $y i32) (local $fire_val i32) (local $sx i32) (local $sy i32)
    (local.set $y (i32.const 0))
    (block $yd (loop $yl
      (br_if $yd (i32.ge_u (local.get $y) (i32.const 50)))
      (local.set $x (i32.const 0))
      (block $xd (loop $xl
        (br_if $xd (i32.ge_u (local.get $x) (i32.const 80)))
        (local.set $fire_val (i32.load8_u (i32.add (i32.const 0x11400)
          (i32.add (i32.mul (local.get $y) (i32.const 80)) (local.get $x)))))
        ;; map to palette index 128-191 (fire palette range)
        (if (i32.gt_u (local.get $fire_val) (i32.const 8))
          (then
            (local.set $fire_val (i32.add (i32.const 128) (i32.shr_u (local.get $fire_val) (i32.const 2))))
            (if (i32.gt_u (local.get $fire_val) (i32.const 191))
              (then (local.set $fire_val (i32.const 191))))
            ;; 2x scale blit
            (local.set $sx (i32.add (i32.const 80) (i32.mul (local.get $x) (i32.const 2))))
            (local.set $sy (i32.add (i32.const 50) (i32.mul (local.get $y) (i32.const 2))))
            (call $put_pixel (local.get $sx) (local.get $sy) (local.get $fire_val))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 1)) (local.get $sy) (local.get $fire_val))
            (call $put_pixel (local.get $sx) (i32.add (local.get $sy) (i32.const 1)) (local.get $fire_val))
            (call $put_pixel (i32.add (local.get $sx) (i32.const 1)) (i32.add (local.get $sy) (i32.const 1)) (local.get $fire_val))
          )
        )
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br $xl)))
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br $yl)))
  )

  ;; ============================================================
  ;; INTRO PHASES
  ;; ============================================================

  ;; Phase 0: Story text scroll over starfield
  (func $phase_story
    (local $timer i32) (local $scroll_y i32) (local $line_y i32)
    (call $clear_fb (i32.const 0))
    (call $update_and_draw_stars)
    (local.set $timer (i32.load16_u (i32.const 0x10342)))
    ;; text scrolls up: starts at y=200, moves up
    (local.set $scroll_y (i32.sub (i32.const 200) (i32.shr_u (local.get $timer) (i32.const 1))))
    ;; Line 1: "THE YEAR IS 2187"
    (local.set $line_y (i32.add (local.get $scroll_y) (i32.const 0)))
    (if (i32.and (i32.gt_s (local.get $line_y) (i32.const -20)) (i32.lt_s (local.get $line_y) (i32.const 210)))
      (then (call $draw_string (i32.const 0x11100) (i32.const 16) (i32.const 64) (local.get $line_y) (i32.const 14) (i32.const 1))))
    ;; Line 2: "THE LAST COLONY SHIP"
    (local.set $line_y (i32.add (local.get $scroll_y) (i32.const 20)))
    (if (i32.and (i32.gt_s (local.get $line_y) (i32.const -20)) (i32.lt_s (local.get $line_y) (i32.const 210)))
      (then (call $draw_string (i32.const 0x11110) (i32.const 20) (i32.const 48) (local.get $line_y) (i32.const 14) (i32.const 1))))
    ;; Line 3: "APPROACHES THE FRONTIER"
    (local.set $line_y (i32.add (local.get $scroll_y) (i32.const 40)))
    (if (i32.and (i32.gt_s (local.get $line_y) (i32.const -20)) (i32.lt_s (local.get $line_y) (i32.const 210)))
      (then (call $draw_string (i32.const 0x11124) (i32.const 23) (i32.const 36) (local.get $line_y) (i32.const 14) (i32.const 1))))
    ;; Line 4: "BUT SOMETHING WAITS"
    (local.set $line_y (i32.add (local.get $scroll_y) (i32.const 70)))
    (if (i32.and (i32.gt_s (local.get $line_y) (i32.const -20)) (i32.lt_s (local.get $line_y) (i32.const 210)))
      (then (call $draw_string (i32.const 0x1113C) (i32.const 19) (i32.const 52) (local.get $line_y) (i32.const 24) (i32.const 1))))
    ;; Line 5: "IN THE DARKNESS..."
    (local.set $line_y (i32.add (local.get $scroll_y) (i32.const 90)))
    (if (i32.and (i32.gt_s (local.get $line_y) (i32.const -20)) (i32.lt_s (local.get $line_y) (i32.const 210)))
      (then (call $draw_string (i32.const 0x11150) (i32.const 18) (i32.const 56) (local.get $line_y) (i32.const 24) (i32.const 1))))
    ;; advance after 500 frames
    (if (i32.gt_u (local.get $timer) (i32.const 500))
      (then
        (i32.store8 (i32.const 0x10340) (i32.const 1))
        (i32.store16 (i32.const 0x10342) (i32.const 0))
      )
    )
  )

  ;; Phase 1: Planet approach - growing circle
  (func $phase_planet
    (local $timer i32) (local $radius i32) (local $cx i32) (local $cy i32)
    (local $x i32) (local $y i32) (local $dx i32) (local $dy i32) (local $dist_sq i32)
    (local $r_sq i32) (local $c i32) (local $hash i32)
    (call $clear_fb (i32.const 0))
    (call $update_and_draw_stars)
    (local.set $timer (i32.load16_u (i32.const 0x10342)))
    (local.set $radius (i32.shr_u (local.get $timer) (i32.const 2)))
    (if (i32.gt_s (local.get $radius) (i32.const 60)) (then (local.set $radius (i32.const 60))))
    (local.set $cx (i32.const 160))
    (local.set $cy (i32.const 100))
    (local.set $r_sq (i32.mul (local.get $radius) (local.get $radius)))
    ;; draw filled circle with surface detail
    (local.set $y (i32.sub (local.get $cy) (local.get $radius)))
    (block $yd (loop $yl
      (br_if $yd (i32.gt_s (local.get $y) (i32.add (local.get $cy) (local.get $radius))))
      (local.set $x (i32.sub (local.get $cx) (local.get $radius)))
      (block $xd (loop $xl
        (br_if $xd (i32.gt_s (local.get $x) (i32.add (local.get $cx) (local.get $radius))))
        (local.set $dx (i32.sub (local.get $x) (local.get $cx)))
        (local.set $dy (i32.sub (local.get $y) (local.get $cy)))
        (local.set $dist_sq (i32.add (i32.mul (local.get $dx) (local.get $dx)) (i32.mul (local.get $dy) (local.get $dy))))
        (if (i32.le_u (local.get $dist_sq) (local.get $r_sq))
          (then
            ;; surface color: hash-based terrain
            (local.set $hash (i32.xor
              (i32.mul (local.get $x) (i32.const 7919))
              (i32.mul (local.get $y) (i32.const 6271))))
            ;; blue/green planet
            (local.set $c (i32.add (i32.const 48)
              (i32.rem_u (i32.and (local.get $hash) (i32.const 0x7FFFFFFF)) (i32.const 16))))
            ;; atmosphere glow at edge
            (if (i32.gt_u (local.get $dist_sq) (i32.mul (i32.sub (local.get $radius) (i32.const 3)) (i32.sub (local.get $radius) (i32.const 3))))
              (then (local.set $c (i32.const 14))))
            (call $put_pixel (local.get $x) (local.get $y) (local.get $c))
          )
        )
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br $xl)))
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br $yl)))
    ;; advance after 300 frames
    (if (i32.gt_u (local.get $timer) (i32.const 300))
      (then
        (i32.store8 (i32.const 0x10340) (i32.const 2))
        (i32.store16 (i32.const 0x10342) (i32.const 0))
      )
    )
  )

  ;; Phase 2: Ship assembly - wireframe then fill
  (func $phase_ship
    (local $timer i32) (local $px i32) (local $py i32) (local $alpha i32)
    (call $clear_fb (i32.const 0))
    (call $update_and_draw_stars)
    (local.set $timer (i32.load16_u (i32.const 0x10342)))
    (local.set $px (i32.const 160))
    (local.set $py (i32.const 100))
    ;; Phase: wireframe first 100 frames, then fill
    (local.set $alpha (i32.shr_u (local.get $timer) (i32.const 1)))
    (if (i32.gt_u (local.get $alpha) (i32.const 15)) (then (local.set $alpha (i32.const 15))))
    ;; Draw ship large (3x scale of player ship)
    ;; Body outline
    (if (i32.gt_u (local.get $timer) (i32.const 10))
      (then
        ;; body
        (call $draw_rect (i32.sub (local.get $px) (i32.const 6)) (i32.sub (local.get $py) (i32.const 6))
          (i32.const 30) (i32.const 15)
          (select (i32.const 11) (i32.const 9) (i32.gt_u (local.get $timer) (i32.const 100))))
      )
    )
    (if (i32.gt_u (local.get $timer) (i32.const 30))
      (then
        ;; wings
        (call $draw_rect (i32.sub (local.get $px) (i32.const 12)) (i32.sub (local.get $py) (i32.const 16))
          (i32.const 18) (i32.const 6) (i32.const 9))
        (call $draw_rect (i32.sub (local.get $px) (i32.const 12)) (i32.add (local.get $py) (i32.const 10))
          (i32.const 18) (i32.const 6) (i32.const 9))
      )
    )
    (if (i32.gt_u (local.get $timer) (i32.const 60))
      (then
        ;; nose
        (call $draw_rect (i32.add (local.get $px) (i32.const 20)) (i32.sub (local.get $py) (i32.const 3))
          (i32.const 8) (i32.const 9) (i32.const 15))
        ;; cockpit
        (call $draw_rect (i32.add (local.get $px) (i32.const 12)) (i32.sub (local.get $py) (i32.const 1))
          (i32.const 6) (i32.const 5) (i32.const 14))
      )
    )
    (if (i32.gt_u (local.get $timer) (i32.const 100))
      (then
        ;; engine glow
        (call $draw_rect (i32.sub (local.get $px) (i32.const 16)) (i32.sub (local.get $py) (i32.const 3))
          (i32.const 6) (i32.const 9) (i32.const 40))
      )
    )
    ;; label
    (if (i32.gt_u (local.get $timer) (i32.const 130))
      (then
        (call $draw_string (i32.const 0x11168) (i32.const 13) (i32.const 108) (i32.const 140) (i32.const 14) (i32.const 1))
      )
    )
    ;; advance after 240 frames
    (if (i32.gt_u (local.get $timer) (i32.const 240))
      (then
        (i32.store8 (i32.const 0x10340) (i32.const 3))
        (i32.store16 (i32.const 0x10342) (i32.const 0))
      )
    )
  )

  ;; Phase 3: Title card with fire
  (func $phase_title
    (local $timer i32)
    (call $clear_fb (i32.const 0))
    (call $update_and_draw_stars)
    (local.set $timer (i32.load16_u (i32.const 0x10342)))
    ;; update and draw fire
    (call $update_fire_buffer)
    (call $draw_fire_to_screen)
    ;; Title text: "STELLAR ASSAULT" - 2x scale, centered
    ;; 15 chars * 16px = 240px, centered at (40, 75)
    (call $draw_string (i32.const 0x11178) (i32.const 7) (i32.const 100) (i32.const 72) (i32.const 15) (i32.const 2))
    ;; "ASSAULT"
    (call $draw_string (i32.const 0x11180) (i32.const 7) (i32.const 100) (i32.const 95) (i32.const 46) (i32.const 2))
    ;; advance after 360 frames
    (if (i32.gt_u (local.get $timer) (i32.const 360))
      (then
        (i32.store8 (i32.const 0x10340) (i32.const 4))
        (i32.store16 (i32.const 0x10342) (i32.const 0))
      )
    )
  )

  ;; Phase 4: Press fire to start
  (func $phase_press_fire
    (local $timer i32) (local $btn i32)
    (call $clear_fb (i32.const 0))
    (call $update_and_draw_stars)
    (local.set $timer (i32.load16_u (i32.const 0x10342)))
    ;; keep fire going
    (call $update_fire_buffer)
    (call $draw_fire_to_screen)
    ;; title
    (call $draw_string (i32.const 0x11178) (i32.const 7) (i32.const 100) (i32.const 72) (i32.const 15) (i32.const 2))
    (call $draw_string (i32.const 0x11180) (i32.const 7) (i32.const 100) (i32.const 95) (i32.const 46) (i32.const 2))
    ;; blink "CLICK TO START"
    (if (i32.and (local.get $timer) (i32.const 32))
      (then
        (call $draw_string (i32.const 0x11188) (i32.const 14) (i32.const 104) (i32.const 140) (i32.const 15) (i32.const 1))
      )
    )
    ;; check NEW mouse click (rising edge) or timeout
    (local.set $btn (i32.and (i32.load8_u (i32.const 0x08))
      (i32.xor (i32.load8_u (i32.const 0x10357)) (i32.const 0xFF))))
    (if (i32.or (i32.and (local.get $btn) (i32.const 1))
          (i32.gt_u (local.get $timer) (i32.const 600)))
      (then
        ;; start gameplay
        (call $music (i32.const 0x12500))
        (i32.store8 (i32.const 0x10340) (i32.const 5))
        (i32.store16 (i32.const 0x10342) (i32.const 0))
        ;; init player
        (i32.store16 (i32.const 0x10360) (i32.const 40))
        (i32.store16 (i32.const 0x10362) (i32.const 100))
        (i32.store8 (i32.const 0x10348) (i32.const 3))  ;; 3 lives
        (i32.store8 (i32.const 0x10349) (i32.const 0))  ;; power level 0
        (i32.store (i32.const 0x10344) (i32.const 0))    ;; score 0
        (i32.store8 (i32.const 0x1034A) (i32.const 0))   ;; wave 0
        (i32.store8 (i32.const 0x1034B) (i32.const 60))  ;; wave timer
        (i32.store8 (i32.const 0x1034C) (i32.const 0))   ;; no boss
      )
    )
  )

  ;; Phase 5: Gameplay
  (func $phase_gameplay
    (local $shake i32) (local $ox i32) (local $oy i32)
    (call $clear_fb (i32.const 0))
    ;; screen shake offset
    (local.set $shake (i32.load8_u (i32.const 0x10354)))
    (if (i32.gt_u (local.get $shake) (i32.const 0))
      (then (i32.store8 (i32.const 0x10354) (i32.sub (local.get $shake) (i32.const 1)))))
    ;; background
    (call $update_and_draw_stars)
    ;; game logic
    (call $update_player)
    (call $update_player_bullets)
    (call $update_enemies)
    (call $update_enemy_bullets)
    (call $spawn_wave)
    (call $update_boss)
    ;; collisions
    (call $check_bullet_enemy)
    (call $check_bullet_boss)
    (call $check_enemy_player)
    (call $check_ship_player)
    (call $check_powerup_player)
    ;; draw everything
    (call $draw_enemies)
    (call $draw_boss)
    (call $draw_player_bullets)
    (call $draw_enemy_bullets)
    (call $draw_player)
    (call $update_and_draw_particles)
    (call $update_and_draw_powerups)
    (call $draw_hud)
    ;; --- Hit flash + scrolling message during invulnerability ---
    (call $draw_hit_effects)
  )

  (func $draw_hit_effects
    (local $inv i32) (local $elapsed i32) (local $msg_idx i32)
    (local $msg_addr i32) (local $msg_len i32) (local $scroll_x i32)
    (local $flash i32) (local $y i32)
    (local.set $inv (i32.load8_u (i32.const 0x10365)))
    (if (i32.eqz (local.get $inv)) (then (return)))
    (local.set $elapsed (i32.sub (i32.const 90) (local.get $inv)))
    ;; White flash overlay for first 6 frames (fade: palette 15=white)
    (if (i32.lt_u (local.get $elapsed) (i32.const 6))
      (then
        (local.set $flash (i32.sub (i32.const 6) (local.get $elapsed)))
        ;; draw horizontal white lines every N rows for a scanline flash effect
        (if (i32.gt_u (local.get $flash) (i32.const 0))
        (then
        (local.set $y (i32.const 0))
        (block $fd (loop $fl
          (br_if $fd (i32.ge_u (local.get $y) (i32.const 200)))
          (if (i32.eqz (i32.rem_u (local.get $y) (local.get $flash)))
            (then
              (call $draw_rect (i32.const 0) (local.get $y) (i32.const 320) (i32.const 1) (i32.const 15))
            )
          )
          (local.set $y (i32.add (local.get $y) (i32.const 1)))
          (br $fl)))
        ))
      )
    )
    ;; Scrolling text for first 70 frames
    (if (i32.lt_u (local.get $elapsed) (i32.const 70))
      (then
        ;; pick message by index at 0x10355
        (local.set $msg_idx (i32.load8_u (i32.const 0x10355)))
        ;; message 0: "HULL BREACH" (11) at 0x111C0
        ;; message 1: "SHIELDS DOWN" (12) at 0x111CC
        ;; message 2: "DAMAGE CRITICAL" (15) at 0x111D8
        (if (i32.eqz (local.get $msg_idx))
          (then
            (local.set $msg_addr (i32.const 0x111C0))
            (local.set $msg_len (i32.const 11))
          )
        )
        (if (i32.eq (local.get $msg_idx) (i32.const 1))
          (then
            (local.set $msg_addr (i32.const 0x111CC))
            (local.set $msg_len (i32.const 12))
          )
        )
        (if (i32.eq (local.get $msg_idx) (i32.const 2))
          (then
            (local.set $msg_addr (i32.const 0x111D8))
            (local.set $msg_len (i32.const 15))
          )
        )
        ;; scroll from right (320) to center, then hold
        ;; target x = 160 - (len*8)/2 = centered
        (if (i32.lt_u (local.get $elapsed) (i32.const 20))
          (then
            ;; scrolling in: x = 320 - elapsed * 16 ... but clamp to target
            (local.set $scroll_x (i32.sub (i32.const 320) (i32.mul (local.get $elapsed) (i32.const 16))))
            ;; clamp to minimum (center)
            (if (i32.lt_s (local.get $scroll_x) (i32.sub (i32.const 160) (i32.mul (local.get $msg_len) (i32.const 4))))
              (then (local.set $scroll_x (i32.sub (i32.const 160) (i32.mul (local.get $msg_len) (i32.const 4))))))
          )
          (else
            ;; hold at center
            (local.set $scroll_x (i32.sub (i32.const 160) (i32.mul (local.get $msg_len) (i32.const 4))))
          )
        )
        ;; blink the text after frame 50
        (if (i32.or (i32.lt_u (local.get $elapsed) (i32.const 50))
              (i32.and (local.get $elapsed) (i32.const 4)))
          (then
            ;; draw with red color (36=bright red in our palette)
            (call $draw_string (local.get $msg_addr) (local.get $msg_len)
              (local.get $scroll_x) (i32.const 95) (i32.const 36) (i32.const 1))
          )
        )
      )
    )
  )

  ;; Phase 6: Game over
  (func $phase_game_over
    (local $timer i32) (local $btn i32) (local $score i32) (local $digits i32) (local $tmp i32) (local $sx i32)
    (call $clear_fb (i32.const 0))
    (call $update_and_draw_stars)
    (call $update_and_draw_particles)
    (local.set $timer (i32.load16_u (i32.const 0x10342)))
    ;; "GAME OVER" or "VICTORY" — centered
    (if (i32.gt_u (i32.load8_u (i32.const 0x10348)) (i32.const 0))
      (then
        ;; "VICTORY" 7 chars * 16px = 112px, center = (320-112)/2 = 104
        (call $draw_string (i32.const 0x111A1) (i32.const 7) (i32.const 104) (i32.const 70) (i32.const 46) (i32.const 2))
      )
      (else
        ;; "GAME OVER" 9 chars * 16px = 144px, center = (320-144)/2 = 88
        (call $draw_string (i32.const 0x11198) (i32.const 9) (i32.const 88) (i32.const 70) (i32.const 36) (i32.const 2))
      )
    )
    ;; show score — center "SC: " + digits as one unit
    ;; count digits in score
    (local.set $score (i32.load (i32.const 0x10344)))
    (local.set $digits (i32.const 1))
    (local.set $tmp (local.get $score))
    (block $done (loop $lp
      (local.set $tmp (i32.div_u (local.get $tmp) (i32.const 10)))
      (br_if $done (i32.eqz (local.get $tmp)))
      (local.set $digits (i32.add (local.get $digits) (i32.const 1)))
      (br $lp)))
    ;; total width = (4 + digits) * 16, sx = (320 - total) / 2
    (local.set $sx (i32.div_u (i32.sub (i32.const 320)
      (i32.mul (i32.add (i32.const 4) (local.get $digits)) (i32.const 16))) (i32.const 2)))
    (call $draw_string (i32.const 0x12388) (i32.const 4) (local.get $sx) (i32.const 110) (i32.const 15) (i32.const 2))
    (call $draw_number (local.get $score) (i32.add (local.get $sx) (i32.const 64)) (i32.const 110) (i32.const 46) (i32.const 2))
    ;; "CLICK TO RESTART"
    (if (i32.and (i32.gt_u (local.get $timer) (i32.const 120)) (i32.and (local.get $timer) (i32.const 32)))
      (then
        (call $draw_string (i32.const 0x111A8) (i32.const 16) (i32.const 96) (i32.const 150) (i32.const 15) (i32.const 1))
      )
    )
    ;; restart on NEW click/space after delay (rising edge)
    (local.set $btn (i32.and (i32.load8_u (i32.const 0x08))
      (i32.xor (i32.load8_u (i32.const 0x10357)) (i32.const 0xFF))))
    (if (i32.and (i32.gt_u (local.get $timer) (i32.const 180))
          (i32.or (i32.and (local.get $btn) (i32.const 1))
                  (i32.and
                    (i32.and (i32.load8_u (i32.const 0x10)) (i32.xor (i32.load8_u (i32.const 0x10358)) (i32.const 0xFF)))
                    (i32.const 16))))
      (then
        ;; reset to title
        (call $music (i32.const 0x12400))
        (i32.store8 (i32.const 0x10340) (i32.const 0))
        (i32.store16 (i32.const 0x10342) (i32.const 0))
      )
    )
  )

  ;; ============================================================
  ;; PALETTE SETUP
  ;; ============================================================

  (func $setup_palette
    (local $i i32) (local $addr i32) (local $r i32) (local $g i32) (local $b i32) (local $t i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 256)))
      (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
      (local.set $r (i32.const 0))
      (local.set $g (i32.const 0))
      (local.set $b (i32.const 0))

      ;; 0: black
      ;; 1-7: dark blues/grays (background, HUD)
      (if (i32.and (i32.ge_u (local.get $i) (i32.const 1)) (i32.le_u (local.get $i) (i32.const 7)))
        (then
          (local.set $t (i32.mul (local.get $i) (i32.const 8)))
          (local.set $r (local.get $t))
          (local.set $g (local.get $t))
          (local.set $b (i32.add (local.get $t) (i32.const 16)))
        )
      )
      ;; 8-15: starfield/text whites (dim to bright)
      (if (i32.and (i32.ge_u (local.get $i) (i32.const 8)) (i32.le_u (local.get $i) (i32.const 15)))
        (then
          (local.set $t (i32.mul (i32.sub (local.get $i) (i32.const 8)) (i32.const 32)))
          (local.set $r (local.get $t))
          (local.set $g (local.get $t))
          (local.set $b (local.get $t))
        )
      )
      ;; 9-11: ship blues
      (if (i32.eq (local.get $i) (i32.const 9)) (then (local.set $r (i32.const 60)) (local.set $g (i32.const 80)) (local.set $b (i32.const 160))))
      (if (i32.eq (local.get $i) (i32.const 11)) (then (local.set $r (i32.const 100)) (local.set $g (i32.const 140)) (local.set $b (i32.const 220))))
      (if (i32.eq (local.get $i) (i32.const 14)) (then (local.set $r (i32.const 180)) (local.set $g (i32.const 220)) (local.set $b (i32.const 255))))
      (if (i32.eq (local.get $i) (i32.const 15)) (then (local.set $r (i32.const 255)) (local.set $g (i32.const 255)) (local.set $b (i32.const 255))))

      ;; 20-25: enemy reds
      (if (i32.and (i32.ge_u (local.get $i) (i32.const 20)) (i32.le_u (local.get $i) (i32.const 25)))
        (then
          (local.set $t (i32.mul (i32.sub (local.get $i) (i32.const 20)) (i32.const 40)))
          (local.set $r (i32.add (i32.const 120) (local.get $t)))
          (local.set $g (i32.shr_u (local.get $t) (i32.const 2)))
          (local.set $b (i32.const 0))
        )
      )
      ;; 26-29: enemy greens
      (if (i32.and (i32.ge_u (local.get $i) (i32.const 26)) (i32.le_u (local.get $i) (i32.const 29)))
        (then
          (local.set $t (i32.mul (i32.sub (local.get $i) (i32.const 26)) (i32.const 40)))
          (local.set $r (i32.shr_u (local.get $t) (i32.const 2)))
          (local.set $g (i32.add (i32.const 100) (local.get $t)))
          (local.set $b (i32.shr_u (local.get $t) (i32.const 2)))
        )
      )
      ;; 30-31: enemy purple
      (if (i32.eq (local.get $i) (i32.const 30)) (then (local.set $r (i32.const 100)) (local.set $g (i32.const 40)) (local.set $b (i32.const 140))))
      (if (i32.eq (local.get $i) (i32.const 31)) (then (local.set $r (i32.const 140)) (local.set $g (i32.const 60)) (local.set $b (i32.const 180))))

      ;; 32-47: explosion/fire (red-orange-yellow-white)
      (if (i32.and (i32.ge_u (local.get $i) (i32.const 32)) (i32.le_u (local.get $i) (i32.const 47)))
        (then
          (local.set $t (i32.sub (local.get $i) (i32.const 32)))
          (local.set $r (i32.add (i32.const 128) (i32.mul (local.get $t) (i32.const 8))))
          (local.set $g (i32.mul (local.get $t) (i32.const 16)))
          (local.set $b (i32.shr_u (local.get $t) (i32.const 1)))
          (if (i32.gt_u (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))
          (if (i32.gt_u (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
        )
      )
      ;; 44-47: bright yellow-white for bullets
      (if (i32.eq (local.get $i) (i32.const 44)) (then (local.set $r (i32.const 255)) (local.set $g (i32.const 220)) (local.set $b (i32.const 80))))
      (if (i32.eq (local.get $i) (i32.const 46)) (then (local.set $r (i32.const 255)) (local.set $g (i32.const 255)) (local.set $b (i32.const 180))))

      ;; 48-63: planet greens/blues
      (if (i32.and (i32.ge_u (local.get $i) (i32.const 48)) (i32.le_u (local.get $i) (i32.const 63)))
        (then
          (local.set $t (i32.sub (local.get $i) (i32.const 48)))
          (local.set $r (i32.mul (local.get $t) (i32.const 4)))
          (local.set $g (i32.add (i32.const 40) (i32.mul (local.get $t) (i32.const 8))))
          (local.set $b (i32.add (i32.const 80) (i32.mul (local.get $t) (i32.const 6))))
          (if (i32.gt_u (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
          (if (i32.gt_u (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
        )
      )

      ;; 64-79: powerup green/cyan ramp (for powerup sparkles)
      (if (i32.and (i32.ge_u (local.get $i) (i32.const 64)) (i32.le_u (local.get $i) (i32.const 79)))
        (then
          (local.set $t (i32.sub (local.get $i) (i32.const 64)))
          (local.set $r (i32.mul (local.get $t) (i32.const 4)))
          (local.set $g (i32.add (i32.const 128) (i32.mul (local.get $t) (i32.const 8))))
          (local.set $b (i32.add (i32.const 80) (i32.mul (local.get $t) (i32.const 11))))
          (if (i32.gt_u (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
          (if (i32.gt_u (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
        )
      )

      ;; 128-191: fire palette for title card (black -> red -> orange -> yellow -> white)
      (if (i32.and (i32.ge_u (local.get $i) (i32.const 128)) (i32.le_u (local.get $i) (i32.const 191)))
        (then
          (local.set $t (i32.mul (i32.sub (local.get $i) (i32.const 128)) (i32.const 4)))
          ;; 0-63 maps to fire ramp
          (if (i32.lt_u (local.get $t) (i32.const 85))
            (then
              (local.set $r (i32.mul (local.get $t) (i32.const 3)))
              (local.set $g (i32.const 0))
              (local.set $b (i32.const 0))
            )
            (else (if (i32.lt_u (local.get $t) (i32.const 170))
              (then
                (local.set $r (i32.const 255))
                (local.set $g (i32.mul (i32.sub (local.get $t) (i32.const 85)) (i32.const 3)))
                (local.set $b (i32.const 0))
              )
              (else
                (local.set $r (i32.const 255))
                (local.set $g (i32.const 255))
                (local.set $b (i32.mul (i32.sub (local.get $t) (i32.const 170)) (i32.const 3)))
              )
            ))
          )
          (if (i32.gt_u (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))
          (if (i32.gt_u (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
          (if (i32.gt_u (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
        )
      )

      (i32.store8 (local.get $addr) (local.get $r))
      (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
      (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; ============================================================
  ;; STATIC DATA (font + strings) via data segments
  ;; ============================================================

  ;; Font: 8x8 bitmap, 96 glyphs (768 bytes at 0x10E00)
  (data (i32.const 0x10E00) "\00\00\00\00\00\00\00\00\00\18\00\18\18\18\18\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\18\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00<fffff<\00~\18\18\18\188\18\00~`0\0c\06f<\00<f\06\1c\06f<\00\0c\0c~L,\1c\0c\00<f\06\06|`~\00<ff|``<\00000\18\0c\06~\00<ff<ff<\00<\06\06>ff<\00\00\18\00\00\18\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00ff~ff<\18\00|ff|ff|\00<f```f<\00\7c\66\63\63\63\66\7c\00~``|``~\00```|``~\00<ffn`f<\00fff~fff\00<\18\18\18\18\18<\00<f\06\06\06\06\06\00flxpxlf\00~``````\00ccck\7fwc\00fnn~vvf\00<fffff<\00```|ff|\00\0e<nfff<\00ffl|ff|\00<f\06<`f<\00\18\18\18\18\18\18~\00<ffffff\00\18<fffff\00cw\7fkccc\00ff<\18<ff\00\18\18\18<fff\00~`0\18\0c\06~\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00")

  ;; Strings at 0x11100+
  (data (i32.const 0x11100) "THE YEAR IS 2187")
  (data (i32.const 0x11110) "THE LAST COLONY SHIP")
  (data (i32.const 0x11124) "APPROACHES THE FRONTIER")
  (data (i32.const 0x1113C) "BUT SOMETHING WAITS")
  (data (i32.const 0x11150) "IN THE DARKNESS...")
  (data (i32.const 0x11168) "YOUR SHIP: MK")
  (data (i32.const 0x11178) "STELLAR\00ASSAULT\00")
  (data (i32.const 0x11188) "CLICK TO START")
  (data (i32.const 0x11198) "GAME OVER")
  (data (i32.const 0x111A1) "VICTORY")
  (data (i32.const 0x111A8) "CLICK TO RESTART")
  (data (i32.const 0x111C0) "HULL BREACH")
  (data (i32.const 0x111CC) "SHIELDS DOWN")
  (data (i32.const 0x111D8) "DAMAGE CRITICAL")
  (data (i32.const 0x12388) "SC: ")

  ;; Music patterns (MIDI-note format, read by harness from memory)
  ;; Format: bpm(u16) steps(u8) tracks(u8) [type vol dur pad]×3 notes...
  ;; Pattern 1: INTRO (100 BPM) at 0x12400
  (data (i32.const 0x12400) "\64\00\40\03\03\66\28\00\00\33\32\00\00\2b\1e\00\2d\00\00\00\00\00\2d\00\00\00\00\00\2d\00\00\00\28\00\00\00\00\00\28\00\00\00\00\00\28\00\00\00\26\00\00\00\00\00\26\00\00\00\00\00\26\00\00\00\28\00\00\00\00\00\00\00\28\00\28\00\00\00\00\00\39\00\00\3c\00\00\39\00\40\00\00\00\3c\00\39\00\34\00\00\37\00\00\3b\00\00\00\37\00\34\00\00\00\32\00\00\35\00\00\39\00\00\00\35\00\32\00\00\00\34\00\00\38\00\00\3b\00\40\00\00\00\3b\00\38\00\00\00\00\00\48\00\00\00\00\00\00\00\00\00\45\00\00\00\00\00\47\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\45\00\00\00\00\00\00\00\00\00\41\00\00\00\00\00\00\00\44\00\00\00\00\00\47\00\00\00")
  ;; Pattern 2: GAMEPLAY (150 BPM) at 0x12500
  (data (i32.const 0x12500) "\96\00\40\03\01\80\08\00\03\66\06\00\01\55\0c\00\2d\00\2d\00\2d\00\2d\2d\2d\00\2d\00\2d\00\34\00\2b\00\2b\00\2b\00\2b\2b\2b\00\2b\00\2b\00\32\00\29\00\29\00\29\00\29\29\29\00\29\00\29\00\30\00\28\00\28\00\28\00\28\28\28\00\28\00\28\00\2d\00\45\48\4c\48\45\48\4c\4f\4c\48\45\48\4c\4f\4c\48\43\47\4a\47\43\47\4a\4f\4a\47\43\47\4a\4f\4a\47\41\45\48\45\41\45\48\4d\48\45\41\45\48\4d\48\45\40\44\47\44\40\44\47\4c\47\44\40\44\47\4c\47\44\51\00\4f\51\00\00\4c\00\4f\00\4c\00\48\00\4c\00\4f\00\4c\4f\00\00\4a\00\47\00\4a\00\47\00\43\00\4d\00\4c\4d\00\00\48\00\45\00\48\00\45\00\41\00\4c\00\00\47\4c\00\4f\00\51\00\4f\4c\00\00\00\00")
  ;; Pattern 3: GAME OVER (80 BPM) at 0x12600
  (data (i32.const 0x12600) "\50\00\40\03\03\66\23\00\00\44\28\00\00\3c\1e\00\26\00\00\00\00\00\00\00\26\00\00\00\00\00\00\00\22\00\00\00\00\00\00\00\22\00\00\00\00\00\00\00\1f\00\00\00\00\00\00\00\1f\00\00\00\00\00\00\00\21\00\00\00\00\00\00\00\21\00\21\00\00\00\00\00\3e\00\00\41\00\00\00\00\3c\00\00\00\00\00\00\00\3a\00\00\3e\00\00\00\00\3a\00\00\00\00\00\00\00\37\00\00\3a\00\00\00\00\37\00\00\00\00\00\00\00\39\00\00\3d\00\00\00\00\39\00\00\00\00\00\00\00\4a\00\00\00\48\00\00\00\45\00\00\00\00\00\00\00\46\00\00\00\45\00\00\00\41\00\00\00\00\00\00\00\43\00\00\00\41\00\00\00\3e\00\00\00\00\00\00\00\40\00\00\00\3d\00\00\00\39\00\00\00\00\00\00\00")
  ;; SFX definitions (voice-based format, read by harness from memory)
  ;; Format: num_voices(u8) pad(u8) then per voice: type vol dur freq_start freq_end delay pad pad
  ;; SFX 0: laser (1 voice)
  (data (i32.const 0x12800) "\01\00\01\60\08\51\39\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00")
  ;; SFX 1: explosion (2 voices)
  (data (i32.const 0x12844) "\02\00\04\bf\0c\00\00\00\00\00\00\80\0f\23\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00")
  ;; SFX 2: pickup (8 voices — rising arpeggio)
  (data (i32.const 0x12888) "\08\00\01\73\06\48\00\00\00\00\00\40\06\48\00\00\00\00\01\73\06\4c\00\3c\00\00\00\40\06\4c\00\3c\00\00\01\73\06\4f\00\78\00\00\00\40\06\4f\00\78\00\00\01\80\0c\54\00\b4\00\00\00\4d\0c\54\00\b4\00\00\00\00")
  ;; SFX 3: hit (5 voices — crunch + rumble)
  (data (i32.const 0x128CC) "\05\00\04\df\0f\00\00\00\00\00\01\9f\0c\32\17\00\00\00\02\60\14\27\0f\00\00\00\04\80\08\00\00\50\00\00\00\60\0f\1b\00\50\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00")
  ;; SFX 4: boss (1 voice)
  (data (i32.const 0x12910) "\01\00\02\80\14\2d\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00")
  ;; SFX address lookup table (5 entries × 4 bytes at 0x12BE0)
  (data (i32.const 0x12BE0) "\00\28\01\00\44\28\01\00\88\28\01\00\cc\28\01\00\10\29\01\00")

  ;; Pattern 4: BOSS FIGHT (180 BPM) at 0x12700
  (data (i32.const 0x12700) "\b4\00\40\03\02\99\07\00\01\66\05\00\02\55\0a\00\28\28\00\28\28\00\28\00\28\28\00\28\00\28\28\00\29\29\00\29\29\00\29\00\29\29\00\29\00\29\29\00\2b\2b\00\2b\2b\00\2b\00\2b\2b\00\2b\00\2b\2b\00\2c\2c\00\2c\2c\00\2c\00\2c\2c\00\2c\00\28\28\00\40\47\4c\47\40\4c\47\4c\40\47\4c\4f\4c\47\40\47\41\48\4d\48\41\4d\48\4d\41\48\4d\51\4d\48\41\48\43\4a\4f\4a\43\4f\4a\4f\43\4a\4f\53\4f\4a\43\4a\44\4b\50\4b\44\50\4b\50\44\4b\50\54\50\4b\40\47\4c\00\4b\00\4c\00\4f\00\4c\00\47\00\00\00\40\00\4d\00\4c\00\4d\00\51\00\4d\00\48\00\00\00\41\00\4f\00\4d\00\4f\00\53\00\4f\00\4a\00\00\00\43\00\50\00\4f\00\51\00\54\00\51\00\4c\00\00\00\00\00")

  ;; ============================================================
  ;; INIT SIN TABLE
  ;; ============================================================

  (func $init_sin_table
    (local $i i32) (local $val i32) (local $angle f64)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 256)))
      (local.set $angle (f64.mul (f64.div (f64.convert_i32_u (local.get $i)) (f64.const 256.0)) (f64.const 6.2832)))
      (local.set $val (i32.trunc_f64_s (f64.add (f64.mul (call $sin_approx (local.get $angle)) (f64.const 127.0)) (f64.const 128.0))))
      (if (i32.lt_s (local.get $val) (i32.const 0)) (then (local.set $val (i32.const 0))))
      (if (i32.gt_s (local.get $val) (i32.const 255)) (then (local.set $val (i32.const 255))))
      (i32.store8 (i32.add (i32.const 0x10CF0) (local.get $i)) (local.get $val))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; ============================================================
  ;; MAIN INIT + FRAME
  ;; ============================================================

  (func (export "init")
    ;; seed PRNG
    (i32.store (i32.const 0x10DF0) (i32.const 314159265))
    ;; init subsystems
    (call $setup_palette)
    (call $init_sin_table)
    ;; font + strings initialized via data segments
    (call $init_stars)
    ;; start at phase 0 (story)
    (i32.store8 (i32.const 0x10340) (i32.const 0))
    (i32.store16 (i32.const 0x10342) (i32.const 0))
  )

  (func (export "frame")
    (local $phase i32) (local $timer i32)
    (local $btn i32) (local $keys i32) (local $new_btn i32) (local $new_keys i32)
    ;; increment phase timer
    (local.set $timer (i32.add (i32.load16_u (i32.const 0x10342)) (i32.const 1)))
    (i32.store16 (i32.const 0x10342) (local.get $timer))
    ;; read current input and compute rising edges
    (local.set $btn (i32.load8_u (i32.const 0x08)))
    (local.set $keys (i32.load8_u (i32.const 0x10)))
    (local.set $new_btn (i32.and (local.get $btn)
      (i32.xor (i32.load8_u (i32.const 0x10357)) (i32.const 0xFF))))
    (local.set $new_keys (i32.and (local.get $keys)
      (i32.xor (i32.load8_u (i32.const 0x10358)) (i32.const 0xFF))))
    ;; dispatch on phase
    (local.set $phase (i32.load8_u (i32.const 0x10340)))
    ;; start intro music once (0x10356 = music state: 0=need intro, 1=intro playing, 2=gameplay)
    (if (i32.and (i32.lt_u (local.get $phase) (i32.const 5))
                 (i32.eqz (i32.load8_u (i32.const 0x10356))))
      (then
        (call $music (i32.const 0x12400))
        (i32.store8 (i32.const 0x10356) (i32.const 1))
      )
    )
    ;; skip intro on NEW click or space — require timer>30 to avoid accidental skip
    (if (i32.and
          (i32.lt_u (local.get $phase) (i32.const 5))
          (i32.gt_u (local.get $timer) (i32.const 30)))
      (then
        (if (i32.or
              (i32.and (local.get $new_btn) (i32.const 1))     ;; newly pressed mouse left
              (i32.and (local.get $new_keys) (i32.const 16)))  ;; newly pressed space
          (then
            ;; jump to gameplay
            (call $music (i32.const 0x12500))
            (i32.store8 (i32.const 0x10340) (i32.const 5))
            (i32.store16 (i32.const 0x10342) (i32.const 0))
            (i32.store16 (i32.const 0x10360) (i32.const 40))
            (i32.store16 (i32.const 0x10362) (i32.const 100))
            (i32.store8 (i32.const 0x10348) (i32.const 3))
            (i32.store8 (i32.const 0x10349) (i32.const 0))
            (i32.store (i32.const 0x10344) (i32.const 0))
            (i32.store8 (i32.const 0x1034A) (i32.const 0))
            (i32.store8 (i32.const 0x1034B) (i32.const 60))
            (i32.store8 (i32.const 0x1034C) (i32.const 0))
            ;; save prev input before returning
            (i32.store8 (i32.const 0x10357) (local.get $btn))
            (i32.store8 (i32.const 0x10358) (local.get $keys))
            (i32.store16 (i32.const 0x1035A) (i32.load16_u (i32.const 0x04)))
            (i32.store16 (i32.const 0x1035C) (i32.load16_u (i32.const 0x06)))
            (call $phase_gameplay)
            (return)
          )
        )
      )
    )
    (if (i32.eqz (local.get $phase)) (then (call $phase_story)))
    (if (i32.eq (local.get $phase) (i32.const 1)) (then (call $phase_planet)))
    (if (i32.eq (local.get $phase) (i32.const 2)) (then (call $phase_ship)))
    (if (i32.eq (local.get $phase) (i32.const 3)) (then (call $phase_title)))
    (if (i32.eq (local.get $phase) (i32.const 4)) (then (call $phase_press_fire)))
    (if (i32.eq (local.get $phase) (i32.const 5)) (then (call $phase_gameplay)))
    (if (i32.eq (local.get $phase) (i32.const 6)) (then (call $phase_game_over)))
    ;; save prev input state at end of frame
    (i32.store8 (i32.const 0x10357) (local.get $btn))
    (i32.store8 (i32.const 0x10358) (local.get $keys))
    (i32.store16 (i32.const 0x1035A) (i32.load16_u (i32.const 0x04)))
    (i32.store16 (i32.const 0x1035C) (i32.load16_u (i32.const 0x06)))
  )
)
