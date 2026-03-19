(module
  (import "env" "memory" (memory 4))
  (import "env" "music" (func $music (param i32)))

  ;; "CODING IS OVER" — Multi-section demoscene piece
  ;;
  ;; Memory layout — const at bottom, dynamic at top of 256KB:
  ;;
  ;; CONST (read-only after init):
  ;;   0x10340 - sin table (256 bytes)
  ;;   0x10440 - font data (768 bytes, ASCII 32-127, 8 bytes each)
  ;;   0x10740 - "CODING IS OVER" (14)
  ;;   0x10750 - "BERRRY.APP" (10)
  ;;   0x10760 - "BERRRY.APP PRESENTS" (19)
  ;;   0x10780 - "INTENT NOT SYNTAX" (17)
  ;;   0x107A0 - "BUILT ON BERRRY.APP" (19)
  ;;   0x107C0 - scroller message (~240 bytes)
  ;;   0x108C0 - "WASMVGA-DEMOS.BERRRY.APP" (24)
  ;;   0x108E0 - tombstone labels: "C\0JAVA\0PYTHON\0RUST\0JS\0GO\0"
  ;;
  ;; DYNAMIC (mutated every frame):
  ;;   0x38000 - PRNG state (4 bytes)
  ;;   0x38004 - start_tick (4 bytes)
  ;;   0x38008 - last_section (4 bytes)
  ;;   0x3800C - prev_input (4 bytes)
  ;;   0x38010 - rain columns: 40 x 4 = 160 bytes
  ;;   0x38100 - fire buffer: 320x40 = 12800 bytes (ends 0x3B500)
  ;;
  ;; Section timing (elapsed_ms % 64000):
  ;;   0     -  8000  Section 0: Code Rain
  ;;   8000  - 20000  Section 1: Graveyard
  ;;   20000 - 32000  Section 2: THE MESSAGE (thumbnail frame ~25s)
  ;;   32000 - 44000  Section 3: Plasma + Text
  ;;   44000 - 56000  Section 4: Scroller
  ;;   56000 - 64000  Section 5: Berrry Finale

  ;; =========================================================
  ;; UTILITY: sin approximation (Taylor series)
  ;; =========================================================
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

  ;; =========================================================
  ;; UTILITY: sin table lookup (index 0-255 → value 0-255)
  ;; =========================================================
  (func $sin_tab (param $idx i32) (result i32)
    (i32.load8_u (i32.add (i32.const 0x10340) (i32.and (local.get $idx) (i32.const 255))))
  )

  ;; =========================================================
  ;; UTILITY: xorshift32 PRNG
  ;; =========================================================
  (func $rand (result i32)
    (local $s i32)
    (local.set $s (i32.load (i32.const 0x38000)))
    (if (i32.eqz (local.get $s)) (then (local.set $s (i32.const 12345))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 13))))
    (local.set $s (i32.xor (local.get $s) (i32.shr_u (local.get $s) (i32.const 17))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 5))))
    (i32.store (i32.const 0x38000) (local.get $s))
    (local.get $s)
  )

  ;; =========================================================
  ;; UTILITY: font pixel lookup
  ;; char c (ASCII), row r (0-7), col k (0-7) → 0 or 1
  ;; =========================================================
  (func $font_pixel (param $c i32) (param $r i32) (param $k i32) (result i32)
    (local $byte i32)
    ;; font stored with row 7 first, so address = base + (c-32)*8 + (7-r)
    (local.set $byte (i32.load8_u (i32.add (i32.const 0x10440)
      (i32.add (i32.mul (i32.sub (local.get $c) (i32.const 32)) (i32.const 8))
               (i32.sub (i32.const 7) (local.get $r))))))
    (i32.and (i32.shr_u (local.get $byte) (i32.sub (i32.const 7) (local.get $k))) (i32.const 1))
  )

  ;; =========================================================
  ;; UTILITY: draw text string to framebuffer
  ;; str_addr, str_len, base_x, base_y, scale, color_index
  ;; Char spacing = 9*scale pixels per character (8 glyph + 1 gap)
  ;; =========================================================
  (func $draw_text (param $str_addr i32) (param $str_len i32)
                   (param $base_x i32) (param $base_y i32)
                   (param $scale i32) (param $color i32)
    (local $ci i32) (local $ch i32) (local $row i32) (local $col i32)
    (local $px i32) (local $py i32) (local $si i32) (local $sj i32)

    (local.set $ci (i32.const 0))
    (block $cdone (loop $cloop
      (br_if $cdone (i32.ge_u (local.get $ci) (local.get $str_len)))
      (local.set $ch (i32.load8_u (i32.add (local.get $str_addr) (local.get $ci))))

      (local.set $row (i32.const 0))
      (block $rdone (loop $rloop
        (br_if $rdone (i32.ge_u (local.get $row) (i32.const 8)))

        (local.set $col (i32.const 0))
        (block $kdone (loop $kloop
          (br_if $kdone (i32.ge_u (local.get $col) (i32.const 8)))

          (if (call $font_pixel (local.get $ch) (local.get $row) (local.get $col))
            (then
              (local.set $px (i32.add (local.get $base_x)
                (i32.add (i32.mul (local.get $ci) (i32.mul (i32.const 9) (local.get $scale)))
                         (i32.mul (local.get $col) (local.get $scale)))))
              (local.set $py (i32.add (local.get $base_y)
                (i32.mul (local.get $row) (local.get $scale))))

              ;; draw scale x scale block
              (local.set $sj (i32.const 0))
              (block $sjd (loop $sjl
                (br_if $sjd (i32.ge_u (local.get $sj) (local.get $scale)))
                (local.set $si (i32.const 0))
                (block $sid (loop $sil
                  (br_if $sid (i32.ge_u (local.get $si) (local.get $scale)))
                  ;; bounds check and write
                  (if (i32.and
                    (i32.and (i32.ge_s (i32.add (local.get $px) (local.get $si)) (i32.const 0))
                             (i32.lt_s (i32.add (local.get $px) (local.get $si)) (i32.const 320)))
                    (i32.and (i32.ge_s (i32.add (local.get $py) (local.get $sj)) (i32.const 0))
                             (i32.lt_s (i32.add (local.get $py) (local.get $sj)) (i32.const 200))))
                    (then
                      (i32.store8
                        (i32.add (i32.const 0x0340)
                          (i32.add (i32.mul (i32.add (local.get $py) (local.get $sj)) (i32.const 320))
                                   (i32.add (local.get $px) (local.get $si))))
                        (local.get $color))
                    ))
                  (local.set $si (i32.add (local.get $si) (i32.const 1)))
                  (br $sil)
                ))
                (local.set $sj (i32.add (local.get $sj) (i32.const 1)))
                (br $sjl)
              ))
            ))

          (local.set $col (i32.add (local.get $col) (i32.const 1)))
          (br $kloop)
        ))

        (local.set $row (i32.add (local.get $row) (i32.const 1)))
        (br $rloop)
      ))

      (local.set $ci (i32.add (local.get $ci) (i32.const 1)))
      (br $cloop)
    ))
  )

  ;; =========================================================
  ;; UTILITY: clear framebuffer to palette index 0
  ;; =========================================================
  (func $clear_fb
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 64000)))
      (i32.store8 (i32.add (i32.const 0x0340) (local.get $i)) (i32.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)
    ))
  )

  ;; =========================================================
  ;; UTILITY: set one palette entry (idx, r, g, b)
  ;; =========================================================
  (func $set_pal (param $i i32) (param $r i32) (param $g i32) (param $b i32)
    (local $addr i32)
    (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
    (i32.store8 (local.get $addr) (local.get $r))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
    (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
  )

  ;; =========================================================
  ;; SECTION 0: Code Rain  (placeholder)
  ;; =========================================================
  (func $pal_rain
    (local $i i32) (local $g i32)
    ;; 0 = black
    (call $set_pal (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))
    ;; 1-20: long green trail ramp (dark → bright green)
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.gt_u (local.get $i) (i32.const 20)))
      (local.set $g (i32.div_u (i32.mul (local.get $i) (i32.const 220)) (i32.const 20)))
      (call $set_pal (local.get $i)
        (i32.div_u (local.get $g) (i32.const 6))
        (local.get $g)
        (i32.div_u (local.get $g) (i32.const 8)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)
    ))
    ;; 21 = bright white-green head
    (call $set_pal (i32.const 21) (i32.const 180) (i32.const 255) (i32.const 180))
    ;; 22 = white flash (brand new char)
    (call $set_pal (i32.const 22) (i32.const 255) (i32.const 255) (i32.const 255))
    ;; 15 = berrry green for reveal text
    (call $set_pal (i32.const 15) (i32.const 0) (i32.const 221) (i32.const 136))
  )

  ;; Draw a single 8x8 char at pixel (px, py) with given color
  (func $draw_char_at (param $ch i32) (param $px i32) (param $py i32) (param $color i32)
    (local $row i32) (local $k i32) (local $sx i32) (local $sy i32)
    (local.set $row (i32.const 0))
    (block $rd (loop $rl
      (br_if $rd (i32.ge_u (local.get $row) (i32.const 8)))
      (local.set $k (i32.const 0))
      (block $kd (loop $kl
        (br_if $kd (i32.ge_u (local.get $k) (i32.const 8)))
        (if (call $font_pixel (local.get $ch) (local.get $row) (local.get $k))
          (then
            (local.set $sx (i32.add (local.get $px) (local.get $k)))
            (local.set $sy (i32.add (local.get $py) (local.get $row)))
            (if (i32.and (i32.lt_u (local.get $sx) (i32.const 320))
                         (i32.lt_u (local.get $sy) (i32.const 200)))
              (then
                (i32.store8
                  (i32.add (i32.const 0x0340)
                    (i32.add (i32.mul (local.get $sy) (i32.const 320)) (local.get $sx)))
                  (local.get $color))))))
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $kl)
      ))
      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br $rl)
    ))
  )

  (func $render_rain (param $elapsed i32)
    (local $col i32) (local $base i32)
    (local $y i32) (local $speed i32) (local $alive i32)
    (local $px i32) (local $trail_i i32) (local $trail_y i32)
    (local $trail_ch i32) (local $trail_color i32)
    (local $kill_dist i32) (local $frame_8 i32)
    (local $reveal_count i32) (local $ri i32)
    (local $target_ch i32) (local $target_x i32)

    ;; Clear screen each frame (redraw all streams fresh)
    (call $clear_fb)

    (local.set $frame_8 (i32.shr_u (local.get $elapsed) (i32.const 6)))

    ;; After 5s, kill columns from edges inward
    (if (i32.gt_u (local.get $elapsed) (i32.const 5000))
      (then
        (local.set $kill_dist (i32.div_u
          (i32.sub (local.get $elapsed) (i32.const 5000)) (i32.const 150)))
        (if (i32.gt_u (local.get $kill_dist) (i32.const 20))
          (then (local.set $kill_dist (i32.const 20))))
        (local.set $col (i32.const 0))
        (block $kd (loop $kl
          (br_if $kd (i32.ge_u (local.get $col) (i32.const 40)))
          (if (i32.or
            (i32.lt_u (local.get $col) (local.get $kill_dist))
            (i32.ge_u (local.get $col) (i32.sub (i32.const 40) (local.get $kill_dist))))
            (then
              (i32.store8 (i32.add (i32.const 0x38013)
                (i32.mul (local.get $col) (i32.const 4))) (i32.const 0))))
          (local.set $col (i32.add (local.get $col) (i32.const 1)))
          (br $kl)
        ))
      ))

    ;; Update and draw each column with full stream
    (local.set $col (i32.const 0))
    (block $cd (loop $cl
      (br_if $cd (i32.ge_u (local.get $col) (i32.const 40)))
      (local.set $base (i32.add (i32.const 0x38010) (i32.mul (local.get $col) (i32.const 4))))
      (local.set $y (i32.load8_u (local.get $base)))
      (local.set $speed (i32.load8_u (i32.add (local.get $base) (i32.const 1))))
      (local.set $alive (i32.load8_u (i32.add (local.get $base) (i32.const 3))))

      (if (local.get $alive)
        (then
          ;; Advance head position
          (local.set $y (i32.add (local.get $y) (local.get $speed)))
          (if (i32.ge_u (local.get $y) (i32.const 224))
            (then
              (local.set $y (i32.const 0))
              (local.set $speed (i32.add (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFFFFFF))
                (i32.const 3)) (i32.const 1)))))
          (i32.store8 (local.get $base) (local.get $y))
          (i32.store8 (i32.add (local.get $base) (i32.const 1)) (local.get $speed))
          (local.set $px (i32.mul (local.get $col) (i32.const 8)))

          ;; Draw stream: head + 15 trailing chars
          (local.set $trail_i (i32.const 0))
          (block $td (loop $tl
            (br_if $td (i32.ge_u (local.get $trail_i) (i32.const 16)))
            (local.set $trail_y (i32.sub (local.get $y)
              (i32.mul (local.get $trail_i) (i32.const 8))))

            ;; Only draw if on screen
            (if (i32.and (i32.ge_s (local.get $trail_y) (i32.const 0))
                         (i32.lt_s (i32.add (local.get $trail_y) (i32.const 8)) (i32.const 200)))
              (then
                ;; Generate char: stable hash of col+position, shifts every ~512ms
                ;; Head shifts every ~128ms, rest every ~512ms
                (local.set $trail_ch
                  (i32.add (i32.rem_u
                    (i32.and
                      (i32.add
                        (i32.add (i32.mul (local.get $col) (i32.const 7))
                                 (i32.mul (local.get $trail_i) (i32.const 13)))
                        (i32.shr_u (local.get $elapsed)
                          (select (i32.const 7) (i32.const 9)
                            (i32.lt_u (local.get $trail_i) (i32.const 2)))))
                      (i32.const 0x7FFFFFFF))
                    (i32.const 94))
                  (i32.const 33)))

                ;; Color: head=22(white), next 2=21(bright), rest fade 20→5
                (local.set $trail_color
                  (select (i32.const 22)
                    (select (i32.const 21)
                      (select
                        (i32.sub (i32.const 20) (local.get $trail_i))
                        (i32.const 1)
                        (i32.lt_u (local.get $trail_i) (i32.const 19)))
                      (i32.lt_u (local.get $trail_i) (i32.const 3)))
                    (i32.eqz (local.get $trail_i))))

                (if (i32.gt_u (local.get $trail_color) (i32.const 0))
                  (then
                    (call $draw_char_at (local.get $trail_ch) (local.get $px)
                      (local.get $trail_y) (local.get $trail_color))))
              ))

            (local.set $trail_i (i32.add (local.get $trail_i) (i32.const 1)))
            (br $tl)
          ))
        ))
      (local.set $col (i32.add (local.get $col) (i32.const 1)))
      (br $cl)
    ))

    ;; Reveal "BERRRY.APP" characters one by one, formed by the rain
    ;; Starting at 2.5s, one char every 350ms
    ;; "BERRRY.APP" at (115, 96), scale 1, spacing 9px
    (if (i32.gt_u (local.get $elapsed) (i32.const 2500))
      (then
        (local.set $reveal_count (i32.div_u
          (i32.sub (local.get $elapsed) (i32.const 2500)) (i32.const 350)))
        (if (i32.gt_u (local.get $reveal_count) (i32.const 10))
          (then (local.set $reveal_count (i32.const 10))))

        ;; Draw each revealed character
        (local.set $ri (i32.const 0))
        (block $rvd (loop $rvl
          (br_if $rvd (i32.ge_u (local.get $ri) (local.get $reveal_count)))
          (local.set $target_ch (i32.load8_u (i32.add (i32.const 0x10750) (local.get $ri))))
          (local.set $target_x (i32.add (i32.const 115)
            (i32.mul (local.get $ri) (i32.const 9))))
          (call $draw_char_at (local.get $target_ch) (local.get $target_x) (i32.const 96) (i32.const 15))
          (local.set $ri (i32.add (local.get $ri) (i32.const 1)))
          (br $rvl)
        ))
      ))
  )

  ;; =========================================================
  ;; SECTION 1: Graveyard  (placeholder)
  ;; =========================================================
  (func $pal_grave
    (local $i i32)
    ;; 0 = dark purple sky
    (call $set_pal (i32.const 0) (i32.const 15) (i32.const 8) (i32.const 30))
    ;; 1-85: fire palette (black → red → yellow → white)
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.gt_u (local.get $i) (i32.const 85)))
      (if (i32.lt_u (local.get $i) (i32.const 29))
        (then ;; black to red
          (call $set_pal (local.get $i) (i32.mul (local.get $i) (i32.const 9)) (i32.const 0) (i32.const 0)))
        (else (if (i32.lt_u (local.get $i) (i32.const 57))
          (then ;; red to yellow
            (call $set_pal (local.get $i) (i32.const 255)
              (i32.mul (i32.sub (local.get $i) (i32.const 29)) (i32.const 9)) (i32.const 0)))
          (else ;; yellow to white
            (call $set_pal (local.get $i) (i32.const 255) (i32.const 255)
              (i32.mul (i32.sub (local.get $i) (i32.const 57)) (i32.const 9)))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)
    ))
    ;; 86 = dark brown ground
    (call $set_pal (i32.const 86) (i32.const 50) (i32.const 28) (i32.const 10))
    ;; 87 = gray tombstone
    (call $set_pal (i32.const 87) (i32.const 70) (i32.const 70) (i32.const 80))
    ;; 88 = lighter tombstone edge
    (call $set_pal (i32.const 88) (i32.const 110) (i32.const 110) (i32.const 120))
    ;; 89 = white for text/stars
    (call $set_pal (i32.const 89) (i32.const 255) (i32.const 255) (i32.const 255))
    ;; 90 = berrry green
    (call $set_pal (i32.const 90) (i32.const 0) (i32.const 221) (i32.const 136))
    ;; 91 = dim star
    (call $set_pal (i32.const 91) (i32.const 100) (i32.const 100) (i32.const 140))
  )

  (func $render_grave (param $elapsed i32)
    (local $t i32) (local $i i32) (local $x i32) (local $y i32) (local $fb i32)
    (local $rise i32) (local $tx i32) (local $ty i32) (local $tw i32) (local $th i32)
    (local $ti i32) (local $heat i32) (local $v1 i32) (local $v2 i32)

    ;; t = ms into this section
    (local.set $t (i32.sub (local.get $elapsed) (i32.const 8000)))

    ;; Fill screen with sky color (0)
    (call $clear_fb)

    ;; Draw stars (deterministic from position)
    (local.set $i (i32.const 0))
    (block $sd (loop $sl
      (br_if $sd (i32.ge_u (local.get $i) (i32.const 60)))
      ;; pseudo-random star positions from seed
      (local.set $x (i32.rem_u (i32.mul (local.get $i) (i32.const 197)) (i32.const 320)))
      (local.set $y (i32.rem_u (i32.mul (local.get $i) (i32.const 53)) (i32.const 130)))
      ;; twinkle: alternate between bright and dim based on tick
      (local.set $fb (i32.add (i32.const 0x0340)
        (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x))))
      (i32.store8 (local.get $fb)
        (select (i32.const 89) (i32.const 91)
          (i32.and (i32.add (local.get $i) (i32.shr_u (local.get $t) (i32.const 9))) (i32.const 1))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sl)
    ))

    ;; Draw ground (brown) from y=170 to 199
    (local.set $y (i32.const 170))
    (block $gd (loop $gl
      (br_if $gd (i32.ge_u (local.get $y) (i32.const 200)))
      (local.set $x (i32.const 0))
      (block $gxd (loop $gxl
        (br_if $gxd (i32.ge_u (local.get $x) (i32.const 320)))
        (i32.store8 (i32.add (i32.const 0x0340)
          (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x))) (i32.const 86))
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br $gxl)
      ))
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br $gl)
    ))

    ;; Draw 6 tombstones rising from bottom
    ;; Rise: over first 4s of section, from y=200 to target y
    (local.set $rise (i32.div_u (local.get $t) (i32.const 40)))
    (if (i32.gt_u (local.get $rise) (i32.const 100))
      (then (local.set $rise (i32.const 100))))

    ;; Tombstone 0: "C" at x=15, w=28, target_top=110
    (call $draw_tombstone (i32.const 15) (i32.const 28) (i32.const 60)
      (local.get $rise) (i32.const 0x108E0) (i32.const 1))
    ;; Tombstone 1: "JAVA" at x=65, w=44
    (call $draw_tombstone (i32.const 60) (i32.const 44) (i32.const 55)
      (local.get $rise) (i32.const 0x108E2) (i32.const 4))
    ;; Tombstone 2: "PYTHON" at x=118, w=60
    (call $draw_tombstone (i32.const 113) (i32.const 60) (i32.const 50)
      (local.get $rise) (i32.const 0x108E7) (i32.const 6))
    ;; Tombstone 3: "RUST" at x=185, w=44
    (call $draw_tombstone (i32.const 180) (i32.const 44) (i32.const 55)
      (local.get $rise) (i32.const 0x108EE) (i32.const 4))
    ;; Tombstone 4: "JS" at x=238, w=28
    (call $draw_tombstone (i32.const 235) (i32.const 28) (i32.const 58)
      (local.get $rise) (i32.const 0x108F3) (i32.const 2))
    ;; Tombstone 5: "GO" at x=278, w=28
    (call $draw_tombstone (i32.const 275) (i32.const 28) (i32.const 62)
      (local.get $rise) (i32.const 0x108F6) (i32.const 2))

    ;; Doom-style fire simulation in buffer at 0x38100 (320×40, rows 0-39 map to y=160-199)
    ;; Seed bottom row (row 39) with random hot values
    (local.set $x (i32.const 0))
    (block $sd (loop $sl
      (br_if $sd (i32.ge_u (local.get $x) (i32.const 320)))
      (i32.store8 (i32.add (i32.const 0x38100) (i32.add (i32.mul (i32.const 39) (i32.const 320)) (local.get $x)))
        (i32.rem_u (i32.and (call $rand) (i32.const 127)) (i32.const 86)))
      (local.set $x (i32.add (local.get $x) (i32.const 1)))
      (br $sl)
    ))
    ;; Propagate fire upward: for each pixel (x, row) where row < 39
    ;; new[row][x] = avg(old[row+1][x-1], old[row+1][x], old[row+1][x+1], old[row+2][x]) - decay
    (local.set $y (i32.const 0))
    (block $fd (loop $fl
      (br_if $fd (i32.ge_u (local.get $y) (i32.const 39)))
      (local.set $x (i32.const 0))
      (block $fxd (loop $fxl
        (br_if $fxd (i32.ge_u (local.get $x) (i32.const 320)))
        ;; below
        (local.set $v1 (i32.load8_u (i32.add (i32.const 0x38100)
          (i32.add (i32.mul (i32.add (local.get $y) (i32.const 1)) (i32.const 320)) (local.get $x)))))
        ;; below-left
        (local.set $v2 (i32.load8_u (i32.add (i32.const 0x38100)
          (i32.add (i32.mul (i32.add (local.get $y) (i32.const 1)) (i32.const 320))
            (select (i32.sub (local.get $x) (i32.const 1)) (i32.const 0)
              (i32.gt_u (local.get $x) (i32.const 0)))))))
        ;; below-right
        (local.set $heat (i32.load8_u (i32.add (i32.const 0x38100)
          (i32.add (i32.mul (i32.add (local.get $y) (i32.const 1)) (i32.const 320))
            (select (i32.add (local.get $x) (i32.const 1)) (i32.const 319)
              (i32.lt_u (local.get $x) (i32.const 319)))))))
        ;; two-below (or bottom row if at row 38)
        (local.set $heat (i32.shr_u
          (i32.add (i32.add (local.get $v1) (local.get $v2))
            (i32.add (local.get $heat)
              (i32.load8_u (i32.add (i32.const 0x38100)
                (i32.add (i32.mul
                  (select (i32.add (local.get $y) (i32.const 2)) (i32.const 39)
                    (i32.lt_u (local.get $y) (i32.const 38)))
                  (i32.const 320)) (local.get $x))))))
          (i32.const 2)))
        ;; random decay 0-1
        (local.set $heat (i32.sub (local.get $heat) (i32.and (call $rand) (i32.const 1))))
        (if (i32.lt_s (local.get $heat) (i32.const 0))
          (then (local.set $heat (i32.const 0))))
        ;; Store with wind: randomly shift x by 0 or 1
        (local.set $v1 (i32.add (local.get $x) (i32.and (call $rand) (i32.const 1))))
        (if (i32.ge_u (local.get $v1) (i32.const 320))
          (then (local.set $v1 (i32.const 319))))
        (i32.store8 (i32.add (i32.const 0x38100)
          (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $v1)))
          (local.get $heat))
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br $fxl)
      ))
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br $fl)
    ))
    ;; Overlay fire buffer onto framebuffer where intensity > 10
    (local.set $y (i32.const 0))
    (block $od (loop $ol
      (br_if $od (i32.ge_u (local.get $y) (i32.const 40)))
      (local.set $x (i32.const 0))
      (block $oxd (loop $oxl
        (br_if $oxd (i32.ge_u (local.get $x) (i32.const 320)))
        (local.set $heat (i32.load8_u (i32.add (i32.const 0x38100)
          (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x)))))
        (if (i32.gt_u (local.get $heat) (i32.const 25))
          (then
            (i32.store8 (i32.add (i32.const 0x0340)
              (i32.add (i32.mul (i32.add (local.get $y) (i32.const 160)) (i32.const 320)) (local.get $x)))
              (local.get $heat))))
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br $oxl)
      ))
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br $ol)
    ))

    ;; "BERRRY.APP PRESENTS" at top center, 1x scale
    ;; 19 chars * 9px = 171px. centered: (320-171)/2 = 74
    (if (i32.gt_u (local.get $t) (i32.const 2000))
      (then
        (call $draw_text (i32.const 0x10760) (i32.const 19)
          (i32.const 74) (i32.const 8) (i32.const 1) (i32.const 90))))
  )

  ;; Helper: draw a tombstone rectangle with text
  ;; params: x, width, height, rise(0-100), str_addr, str_len
  (func $draw_tombstone (param $tx i32) (param $tw i32) (param $th i32)
                         (param $rise i32) (param $str i32) (param $slen i32)
    (local $top_y i32) (local $x i32) (local $y i32) (local $fb i32)
    (local $text_x i32) (local $text_y i32)

    ;; top_y = 170 - (th * rise / 100)
    (local.set $top_y (i32.sub (i32.const 170)
      (i32.div_u (i32.mul (local.get $th) (local.get $rise)) (i32.const 100))))

    ;; Draw filled rectangle from (tx, top_y) to (tx+tw, 170)
    (local.set $y (local.get $top_y))
    (block $yd (loop $yl
      (br_if $yd (i32.ge_u (local.get $y) (i32.const 170)))
      (if (i32.and (i32.ge_s (local.get $y) (i32.const 0))
                   (i32.lt_s (local.get $y) (i32.const 200)))
        (then
          (local.set $x (local.get $tx))
          (block $xd (loop $xl
            (br_if $xd (i32.ge_u (local.get $x) (i32.add (local.get $tx) (local.get $tw))))
            (if (i32.lt_u (local.get $x) (i32.const 320))
              (then
                (local.set $fb (i32.add (i32.const 0x0340)
                  (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x))))
                ;; Edge pixels lighter
                (i32.store8 (local.get $fb)
                  (select (i32.const 88) (i32.const 87)
                    (i32.or
                      (i32.eq (local.get $x) (local.get $tx))
                      (i32.or
                        (i32.eq (local.get $x) (i32.sub (i32.add (local.get $tx) (local.get $tw)) (i32.const 1)))
                        (i32.eq (local.get $y) (local.get $top_y))))))))
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $xl)
          ))
        ))
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br $yl)
    ))

    ;; Draw text centered on tombstone
    (local.set $text_x (i32.add (local.get $tx)
      (i32.div_u (i32.sub (local.get $tw) (i32.mul (local.get $slen) (i32.const 9))) (i32.const 2))))
    (local.set $text_y (i32.add (local.get $top_y)
      (i32.div_u (i32.sub (i32.sub (i32.const 170) (local.get $top_y)) (i32.const 8)) (i32.const 2))))
    (if (i32.ge_s (local.get $text_y) (i32.const 0))
      (then
        (call $draw_text (local.get $str) (local.get $slen)
          (local.get $text_x) (local.get $text_y) (i32.const 1) (i32.const 89))))
  )

  ;; =========================================================
  ;; SECTION 2: THE MESSAGE  (placeholder)
  ;; =========================================================
  (func $pal_message
    ;; 0 = black
    (call $set_pal (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))
    ;; 1 = text color (updated per frame for pulse)
    (call $set_pal (i32.const 1) (i32.const 255) (i32.const 255) (i32.const 255))
    ;; 2 = berrry green
    (call $set_pal (i32.const 2) (i32.const 0) (i32.const 221) (i32.const 136))
    ;; 3 = scanline dim
    (call $set_pal (i32.const 3) (i32.const 30) (i32.const 30) (i32.const 30))
    ;; 4 = glitch bright
    (call $set_pal (i32.const 4) (i32.const 180) (i32.const 180) (i32.const 200))
  )

  (func $render_message (param $elapsed i32)
    (local $t i32) (local $x i32) (local $y i32) (local $gb i32)
    (local $glitch_y i32) (local $glitch_w i32) (local $gx i32)
    (local $text_x i32) (local $pulse i32)

    (local.set $t (i32.sub (local.get $elapsed) (i32.const 20000)))

    ;; Pulse text color: oscillate between white (255,255,255) and red (255,0,0)
    (local.set $pulse (call $sin_tab (i32.shr_u (local.get $t) (i32.const 2))))
    (call $set_pal (i32.const 1) (i32.const 255) (local.get $pulse) (local.get $pulse))

    ;; Clear to black
    (call $clear_fb)

    ;; Initial glitch effect: first 500ms, random blocks
    (if (i32.lt_u (local.get $t) (i32.const 500))
      (then
        (local.set $y (i32.const 0))
        (block $gd (loop $gl
          (br_if $gd (i32.ge_u (local.get $y) (i32.const 40)))
          (local.set $glitch_y (i32.rem_u
            (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 200)))
          (local.set $gx (i32.rem_u
            (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 280)))
          (local.set $glitch_w (i32.add
            (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 40)) (i32.const 10)))
          (local.set $x (local.get $gx))
          (block $gwd (loop $gwl
            (br_if $gwd (i32.ge_u (local.get $x)
              (i32.add (local.get $gx) (local.get $glitch_w))))
            (if (i32.lt_u (local.get $x) (i32.const 320))
              (then
                (i32.store8 (i32.add (i32.const 0x0340)
                  (i32.add (i32.mul (local.get $glitch_y) (i32.const 320)) (local.get $x)))
                  (i32.const 4))))
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $gwl)
          ))
          (local.set $y (i32.add (local.get $y) (i32.const 1)))
          (br $gl)
        ))
        (return)
      ))

    ;; "CODING IS OVER" at 2x scale, centered
    ;; 14 chars * 9 * 2 = 252px. base_x = (320-252)/2 = 34
    (call $draw_text (i32.const 0x10740) (i32.const 14)
      (i32.const 34) (i32.const 72) (i32.const 2) (i32.const 1))

    ;; "BERRRY.APP" at 1x below, centered
    ;; 10 chars * 9 = 90px. base_x = (320-90)/2 = 115
    (call $draw_text (i32.const 0x10750) (i32.const 10)
      (i32.const 115) (i32.const 100) (i32.const 1) (i32.const 2))

    ;; CRT scanlines: darken every other row
    (local.set $y (i32.const 0))
    (block $sd (loop $sl
      (br_if $sd (i32.ge_u (local.get $y) (i32.const 200)))
      (if (i32.and (local.get $y) (i32.const 1))
        (then
          (local.set $x (i32.const 0))
          (block $sxd (loop $sxl
            (br_if $sxd (i32.ge_u (local.get $x) (i32.const 320)))
            (local.set $gb (i32.add (i32.const 0x0340)
              (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x))))
            (if (i32.load8_u (local.get $gb))
              (then (i32.store8 (local.get $gb) (i32.const 3))))
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $sxl)
          ))
        ))
      (local.set $y (i32.add (local.get $y) (i32.const 2)))
      (br $sl)
    ))

    ;; Horizontal glitch bars: every ~8 frames, shift a few random rows
    (if (i32.lt_u (i32.and (local.get $t) (i32.const 127)) (i32.const 16))
      (then
        (local.set $y (i32.const 0))
        (block $hd (loop $hl
          (br_if $hd (i32.ge_u (local.get $y) (i32.const 3)))
          (local.set $glitch_y (i32.rem_u
            (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 200)))
          ;; fill row with offset color
          (local.set $x (i32.const 0))
          (block $hxd (loop $hxl
            (br_if $hxd (i32.ge_u (local.get $x) (i32.const 320)))
            (i32.store8 (i32.add (i32.const 0x0340)
              (i32.add (i32.mul (local.get $glitch_y) (i32.const 320)) (local.get $x)))
              (select (i32.const 4) (i32.const 0)
                (i32.lt_u (i32.and (call $rand) (i32.const 7)) (i32.const 3))))
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $hxl)
          ))
          (local.set $y (i32.add (local.get $y) (i32.const 1)))
          (br $hl)
        ))
      ))
  )

  ;; =========================================================
  ;; SECTION 3: Plasma + Text  (placeholder)
  ;; =========================================================
  (func $pal_plasma
    (local $i i32) (local $f f64) (local $v f64)
    (local $r i32) (local $g i32) (local $b i32)
    ;; 0-239: plasma rainbow (dimmed)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 240)))
      (local.set $f (f64.div (f64.convert_i32_u (local.get $i)) (f64.const 240.0)))
      (local.set $v (f64.add (f64.mul (call $sin_approx (f64.mul (local.get $f) (f64.const 6.2832))) (f64.const 40.0)) (f64.const 50.0)))
      (local.set $r (i32.trunc_f64_s (local.get $v)))
      (local.set $v (f64.add (f64.mul (call $sin_approx (f64.add (f64.mul (local.get $f) (f64.const 6.2832)) (f64.const 2.094))) (f64.const 40.0)) (f64.const 50.0)))
      (local.set $g (i32.trunc_f64_s (local.get $v)))
      (local.set $v (f64.add (f64.mul (call $sin_approx (f64.add (f64.mul (local.get $f) (f64.const 6.2832)) (f64.const 4.189))) (f64.const 40.0)) (f64.const 50.0)))
      (local.set $b (i32.trunc_f64_s (local.get $v)))
      (if (i32.lt_s (local.get $r) (i32.const 0)) (then (local.set $r (i32.const 0))))
      (if (i32.gt_s (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))
      (if (i32.lt_s (local.get $g) (i32.const 0)) (then (local.set $g (i32.const 0))))
      (if (i32.gt_s (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
      (if (i32.lt_s (local.get $b) (i32.const 0)) (then (local.set $b (i32.const 0))))
      (if (i32.gt_s (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
      (call $set_pal (local.get $i) (local.get $r) (local.get $g) (local.get $b))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)
    ))
    ;; 240-249: bright white-cyan text
    (local.set $i (i32.const 240))
    (block $td (loop $tl
      (br_if $td (i32.gt_u (local.get $i) (i32.const 249)))
      (call $set_pal (local.get $i) (i32.const 255) (i32.const 255) (i32.const 255))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $tl)
    ))
    ;; 250 = berrry green
    (call $set_pal (i32.const 250) (i32.const 0) (i32.const 221) (i32.const 136))
  )

  (func $render_plasma (param $elapsed i32)
    (local $t i32) (local $tick i32) (local $x i32) (local $y i32)
    (local $v1 i32) (local $v2 i32) (local $v3 i32) (local $v4 i32) (local $color i32)
    (local $sec_t i32) (local $wave i32) (local $text_y i32)

    (local.set $sec_t (i32.sub (local.get $elapsed) (i32.const 32000)))
    (local.set $tick (i32.shr_u (local.get $elapsed) (i32.const 4)))

    ;; Draw plasma background
    (local.set $y (i32.const 0))
    (block $yd (loop $yl
      (br_if $yd (i32.ge_u (local.get $y) (i32.const 200)))
      (local.set $x (i32.const 0))
      (block $xd (loop $xl
        (br_if $xd (i32.ge_u (local.get $x) (i32.const 320)))
        (local.set $v1 (call $sin_tab (i32.add (local.get $x) (local.get $tick))))
        (local.set $v2 (call $sin_tab (i32.add (local.get $y) (i32.shl (local.get $tick) (i32.const 1)))))
        (local.set $v3 (call $sin_tab (i32.add (i32.add (local.get $x) (local.get $y)) (local.get $tick))))
        (local.set $v4 (call $sin_tab (i32.add
          (i32.add (i32.mul (local.get $x) (i32.const 2)) (i32.mul (local.get $y) (i32.const 3)))
          (i32.mul (local.get $tick) (i32.const 3)))))
        (local.set $color (i32.rem_u
          (i32.shr_u (i32.add (i32.add (local.get $v1) (local.get $v2))
            (i32.add (local.get $v3) (local.get $v4))) (i32.const 2))
          (i32.const 240)))
        (i32.store8 (i32.add (i32.const 0x0340)
          (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x)))
          (local.get $color))
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br $xl)
      ))
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br $yl)
    ))

    ;; Overlay text with sine wave Y offset
    ;; First 6s: "INTENT NOT SYNTAX" (17 chars * 9 * 2 = 306px → x=7)
    ;; Last 6s: "BUILT ON BERRRY.APP" (19 chars * 9 * 1 = 171px → x=74)
    (local.set $wave (i32.sub
      (i32.shr_u (call $sin_tab (i32.shr_u (local.get $sec_t) (i32.const 3))) (i32.const 2))
      (i32.const 32)))
    (local.set $text_y (i32.add (i32.const 88) (local.get $wave)))

    (if (i32.lt_u (local.get $sec_t) (i32.const 6000))
      (then
        (call $draw_text (i32.const 0x10780) (i32.const 17)
          (i32.const 7) (local.get $text_y) (i32.const 2) (i32.const 245)))
      (else
        (call $draw_text (i32.const 0x107A0) (i32.const 19)
          (i32.const 74) (local.get $text_y) (i32.const 1) (i32.const 250))))
  )

  ;; =========================================================
  ;; SECTION 4: Scroller  (placeholder)
  ;; =========================================================
  (func $pal_scroll
    (local $i i32)
    ;; 0 = deep blue-black
    (call $set_pal (i32.const 0) (i32.const 4) (i32.const 4) (i32.const 16))
    ;; 1 = dim star
    (call $set_pal (i32.const 1) (i32.const 60) (i32.const 60) (i32.const 100))
    ;; 2 = medium star
    (call $set_pal (i32.const 2) (i32.const 140) (i32.const 140) (i32.const 180))
    ;; 3 = bright star
    (call $set_pal (i32.const 3) (i32.const 255) (i32.const 255) (i32.const 255))
    ;; 240-255: text brightness ramp from background (4,4,16) to white (255,255,255)
    ;; index 240 = background, 255 = full white
    (local.set $i (i32.const 0))
    (block $td (loop $tl
      (br_if $td (i32.gt_u (local.get $i) (i32.const 15)))
      (call $set_pal (i32.add (i32.const 240) (local.get $i))
        ;; R: 4 + i * (255-4) / 15 = 4 + i * 251 / 15
        (i32.add (i32.const 4) (i32.div_u (i32.mul (local.get $i) (i32.const 251)) (i32.const 15)))
        ;; G: 4 + i * 251 / 15
        (i32.add (i32.const 4) (i32.div_u (i32.mul (local.get $i) (i32.const 251)) (i32.const 15)))
        ;; B: 16 + i * (255-16) / 15 = 16 + i * 239 / 15
        (i32.add (i32.const 16) (i32.div_u (i32.mul (local.get $i) (i32.const 239)) (i32.const 15))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $tl)
    ))
  )

  ;; Bilinear sample the text texture at fixed-point coords (tx_fp, ty_fp)
  ;; Returns 0-256 brightness. Samples 4 neighboring integer texels and blends.
  (func $text_texel_fp (param $tx_fp i32) (param $ty_fp i32) (result i32)
    (local $tx i32) (local $ty i32) (local $fx i32) (local $fy i32)
    (local $s00 i32) (local $s10 i32) (local $s01 i32) (local $s11 i32)
    (local $top i32) (local $bot i32)
    (local.set $tx (i32.shr_s (local.get $tx_fp) (i32.const 8)))
    (local.set $ty (i32.shr_s (local.get $ty_fp) (i32.const 8)))
    (local.set $fx (i32.and (local.get $tx_fp) (i32.const 255)))
    (local.set $fy (i32.and (local.get $ty_fp) (i32.const 255)))
    (local.set $s00 (call $text_texel (local.get $tx) (local.get $ty)))
    (local.set $s10 (call $text_texel (i32.add (local.get $tx) (i32.const 1)) (local.get $ty)))
    (local.set $s01 (call $text_texel (local.get $tx) (i32.add (local.get $ty) (i32.const 1))))
    (local.set $s11 (call $text_texel (i32.add (local.get $tx) (i32.const 1)) (i32.add (local.get $ty) (i32.const 1))))
    (local.set $top (i32.add
      (i32.mul (local.get $s00) (i32.sub (i32.const 256) (local.get $fx)))
      (i32.mul (local.get $s10) (local.get $fx))))
    (local.set $bot (i32.add
      (i32.mul (local.get $s01) (i32.sub (i32.const 256) (local.get $fx)))
      (i32.mul (local.get $s11) (local.get $fx))))
    (i32.shr_u (i32.add
      (i32.mul (local.get $top) (i32.sub (i32.const 256) (local.get $fy)))
      (i32.mul (local.get $bot) (local.get $fy)))
      (i32.const 8))
  )

  ;; Sample the 224×90 virtual text texture at integer coords (tx, ty)
  ;; Returns 0 or 1. Out-of-bounds and inter-line gaps return 0.
  (func $text_texel (param $tx i32) (param $ty i32) (result i32)
    (local $line i32) (local $fr i32) (local $cc i32) (local $ci i32) (local $ch i32)
    (if (result i32) (i32.or (i32.or
      (i32.lt_s (local.get $tx) (i32.const 0)) (i32.ge_s (local.get $tx) (i32.const 224)))
      (i32.or (i32.lt_s (local.get $ty) (i32.const 0)) (i32.ge_s (local.get $ty) (i32.const 90))))
      (then (i32.const 0))
      (else
        (local.set $line (i32.div_u (local.get $ty) (i32.const 10)))
        (local.set $fr (i32.rem_u (local.get $ty) (i32.const 10)))
        (if (result i32) (i32.ge_u (local.get $fr) (i32.const 8))
          (then (i32.const 0))  ;; inter-line gap
          (else
            (local.set $cc (i32.div_u (local.get $tx) (i32.const 8)))
            (local.set $ci (i32.add (i32.mul (local.get $line) (i32.const 28)) (local.get $cc)))
            (if (result i32) (i32.ge_u (local.get $ci) (i32.const 240))
              (then (i32.const 0))
              (else
                (local.set $ch (i32.load8_u (i32.add (i32.const 0x107C0) (local.get $ci))))
                (if (result i32) (i32.eq (local.get $ch) (i32.const 32))
                  (then (i32.const 0))
                  (else (call $font_pixel (local.get $ch) (local.get $fr)
                    (i32.rem_u (local.get $tx) (i32.const 8))))))))))))

  (func $render_scroll (param $elapsed i32)
    (local $t i32) (local $tick i32) (local $i i32)
    (local $star_x i32) (local $star_y i32) (local $star_speed i32)
    (local $sy i32) (local $sx i32) (local $df i32)
    (local $scroll i32) (local $screen_half i32) (local $left i32)
    (local $right i32) (local $color i32)
    ;; Fixed-point 8-bit fraction
    (local $ty_fp i32) (local $tx_fp i32)
    (local $bright i32) (local $depth_bright i32)
    (local $step i32) (local $sum i32) (local $vstep i32)
    (local $left_fp i32)

    (local.set $t (i32.sub (local.get $elapsed) (i32.const 44000)))
    (local.set $tick (i32.shr_u (local.get $t) (i32.const 4)))

    ;; Clear to background
    (call $clear_fb)

    ;; Draw starfield (3 layers with parallax)
    (local.set $i (i32.const 0))
    (block $sd (loop $sl
      (br_if $sd (i32.ge_u (local.get $i) (i32.const 80)))
      (local.set $star_x (i32.rem_u (i32.add
        (i32.rem_u (i32.mul (local.get $i) (i32.const 197)) (i32.const 320))
        (i32.mul (local.get $tick) (i32.add (i32.rem_u (local.get $i) (i32.const 3)) (i32.const 1))))
        (i32.const 320)))
      (local.set $star_y (i32.rem_u (i32.mul (local.get $i) (i32.const 53)) (i32.const 200)))
      (local.set $star_speed (i32.add (i32.rem_u (local.get $i) (i32.const 3)) (i32.const 1)))
      (i32.store8 (i32.add (i32.const 0x0340)
        (i32.add (i32.mul (local.get $star_y) (i32.const 320)) (local.get $star_x)))
        (local.get $star_speed))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sl)
    ))

    ;; Star Wars perspective crawl with bilinear interpolation
    ;; Virtual texture: 224×90 (28 chars × 8px wide, 9 lines × 10px tall)
    ;; Fixed-point coords with 8 bits of fraction for smooth AA

    ;; scroll in fixed-point: t * 256 / 100 - 15210 (subpixel smooth scrolling)
    ;; offset so line 0 just enters from bottom at t=0
    (local.set $scroll (i32.sub
      (i32.div_u (i32.mul (local.get $t) (i32.const 256)) (i32.const 100))
      (i32.const 15210)))

    ;; Iterate screen rows sy = 34..199
    (local.set $sy (i32.const 34))
    (block $yd (loop $yl
      (br_if $yd (i32.ge_u (local.get $sy) (i32.const 200)))

      ;; df = sy - 30
      (local.set $df (i32.sub (local.get $sy) (i32.const 30)))

      ;; text_y fixed-point: scroll_fp - 5000*256/df + 89*256
      (local.set $ty_fp (i32.add
        (i32.sub (local.get $scroll)
          (i32.div_u (i32.const 1280000) (local.get $df)))
        (i32.const 22784)))

      ;; Check if ty_fp is in range [0, 90*256 = 23040)
      (if (i32.and (i32.ge_s (local.get $ty_fp) (i32.const 0))
                   (i32.lt_s (local.get $ty_fp) (i32.const 23040)))
        (then
          ;; left_fp in fixed-point: (160 - df*150/169) * 256
          ;; = 40960 - df*38400/169  (smooth, no integer rounding jumps)
          (local.set $left_fp (i32.sub (i32.const 40960)
            (i32.div_u (i32.mul (local.get $df) (i32.const 38400)) (i32.const 169))))
          ;; Integer left/right for loop bounds only
          (local.set $left (i32.shr_s (local.get $left_fp) (i32.const 8)))
          (local.set $screen_half (i32.div_u
            (i32.mul (local.get $df) (i32.const 150)) (i32.const 169)))
          (local.set $right (i32.add (i32.const 160) (local.get $screen_half)))
          (if (i32.lt_s (local.get $left) (i32.const 0))
            (then (local.set $left (i32.const 0))))
          (if (i32.gt_s (local.get $right) (i32.const 320))
            (then (local.set $right (i32.const 320))))

          ;; Depth brightness: 0-15 based on df
          (local.set $depth_bright
            (select (i32.div_u (local.get $df) (i32.const 11)) (i32.const 15)
              (i32.lt_u (i32.div_u (local.get $df) (i32.const 11)) (i32.const 15))))

          ;; Horizontal step per pixel in texel-fp: 253*128/df = 32384/df
          (local.set $step (i32.div_u (i32.const 32384) (local.get $df)))
          ;; Vertical step: approximate as 1280000/(df*df) in fp units
          ;; Clamp to avoid huge values at small df
          (local.set $vstep (i32.div_u (i32.const 1280000) (i32.mul (local.get $df) (local.get $df))))
          (if (i32.gt_u (local.get $vstep) (i32.const 2560))
            (then (local.set $vstep (i32.const 2560))))  ;; cap at 10 texels

          ;; Iterate screen columns
          (local.set $sx (local.get $left))
          (block $xd (loop $xl
            (br_if $xd (i32.ge_u (local.get $sx) (local.get $right)))

            ;; text_x fixed-point using left_fp for smooth horizontal mapping
            ;; tx_fp = (sx*256 - left_fp) * 253 / (df * 2)  [253/2 = 126.5 exact]
            (local.set $tx_fp (i32.div_u
              (i32.mul (i32.sub (i32.mul (local.get $sx) (i32.const 256)) (local.get $left_fp)) (i32.const 253))
              (i32.mul (local.get $df) (i32.const 2))))

            ;; Check tx_fp < 224*256 = 57344
            (if (i32.lt_u (local.get $tx_fp) (i32.const 57344))
              (then
                ;; Adaptive sampling: single bilinear for close text (step < 256),
                ;; 2×2 area of bilinears for distant text (step >= 256)
                (if (i32.lt_u (local.get $step) (i32.const 256))
                  (then
                    ;; Close text: pixel < 1 texel, pure bilinear
                    (local.set $bright (call $text_texel_fp
                      (local.get $tx_fp) (local.get $ty_fp))))
                  (else
                    ;; Distant text: pixel covers multiple texels, area sample
                    (local.set $sum (i32.const 0))
                    (local.set $sum (i32.add (local.get $sum) (call $text_texel_fp
                      (i32.sub (local.get $tx_fp) (i32.shr_u (local.get $step) (i32.const 2)))
                      (i32.sub (local.get $ty_fp) (i32.shr_u (local.get $vstep) (i32.const 2))))))
                    (local.set $sum (i32.add (local.get $sum) (call $text_texel_fp
                      (i32.add (local.get $tx_fp) (i32.shr_u (local.get $step) (i32.const 2)))
                      (i32.sub (local.get $ty_fp) (i32.shr_u (local.get $vstep) (i32.const 2))))))
                    (local.set $sum (i32.add (local.get $sum) (call $text_texel_fp
                      (i32.sub (local.get $tx_fp) (i32.shr_u (local.get $step) (i32.const 2)))
                      (i32.add (local.get $ty_fp) (i32.shr_u (local.get $vstep) (i32.const 2))))))
                    (local.set $sum (i32.add (local.get $sum) (call $text_texel_fp
                      (i32.add (local.get $tx_fp) (i32.shr_u (local.get $step) (i32.const 2)))
                      (i32.add (local.get $ty_fp) (i32.shr_u (local.get $vstep) (i32.const 2))))))
                    (local.set $bright (i32.shr_u (local.get $sum) (i32.const 2)))))

                ;; Map to palette 240-255 (240=bg, 255=white)
                ;; color = 240 + (bright * depth_bright) >> 8
                (if (i32.gt_u (local.get $bright) (i32.const 0))
                  (then
                    (local.set $color (i32.add (i32.const 240)
                      (i32.shr_u (i32.mul (local.get $bright) (local.get $depth_bright))
                        (i32.const 8))))
                    (if (i32.gt_u (local.get $color) (i32.const 255))
                      (then (local.set $color (i32.const 255))))
                    (if (i32.gt_u (local.get $color) (i32.const 240))
                      (then
                        (i32.store8 (i32.add (i32.const 0x0340)
                          (i32.add (i32.mul (local.get $sy) (i32.const 320)) (local.get $sx)))
                          (local.get $color))))))))

            (local.set $sx (i32.add (local.get $sx) (i32.const 1)))
            (br $xl)
          ))))

      (local.set $sy (i32.add (local.get $sy) (i32.const 1)))
      (br $yl)
    ))
  )

  ;; =========================================================
  ;; SECTION 5: Berrry Finale  (placeholder)
  ;; =========================================================
  (func $pal_berrry
    ;; 0 = black
    (call $set_pal (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))
    ;; 1 = white text
    (call $set_pal (i32.const 1) (i32.const 255) (i32.const 255) (i32.const 255))
    ;; 2 = berrry green
    (call $set_pal (i32.const 2) (i32.const 0) (i32.const 221) (i32.const 136))
    ;; 3 = red berry
    (call $set_pal (i32.const 3) (i32.const 220) (i32.const 40) (i32.const 60))
    ;; 4 = purple berry
    (call $set_pal (i32.const 4) (i32.const 160) (i32.const 40) (i32.const 200))
    ;; 5 = blue berry
    (call $set_pal (i32.const 5) (i32.const 60) (i32.const 80) (i32.const 220))
    ;; 6 = sparkle
    (call $set_pal (i32.const 6) (i32.const 200) (i32.const 200) (i32.const 255))
    ;; 7 = dim text
    (call $set_pal (i32.const 7) (i32.const 100) (i32.const 100) (i32.const 100))
    ;; 8 = red berry highlight
    (call $set_pal (i32.const 8) (i32.const 255) (i32.const 120) (i32.const 130))
    ;; 9 = purple berry highlight
    (call $set_pal (i32.const 9) (i32.const 220) (i32.const 120) (i32.const 255))
    ;; 10 = blue berry highlight
    (call $set_pal (i32.const 10) (i32.const 140) (i32.const 160) (i32.const 255))
  )

  (func $render_berrry (param $elapsed i32)
    (local $t i32) (local $i i32) (local $x i32) (local $y i32)
    (local $bx i32) (local $by i32) (local $dx i32) (local $dy i32)
    (local $dist_sq i32) (local $fb i32)
    (local $pulse i32) (local $fade i32) (local $text_color i32)

    (local.set $t (i32.sub (local.get $elapsed) (i32.const 56000)))

    ;; Clear
    (call $clear_fb)

    ;; Fade in: first 1s gradually reveal, last 1s fade out
    (local.set $text_color (i32.const 2))
    (if (i32.lt_u (local.get $t) (i32.const 1000))
      (then (local.set $text_color (i32.const 7)))
      (else (if (i32.gt_u (local.get $t) (i32.const 7000))
        (then (local.set $text_color (i32.const 7))))))

    ;; Sparkle particles in background
    (local.set $i (i32.const 0))
    (block $spd (loop $spl
      (br_if $spd (i32.ge_u (local.get $i) (i32.const 60)))
      (local.set $x (i32.rem_u (i32.add
        (i32.mul (local.get $i) (i32.const 197))
        (i32.mul (i32.shr_u (local.get $t) (i32.const 5)) (i32.add (local.get $i) (i32.const 1))))
        (i32.const 320)))
      (local.set $y (i32.rem_u (i32.add
        (i32.mul (local.get $i) (i32.const 53))
        (i32.shr_u (local.get $t) (i32.const 6)))
        (i32.const 200)))
      ;; twinkle
      (if (i32.and (i32.add (local.get $i) (i32.shr_u (local.get $t) (i32.const 7))) (i32.const 1))
        (then
          (i32.store8 (i32.add (i32.const 0x0340)
            (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x)))
            (i32.const 6))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $spl)
    ))

    ;; "BERRRY.APP" at 3x scale, centered
    ;; 10 * 9 * 3 = 270px → x = (320-270)/2 = 25
    (call $draw_text (i32.const 0x10750) (i32.const 10)
      (i32.const 25) (i32.const 55) (i32.const 3) (local.get $text_color))

    ;; "WASMVGA-DEMOS.BERRRY.APP" at 1x below
    ;; 24 * 9 = 216px → x = (320-216)/2 = 52
    (call $draw_text (i32.const 0x108C0) (i32.const 24)
      (i32.const 52) (i32.const 90) (i32.const 1) (i32.const 1))

    ;; 3 bouncing berry circles
    ;; Berry 0 (red): orbits around center
    (local.set $bx (i32.add (i32.const 160)
      (i32.sub (i32.shr_u (call $sin_tab (i32.shr_u (local.get $t) (i32.const 3))) (i32.const 1)) (i32.const 64))))
    (local.set $by (i32.add (i32.const 140)
      (i32.sub (i32.shr_u (call $sin_tab (i32.add (i32.shr_u (local.get $t) (i32.const 3)) (i32.const 64))) (i32.const 1)) (i32.const 64))))
    (call $draw_berry (local.get $bx) (local.get $by) (i32.const 3))

    ;; Berry 1 (purple): different phase
    (local.set $bx (i32.add (i32.const 160)
      (i32.sub (i32.shr_u (call $sin_tab (i32.add (i32.shr_u (local.get $t) (i32.const 3)) (i32.const 85))) (i32.const 1)) (i32.const 64))))
    (local.set $by (i32.add (i32.const 140)
      (i32.sub (i32.shr_u (call $sin_tab (i32.add (i32.shr_u (local.get $t) (i32.const 3)) (i32.const 149))) (i32.const 1)) (i32.const 64))))
    (call $draw_berry (local.get $bx) (local.get $by) (i32.const 4))

    ;; Berry 2 (blue): different phase
    (local.set $bx (i32.add (i32.const 160)
      (i32.sub (i32.shr_u (call $sin_tab (i32.add (i32.shr_u (local.get $t) (i32.const 3)) (i32.const 170))) (i32.const 1)) (i32.const 64))))
    (local.set $by (i32.add (i32.const 140)
      (i32.sub (i32.shr_u (call $sin_tab (i32.add (i32.shr_u (local.get $t) (i32.const 3)) (i32.const 234))) (i32.const 1)) (i32.const 64))))
    (call $draw_berry (local.get $bx) (local.get $by) (i32.const 5))
  )

  ;; Helper: draw a filled circle (berry) at (cx, cy) with palette color
  (func $draw_berry (param $cx i32) (param $cy i32) (param $color i32)
    (local $dx i32) (local $dy i32) (local $px i32) (local $py i32)
    (local $dist_sq2 i32)
    (local.set $dy (i32.const -9))
    (block $yd (loop $yl
      (br_if $yd (i32.gt_s (local.get $dy) (i32.const 9)))
      (local.set $dx (i32.const -9))
      (block $xd (loop $xl
        (br_if $xd (i32.gt_s (local.get $dx) (i32.const 9)))
        ;; dist_sq = dx*dx + dy*dy
        (local.set $dist_sq2 (i32.add (i32.mul (local.get $dx) (local.get $dx))
                   (i32.mul (local.get $dy) (local.get $dy))))
        ;; if dist_sq <= 81 (radius 9)
        (if (i32.le_s (local.get $dist_sq2) (i32.const 81))
          (then
            (local.set $px (i32.add (local.get $cx) (local.get $dx)))
            (local.set $py (i32.add (local.get $cy) (local.get $dy)))
            (if (i32.and
              (i32.and (i32.ge_s (local.get $px) (i32.const 0))
                       (i32.lt_s (local.get $px) (i32.const 320)))
              (i32.and (i32.ge_s (local.get $py) (i32.const 0))
                       (i32.lt_s (local.get $py) (i32.const 200))))
              (then
                ;; highlight: inner radius <= 25 uses color+5 (highlight palette)
                (i32.store8 (i32.add (i32.const 0x0340)
                  (i32.add (i32.mul (local.get $py) (i32.const 320)) (local.get $px)))
                  (select (i32.add (local.get $color) (i32.const 5))
                          (local.get $color)
                          (i32.le_s (local.get $dist_sq2) (i32.const 25))))))))
        (local.set $dx (i32.add (local.get $dx) (i32.const 1)))
        (br $xl)
      ))
      (local.set $dy (i32.add (local.get $dy) (i32.const 1)))
      (br $yl)
    ))
  )

  ;; =========================================================
  ;; INIT
  ;; =========================================================
  (func (export "init")
    (local $i i32) (local $val i32) (local $angle f64)

    ;; Build sin table at 0x10340 (256 entries, 0-255)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 256)))
      (local.set $angle (f64.mul (f64.div (f64.convert_i32_u (local.get $i)) (f64.const 256.0)) (f64.const 6.283185307)))
      (local.set $val (i32.trunc_f64_s (f64.add (f64.mul (call $sin_approx (local.get $angle)) (f64.const 127.0)) (f64.const 128.0))))
      (if (i32.lt_s (local.get $val) (i32.const 0)) (then (local.set $val (i32.const 0))))
      (if (i32.gt_s (local.get $val) (i32.const 255)) (then (local.set $val (i32.const 255))))
      (i32.store8 (i32.add (i32.const 0x10340) (local.get $i)) (local.get $val))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)
    ))

    ;; Capture start tick
    (i32.store (i32.const 0x38004) (i32.load (i32.const 0x0C)))

    ;; Init PRNG seed
    (i32.store (i32.const 0x38000) (i32.const 48271))

    ;; Set last_section to 255 (force palette setup on first frame)
    (i32.store (i32.const 0x38008) (i32.const 255))

    ;; Init rain columns: 40 columns, random y/speed/char
    (local.set $i (i32.const 0))
    (block $rdone (loop $rlp
      (br_if $rdone (i32.ge_u (local.get $i) (i32.const 40)))
      ;; y position: random 0-199
      (i32.store8 (i32.add (i32.const 0x38010) (i32.mul (local.get $i) (i32.const 4)))
        (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 200)))
      ;; speed: 1-3
      (i32.store8 (i32.add (i32.const 0x38011) (i32.mul (local.get $i) (i32.const 4)))
        (i32.add (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 3)) (i32.const 1)))
      ;; char: random ASCII 33-126
      (i32.store8 (i32.add (i32.const 0x38012) (i32.mul (local.get $i) (i32.const 4)))
        (i32.add (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 94)) (i32.const 33)))
      ;; alive: 1
      (i32.store8 (i32.add (i32.const 0x38013) (i32.mul (local.get $i) (i32.const 4)))
        (i32.const 1))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $rlp)
    ))
  )

  ;; =========================================================
  ;; FRAME — main dispatcher
  ;; =========================================================
  (func (export "frame")
    (local $tick_ms i32) (local $elapsed i32) (local $section i32)
    (local $last_section i32) (local $input i32) (local $prev_input i32)
    (local $next_boundary i32)

    ;; Read current tick
    (local.set $tick_ms (i32.load (i32.const 0x0C)))

    ;; Compute elapsed time since init, modulo 64000 for looping
    (local.set $elapsed (i32.rem_u
      (i32.sub (local.get $tick_ms) (i32.load (i32.const 0x38004)))
      (i32.const 64000)))

    ;; Determine section from elapsed time
    (local.set $section (i32.const 0))
    (if (i32.ge_u (local.get $elapsed) (i32.const 8000))
      (then (local.set $section (i32.const 1))))
    (if (i32.ge_u (local.get $elapsed) (i32.const 20000))
      (then (local.set $section (i32.const 2))))
    (if (i32.ge_u (local.get $elapsed) (i32.const 32000))
      (then (local.set $section (i32.const 3))))
    (if (i32.ge_u (local.get $elapsed) (i32.const 44000))
      (then (local.set $section (i32.const 4))))
    (if (i32.ge_u (local.get $elapsed) (i32.const 56000))
      (then (local.set $section (i32.const 5))))

    ;; Navigation: space/click/right=next, left=prev (rising edge per-bit)
    ;; keyboard@0x10: bit2=Left(4), bit3=Right(8), bit4=Space(16)
    ;; mouse@0x08: bit0=left_click(1)
    (local.set $input (i32.or
      (i32.and (i32.load8_u (i32.const 0x10)) (i32.const 28))  ;; bits 2,3,4 = left,right,space
      (i32.and (i32.load8_u (i32.const 0x08)) (i32.const 1)))) ;; left click
    (local.set $prev_input (i32.load (i32.const 0x3800C)))
    (i32.store (i32.const 0x3800C) (local.get $input))

    ;; Rising edge: any of space/right/click newly pressed (was 0, now 1)
    ;; new_bits = input & ~prev_input (bits that just turned on)
    ;; Check if any of the "next" bits (25 = 16|8|1) are newly on
    (if (i32.and
      (i32.and (local.get $input) (i32.xor (local.get $prev_input) (i32.const 0xFFFFFFFF)))
      (i32.const 25))
      (then
        ;; Compute next section boundary
        (local.set $next_boundary (i32.const 8000))
        (if (i32.ge_u (local.get $elapsed) (i32.const 8000))
          (then (local.set $next_boundary (i32.const 20000))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 20000))
          (then (local.set $next_boundary (i32.const 32000))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 32000))
          (then (local.set $next_boundary (i32.const 44000))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 44000))
          (then (local.set $next_boundary (i32.const 56000))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 56000))
          (then (local.set $next_boundary (i32.const 64000))))
        ;; Shift start_tick backward so elapsed jumps to next_boundary
        (i32.store (i32.const 0x38004)
          (i32.sub (local.get $tick_ms) (local.get $next_boundary)))
        ;; Recompute elapsed and section
        (local.set $elapsed (i32.rem_u
          (i32.sub (local.get $tick_ms) (i32.load (i32.const 0x38004)))
          (i32.const 64000)))
        (local.set $section (i32.const 0))
        (if (i32.ge_u (local.get $elapsed) (i32.const 8000))
          (then (local.set $section (i32.const 1))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 20000))
          (then (local.set $section (i32.const 2))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 32000))
          (then (local.set $section (i32.const 3))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 44000))
          (then (local.set $section (i32.const 4))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 56000))
          (then (local.set $section (i32.const 5))))
      ))

    ;; Rising edge on left(4) → previous section
    (if (i32.and
      (i32.and (local.get $input) (i32.xor (local.get $prev_input) (i32.const 0xFFFFFFFF)))
      (i32.const 4))
      (then
        ;; Compute previous section boundary
        (local.set $next_boundary (i32.const 56000))  ;; wrap to last section
        (if (i32.ge_u (local.get $elapsed) (i32.const 8000))
          (then (local.set $next_boundary (i32.const 0))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 20000))
          (then (local.set $next_boundary (i32.const 8000))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 32000))
          (then (local.set $next_boundary (i32.const 20000))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 44000))
          (then (local.set $next_boundary (i32.const 32000))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 56000))
          (then (local.set $next_boundary (i32.const 44000))))
        ;; Shift start_tick so elapsed jumps to prev boundary
        (i32.store (i32.const 0x38004)
          (i32.sub (local.get $tick_ms) (local.get $next_boundary)))
        ;; Recompute elapsed and section
        (local.set $elapsed (i32.rem_u
          (i32.sub (local.get $tick_ms) (i32.load (i32.const 0x38004)))
          (i32.const 64000)))
        (local.set $section (i32.const 0))
        (if (i32.ge_u (local.get $elapsed) (i32.const 8000))
          (then (local.set $section (i32.const 1))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 20000))
          (then (local.set $section (i32.const 2))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 32000))
          (then (local.set $section (i32.const 3))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 44000))
          (then (local.set $section (i32.const 4))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 56000))
          (then (local.set $section (i32.const 5))))
      ))

    ;; On section change: set up palette and re-init PRNG for consistency
    (local.set $last_section (i32.load (i32.const 0x38008)))
    (if (i32.ne (local.get $section) (local.get $last_section))
      (then
        (i32.store (i32.const 0x38008) (local.get $section))
        ;; dispatch palette setup
        (if (i32.eqz (local.get $section))            (then (call $pal_rain)))
        (if (i32.eq (local.get $section) (i32.const 1)) (then (call $pal_grave)))
        (if (i32.eq (local.get $section) (i32.const 2)) (then (call $pal_message)))
        (if (i32.eq (local.get $section) (i32.const 3)) (then (call $pal_plasma)))
        (if (i32.eq (local.get $section) (i32.const 4)) (then (call $pal_scroll)))
        (if (i32.eq (local.get $section) (i32.const 5)) (then (call $pal_berrry)))
        ;; start music: section 0→pattern 5, section 1→pattern 6, etc.
        (call $music (i32.add (local.get $section) (i32.const 5)))
      )
    )

    ;; Dispatch render
    (if (i32.eqz (local.get $section))            (then (call $render_rain (local.get $elapsed))))
    (if (i32.eq (local.get $section) (i32.const 1)) (then (call $render_grave (local.get $elapsed))))
    (if (i32.eq (local.get $section) (i32.const 2)) (then (call $render_message (local.get $elapsed))))
    (if (i32.eq (local.get $section) (i32.const 3)) (then (call $render_plasma (local.get $elapsed))))
    (if (i32.eq (local.get $section) (i32.const 4)) (then (call $render_scroll (local.get $elapsed))))
    (if (i32.eq (local.get $section) (i32.const 5)) (then (call $render_berrry (local.get $elapsed))))
  )

  ;; =========================================================
  ;; DATA SEGMENTS
  ;; =========================================================

  ;; 8x8 bitmap font at 0x10440: 96 chars (ASCII 32-127), 8 bytes each
  ;; (copied from scroller.wat)
  (data (i32.const 0x10440) "\00\00\00\00\00\00\00\00\00\18\00\18\18\18\18\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\18\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00<fffff<\00~\18\18\18\188\18\00~`0\0c\06f<\00<f\06\1c\06f<\00\0c\0c~L,\1c\0c\00<f\06\06|`~\00<ff|``<\00000\18\0c\06~\00<ff<ff<\00<\06\06>ff<\00\00\18\00\00\18\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00ff~ff<\18\00|ff|ff|\00<f```f<\00\7c\66\63\63\63\66\7c\00~``|``~\00```|``~\00<ffn`f<\00fff~fff\00<\18\18\18\18\18<\00<f\06\06\06\06\06\00flxpxlf\00~``````\00ccck\7fwc\00fnn~vvf\00<fffff<\00```|ff|\00\0e<nfff<\00ffl|ff|\00<f\06<`f<\00\18\18\18\18\18\18~\00<ffffff\00\18<fffff\00cw\7fkccc\00ff<\18<ff\00\18\18\18<fff\00~`0\18\0c\06~\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00")

  ;; Strings
  (data (i32.const 0x10740) "CODING IS OVER")
  (data (i32.const 0x10750) "BERRRY.APP")
  (data (i32.const 0x10760) "BERRRY.APP PRESENTS")
  (data (i32.const 0x10780) "INTENT NOT SYNTAX")
  (data (i32.const 0x107A0) "BUILT ON BERRRY.APP")
  (data (i32.const 0x107C0) "THIS DEMO WAS WRITTEN IN RAW WEBASSEMBLY TEXT ... BY CLAUDE CODE ... NO COMPILER ... NO FRAMEWORK ... JUST AN AI WRITING WAT BYTECODE DIRECTLY ... HOSTED ON BERRRY.APP ... THE IRONY? ... CODE WROTE THIS MESSAGE ABOUT THE END OF CODE ...    ")
  (data (i32.const 0x108C0) "WASMVGA-DEMOS.BERRRY.APP")
  (data (i32.const 0x108E0) "C\00JAVA\00PYTHON\00RUST\00JS\00GO\00")
)
