(module
  (import "env" "memory" (memory 4))
  (import "env" "sfx" (func $sfx (param i32)))
  (import "env" "note" (func $note (param i32 i32 i32 i32)))
  (import "env" "music" (func $music (param i32)))

  ;; ============================================================
  ;; ARKANOID — Brick-breaking arcade game
  ;; ============================================================
  ;; Controls: Mouse X / Left-Right arrows to move paddle
  ;;           Click / Space to launch ball
  ;;
  ;; Memory layout:
  ;;   0x10340  CONST DATA (sin table, font, brick colors, etc.)
  ;;   0x10340  sin table (256 bytes)
  ;;   0x10440  font data (96 * 8 = 768 bytes)
  ;;   0x10740  brick color table (8 * 3 = 24 bytes)
  ;;   0x10760  powerup color table (8 * 3 = 24)
  ;;   0x10700  title text
  ;;   0x10800  SFX data (multiple sound defs)
  ;;   0x10A00  music pattern data
  ;;
  ;;   DYNAMIC DATA (top of guest area, growing down):
  ;;   0x3F000  PRNG state (4 bytes)
  ;;   0x3F004  game state (64 bytes)
  ;;   0x3F044  paddle state (16 bytes)
  ;;   0x3F054  ball state (3 balls * 20 bytes = 60)
  ;;   0x3F090  bricks (14 cols * 8 rows * 4 bytes = 448)
  ;;   0x3F250  particles (64 * 16 bytes = 1024)
  ;;   0x3F650  powerups (8 * 12 bytes = 96)
  ;;   0x3F6B0  star field (64 * 4 bytes = 256)
  ;; ============================================================

  ;; --- Game state at 0x3F004 ---
  ;; +0: phase (u8): 0=title, 1=playing, 2=game_over, 3=level_complete, 4=you_win
  ;; +1: lives (u8)
  ;; +2: level (u8)
  ;; +4: score (u32)
  ;; +8: combo (u16)
  ;; +10: combo_timer (u16)
  ;; +12: prev_input (u8)
  ;; +13: shake_timer (u8)
  ;; +14: flash_timer (u8)
  ;; +16: bricks_left (u16)
  ;; +18: phase_timer (u16)
  ;; +20: music_state (u8)

  ;; --- Paddle at 0x3F044 ---
  ;; +0: x (i16, 8.8 fixed point center)
  ;; +2: width (u8, half-width in pixels)
  ;; +3: sticky (u8, ball sticks to paddle)

  ;; --- Ball at 0x3F054 (each 20 bytes) ---
  ;; +0: active (u8)
  ;; +1: pad
  ;; +2: x (i32, 16.16 fixed)
  ;; +6: y (i32, 16.16 fixed — NOT USED, stored at +8)
  ;; +8: y (i32, 16.16 fixed)
  ;; +12: dx (i32, 16.16 fixed)
  ;; +16: dy (i32, 16.16 fixed)

  ;; --- Brick at 0x3F090 (each 4 bytes) ---
  ;; +0: type (u8): 0=empty, 1-7=color, 8=silver(2hits), 9=gold(indestructible)
  ;; +1: hits_left (u8)
  ;; +2: anim (u8) — hit flash timer
  ;; +3: pad

  ;; --- Particle at 0x3F250 (each 16 bytes) ---
  ;; +0: active (u8)
  ;; +1: color (u8)
  ;; +2: x (i16, 8.8 fixed)
  ;; +4: y (i16, 8.8 fixed)  — actually stored as u16
  ;; +6: dx (i16, 8.8 fixed)
  ;; +8: dy (i16, 8.8 fixed)
  ;; +10: life (u8)
  ;; +11: pad

  ;; --- Powerup at 0x3F650 (each 12 bytes) ---
  ;; +0: active (u8)
  ;; +1: type (u8): 0=extend, 1=multi, 2=slow, 3=life, 4=fire
  ;; +2: x (u16)
  ;; +4: y (u16, 8.8 fixed)
  ;; +6: pad

  ;; --- Stars at 0x3F6B0 (each 4 bytes) ---
  ;; +0: x (u16)
  ;; +2: y (u8)
  ;; +3: speed (u8)

  ;; Brick layout constants
  ;; 14 columns x 8 rows, each brick 20x8 pixels
  ;; Left margin = (320 - 14*20) / 2 = 20
  ;; Top margin = 30

  ;; ========================
  ;; PRNG (xorshift32)
  ;; ========================
  (func $rand (result i32)
    (local $s i32)
    (local.set $s (i32.load (i32.const 0x3F000)))
    (if (i32.eqz (local.get $s)) (then (local.set $s (i32.const 987654321))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 13))))
    (local.set $s (i32.xor (local.get $s) (i32.shr_u (local.get $s) (i32.const 17))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 5))))
    (i32.store (i32.const 0x3F000) (local.get $s))
    (local.get $s)
  )

  ;; ========================
  ;; put_pixel (x, y, color)
  ;; ========================
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

  ;; ========================
  ;; fill_rect (x, y, w, h, color)
  ;; ========================
  (func $fill_rect (param $x i32) (param $y i32) (param $w i32) (param $h i32) (param $c i32)
    (local $ix i32) (local $iy i32)
    (local.set $iy (i32.const 0))
    (block $done
      (loop $ly
        (br_if $done (i32.ge_s (local.get $iy) (local.get $h)))
        (local.set $ix (i32.const 0))
        (block $done2
          (loop $lx
            (br_if $done2 (i32.ge_s (local.get $ix) (local.get $w)))
            (call $put_pixel
              (i32.add (local.get $x) (local.get $ix))
              (i32.add (local.get $y) (local.get $iy))
              (local.get $c))
            (local.set $ix (i32.add (local.get $ix) (i32.const 1)))
            (br $lx)
          )
        )
        (local.set $iy (i32.add (local.get $iy) (i32.const 1)))
        (br $ly)
      )
    )
  )

  ;; ========================
  ;; draw_char (char_code, x, y, color)
  ;; ========================
  (func $draw_char (param $ch i32) (param $x i32) (param $y i32) (param $c i32)
    (local $row i32) (local $col i32) (local $bits i32)
    (local $font_addr i32)
    ;; font starts at 0x10440, each char is 8 bytes (8x8)
    ;; char_code - 32 = index
    (local.set $font_addr (i32.add (i32.const 0x10440)
      (i32.mul (i32.sub (local.get $ch) (i32.const 32)) (i32.const 8))))
    (local.set $row (i32.const 0))
    (block $done
      (loop $lr
        (br_if $done (i32.ge_s (local.get $row) (i32.const 8)))
        (local.set $bits (i32.load8_u (i32.add (local.get $font_addr) (local.get $row))))
        (local.set $col (i32.const 0))
        (block $done2
          (loop $lc
            (br_if $done2 (i32.ge_s (local.get $col) (i32.const 8)))
            (if (i32.and (local.get $bits) (i32.shl (i32.const 128) (i32.const 0)))
              (then
                (if (i32.and (local.get $bits) (i32.shr_u (i32.const 128) (local.get $col)))
                  (then
                    (call $put_pixel
                      (i32.add (local.get $x) (local.get $col))
                      (i32.add (local.get $y) (local.get $row))
                      (local.get $c))
                  )
                )
              )
            )
            (local.set $col (i32.add (local.get $col) (i32.const 1)))
            (br $lc)
          )
        )
        (local.set $row (i32.add (local.get $row) (i32.const 1)))
        (br $lr)
      )
    )
  )

  ;; Simplified draw_char — just check each bit
  (func $draw_char2 (param $ch i32) (param $x i32) (param $y i32) (param $c i32)
    (local $row i32) (local $col i32) (local $bits i32)
    (local $font_addr i32)
    (local.set $font_addr (i32.add (i32.const 0x10440)
      (i32.mul (i32.sub (local.get $ch) (i32.const 32)) (i32.const 8))))
    (local.set $row (i32.const 0))
    (block $done
      (loop $lr
        (br_if $done (i32.ge_s (local.get $row) (i32.const 8)))
        (local.set $bits (i32.load8_u (i32.add (local.get $font_addr) (local.get $row))))
        (local.set $col (i32.const 0))
        (block $done2
          (loop $lc
            (br_if $done2 (i32.ge_s (local.get $col) (i32.const 8)))
            (if (i32.and (local.get $bits) (i32.shr_u (i32.const 128) (local.get $col)))
              (then
                (call $put_pixel
                  (i32.add (local.get $x) (local.get $col))
                  (i32.add (local.get $y) (local.get $row))
                  (local.get $c))
              )
            )
            (local.set $col (i32.add (local.get $col) (i32.const 1)))
            (br $lc)
          )
        )
        (local.set $row (i32.add (local.get $row) (i32.const 1)))
        (br $lr)
      )
    )
  )

  ;; ========================
  ;; draw_string (addr, x, y, color)  — null-terminated
  ;; ========================
  (func $draw_string (param $addr i32) (param $x i32) (param $y i32) (param $c i32)
    (local $ch i32) (local $ox i32)
    (local.set $ox (local.get $x))
    (block $done
      (loop $lp
        (local.set $ch (i32.load8_u (local.get $addr)))
        (br_if $done (i32.eqz (local.get $ch)))
        (call $draw_char2 (local.get $ch) (local.get $ox) (local.get $y) (local.get $c))
        (local.set $ox (i32.add (local.get $ox) (i32.const 8)))
        (local.set $addr (i32.add (local.get $addr) (i32.const 1)))
        (br $lp)
      )
    )
  )

  ;; ========================
  ;; draw_number (value, x, y, color, digits)
  ;; ========================
  (func $draw_number (param $val i32) (param $x i32) (param $y i32) (param $c i32) (param $digits i32)
    (local $d i32) (local $pow i32) (local $ox i32) (local $digit i32)
    (local.set $ox (local.get $x))
    ;; compute 10^(digits-1)
    (local.set $pow (i32.const 1))
    (local.set $d (i32.sub (local.get $digits) (i32.const 1)))
    (block $done
      (loop $lp
        (br_if $done (i32.le_s (local.get $d) (i32.const 0)))
        (local.set $pow (i32.mul (local.get $pow) (i32.const 10)))
        (local.set $d (i32.sub (local.get $d) (i32.const 1)))
        (br $lp)
      )
    )
    ;; draw each digit
    (block $done2
      (loop $lp2
        (br_if $done2 (i32.eqz (local.get $pow)))
        (local.set $digit (i32.div_u (local.get $val) (local.get $pow)))
        (local.set $val (i32.rem_u (local.get $val) (local.get $pow)))
        (call $draw_char2 (i32.add (local.get $digit) (i32.const 48))
          (local.get $ox) (local.get $y) (local.get $c))
        (local.set $ox (i32.add (local.get $ox) (i32.const 8)))
        (local.set $pow (i32.div_u (local.get $pow) (i32.const 10)))
        (br $lp2)
      )
    )
  )

  ;; ========================
  ;; spawn_particles (x, y, color, count)
  ;; ========================
  (func $spawn_particles (param $x i32) (param $y i32) (param $color i32) (param $count i32)
    (local $i i32) (local $addr i32) (local $r i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
        ;; find free particle slot
        (block $found
          (local.set $addr (i32.const 0x3F250))
          (block $nofree
            (loop $search
              (br_if $nofree (i32.ge_u (local.get $addr) (i32.const 0x3F650)))
              (br_if $found (i32.eqz (i32.load8_u (local.get $addr))))
              (local.set $addr (i32.add (local.get $addr) (i32.const 16)))
              (br $search)
            )
          )
          (br $done) ;; no free slots
        )
        ;; activate particle
        (i32.store8 (local.get $addr) (i32.const 1)) ;; active
        (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $color))
        ;; x in 8.8 fixed
        (i32.store16 (i32.add (local.get $addr) (i32.const 2))
          (i32.shl (local.get $x) (i32.const 8)))
        ;; y in 8.8 fixed
        (i32.store16 (i32.add (local.get $addr) (i32.const 4))
          (i32.shl (local.get $y) (i32.const 8)))
        ;; random dx (-3..3 in 8.8)
        (local.set $r (call $rand))
        (i32.store16 (i32.add (local.get $addr) (i32.const 6))
          (i32.sub (i32.and (local.get $r) (i32.const 0x3FF)) (i32.const 0x200)))
        ;; random dy (-5..0 in 8.8)  — mostly upward
        (local.set $r (call $rand))
        (i32.store16 (i32.add (local.get $addr) (i32.const 8))
          (i32.sub (i32.and (local.get $r) (i32.const 0x3FF)) (i32.const 0x380)))
        ;; life = 20-40 frames
        (local.set $r (call $rand))
        (i32.store8 (i32.add (local.get $addr) (i32.const 10))
          (i32.add (i32.and (local.get $r) (i32.const 31)) (i32.const 15)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )
  )

  ;; ========================
  ;; update_particles
  ;; ========================
  (func $update_particles
    (local $addr i32) (local $x i32) (local $y i32) (local $dy i32) (local $life i32)
    (local.set $addr (i32.const 0x3F250))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $addr) (i32.const 0x3F650)))
        (if (i32.load8_u (local.get $addr))
          (then
            ;; update position
            (i32.store16 (i32.add (local.get $addr) (i32.const 2))
              (i32.add
                (i32.load16_s (i32.add (local.get $addr) (i32.const 2)))
                (i32.load16_s (i32.add (local.get $addr) (i32.const 6)))))
            (i32.store16 (i32.add (local.get $addr) (i32.const 4))
              (i32.add
                (i32.load16_s (i32.add (local.get $addr) (i32.const 4)))
                (i32.load16_s (i32.add (local.get $addr) (i32.const 8)))))
            ;; gravity: dy += 0x18 (small downward accel)
            (local.set $dy (i32.load16_s (i32.add (local.get $addr) (i32.const 8))))
            (i32.store16 (i32.add (local.get $addr) (i32.const 8))
              (i32.add (local.get $dy) (i32.const 0x18)))
            ;; decrease life
            (local.set $life (i32.load8_u (i32.add (local.get $addr) (i32.const 10))))
            (if (i32.le_s (local.get $life) (i32.const 1))
              (then (i32.store8 (local.get $addr) (i32.const 0))) ;; deactivate
              (else (i32.store8 (i32.add (local.get $addr) (i32.const 10))
                (i32.sub (local.get $life) (i32.const 1))))
            )
          )
        )
        (local.set $addr (i32.add (local.get $addr) (i32.const 16)))
        (br $lp)
      )
    )
  )

  ;; ========================
  ;; draw_particles
  ;; ========================
  (func $draw_particles
    (local $addr i32) (local $x i32) (local $y i32) (local $color i32) (local $life i32)
    (local.set $addr (i32.const 0x3F250))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $addr) (i32.const 0x3F650)))
        (if (i32.load8_u (local.get $addr))
          (then
            (local.set $x (i32.shr_s (i32.load16_s (i32.add (local.get $addr) (i32.const 2))) (i32.const 8)))
            (local.set $y (i32.shr_s (i32.load16_s (i32.add (local.get $addr) (i32.const 4))) (i32.const 8)))
            (local.set $color (i32.load8_u (i32.add (local.get $addr) (i32.const 1))))
            (local.set $life (i32.load8_u (i32.add (local.get $addr) (i32.const 10))))
            ;; draw 2x2 if young, 1x1 if old
            (call $put_pixel (local.get $x) (local.get $y) (local.get $color))
            (if (i32.gt_u (local.get $life) (i32.const 8))
              (then
                (call $put_pixel (i32.add (local.get $x) (i32.const 1)) (local.get $y) (local.get $color))
                (call $put_pixel (local.get $x) (i32.add (local.get $y) (i32.const 1)) (local.get $color))
              )
            )
          )
        )
        (local.set $addr (i32.add (local.get $addr) (i32.const 16)))
        (br $lp)
      )
    )
  )

  ;; ========================
  ;; spawn_powerup (x, y)
  ;; ========================
  (func $spawn_powerup (param $x i32) (param $y i32)
    (local $addr i32) (local $r i32)
    ;; only 15% chance
    (local.set $r (call $rand))
    (if (i32.gt_u (i32.rem_u (i32.and (local.get $r) (i32.const 0x7FFFFFFF)) (i32.const 100)) (i32.const 14))
      (then return)
    )
    ;; find free slot
    (local.set $addr (i32.const 0x3F650))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $addr) (i32.const 0x3F6B0)))
        (if (i32.eqz (i32.load8_u (local.get $addr)))
          (then
            (i32.store8 (local.get $addr) (i32.const 1)) ;; active
            ;; random type 0-4
            (local.set $r (call $rand))
            (i32.store8 (i32.add (local.get $addr) (i32.const 1))
              (i32.rem_u (i32.and (local.get $r) (i32.const 0x7FFFFFFF)) (i32.const 5)))
            (i32.store16 (i32.add (local.get $addr) (i32.const 2)) (local.get $x))
            (i32.store16 (i32.add (local.get $addr) (i32.const 4))
              (i32.shl (local.get $y) (i32.const 8)))
            (return)
          )
        )
        (local.set $addr (i32.add (local.get $addr) (i32.const 12)))
        (br $lp)
      )
    )
  )

  ;; ========================
  ;; update_powerups
  ;; ========================
  (func $update_powerups
    (local $addr i32) (local $y i32) (local $px i32) (local $py i32)
    (local $paddle_x i32) (local $paddle_w i32) (local $type i32)
    (local.set $paddle_x (i32.load16_s (i32.const 0x3F044)))
    (local.set $paddle_w (i32.load8_u (i32.add (i32.const 0x3F044) (i32.const 2))))
    (local.set $addr (i32.const 0x3F650))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $addr) (i32.const 0x3F6B0)))
        (if (i32.load8_u (local.get $addr))
          (then
            ;; move down
            (local.set $y (i32.load16_u (i32.add (local.get $addr) (i32.const 4))))
            (local.set $y (i32.add (local.get $y) (i32.const 0xC0))) ;; ~0.75 pixel/frame
            (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $y))
            (local.set $py (i32.shr_u (local.get $y) (i32.const 8)))
            (local.set $px (i32.load16_u (i32.add (local.get $addr) (i32.const 2))))
            ;; off screen?
            (if (i32.gt_u (local.get $py) (i32.const 200))
              (then (i32.store8 (local.get $addr) (i32.const 0)))
              (else
                ;; check paddle collision (paddle y = 185)
                (if (i32.and
                  (i32.ge_u (local.get $py) (i32.const 182))
                  (i32.and
                    (i32.ge_s (local.get $px) (i32.sub (local.get $paddle_x) (local.get $paddle_w)))
                    (i32.le_s (local.get $px) (i32.add (local.get $paddle_x) (local.get $paddle_w)))))
                  (then
                    ;; collected!
                    (local.set $type (i32.load8_u (i32.add (local.get $addr) (i32.const 1))))
                    (i32.store8 (local.get $addr) (i32.const 0))
                    (call $apply_powerup (local.get $type))
                    ;; powerup sound
                    (call $note (i32.const 0) (i32.const 880) (i32.const 60) (i32.const 100))
                    (call $note (i32.const 0) (i32.const 1100) (i32.const 60) (i32.const 100))
                    (call $note (i32.const 0) (i32.const 1320) (i32.const 80) (i32.const 120))
                    ;; particles
                    (call $spawn_particles (local.get $px) (local.get $py) (i32.const 15) (i32.const 8))
                  )
                )
              )
            )
          )
        )
        (local.set $addr (i32.add (local.get $addr) (i32.const 12)))
        (br $lp)
      )
    )
  )

  ;; ========================
  ;; draw_powerups — pill capsule with centered letter
  ;; ========================
  (func $draw_powerups
    (local $addr i32) (local $px i32) (local $py i32) (local $type i32)
    (local $color i32) (local $dark i32) (local $frame i32) (local $letter i32)
    (local $left i32) (local $top i32)
    (local.set $frame (i32.load (i32.const 0x00)))
    (local.set $addr (i32.const 0x3F650))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $addr) (i32.const 0x3F6B0)))
        (if (i32.load8_u (local.get $addr))
          (then
            (local.set $px (i32.load16_u (i32.add (local.get $addr) (i32.const 2))))
            (local.set $py (i32.shr_u (i32.load16_u (i32.add (local.get $addr) (i32.const 4))) (i32.const 8)))
            (local.set $type (i32.load8_u (i32.add (local.get $addr) (i32.const 1))))
            ;; color based on type: 0=green(10), 1=cyan(11), 2=blue(9), 3=red(12), 4=yellow(14)
            (local.set $color
              (select (i32.const 10)
                (select (i32.const 11)
                  (select (i32.const 9)
                    (select (i32.const 12) (i32.const 14)
                      (i32.eq (local.get $type) (i32.const 3)))
                    (i32.eq (local.get $type) (i32.const 2)))
                  (i32.eq (local.get $type) (i32.const 1)))
                (i32.eq (local.get $type) (i32.const 0))))
            ;; darker shade for border
            (local.set $dark
              (select (i32.const 2)
                (select (i32.const 3)
                  (select (i32.const 1)
                    (select (i32.const 4) (i32.const 6)
                      (i32.eq (local.get $type) (i32.const 3)))
                    (i32.eq (local.get $type) (i32.const 2)))
                  (i32.eq (local.get $type) (i32.const 1)))
                (i32.eq (local.get $type) (i32.const 0))))
            ;; letter for each type
            (local.set $letter
              (select (i32.const 69) ;; E
                (select (i32.const 77) ;; M
                  (select (i32.const 83) ;; S
                    (select (i32.const 76) (i32.const 70) ;; L or F
                      (i32.eq (local.get $type) (i32.const 3)))
                    (i32.eq (local.get $type) (i32.const 2)))
                  (i32.eq (local.get $type) (i32.const 1)))
                (i32.eq (local.get $type) (i32.const 0))))
            ;; capsule: 16 wide x 10 tall, centered on px,py
            (local.set $left (i32.sub (local.get $px) (i32.const 8)))
            (local.set $top (i32.sub (local.get $py) (i32.const 1)))
            ;; dark border/shadow
            (call $fill_rect (i32.add (local.get $left) (i32.const 2)) (local.get $top)
              (i32.const 12) (i32.const 10) (local.get $dark))
            ;; main body
            (call $fill_rect (i32.add (local.get $left) (i32.const 2)) (i32.add (local.get $top) (i32.const 1))
              (i32.const 12) (i32.const 8) (local.get $color))
            ;; rounded ends (left pill cap)
            (call $fill_rect (i32.add (local.get $left) (i32.const 1)) (i32.add (local.get $top) (i32.const 2))
              (i32.const 1) (i32.const 6) (local.get $color))
            ;; rounded ends (right pill cap)
            (call $fill_rect (i32.add (local.get $left) (i32.const 14)) (i32.add (local.get $top) (i32.const 2))
              (i32.const 1) (i32.const 6) (local.get $color))
            ;; highlight stripe on top
            (call $fill_rect (i32.add (local.get $left) (i32.const 3)) (i32.add (local.get $top) (i32.const 1))
              (i32.const 10) (i32.const 1) (i32.const 15))
            ;; highlight dot
            (call $put_pixel (i32.add (local.get $left) (i32.const 3)) (i32.add (local.get $top) (i32.const 2)) (i32.const 15))
            ;; draw letter centered (8x8 char at left+4, top+1)
            (call $draw_char2 (local.get $letter)
              (i32.add (local.get $left) (i32.const 4))
              (i32.add (local.get $top) (i32.const 1))
              (i32.const 15))
          )
        )
        (local.set $addr (i32.add (local.get $addr) (i32.const 12)))
        (br $lp)
      )
    )
  )

  ;; ========================
  ;; apply_powerup
  ;; ========================
  (func $apply_powerup (param $type i32)
    (local $i i32) (local $addr i32) (local $ball0 i32)
    ;; 0=extend paddle, 1=multi ball, 2=slow, 3=extra life, 4=fire (not implemented, just score)
    (if (i32.eq (local.get $type) (i32.const 0))
      (then
        ;; extend paddle width (max 40)
        (i32.store8 (i32.add (i32.const 0x3F044) (i32.const 2))
          (select (i32.const 40)
            (i32.add (i32.load8_u (i32.add (i32.const 0x3F044) (i32.const 2))) (i32.const 8))
            (i32.gt_u
              (i32.add (i32.load8_u (i32.add (i32.const 0x3F044) (i32.const 2))) (i32.const 8))
              (i32.const 40))))
      )
    )
    (if (i32.eq (local.get $type) (i32.const 1))
      (then
        ;; multi: activate balls 1 and 2 from ball 0's position
        (local.set $ball0 (i32.const 0x3F054))
        (if (i32.load8_u (local.get $ball0))
          (then
            ;; ball 1
            (local.set $addr (i32.add (local.get $ball0) (i32.const 20)))
            (if (i32.eqz (i32.load8_u (local.get $addr)))
              (then
                (i32.store8 (local.get $addr) (i32.const 1))
                (i32.store (i32.add (local.get $addr) (i32.const 2))
                  (i32.load (i32.add (local.get $ball0) (i32.const 2))))
                (i32.store (i32.add (local.get $addr) (i32.const 8))
                  (i32.load (i32.add (local.get $ball0) (i32.const 8))))
                ;; different angle
                (i32.store (i32.add (local.get $addr) (i32.const 12)) (i32.const 0xFFFF0000)) ;; dx = -1
                (i32.store (i32.add (local.get $addr) (i32.const 16))
                  (i32.load (i32.add (local.get $ball0) (i32.const 16))))
              )
            )
            ;; ball 2
            (local.set $addr (i32.add (local.get $ball0) (i32.const 40)))
            (if (i32.eqz (i32.load8_u (local.get $addr)))
              (then
                (i32.store8 (local.get $addr) (i32.const 1))
                (i32.store (i32.add (local.get $addr) (i32.const 2))
                  (i32.load (i32.add (local.get $ball0) (i32.const 2))))
                (i32.store (i32.add (local.get $addr) (i32.const 8))
                  (i32.load (i32.add (local.get $ball0) (i32.const 8))))
                (i32.store (i32.add (local.get $addr) (i32.const 12)) (i32.const 0x00010000)) ;; dx = +1
                (i32.store (i32.add (local.get $addr) (i32.const 16))
                  (i32.load (i32.add (local.get $ball0) (i32.const 16))))
              )
            )
          )
        )
      )
    )
    (if (i32.eq (local.get $type) (i32.const 2))
      (then
        ;; slow: reduce ball speed — halve dy for all active balls
        (local.set $i (i32.const 0))
        (block $sdone
          (loop $slp
            (br_if $sdone (i32.ge_s (local.get $i) (i32.const 3)))
            (local.set $addr (i32.add (i32.const 0x3F054) (i32.mul (local.get $i) (i32.const 20))))
            (if (i32.load8_u (local.get $addr))
              (then
                ;; clamp speed: if dy magnitude < 0x10000, set to +-0x10000
                ;; just set to base speed
                (i32.store (i32.add (local.get $addr) (i32.const 16))
                  (select (i32.const 0x00010000) (i32.const 0xFFFF0000)
                    (i32.gt_s (i32.load (i32.add (local.get $addr) (i32.const 16))) (i32.const 0))))
              )
            )
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $slp)
          )
        )
      )
    )
    (if (i32.eq (local.get $type) (i32.const 3))
      (then
        ;; extra life (max 9)
        (if (i32.lt_u (i32.load8_u (i32.add (i32.const 0x3F004) (i32.const 1))) (i32.const 9))
          (then
            (i32.store8 (i32.add (i32.const 0x3F004) (i32.const 1))
              (i32.add (i32.load8_u (i32.add (i32.const 0x3F004) (i32.const 1))) (i32.const 1)))
          )
        )
      )
    )
    (if (i32.eq (local.get $type) (i32.const 4))
      (then
        ;; fire: bonus 500 points
        (i32.store (i32.add (i32.const 0x3F004) (i32.const 4))
          (i32.add (i32.load (i32.add (i32.const 0x3F004) (i32.const 4))) (i32.const 500)))
      )
    )
  )

  ;; ========================
  ;; setup_level
  ;; ========================
  (func $setup_level
    (local $row i32) (local $col i32) (local $addr i32) (local $type i32)
    (local $level i32) (local $r i32)
    (local.set $level (i32.load8_u (i32.add (i32.const 0x3F004) (i32.const 2))))
    ;; clear bricks
    (local.set $addr (i32.const 0x3F090))
    (block $cd
      (loop $cl
        (br_if $cd (i32.ge_u (local.get $addr) (i32.const 0x3F250)))
        (i32.store (local.get $addr) (i32.const 0))
        (local.set $addr (i32.add (local.get $addr) (i32.const 4)))
        (br $cl)
      )
    )
    ;; clear particles, powerups
    (local.set $addr (i32.const 0x3F250))
    (block $cd2
      (loop $cl2
        (br_if $cd2 (i32.ge_u (local.get $addr) (i32.const 0x3F6B0)))
        (i32.store8 (local.get $addr) (i32.const 0))
        (local.set $addr (i32.add (local.get $addr) (i32.const 1)))
        (br $cl2)
      )
    )
    ;; fill bricks based on level pattern
    (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 16)) (i32.const 0)) ;; bricks_left = 0
    (local.set $row (i32.const 0))
    (block $rdone
      (loop $rlp
        (br_if $rdone (i32.ge_s (local.get $row) (i32.const 8)))
        (local.set $col (i32.const 0))
        (block $cdone
          (loop $clp
            (br_if $cdone (i32.ge_s (local.get $col) (i32.const 14)))
            (local.set $addr (i32.add (i32.const 0x3F090)
              (i32.mul (i32.add (i32.mul (local.get $row) (i32.const 14)) (local.get $col)) (i32.const 4))))
            ;; determine brick type based on level
            (local.set $r (call $rand))
            (local.set $type
              (select (i32.const 0) ;; empty for some patterns
                (i32.add (i32.rem_u
                  (i32.and (i32.add (local.get $row) (i32.mul (local.get $level) (i32.const 3))) (i32.const 0x7FFFFFFF))
                  (i32.const 7)) (i32.const 1))
                ;; empty if: level 0 and row > 5, or random gap
                (i32.and
                  (i32.lt_u (local.get $level) (i32.const 2))
                  (i32.gt_s (local.get $row) (i32.const 5)))))
            ;; add silver bricks on higher levels
            (if (i32.and
              (i32.gt_u (local.get $level) (i32.const 1))
              (i32.eqz (i32.rem_u (i32.and (local.get $r) (i32.const 0x7FFFFFFF)) (i32.const 8))))
              (then (local.set $type (i32.const 8))) ;; silver
            )
            ;; add gold bricks on level 3+
            (if (i32.and
              (i32.gt_u (local.get $level) (i32.const 2))
              (i32.eqz (i32.rem_u (i32.and (local.get $r) (i32.const 0x7FFFFFFF)) (i32.const 16))))
              (then (local.set $type (i32.const 9))) ;; gold
            )
            (i32.store8 (local.get $addr) (local.get $type))
            ;; hits_left
            (i32.store8 (i32.add (local.get $addr) (i32.const 1))
              (select (i32.const 2)
                (select (i32.const 99) (i32.const 1)
                  (i32.eq (local.get $type) (i32.const 9)))
                (i32.eq (local.get $type) (i32.const 8))))
            ;; count destructible bricks
            (if (i32.and (i32.gt_u (local.get $type) (i32.const 0))
                         (i32.lt_u (local.get $type) (i32.const 9)))
              (then
                (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 16))
                  (i32.add (i32.load16_u (i32.add (i32.const 0x3F004) (i32.const 16))) (i32.const 1)))
              )
            )
            ;; count silver too
            (if (i32.eq (local.get $type) (i32.const 8))
              (then
                (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 16))
                  (i32.add (i32.load16_u (i32.add (i32.const 0x3F004) (i32.const 16))) (i32.const 1)))
              )
            )
            (local.set $col (i32.add (local.get $col) (i32.const 1)))
            (br $clp)
          )
        )
        (local.set $row (i32.add (local.get $row) (i32.const 1)))
        (br $rlp)
      )
    )
    ;; reset paddle
    (i32.store16 (i32.const 0x3F044) (i32.const 160)) ;; center
    (i32.store8 (i32.add (i32.const 0x3F044) (i32.const 2)) (i32.const 24)) ;; half-width
    (i32.store8 (i32.add (i32.const 0x3F044) (i32.const 3)) (i32.const 1))  ;; sticky=true
    ;; reset balls
    (local.set $addr (i32.const 0x3F054))
    (block $bdone
      (loop $blp
        (br_if $bdone (i32.ge_u (local.get $addr) (i32.add (i32.const 0x3F054) (i32.const 60))))
        (i32.store8 (local.get $addr) (i32.const 0))
        (local.set $addr (i32.add (local.get $addr) (i32.const 20)))
        (br $blp)
      )
    )
    ;; activate ball 0 on paddle
    (i32.store8 (i32.const 0x3F054) (i32.const 1)) ;; active
    (i32.store (i32.add (i32.const 0x3F054) (i32.const 2))
      (i32.shl (i32.const 160) (i32.const 16))) ;; x = paddle center
    (i32.store (i32.add (i32.const 0x3F054) (i32.const 8))
      (i32.shl (i32.const 181) (i32.const 16))) ;; y = just above paddle
    (i32.store (i32.add (i32.const 0x3F054) (i32.const 12)) (i32.const 0)) ;; dx = 0
    (i32.store (i32.add (i32.const 0x3F054) (i32.const 16)) (i32.const 0)) ;; dy = 0
  )

  ;; ========================
  ;; launch_ball — give ball velocity
  ;; ========================
  (func $launch_ball
    (local $r i32)
    ;; only if sticky
    (if (i32.load8_u (i32.add (i32.const 0x3F044) (i32.const 3)))
      (then
        (i32.store8 (i32.add (i32.const 0x3F044) (i32.const 3)) (i32.const 0)) ;; unstick
        ;; set ball 0 velocity: random-ish angle upward
        (local.set $r (call $rand))
        (i32.store (i32.add (i32.const 0x3F054) (i32.const 12))
          ;; dx between -1.5 and 1.5 (fixed 16.16)
          (i32.sub (i32.and (local.get $r) (i32.const 0x1FFFF)) (i32.const 0x10000)))
        (i32.store (i32.add (i32.const 0x3F054) (i32.const 16))
          (i32.const 0xFFFE0000)) ;; dy = -2.0 upward
        ;; launch sound
        (call $note (i32.const 3) (i32.const 440) (i32.const 80) (i32.const 150))
      )
    )
  )

  ;; ========================
  ;; update_balls
  ;; ========================
  (func $update_balls
    (local $i i32) (local $addr i32)
    (local $bx i32) (local $by i32) (local $dx i32) (local $dy i32)
    (local $px i32) (local $py i32) ;; pixel coords
    (local $paddle_x i32) (local $paddle_w i32)
    (local $hit_col i32) (local $hit_row i32) (local $brick_addr i32) (local $brick_type i32)
    (local $brick_px i32) (local $brick_py i32)
    (local $rel i32) (local $any_active i32)

    (local.set $paddle_x (i32.load16_s (i32.const 0x3F044)))
    (local.set $paddle_w (i32.load8_u (i32.add (i32.const 0x3F044) (i32.const 2))))
    (local.set $any_active (i32.const 0))

    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (i32.const 3)))
        (local.set $addr (i32.add (i32.const 0x3F054) (i32.mul (local.get $i) (i32.const 20))))
        (if (i32.load8_u (local.get $addr))
          (then
            (local.set $any_active (i32.const 1))

            ;; if sticky, ball follows paddle
            (if (i32.and (i32.eqz (local.get $i))
                         (i32.load8_u (i32.add (i32.const 0x3F044) (i32.const 3))))
              (then
                (i32.store (i32.add (local.get $addr) (i32.const 2))
                  (i32.shl (local.get $paddle_x) (i32.const 16)))
                (i32.store (i32.add (local.get $addr) (i32.const 8))
                  (i32.shl (i32.const 181) (i32.const 16)))
              )
              (else
                ;; load state
                (local.set $bx (i32.load (i32.add (local.get $addr) (i32.const 2))))
                (local.set $by (i32.load (i32.add (local.get $addr) (i32.const 8))))
                (local.set $dx (i32.load (i32.add (local.get $addr) (i32.const 12))))
                (local.set $dy (i32.load (i32.add (local.get $addr) (i32.const 16))))

                ;; move
                (local.set $bx (i32.add (local.get $bx) (local.get $dx)))
                (local.set $by (i32.add (local.get $by) (local.get $dy)))

                ;; pixel coords
                (local.set $px (i32.shr_s (local.get $bx) (i32.const 16)))
                (local.set $py (i32.shr_s (local.get $by) (i32.const 16)))

                ;; wall bounces
                ;; left wall
                (if (i32.lt_s (local.get $px) (i32.const 2))
                  (then
                    (local.set $bx (i32.shl (i32.const 2) (i32.const 16)))
                    (local.set $dx (i32.sub (i32.const 0) (local.get $dx)))
                    (call $note (i32.const 3) (i32.const 300) (i32.const 30) (i32.const 80))
                  )
                )
                ;; right wall
                (if (i32.gt_s (local.get $px) (i32.const 317))
                  (then
                    (local.set $bx (i32.shl (i32.const 317) (i32.const 16)))
                    (local.set $dx (i32.sub (i32.const 0) (local.get $dx)))
                    (call $note (i32.const 3) (i32.const 300) (i32.const 30) (i32.const 80))
                  )
                )
                ;; top wall
                (if (i32.lt_s (local.get $py) (i32.const 12))
                  (then
                    (local.set $by (i32.shl (i32.const 12) (i32.const 16)))
                    (local.set $dy (i32.sub (i32.const 0) (local.get $dy)))
                    (call $note (i32.const 3) (i32.const 350) (i32.const 30) (i32.const 80))
                  )
                )
                ;; bottom — ball lost
                (if (i32.gt_s (local.get $py) (i32.const 200))
                  (then
                    (i32.store8 (local.get $addr) (i32.const 0)) ;; deactivate
                    ;; don't count as "any_active" anymore - we check later
                  )
                  (else
                    ;; paddle collision
                    (if (i32.and
                      (i32.and
                        (i32.ge_s (local.get $py) (i32.const 183))
                        (i32.lt_s (local.get $py) (i32.const 190)))
                      (i32.and
                        (i32.ge_s (local.get $px) (i32.sub (local.get $paddle_x) (local.get $paddle_w)))
                        (i32.le_s (local.get $px) (i32.add (local.get $paddle_x) (local.get $paddle_w)))))
                      (then
                        ;; reflect upward
                        (local.set $by (i32.shl (i32.const 182) (i32.const 16)))
                        ;; adjust dx based on hit position
                        (local.set $rel (i32.sub (local.get $px) (local.get $paddle_x)))
                        ;; rel ranges from -paddle_w to +paddle_w, map to dx
                        (local.set $dx (i32.mul (local.get $rel) (i32.const 0x1800))) ;; scale factor
                        (local.set $dy (i32.sub (i32.const 0) (local.get $dy)))
                        ;; ensure dy is negative (upward)
                        (if (i32.gt_s (local.get $dy) (i32.const 0))
                          (then (local.set $dy (i32.sub (i32.const 0) (local.get $dy))))
                        )
                        ;; ensure minimum upward speed
                        (if (i32.gt_s (local.get $dy) (i32.const 0xFFFF0000))
                          (then (local.set $dy (i32.const 0xFFFF0000)))
                        )
                        ;; paddle hit sound — pitch based on position
                        (call $note (i32.const 3)
                          (i32.add (i32.const 400) (i32.mul (i32.add (local.get $rel) (local.get $paddle_w)) (i32.const 8)))
                          (i32.const 50) (i32.const 120))
                        ;; reset combo
                        (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 8)) (i32.const 0))
                      )
                    )

                    ;; brick collision
                    ;; check which brick the ball is in
                    (local.set $hit_col (i32.div_s (i32.sub (local.get $px) (i32.const 20)) (i32.const 20)))
                    (local.set $hit_row (i32.div_s (i32.sub (local.get $py) (i32.const 30)) (i32.const 8)))
                    (if (i32.and
                      (i32.and (i32.ge_s (local.get $hit_col) (i32.const 0))
                               (i32.lt_s (local.get $hit_col) (i32.const 14)))
                      (i32.and (i32.ge_s (local.get $hit_row) (i32.const 0))
                               (i32.lt_s (local.get $hit_row) (i32.const 8))))
                      (then
                        (local.set $brick_addr (i32.add (i32.const 0x3F090)
                          (i32.mul (i32.add (i32.mul (local.get $hit_row) (i32.const 14)) (local.get $hit_col)) (i32.const 4))))
                        (local.set $brick_type (i32.load8_u (local.get $brick_addr)))
                        (if (i32.gt_u (local.get $brick_type) (i32.const 0))
                          (then
                            ;; hit the brick
                            (call $hit_brick (local.get $brick_addr) (local.get $hit_col) (local.get $hit_row))
                            ;; bounce: determine bounce direction
                            ;; simple: bounce based on approach direction
                            (local.set $brick_px (i32.add (i32.const 20) (i32.mul (local.get $hit_col) (i32.const 20))))
                            (local.set $brick_py (i32.add (i32.const 30) (i32.mul (local.get $hit_row) (i32.const 8))))
                            ;; if coming from side, flip dx; if from top/bottom, flip dy
                            ;; simple heuristic: check overlap
                            (if (i32.or
                              (i32.le_s (local.get $px) (local.get $brick_px))
                              (i32.ge_s (local.get $px) (i32.add (local.get $brick_px) (i32.const 19))))
                              (then (local.set $dx (i32.sub (i32.const 0) (local.get $dx))))
                              (else (local.set $dy (i32.sub (i32.const 0) (local.get $dy))))
                            )
                          )
                        )
                      )
                    )
                  )
                )

                ;; store back
                (i32.store (i32.add (local.get $addr) (i32.const 2)) (local.get $bx))
                (i32.store (i32.add (local.get $addr) (i32.const 8)) (local.get $by))
                (i32.store (i32.add (local.get $addr) (i32.const 12)) (local.get $dx))
                (i32.store (i32.add (local.get $addr) (i32.const 16)) (local.get $dy))
              )
            )
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )

    ;; check if all balls are dead
    ;; recount active balls
    (local.set $any_active (i32.const 0))
    (local.set $i (i32.const 0))
    (block $chk_done
      (loop $chk
        (br_if $chk_done (i32.ge_s (local.get $i) (i32.const 3)))
        (if (i32.load8_u (i32.add (i32.const 0x3F054) (i32.mul (local.get $i) (i32.const 20))))
          (then (local.set $any_active (i32.const 1)))
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $chk)
      )
    )
    (if (i32.eqz (local.get $any_active))
      (then
        ;; lose a life
        (call $lose_life)
      )
    )
  )

  ;; ========================
  ;; hit_brick (brick_addr, col, row)
  ;; ========================
  (func $hit_brick (param $addr i32) (param $col i32) (param $row i32)
    (local $type i32) (local $hits i32) (local $score i32) (local $combo i32)
    (local $bx i32) (local $by i32) (local $color i32)
    (local.set $type (i32.load8_u (local.get $addr)))
    (local.set $hits (i32.load8_u (i32.add (local.get $addr) (i32.const 1))))
    ;; gold is indestructible
    (if (i32.eq (local.get $type) (i32.const 9))
      (then
        ;; just flash and sound
        (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (i32.const 4))
        (call $note (i32.const 1) (i32.const 200) (i32.const 40) (i32.const 100))
        (return)
      )
    )
    ;; decrease hits
    (local.set $hits (i32.sub (local.get $hits) (i32.const 1)))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $hits))
    (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (i32.const 4)) ;; flash
    (if (i32.le_s (local.get $hits) (i32.const 0))
      (then
        ;; destroy brick
        (i32.store8 (local.get $addr) (i32.const 0))
        ;; decrement bricks_left
        (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 16))
          (i32.sub (i32.load16_u (i32.add (i32.const 0x3F004) (i32.const 16))) (i32.const 1)))
        ;; combo scoring
        (local.set $combo (i32.load16_u (i32.add (i32.const 0x3F004) (i32.const 8))))
        (local.set $combo (i32.add (local.get $combo) (i32.const 1)))
        (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 8)) (local.get $combo))
        (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 10)) (i32.const 60)) ;; combo timer
        ;; score = 10 * type * combo
        (local.set $score (i32.mul (i32.mul (i32.const 10) (local.get $type)) (local.get $combo)))
        (i32.store (i32.add (i32.const 0x3F004) (i32.const 4))
          (i32.add (i32.load (i32.add (i32.const 0x3F004) (i32.const 4))) (local.get $score)))
        ;; brick position for particles
        (local.set $bx (i32.add (i32.const 30) (i32.mul (local.get $col) (i32.const 20))))
        (local.set $by (i32.add (i32.const 34) (i32.mul (local.get $row) (i32.const 8))))
        ;; color based on type (use palette colors)
        ;; type 1-7 maps to colors: red(4), green(2), blue(1), yellow(14), magenta(5), cyan(3), white(15)
        (local.set $color
          (select (i32.const 4)
            (select (i32.const 2)
              (select (i32.const 1)
                (select (i32.const 14)
                  (select (i32.const 5)
                    (select (i32.const 3) (i32.const 15)
                      (i32.eq (local.get $type) (i32.const 6)))
                    (i32.eq (local.get $type) (i32.const 5)))
                  (i32.eq (local.get $type) (i32.const 4)))
                (i32.eq (local.get $type) (i32.const 3)))
              (i32.eq (local.get $type) (i32.const 2)))
            (i32.eq (local.get $type) (i32.const 1))))
        ;; spawn particles
        (call $spawn_particles (local.get $bx) (local.get $by) (local.get $color) (i32.const 10))
        ;; brick break sound — pitch increases with combo
        (call $note (i32.const 1)
          (i32.add (i32.const 300) (i32.mul (local.get $combo) (i32.const 40)))
          (i32.const 60) (i32.const 140))
        ;; maybe spawn powerup
        (call $spawn_powerup (local.get $bx) (local.get $by))
        ;; screen shake
        (i32.store8 (i32.add (i32.const 0x3F004) (i32.const 13)) (i32.const 3))
      )
      (else
        ;; just a hit sound (silver brick)
        (call $note (i32.const 1) (i32.const 250) (i32.const 40) (i32.const 120))
      )
    )
  )

  ;; ========================
  ;; lose_life
  ;; ========================
  (func $lose_life
    (local $lives i32)
    (local.set $lives (i32.load8_u (i32.add (i32.const 0x3F004) (i32.const 1))))
    (local.set $lives (i32.sub (local.get $lives) (i32.const 1)))
    (i32.store8 (i32.add (i32.const 0x3F004) (i32.const 1)) (local.get $lives))
    ;; death sound
    (call $note (i32.const 2) (i32.const 200) (i32.const 200) (i32.const 180))
    (call $note (i32.const 2) (i32.const 150) (i32.const 300) (i32.const 160))
    ;; screen shake
    (i32.store8 (i32.add (i32.const 0x3F004) (i32.const 13)) (i32.const 10))
    (i32.store8 (i32.add (i32.const 0x3F004) (i32.const 14)) (i32.const 8)) ;; flash
    (if (i32.le_s (local.get $lives) (i32.const 0))
      (then
        ;; game over
        (i32.store8 (i32.const 0x3F004) (i32.const 2))
        (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 18)) (i32.const 0))
        (call $music (i32.const 0)) ;; stop music
        ;; game over sound
        (call $note (i32.const 2) (i32.const 300) (i32.const 150) (i32.const 200))
        (call $note (i32.const 2) (i32.const 200) (i32.const 200) (i32.const 180))
        (call $note (i32.const 2) (i32.const 100) (i32.const 400) (i32.const 200))
      )
      (else
        ;; reset ball on paddle
        (i32.store8 (i32.const 0x3F054) (i32.const 1))
        (i32.store (i32.add (i32.const 0x3F054) (i32.const 2))
          (i32.shl (i32.load16_s (i32.const 0x3F044)) (i32.const 16)))
        (i32.store (i32.add (i32.const 0x3F054) (i32.const 8))
          (i32.shl (i32.const 181) (i32.const 16)))
        (i32.store (i32.add (i32.const 0x3F054) (i32.const 12)) (i32.const 0))
        (i32.store (i32.add (i32.const 0x3F054) (i32.const 16)) (i32.const 0))
        ;; deactivate extra balls
        (i32.store8 (i32.add (i32.const 0x3F054) (i32.const 20)) (i32.const 0))
        (i32.store8 (i32.add (i32.const 0x3F054) (i32.const 40)) (i32.const 0))
        (i32.store8 (i32.add (i32.const 0x3F044) (i32.const 3)) (i32.const 1)) ;; sticky
        ;; reset paddle width
        (i32.store8 (i32.add (i32.const 0x3F044) (i32.const 2)) (i32.const 24))
      )
    )
  )

  ;; ========================
  ;; draw_brick (col, row)
  ;; ========================
  (func $draw_brick (param $col i32) (param $row i32)
    (local $addr i32) (local $type i32) (local $bx i32) (local $by i32)
    (local $color i32) (local $highlight i32) (local $shadow i32)
    (local $anim i32) (local $frame i32)
    (local.set $addr (i32.add (i32.const 0x3F090)
      (i32.mul (i32.add (i32.mul (local.get $row) (i32.const 14)) (local.get $col)) (i32.const 4))))
    (local.set $type (i32.load8_u (local.get $addr)))
    (if (i32.eqz (local.get $type)) (then return))
    (local.set $bx (i32.add (i32.const 20) (i32.mul (local.get $col) (i32.const 20))))
    (local.set $by (i32.add (i32.const 30) (i32.mul (local.get $row) (i32.const 8))))
    (local.set $anim (i32.load8_u (i32.add (local.get $addr) (i32.const 2))))
    ;; decay anim
    (if (i32.gt_u (local.get $anim) (i32.const 0))
      (then
        (i32.store8 (i32.add (local.get $addr) (i32.const 2))
          (i32.sub (local.get $anim) (i32.const 1)))
      )
    )
    ;; color mapping for brick types
    ;; Using 6x6x6 color cube starting at palette index 16
    ;; type 1=red, 2=green, 3=blue, 4=yellow, 5=magenta, 6=cyan, 7=orange
    ;; 8=silver, 9=gold
    (local.set $color
      (select (i32.const 4)   ;; red
        (select (i32.const 10) ;; bright green
          (select (i32.const 9) ;; bright blue
            (select (i32.const 14) ;; yellow
              (select (i32.const 13) ;; magenta
                (select (i32.const 11) ;; cyan
                  (select (i32.const 6) ;; brown/orange -> dark yellow
                    (select (i32.const 7) (i32.const 14) ;; silver=7(gray), gold=14(yellow)
                      (i32.eq (local.get $type) (i32.const 8)))
                    (i32.eq (local.get $type) (i32.const 7)))
                  (i32.eq (local.get $type) (i32.const 6)))
                (i32.eq (local.get $type) (i32.const 5)))
              (i32.eq (local.get $type) (i32.const 4)))
            (i32.eq (local.get $type) (i32.const 3)))
          (i32.eq (local.get $type) (i32.const 2)))
        (i32.eq (local.get $type) (i32.const 1))))
    ;; flash white if hit
    (if (i32.gt_u (local.get $anim) (i32.const 0))
      (then (local.set $color (i32.const 15)))
    )
    ;; draw brick body (20x8 with 1px border)
    (call $fill_rect (local.get $bx) (local.get $by) (i32.const 20) (i32.const 8) (local.get $color))
    ;; dark border (bottom and right) for 3D effect
    (call $fill_rect (local.get $bx) (i32.add (local.get $by) (i32.const 7))
      (i32.const 20) (i32.const 1) (i32.const 0)) ;; bottom
    (call $fill_rect (i32.add (local.get $bx) (i32.const 19)) (local.get $by)
      (i32.const 1) (i32.const 8) (i32.const 0)) ;; right
    ;; highlight (top and left) for 3D bevel
    (call $fill_rect (local.get $bx) (local.get $by)
      (i32.const 20) (i32.const 1) (i32.const 15)) ;; top = white
    (call $fill_rect (local.get $bx) (local.get $by)
      (i32.const 1) (i32.const 8) (i32.const 15)) ;; left = white
    ;; gold bricks get a shimmer effect
    (if (i32.eq (local.get $type) (i32.const 9))
      (then
        (local.set $frame (i32.load (i32.const 0x00)))
        (call $fill_rect
          (i32.add (local.get $bx) (i32.add (i32.const 2)
            (i32.rem_u (i32.add (local.get $frame) (i32.mul (local.get $col) (i32.const 3))) (i32.const 14))))
          (i32.add (local.get $by) (i32.const 2))
          (i32.const 3) (i32.const 4) (i32.const 15))
      )
    )
  )

  ;; ========================
  ;; draw_paddle
  ;; ========================
  (func $draw_paddle
    (local $px i32) (local $pw i32) (local $y i32)
    (local.set $px (i32.load16_s (i32.const 0x3F044)))
    (local.set $pw (i32.load8_u (i32.add (i32.const 0x3F044) (i32.const 2))))
    (local.set $y (i32.const 185))
    ;; main body
    (call $fill_rect (i32.sub (local.get $px) (local.get $pw)) (local.get $y)
      (i32.mul (local.get $pw) (i32.const 2)) (i32.const 6) (i32.const 7)) ;; gray
    ;; highlight top
    (call $fill_rect (i32.sub (local.get $px) (local.get $pw)) (local.get $y)
      (i32.mul (local.get $pw) (i32.const 2)) (i32.const 1) (i32.const 15)) ;; white
    ;; dark bottom
    (call $fill_rect (i32.sub (local.get $px) (local.get $pw)) (i32.add (local.get $y) (i32.const 5))
      (i32.mul (local.get $pw) (i32.const 2)) (i32.const 1) (i32.const 8)) ;; dark gray
    ;; center detail
    (call $fill_rect (i32.sub (local.get $px) (i32.const 3)) (i32.add (local.get $y) (i32.const 2))
      (i32.const 6) (i32.const 2) (i32.const 11)) ;; cyan accent
  )

  ;; ========================
  ;; draw_ball (ball index)
  ;; ========================
  (func $draw_ball (param $i i32)
    (local $addr i32) (local $px i32) (local $py i32) (local $frame i32)
    (local.set $addr (i32.add (i32.const 0x3F054) (i32.mul (local.get $i) (i32.const 20))))
    (if (i32.eqz (i32.load8_u (local.get $addr))) (then return))
    (local.set $px (i32.shr_s (i32.load (i32.add (local.get $addr) (i32.const 2))) (i32.const 16)))
    (local.set $py (i32.shr_s (i32.load (i32.add (local.get $addr) (i32.const 8))) (i32.const 16)))
    ;; 3x3 ball with glow
    (call $put_pixel (local.get $px) (i32.sub (local.get $py) (i32.const 1)) (i32.const 15))
    (call $put_pixel (i32.sub (local.get $px) (i32.const 1)) (local.get $py) (i32.const 15))
    (call $put_pixel (local.get $px) (local.get $py) (i32.const 15))
    (call $put_pixel (i32.add (local.get $px) (i32.const 1)) (local.get $py) (i32.const 15))
    (call $put_pixel (local.get $px) (i32.add (local.get $py) (i32.const 1)) (i32.const 15))
    ;; glow
    (call $put_pixel (i32.sub (local.get $px) (i32.const 1)) (i32.sub (local.get $py) (i32.const 1)) (i32.const 7))
    (call $put_pixel (i32.add (local.get $px) (i32.const 1)) (i32.sub (local.get $py) (i32.const 1)) (i32.const 7))
    (call $put_pixel (i32.sub (local.get $px) (i32.const 1)) (i32.add (local.get $py) (i32.const 1)) (i32.const 7))
    (call $put_pixel (i32.add (local.get $px) (i32.const 1)) (i32.add (local.get $py) (i32.const 1)) (i32.const 7))
  )

  ;; ========================
  ;; draw_hud
  ;; ========================
  (func $draw_hud
    (local $i i32) (local $lives i32)
    ;; score
    (call $draw_string (i32.const 0x10700) (i32.const 4) (i32.const 2) (i32.const 15))
    (call $draw_number (i32.load (i32.add (i32.const 0x3F004) (i32.const 4)))
      (i32.const 52) (i32.const 2) (i32.const 14) (i32.const 7))
    ;; lives as small balls
    (local.set $lives (i32.load8_u (i32.add (i32.const 0x3F004) (i32.const 1))))
    (local.set $i (i32.const 0))
    (block $ldone
      (loop $llp
        (br_if $ldone (i32.ge_s (local.get $i) (local.get $lives)))
        (call $fill_rect
          (i32.add (i32.const 270) (i32.mul (local.get $i) (i32.const 10)))
          (i32.const 3) (i32.const 4) (i32.const 4) (i32.const 12))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $llp)
      )
    )
    ;; level
    (call $draw_string (i32.const 0x10707) (i32.const 130) (i32.const 2) (i32.const 11))
    (call $draw_number (i32.add (i32.load8_u (i32.add (i32.const 0x3F004) (i32.const 2))) (i32.const 1))
      (i32.const 170) (i32.const 2) (i32.const 11) (i32.const 2))
    ;; combo indicator
    (if (i32.gt_u (i32.load16_u (i32.add (i32.const 0x3F004) (i32.const 8))) (i32.const 1))
      (then
        (call $draw_string (i32.const 0x1070B) (i32.const 200) (i32.const 2) (i32.const 14))
        (call $draw_number (i32.load16_u (i32.add (i32.const 0x3F004) (i32.const 8)))
          (i32.const 248) (i32.const 2) (i32.const 14) (i32.const 2))
      )
    )
  )

  ;; ========================
  ;; draw_stars (background)
  ;; ========================
  (func $draw_stars
    (local $addr i32) (local $x i32) (local $y i32) (local $spd i32)
    (local.set $addr (i32.const 0x3F6B0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $addr) (i32.add (i32.const 0x3F6B0) (i32.const 256))))
        (local.set $x (i32.load16_u (local.get $addr)))
        (local.set $y (i32.load8_u (i32.add (local.get $addr) (i32.const 2))))
        (local.set $spd (i32.load8_u (i32.add (local.get $addr) (i32.const 3))))
        ;; move star down slowly
        (local.set $y (i32.add (local.get $y) (local.get $spd)))
        (if (i32.gt_u (local.get $y) (i32.const 199))
          (then
            (local.set $y (i32.const 0))
            (local.set $x (i32.and (call $rand) (i32.const 0x1FF)))
            (if (i32.ge_u (local.get $x) (i32.const 320))
              (then (local.set $x (i32.sub (local.get $x) (i32.const 200))))
            )
            (i32.store16 (local.get $addr) (local.get $x))
          )
        )
        (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $y))
        ;; draw: brightness based on speed
        (call $put_pixel (local.get $x) (local.get $y)
          (select (i32.const 15) (select (i32.const 7) (i32.const 8)
            (i32.eq (local.get $spd) (i32.const 2)))
            (i32.ge_u (local.get $spd) (i32.const 3))))
        (local.set $addr (i32.add (local.get $addr) (i32.const 4)))
        (br $lp)
      )
    )
  )

  ;; ========================
  ;; init_stars
  ;; ========================
  (func $init_stars
    (local $i i32) (local $addr i32) (local $r i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (i32.const 64)))
        (local.set $addr (i32.add (i32.const 0x3F6B0) (i32.mul (local.get $i) (i32.const 4))))
        (local.set $r (call $rand))
        (i32.store16 (local.get $addr) (i32.rem_u (i32.and (local.get $r) (i32.const 0x7FFF)) (i32.const 320)))
        (local.set $r (call $rand))
        (i32.store8 (i32.add (local.get $addr) (i32.const 2))
          (i32.rem_u (i32.and (local.get $r) (i32.const 0xFF)) (i32.const 200)))
        (i32.store8 (i32.add (local.get $addr) (i32.const 3))
          (i32.add (i32.and (local.get $r) (i32.const 3)) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )
  )

  ;; ========================
  ;; clear_screen
  ;; ========================
  (func $clear_screen
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 64000)))
        ;; fill with black
        (i32.store8 (i32.add (i32.const 0x0340) (local.get $i)) (i32.const 0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )
  )

  ;; ========================
  ;; draw_borders
  ;; ========================
  (func $draw_borders
    ;; left wall
    (call $fill_rect (i32.const 0) (i32.const 12) (i32.const 2) (i32.const 188) (i32.const 8))
    ;; right wall
    (call $fill_rect (i32.const 318) (i32.const 12) (i32.const 2) (i32.const 188) (i32.const 8))
    ;; top wall
    (call $fill_rect (i32.const 0) (i32.const 12) (i32.const 320) (i32.const 2) (i32.const 8))
    ;; wall highlights
    (call $fill_rect (i32.const 1) (i32.const 12) (i32.const 1) (i32.const 188) (i32.const 7))
    (call $fill_rect (i32.const 318) (i32.const 12) (i32.const 1) (i32.const 188) (i32.const 7))
    (call $fill_rect (i32.const 0) (i32.const 13) (i32.const 320) (i32.const 1) (i32.const 7))
  )

  ;; ========================
  ;; INIT
  ;; ========================
  (func (export "init")
    ;; setup palette — use default, it's fine for this game
    ;; init PRNG
    (i32.store (i32.const 0x3F000) (i32.const 0xDEADBEEF))
    ;; init stars
    (call $init_stars)
    ;; set title phase
    (i32.store8 (i32.const 0x3F004) (i32.const 0)) ;; phase = title
    (i32.store8 (i32.add (i32.const 0x3F004) (i32.const 1)) (i32.const 3)) ;; lives
    (i32.store8 (i32.add (i32.const 0x3F004) (i32.const 2)) (i32.const 0)) ;; level
    (i32.store (i32.add (i32.const 0x3F004) (i32.const 4)) (i32.const 0))  ;; score
    (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 18)) (i32.const 0)) ;; phase_timer
    ;; start title music
    (call $music (i32.const 0x10A00))
  )

  ;; ========================
  ;; FRAME
  ;; ========================
  (func (export "frame")
    (local $phase i32) (local $input i32) (local $prev_input i32)
    (local $new_input i32) (local $mouse_x i32) (local $keys i32)
    (local $paddle_x i32) (local $timer i32) (local $frame i32)
    (local $row i32) (local $col i32) (local $shake_x i32) (local $shake_y i32)
    (local $combo_timer i32)

    (local.set $phase (i32.load8_u (i32.const 0x3F004)))
    (local.set $frame (i32.load (i32.const 0x00)))

    ;; read input
    (local.set $mouse_x (i32.load16_u (i32.const 0x04)))
    (local.set $keys (i32.load8_u (i32.const 0x10)))
    ;; combine: space(bit4) and mouse button (bit0 of 0x08)
    (local.set $input (i32.or
      (i32.and (local.get $keys) (i32.const 0x1C)) ;; left(bit2), right(bit3), space(bit4)
      (i32.and (i32.load8_u (i32.const 0x08)) (i32.const 1)))) ;; mouse left
    (local.set $prev_input (i32.load8_u (i32.add (i32.const 0x3F004) (i32.const 12))))
    (local.set $new_input (i32.and (local.get $input)
      (i32.xor (local.get $prev_input) (i32.const 0xFF))))
    (i32.store8 (i32.add (i32.const 0x3F004) (i32.const 12)) (local.get $input))

    ;; clear screen
    (call $clear_screen)
    ;; draw stars background
    (call $draw_stars)

    ;; === TITLE PHASE ===
    (if (i32.eqz (local.get $phase))
      (then
        ;; draw title
        (call $draw_string (i32.const 0x10713) ;; "ARKANOID"
          (i32.sub (i32.const 128) (i32.const 32))
          (i32.add (i32.const 60)
            (i32.div_s
              (i32.sub (i32.load8_u (i32.add (i32.const 0x10340)
                (i32.and (local.get $frame) (i32.const 255)))) (i32.const 128))
              (i32.const 32)))
          (i32.const 14))
        ;; subtitle
        (call $draw_string (i32.const 0x1071C) ;; "WASM EDITION"
          (i32.const 112) (i32.const 90) (i32.const 11))
        ;; blinking "PRESS SPACE"
        (if (i32.and (local.get $frame) (i32.const 32))
          (then
            (call $draw_string (i32.const 0x10729) ;; "PRESS SPACE"
              (i32.const 116) (i32.const 130) (i32.const 15))
          )
        )
        ;; check for start
        (if (i32.or
          (i32.and (local.get $new_input) (i32.const 0x10)) ;; space
          (i32.and (local.get $new_input) (i32.const 1)))   ;; mouse click
          (then
            (i32.store8 (i32.const 0x3F004) (i32.const 1)) ;; phase = playing
            (i32.store8 (i32.add (i32.const 0x3F004) (i32.const 1)) (i32.const 3))
            (i32.store8 (i32.add (i32.const 0x3F004) (i32.const 2)) (i32.const 0))
            (i32.store (i32.add (i32.const 0x3F004) (i32.const 4)) (i32.const 0))
            (call $setup_level)
            ;; play start sound
            (call $note (i32.const 1) (i32.const 440) (i32.const 100) (i32.const 150))
            (call $note (i32.const 1) (i32.const 660) (i32.const 100) (i32.const 150))
            (call $note (i32.const 1) (i32.const 880) (i32.const 150) (i32.const 180))
            ;; gameplay music
            (call $music (i32.const 0x10B00))
          )
        )
      )
    )

    ;; === PLAYING PHASE ===
    (if (i32.eq (local.get $phase) (i32.const 1))
      (then
        ;; update paddle from mouse or keys
        (local.set $paddle_x (i32.load16_s (i32.const 0x3F044)))
        ;; mouse control: use mouse_x if it changed since last frame
        (if (i32.ne (local.get $mouse_x) (i32.load16_u (i32.add (i32.const 0x3F004) (i32.const 24))))
          (then (local.set $paddle_x (local.get $mouse_x)))
          (else
            ;; keyboard control
            (if (i32.and (local.get $keys) (i32.const 4)) ;; left
              (then (local.set $paddle_x (i32.sub (local.get $paddle_x) (i32.const 4))))
            )
            (if (i32.and (local.get $keys) (i32.const 8)) ;; right
              (then (local.set $paddle_x (i32.add (local.get $paddle_x) (i32.const 4))))
            )
          )
        )
        ;; save mouse_x for next frame comparison
        (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 24)) (local.get $mouse_x))
        ;; clamp paddle
        (if (i32.lt_s (local.get $paddle_x)
          (i32.add (i32.const 3) (i32.load8_u (i32.add (i32.const 0x3F044) (i32.const 2)))))
          (then (local.set $paddle_x
            (i32.add (i32.const 3) (i32.load8_u (i32.add (i32.const 0x3F044) (i32.const 2))))))
        )
        (if (i32.gt_s (local.get $paddle_x)
          (i32.sub (i32.const 317) (i32.load8_u (i32.add (i32.const 0x3F044) (i32.const 2)))))
          (then (local.set $paddle_x
            (i32.sub (i32.const 317) (i32.load8_u (i32.add (i32.const 0x3F044) (i32.const 2))))))
        )
        (i32.store16 (i32.const 0x3F044) (local.get $paddle_x))

        ;; launch ball on space/click
        (if (i32.or
          (i32.and (local.get $new_input) (i32.const 0x10))
          (i32.and (local.get $new_input) (i32.const 1)))
          (then (call $launch_ball))
        )

        ;; update balls
        (call $update_balls)
        ;; update particles
        (call $update_particles)
        ;; update powerups
        (call $update_powerups)

        ;; combo timer decay
        (local.set $combo_timer (i32.load16_u (i32.add (i32.const 0x3F004) (i32.const 10))))
        (if (i32.gt_u (local.get $combo_timer) (i32.const 0))
          (then
            (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 10))
              (i32.sub (local.get $combo_timer) (i32.const 1)))
            (if (i32.eq (local.get $combo_timer) (i32.const 1))
              (then (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 8)) (i32.const 0)))
            )
          )
        )

        ;; screen shake
        (local.set $shake_x (i32.const 0))
        (local.set $shake_y (i32.const 0))
        (if (i32.gt_u (i32.load8_u (i32.add (i32.const 0x3F004) (i32.const 13))) (i32.const 0))
          (then
            (i32.store8 (i32.add (i32.const 0x3F004) (i32.const 13))
              (i32.sub (i32.load8_u (i32.add (i32.const 0x3F004) (i32.const 13))) (i32.const 1)))
            ;; apply shake (just for visual - we shift drawing)
          )
        )

        ;; flash timer
        (if (i32.gt_u (i32.load8_u (i32.add (i32.const 0x3F004) (i32.const 14))) (i32.const 0))
          (then
            (i32.store8 (i32.add (i32.const 0x3F004) (i32.const 14))
              (i32.sub (i32.load8_u (i32.add (i32.const 0x3F004) (i32.const 14))) (i32.const 1)))
          )
        )

        ;; draw game elements
        (call $draw_borders)
        ;; draw bricks
        (local.set $row (i32.const 0))
        (block $rdone
          (loop $rlp
            (br_if $rdone (i32.ge_s (local.get $row) (i32.const 8)))
            (local.set $col (i32.const 0))
            (block $cdone
              (loop $clp
                (br_if $cdone (i32.ge_s (local.get $col) (i32.const 14)))
                (call $draw_brick (local.get $col) (local.get $row))
                (local.set $col (i32.add (local.get $col) (i32.const 1)))
                (br $clp)
              )
            )
            (local.set $row (i32.add (local.get $row) (i32.const 1)))
            (br $rlp)
          )
        )
        ;; draw paddle
        (call $draw_paddle)
        ;; draw balls
        (call $draw_ball (i32.const 0))
        (call $draw_ball (i32.const 1))
        (call $draw_ball (i32.const 2))
        ;; draw particles
        (call $draw_particles)
        ;; draw powerups
        (call $draw_powerups)
        ;; draw HUD
        (call $draw_hud)

        ;; check level complete
        (if (i32.eqz (i32.load16_u (i32.add (i32.const 0x3F004) (i32.const 16))))
          (then
            ;; next level!
            (if (i32.ge_u (i32.load8_u (i32.add (i32.const 0x3F004) (i32.const 2))) (i32.const 4))
              (then
                ;; you win!
                (i32.store8 (i32.const 0x3F004) (i32.const 4))
                (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 18)) (i32.const 0))
                (call $music (i32.const 0))
                (call $note (i32.const 0) (i32.const 523) (i32.const 200) (i32.const 200))
                (call $note (i32.const 0) (i32.const 659) (i32.const 200) (i32.const 200))
                (call $note (i32.const 0) (i32.const 784) (i32.const 200) (i32.const 200))
                (call $note (i32.const 0) (i32.const 1047) (i32.const 400) (i32.const 255))
              )
              (else
                ;; advance level
                (i32.store8 (i32.add (i32.const 0x3F004) (i32.const 2))
                  (i32.add (i32.load8_u (i32.add (i32.const 0x3F004) (i32.const 2))) (i32.const 1)))
                (call $setup_level)
                ;; level complete sound
                (call $note (i32.const 1) (i32.const 660) (i32.const 100) (i32.const 180))
                (call $note (i32.const 1) (i32.const 880) (i32.const 150) (i32.const 200))
              )
            )
          )
        )
      )
    )

    ;; === GAME OVER PHASE ===
    (if (i32.eq (local.get $phase) (i32.const 2))
      (then
        ;; draw game state behind text
        (call $draw_borders)
        (call $draw_paddle)
        (call $draw_particles)
        (call $draw_hud)
        ;; GAME OVER text
        (call $draw_string (i32.const 0x10735) ;; "GAME OVER"
          (i32.const 124) (i32.const 80) (i32.const 4))
        ;; final score
        (call $draw_string (i32.const 0x10700) ;; "SCORE"
          (i32.const 120) (i32.const 100) (i32.const 15))
        (call $draw_number (i32.load (i32.add (i32.const 0x3F004) (i32.const 4)))
          (i32.const 168) (i32.const 100) (i32.const 14) (i32.const 7))
        ;; blink restart
        (local.set $timer (i32.load16_u (i32.add (i32.const 0x3F004) (i32.const 18))))
        (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 18))
          (i32.add (local.get $timer) (i32.const 1)))
        (if (i32.gt_u (local.get $timer) (i32.const 60))
          (then
            (if (i32.and (local.get $frame) (i32.const 32))
              (then
                (call $draw_string (i32.const 0x10729) ;; "PRESS SPACE"
                  (i32.const 116) (i32.const 130) (i32.const 15))
              )
            )
            (if (i32.or
              (i32.and (local.get $new_input) (i32.const 0x10))
              (i32.and (local.get $new_input) (i32.const 1)))
              (then
                ;; restart
                (i32.store8 (i32.const 0x3F004) (i32.const 0)) ;; title
                (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 18)) (i32.const 0))
                (call $music (i32.const 0x10A00))
              )
            )
          )
        )
      )
    )

    ;; === YOU WIN PHASE ===
    (if (i32.eq (local.get $phase) (i32.const 4))
      (then
        (call $draw_borders)
        (call $draw_hud)
        ;; YOU WIN!
        (call $draw_string (i32.const 0x1073F) ;; "YOU WIN!"
          (i32.const 128) (i32.const 70)
          (select (i32.const 14) (i32.const 10)
            (i32.and (local.get $frame) (i32.const 8))))
        (call $draw_string (i32.const 0x10700) ;; "SCORE"
          (i32.const 120) (i32.const 100) (i32.const 15))
        (call $draw_number (i32.load (i32.add (i32.const 0x3F004) (i32.const 4)))
          (i32.const 168) (i32.const 100) (i32.const 14) (i32.const 7))
        ;; spawn celebration particles
        (if (i32.eqz (i32.and (local.get $frame) (i32.const 7)))
          (then
            (call $spawn_particles
              (i32.add (i32.const 40) (i32.rem_u (call $rand) (i32.const 240)))
              (i32.add (i32.const 40) (i32.rem_u (call $rand) (i32.const 100)))
              (i32.add (i32.const 9) (i32.and (local.get $frame) (i32.const 7)))
              (i32.const 5))
          )
        )
        (call $update_particles)
        (call $draw_particles)
        ;; restart option
        (local.set $timer (i32.load16_u (i32.add (i32.const 0x3F004) (i32.const 18))))
        (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 18))
          (i32.add (local.get $timer) (i32.const 1)))
        (if (i32.gt_u (local.get $timer) (i32.const 120))
          (then
            (if (i32.and (local.get $frame) (i32.const 32))
              (then
                (call $draw_string (i32.const 0x10729)
                  (i32.const 116) (i32.const 150) (i32.const 15))
              )
            )
            (if (i32.or
              (i32.and (local.get $new_input) (i32.const 0x10))
              (i32.and (local.get $new_input) (i32.const 1)))
              (then
                (i32.store8 (i32.const 0x3F004) (i32.const 0))
                (i32.store16 (i32.add (i32.const 0x3F004) (i32.const 18)) (i32.const 0))
                (call $music (i32.const 0x10A00))
              )
            )
          )
        )
      )
    )
  )

  ;; ================================================================
  ;; DATA SEGMENTS
  ;; ================================================================

  ;; Sin table (256 entries, 0-255 representing -1..+1 centered at 128)
  (data (i32.const 0x10340)
    "\80\83\86\89\8c\8f\92\95\98\9b\9e\a2\a5\a7\aa\ad"
    "\b0\b3\b5\b8\ba\bc\bf\c1\c3\c5\c7\c9\cb\cc\ce\cf"
    "\d1\d2\d3\d4\d5\d6\d7\d8\d8\d9\d9\da\da\da\da\da"
    "\db\da\da\da\da\da\d9\d9\d8\d8\d7\d6\d5\d4\d3\d2"
    "\d1\cf\ce\cc\cb\c9\c7\c5\c3\c1\bf\bc\ba\b8\b5\b3"
    "\b0\ad\aa\a7\a5\a2\9e\9b\98\95\92\8f\8c\89\86\83"
    "\80\7d\7a\77\74\71\6e\6b\68\65\62\5e\5b\59\56\53"
    "\50\4d\4b\48\46\44\41\3f\3d\3b\39\37\35\34\32\31"
    "\2f\2e\2d\2c\2b\2a\29\28\28\27\27\26\26\26\26\26"
    "\25\26\26\26\26\26\27\27\28\28\29\2a\2b\2c\2d\2e"
    "\2f\31\32\34\35\37\39\3b\3d\3f\41\44\46\48\4b\4d"
    "\50\53\56\59\5b\5e\62\65\68\6b\6e\71\74\77\7a\7d"
    "\80\83\86\89\8c\8f\92\95\98\9b\9e\a2\a5\a7\aa\ad"
    "\b0\b3\b5\b8\ba\bc\bf\c1\c3\c5\c7\c9\cb\cc\ce\cf"
    "\d1\d2\d3\d4\d5\d6\d7\d8\d8\d9\d9\da\da\da\da\da"
    "\db\da\da\da\da\da\d9\d9\d8\d8\d7\d6\d5\d4\d3\d2"
  )

  ;; Font data at 0x10440 (8x8 bitmap font, ASCII 32-127)
  ;; Space (32) through '/' (47)
  (data (i32.const 0x10440)
    "\00\00\00\00\00\00\00\00"  ;; 32 space
    "\18\18\18\18\18\00\18\00"  ;; 33 !
    "\6c\6c\00\00\00\00\00\00"  ;; 34 "
    "\6c\6c\fe\6c\fe\6c\6c\00"  ;; 35 #
    "\18\3e\60\3c\06\7c\18\00"  ;; 36 $
    "\00\c6\cc\18\30\66\c6\00"  ;; 37 %
    "\38\6c\38\76\dc\cc\76\00"  ;; 38 &
    "\18\18\30\00\00\00\00\00"  ;; 39 '
    "\0c\18\30\30\30\18\0c\00"  ;; 40 (
    "\30\18\0c\0c\0c\18\30\00"  ;; 41 )
    "\00\66\3c\ff\3c\66\00\00"  ;; 42 *
    "\00\18\18\7e\18\18\00\00"  ;; 43 +
    "\00\00\00\00\00\18\18\30"  ;; 44 ,
    "\00\00\00\7e\00\00\00\00"  ;; 45 -
    "\00\00\00\00\00\18\18\00"  ;; 46 .
    "\06\0c\18\30\60\c0\80\00"  ;; 47 /
  )
  ;; '0' (48) through '9' (57)
  (data (i32.const 0x104C0)
    "\7c\c6\ce\de\f6\e6\7c\00"  ;; 48 0
    "\18\38\18\18\18\18\7e\00"  ;; 49 1
    "\3c\66\06\1c\30\60\7e\00"  ;; 50 2
    "\3c\66\06\1c\06\66\3c\00"  ;; 51 3
    "\0c\1c\3c\6c\7e\0c\0c\00"  ;; 52 4
    "\7e\60\7c\06\06\66\3c\00"  ;; 53 5
    "\1c\30\60\7c\66\66\3c\00"  ;; 54 6
    "\7e\06\0c\18\30\30\30\00"  ;; 55 7
    "\3c\66\66\3c\66\66\3c\00"  ;; 56 8
    "\3c\66\66\3e\06\0c\38\00"  ;; 57 9
  )
  ;; ':' (58) through '@' (64)
  (data (i32.const 0x10510)
    "\00\18\18\00\18\18\00\00"  ;; 58 :
    "\00\18\18\00\18\18\30\00"  ;; 59 ;
    "\0c\18\30\60\30\18\0c\00"  ;; 60 <
    "\00\00\7e\00\7e\00\00\00"  ;; 61 =
    "\30\18\0c\06\0c\18\30\00"  ;; 62 >
    "\3c\66\0c\18\18\00\18\00"  ;; 63 ?
    "\7c\c6\de\de\de\c0\7c\00"  ;; 64 @
  )
  ;; 'A' (65) through 'Z' (90)
  (data (i32.const 0x10548)
    "\18\3c\66\66\7e\66\66\00"  ;; A
    "\7c\66\66\7c\66\66\7c\00"  ;; B
    "\3c\66\60\60\60\66\3c\00"  ;; C
    "\78\6c\66\66\66\6c\78\00"  ;; D
    "\7e\60\60\78\60\60\7e\00"  ;; E
    "\7e\60\60\78\60\60\60\00"  ;; F
    "\3c\66\60\6e\66\66\3e\00"  ;; G
    "\66\66\66\7e\66\66\66\00"  ;; H
    "\3c\18\18\18\18\18\3c\00"  ;; I
    "\06\06\06\06\06\66\3c\00"  ;; J
    "\66\6c\78\70\78\6c\66\00"  ;; K
    "\60\60\60\60\60\60\7e\00"  ;; L
    "\c6\ee\fe\d6\c6\c6\c6\00"  ;; M
    "\c6\e6\f6\de\ce\c6\c6\00"  ;; N
    "\3c\66\66\66\66\66\3c\00"  ;; O
    "\7c\66\66\7c\60\60\60\00"  ;; P
    "\3c\66\66\66\6a\6c\36\00"  ;; Q
    "\7c\66\66\7c\6c\66\66\00"  ;; R
    "\3c\66\60\3c\06\66\3c\00"  ;; S
    "\7e\18\18\18\18\18\18\00"  ;; T
    "\66\66\66\66\66\66\3c\00"  ;; U
    "\66\66\66\66\66\3c\18\00"  ;; V
    "\c6\c6\c6\d6\fe\ee\c6\00"  ;; W
    "\c6\c6\6c\38\6c\c6\c6\00"  ;; X
    "\66\66\66\3c\18\18\18\00"  ;; Y
    "\7e\06\0c\18\30\60\7e\00"  ;; Z
  )
  ;; '[' (91) through '`' (96)
  (data (i32.const 0x10618)
    "\3c\30\30\30\30\30\3c\00"  ;; [
    "\c0\60\30\18\0c\06\02\00"  ;; backslash
    "\3c\0c\0c\0c\0c\0c\3c\00"  ;; ]
    "\10\38\6c\c6\00\00\00\00"  ;; ^
    "\00\00\00\00\00\00\00\ff"  ;; _
    "\30\18\0c\00\00\00\00\00"  ;; `
  )

  ;; Strings
  (data (i32.const 0x10700) "SCORE:\00")
  (data (i32.const 0x10707) "LVL\00")
  (data (i32.const 0x1070B) "COMBO x\00")
  (data (i32.const 0x10713) "ARKANOID\00")
  (data (i32.const 0x1071C) "WASM EDITION\00")
  (data (i32.const 0x10729) "PRESS SPACE\00")
  (data (i32.const 0x10735) "GAME OVER\00")
  (data (i32.const 0x1073F) "YOU WIN!\00")

  ;; ================================================================
  ;; MUSIC PATTERNS
  ;; ================================================================
  ;; Format: bpm(u16), steps(u8), num_tracks(u8),
  ;;         per track: type(u8), vol(u8), dur_cs(u8), pad(u8)
  ;;         then note data: track0[steps], track1[steps], track2[steps]
  ;; MIDI: C3=48, D3=50, E3=52, F3=53, G3=55, A3=57, B3=59
  ;;        C4=60, D4=62, E4=64, F4=65, G4=67, A4=69, B4=71
  ;;        C5=72, D5=74, E5=76

  ;; Title: 110 BPM, 32 steps — mysterious/atmospheric Am→F→C→G
  (data (i32.const 0x10A00)
    "\6e\00"  ;; bpm = 110
    "\20"     ;; steps = 32
    "\03"     ;; num_tracks = 3
    "\03\50\0a\00"  ;; track0: triangle bass, vol=80, dur=10cs (warm)
    "\00\30\08\00"  ;; track1: sine pad/arp, vol=48, dur=8cs (soft)
    "\01\28\05\00"  ;; track2: square melody, vol=40, dur=5cs
    ;; bass: Am(A2=45) | F(F2=41) | C(C3=48) | G(G2=43) — root notes with rhythm
    "\2d\00\2d\2d\00\2d\00\2d"  ;; Am bars
    "\29\00\29\29\00\29\00\29"  ;; F bars
    "\30\00\30\30\00\30\00\30"  ;; C bars
    "\2b\00\2b\2b\00\2b\00\2b"  ;; G bars
    ;; arp: chord tones rolling up — Am(A3,C4,E4) F(F3,A3,C4) C(C4,E4,G4) G(G3,B3,D4)
    "\39\3c\40\3c\39\40\3c\39"  ;; Am: A3=57,C4=60,E4=64
    "\35\39\3c\39\35\3c\39\35"  ;; F: F3=53,A3=57,C4=60
    "\3c\40\43\40\3c\43\40\3c"  ;; C: C4=60,E4=64,G4=67
    "\37\3b\3e\3b\37\3e\3b\37"  ;; G: G3=55,B3=59,D4=62
    ;; lead: haunting melody over the progression
    "\00\00\45\48\45\00\43\45"  ;; over Am: E4→A4→E4→G4→E4
    "\00\00\41\45\41\00\3c\41"  ;; over F: F4→E4→F4→C4→F4
    "\00\00\43\48\4c\00\48\43"  ;; over C: G4→A4→C5→A4→G4
    "\00\00\43\47\43\00\3e\3b"  ;; over G: G4→B4→G4→D4→B3
  )

  ;; Gameplay: 150 BPM, 32 steps — energetic driving chiptune Em→C→D→B
  (data (i32.const 0x10B00)
    "\96\00"  ;; bpm = 150
    "\20"     ;; steps = 32
    "\03"     ;; num_tracks = 3
    "\01\58\08\00"  ;; track0: square bass, vol=88, dur=8cs (punchy)
    "\03\50\0a\00"  ;; track1: triangle arp, vol=80, dur=10cs (sustained)
    "\02\48\0c\00"  ;; track2: sawtooth lead, vol=72, dur=12cs (bright, legato)
    ;; bass: driving 8th-note pulse — Em(E2=40) | C(C2=36) | D(D2=38) | B(B1=35)
    "\28\00\28\28\00\28\28\00"  ;; Em
    "\24\00\24\24\00\24\24\00"  ;; C
    "\26\00\26\26\00\26\26\00"  ;; D
    "\23\00\23\23\00\23\28\00"  ;; B → turnaround to Em
    ;; arp: Em(E3,G3,B3) C(C3,E3,G3) D(D3,F#3,A3) B(B2,D#3,F#3)
    "\34\37\3b\37\34\3b\37\34"  ;; Em: E3=52,G3=55,B3=59
    "\30\34\37\34\30\37\34\30"  ;; C: C3=48,E3=52,G3=55
    "\32\36\39\36\32\39\36\32"  ;; D: D3=50,F#3=54,A3=57
    "\2f\33\36\33\2f\36\33\2f"  ;; B: B2=47,D#3=51,F#3=54
    ;; lead: catchy melodic hook
    "\40\43\47\43\40\47\4c\47"  ;; Em: E4→G4→B4→G4→E4→B4→E5→B4
    "\3c\40\43\48\43\40\3c\40"  ;; C: C4→E4→G4→C5→G4→E4→C4→E4
    "\3e\42\45\42\3e\45\4a\45"  ;; D: D4→F#4→A4→F#4→D4→A4→D5→A4
    "\3b\3e\43\47\43\3e\3b\3e"  ;; B: B3→D4→G4→B4→G4→D4→B3→D4
  )
)
