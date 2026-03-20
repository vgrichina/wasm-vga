(module
  (import "env" "memory" (memory 8))
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
  ;;   0x107C0 - scroller message (252 bytes, 9 lines of 28)
  ;;   0x108C0 - "WASMVGA-DEMOS.BERRRY.APP" (24)
  ;;   0x108E0 - tombstone labels: "C\0JAVA\0PYTHON\0RUST\0JS\0GO\0"
  ;;
  ;; DYNAMIC (mutated every frame):
  ;;   0x38000 - PRNG state (4 bytes)
  ;;   0x38004 - start_tick (4 bytes)
  ;;   0x38008 - last_section (4 bytes)
  ;;   0x3800C - prev_input (4 bytes)
  ;;   0x38010 - rain columns: 40 x 4 = 160 bytes
  ;;   0x38100 - fire buffer: 320x104 = 33280 bytes (ends 0x40300)
  ;;
  ;; Section timing (elapsed_ms % 52000):
  ;;   0     -  8000  Section 0: Code Rain
  ;;   8000  - 20000  Section 1: Graveyard + "CODING IS OVER"
  ;;   20000 - 32000  Section 2: Plasma + "INTENT NOT SYNTAX"
  ;;   32000 - 44000  Section 3: Scroller
  ;;   44000 - 52000  Section 4: Berrry Finale

  ;; =========================================================
  ;; UTILITY: sin approximation (Taylor series)
  ;; =========================================================
  (func $sin_approx (param $x f64) (result f64)
    (local $x2 f64) (local $x3 f64) (local $x5 f64) (local $x7 f64)
    (local $sign f64)
    (local.set $sign (f64.const 1.0))
    (local.set $x (f64.sub (local.get $x)
      (f64.mul (f64.floor (f64.div (local.get $x) (f64.const 6.283185307179586))) (f64.const 6.283185307179586))))
    (if (f64.ge (local.get $x) (f64.const 3.141592653589793))
      (then
        (local.set $x (f64.sub (local.get $x) (f64.const 3.141592653589793)))
        (local.set $sign (f64.const -1.0))))
    (if (f64.gt (local.get $x) (f64.const 1.5707963267948966))
      (then (local.set $x (f64.sub (f64.const 3.141592653589793) (local.get $x)))))
    (local.set $x2 (f64.mul (local.get $x) (local.get $x)))
    (local.set $x3 (f64.mul (local.get $x2) (local.get $x)))
    (local.set $x5 (f64.mul (local.get $x3) (local.get $x2)))
    (local.set $x7 (f64.mul (local.get $x5) (local.get $x2)))
    (f64.mul (local.get $sign)
      (f64.sub (f64.add (local.get $x) (f64.div (local.get $x5) (f64.const 120.0)))
        (f64.add (f64.div (local.get $x3) (f64.const 6.0)) (f64.div (local.get $x7) (f64.const 5040.0)))))
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
  ;; UTILITY: draw starfield (120 static stars, palette-based twinkle)
  ;; max_y: stars only placed in rows 0..max_y-1
  ;; tick: time value for palette animation
  ;; Stars use shared palette indices 1-6 (all sections keep these free)
  ;; 6 entries with different phase offsets = desynchronized twinkle
  ;; Call AFTER clear_fb, BEFORE other rendering
  ;; =========================================================
  (func $draw_stars (param $max_y i32) (param $tick i32)
    (local $i i32) (local $x i32) (local $y i32) (local $layer i32)
    (local $wave i32) (local $base i32) (local $bright i32)

    ;; Animate palette entries 1-6 with phase-shifted sin waves
    ;; Pairs (0,1), (2,3), (4,5) share a brightness tier but differ in phase
    (local.set $i (i32.const 0))
    (block $pd (loop $pl
      (br_if $pd (i32.ge_u (local.get $i) (i32.const 6)))
      ;; wave = sin_tab((tick>>3) + i*43) => 0-255, 43≈256/6
      (local.set $wave (call $sin_tab (i32.add
        (i32.shr_u (local.get $tick) (i32.const 3))
        (i32.mul (local.get $i) (i32.const 43)))))
      ;; base brightness per tier: dim(60), med(130), bright(210)
      ;; tier = i/2 (0,1→dim, 2,3→med, 4,5→bright)
      (local.set $base (i32.add (i32.const 60)
        (i32.mul (i32.div_u (local.get $i) (i32.const 2)) (i32.const 75))))
      ;; bright = base + (wave-128)>>4, clamped 30-255 (subtle shimmer)
      (local.set $bright (i32.add (local.get $base)
        (i32.shr_s (i32.sub (local.get $wave) (i32.const 128)) (i32.const 4))))
      (if (i32.lt_s (local.get $bright) (i32.const 30))
        (then (local.set $bright (i32.const 30))))
      (if (i32.gt_s (local.get $bright) (i32.const 255))
        (then (local.set $bright (i32.const 255))))
      ;; Set palette: slight blue tint (+20 on B channel)
      (call $set_pal (i32.add (local.get $i) (i32.const 1))
        (local.get $bright) (local.get $bright)
        (select (i32.const 255)
          (i32.add (local.get $bright) (i32.const 20))
          (i32.gt_s (i32.add (local.get $bright) (i32.const 20)) (i32.const 255))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $pl)
    ))

    ;; Plot 80 primary stars with xor-shift hash (no diagonal banding)
    (local.set $i (i32.const 0))
    (block $sd (loop $sl
      (br_if $sd (i32.ge_u (local.get $i) (i32.const 80)))
      ;; Hash x: h = i*0x45d9f3b; h ^= h>>16; h ^= h>>8
      (local.set $x (i32.mul (local.get $i) (i32.const 0x45d9f3b)))
      (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 16))))
      (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 8))))
      (local.set $x (i32.rem_u (i32.and (local.get $x) (i32.const 0x7FFFFFFF)) (i32.const 320)))
      ;; Hash y: different multiplier for independence
      (local.set $y (i32.mul (local.get $i) (i32.const 0x27d4eb2d)))
      (local.set $y (i32.xor (local.get $y) (i32.shr_u (local.get $y) (i32.const 16))))
      (local.set $y (i32.xor (local.get $y) (i32.shr_u (local.get $y) (i32.const 8))))
      (local.set $y (i32.rem_u (i32.and (local.get $y) (i32.const 0x7FFFFFFF)) (local.get $max_y)))
      ;; layer = 1 + (hash(i) % 6) — use mixed bits for tier
      (local.set $layer (i32.add (i32.const 1)
        (i32.rem_u (i32.and
          (i32.xor (i32.mul (local.get $i) (i32.const 0x9e3779b9))
            (i32.shr_u (i32.mul (local.get $i) (i32.const 0x9e3779b9)) (i32.const 13)))
          (i32.const 0x7FFFFFFF)) (i32.const 6))))
      (i32.store8 (i32.add (i32.const 0x0340)
        (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x)))
        (local.get $layer))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sl)
    ))

    ;; Cluster pass: 60 dim companion stars near bright primaries (i < 30)
    ;; Creates natural clumping — a few dense patches amid sparse field
    (local.set $i (i32.const 0))
    (block $cd (loop $cl
      (br_if $cd (i32.ge_u (local.get $i) (i32.const 60)))
      ;; Pick parent star: i/2 (so 2 companions per parent, first 30 parents)
      (local.set $base (i32.shr_u (local.get $i) (i32.const 1)))
      ;; Recompute parent x,y
      (local.set $x (i32.mul (local.get $base) (i32.const 0x45d9f3b)))
      (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 16))))
      (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 8))))
      (local.set $x (i32.rem_u (i32.and (local.get $x) (i32.const 0x7FFFFFFF)) (i32.const 320)))
      (local.set $y (i32.mul (local.get $base) (i32.const 0x27d4eb2d)))
      (local.set $y (i32.xor (local.get $y) (i32.shr_u (local.get $y) (i32.const 16))))
      (local.set $y (i32.xor (local.get $y) (i32.shr_u (local.get $y) (i32.const 8))))
      (local.set $y (i32.rem_u (i32.and (local.get $y) (i32.const 0x7FFFFFFF)) (local.get $max_y)))
      ;; Offset: hash-based ±3..8 pixels from parent
      (local.set $wave (i32.mul (i32.add (local.get $i) (i32.const 200)) (i32.const 0x6c62272e)))
      (local.set $wave (i32.xor (local.get $wave) (i32.shr_u (local.get $wave) (i32.const 15))))
      (local.set $x (i32.add (local.get $x)
        (i32.sub (i32.rem_u (i32.and (local.get $wave) (i32.const 0x7FFF)) (i32.const 17)) (i32.const 8))))
      (local.set $wave (i32.mul (local.get $wave) (i32.const 0x846ca68b)))
      (local.set $y (i32.add (local.get $y)
        (i32.sub (i32.rem_u (i32.and (local.get $wave) (i32.const 0x7FFF)) (i32.const 17)) (i32.const 8))))
      ;; Clamp to screen
      (if (i32.lt_s (local.get $x) (i32.const 0)) (then (local.set $x (i32.const 0))))
      (if (i32.ge_s (local.get $x) (i32.const 320)) (then (local.set $x (i32.const 319))))
      (if (i32.lt_s (local.get $y) (i32.const 0)) (then (local.set $y (i32.const 0))))
      (if (i32.ge_s (local.get $y) (local.get $max_y))
        (then (local.set $y (i32.sub (local.get $max_y) (i32.const 1)))))
      ;; Always dim tier (1 or 2)
      (local.set $layer (i32.add (i32.const 1)
        (i32.and (local.get $i) (i32.const 1))))
      (i32.store8 (i32.add (i32.const 0x0340)
        (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x)))
        (local.get $layer))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $cl)
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
    ;; 10-29: long green trail ramp (dark → bright green)
    ;; Loop i=1..20, palette index = i+9
    (local.set $i (i32.const 1))
    (block $done (loop $lp
      (br_if $done (i32.gt_u (local.get $i) (i32.const 20)))
      (local.set $g (i32.div_u (i32.mul (local.get $i) (i32.const 220)) (i32.const 20)))
      (call $set_pal (i32.add (local.get $i) (i32.const 9))
        (i32.div_u (local.get $g) (i32.const 6))
        (local.get $g)
        (i32.div_u (local.get $g) (i32.const 8)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)
    ))
    ;; 30 = bright white-green head
    (call $set_pal (i32.const 30) (i32.const 180) (i32.const 255) (i32.const 180))
    ;; 31 = white flash (brand new char)
    (call $set_pal (i32.const 31) (i32.const 255) (i32.const 255) (i32.const 255))
    ;; 32 = berrry green for reveal text
    (call $set_pal (i32.const 32) (i32.const 0) (i32.const 221) (i32.const 136))
    ;; Reset keyword letter states (0x38200-0x3823F)
    (local.set $i (i32.const 0))
    (block $rd (loop $rl
      (br_if $rd (i32.ge_u (local.get $i) (i32.const 64)))
      (i32.store (i32.add (i32.const 0x38200) (local.get $i)) (i32.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 4)))
      (br $rl)
    ))
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

  ;; Draw a keyword with rain-synced falling animation
  ;; Each char rides its rain column's head down, locking when it reaches target_y
  ;; State per char at state_addr: 0=waiting, 1=riding rain, 2=locked
  ;; deadline_ms: force-lock any unlocked chars by this time (guarantees glow window)
  (func $draw_keyword (param $elapsed i32) (param $str_addr i32) (param $str_len i32)
                      (param $base_x i32) (param $target_y i32)
                      (param $start_ms i32) (param $state_addr i32)
                      (param $deadline_ms i32)
    (local $i i32) (local $col i32) (local $px i32)
    (local $ch i32) (local $state i32) (local $rain_y i32)
    (local $sa i32) (local $past_deadline i32)

    ;; Skip if not started
    (if (i32.lt_u (local.get $elapsed) (local.get $start_ms)) (then (return)))

    (local.set $past_deadline (i32.ge_u (local.get $elapsed) (local.get $deadline_ms)))

    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (local.get $str_len)))

      (local.set $col (i32.add (i32.shr_u (local.get $base_x) (i32.const 3))
        (local.get $i)))
      (local.set $px (i32.mul (local.get $col) (i32.const 8)))
      (local.set $sa (i32.add (local.get $state_addr) (local.get $i)))
      (local.set $state (i32.load8_u (local.get $sa)))

      ;; Force-lock if past deadline
      (if (i32.and (local.get $past_deadline) (i32.lt_u (local.get $state) (i32.const 2)))
        (then
          (i32.store8 (local.get $sa) (i32.const 2))
          (local.set $state (i32.const 2))))

      ;; Read rain column head y
      (local.set $rain_y (i32.load8_u (i32.add (i32.const 0x38010)
        (i32.mul (local.get $col) (i32.const 4)))))

      (if (i32.eqz (local.get $state))
        (then
          ;; WAITING: capture when rain head wraps near top
          (if (i32.lt_u (local.get $rain_y) (i32.const 8))
            (then (i32.store8 (local.get $sa) (i32.const 1))
              (local.set $state (i32.const 1))))
        ))

      (if (i32.eq (local.get $state) (i32.const 1))
        (then
          ;; RIDING: follow rain head, lock when it crosses target_y
          (if (i32.ge_u (local.get $rain_y) (local.get $target_y))
            (then
              (i32.store8 (local.get $sa) (i32.const 2))
              (local.set $state (i32.const 2)))
            (else
              ;; Draw scramble char at rain head, flash real char every 4th tick
              (local.set $ch
                (select
                  (i32.load8_u (i32.add (local.get $str_addr) (local.get $i)))
                  (i32.add (i32.rem_u
                    (i32.and (i32.add
                      (i32.mul (local.get $i) (i32.const 7))
                      (i32.shr_u (local.get $elapsed) (i32.const 4)))
                      (i32.const 0x7FFFFFFF))
                    (i32.const 94)) (i32.const 33))
                  (i32.eqz (i32.rem_u
                    (i32.shr_u (local.get $elapsed) (i32.const 6))
                    (i32.const 4)))))
              (if (i32.lt_u (local.get $rain_y) (i32.const 192))
                (then (call $draw_char_at (local.get $ch) (local.get $px)
                  (local.get $rain_y) (i32.const 31))))
            ))
        ))

      (if (i32.eq (local.get $state) (i32.const 2))
        (then
          ;; LOCKED: draw correct char in green
          (local.set $ch (i32.load8_u (i32.add (local.get $str_addr) (local.get $i))))
          (call $draw_char_at (local.get $ch) (local.get $px)
            (local.get $target_y) (i32.const 32))
        ))

      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)
    ))
  )

  (func $render_rain (param $elapsed i32)
    (local $col i32) (local $base i32)
    (local $y i32) (local $speed i32) (local $alive i32)
    (local $px i32) (local $trail_i i32) (local $trail_y i32)
    (local $trail_ch i32) (local $trail_color i32)

    ;; Clear screen each frame
    (call $clear_fb)

    ;; Update and draw each rain column
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

                ;; Color: head=31(white), next 2=30(bright), rest fade 29→10
                (local.set $trail_color
                  (select (i32.const 31)
                    (select (i32.const 30)
                      (select
                        (i32.sub (i32.const 29) (local.get $trail_i))
                        (i32.const 10)
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

    ;; Falling keywords — rain-synced, with deadlines for guaranteed glow
    ;; All locked by 5500ms → 2.5s glow before section ends at 8000ms
    (call $draw_keyword (local.get $elapsed) (i32.const 0x10750) (i32.const 10)
      (i32.const 120) (i32.const 96) (i32.const 300) (i32.const 0x38200) (i32.const 3000))
    (call $draw_keyword (local.get $elapsed) (i32.const 0x10960) (i32.const 4)
      (i32.const 24) (i32.const 40) (i32.const 1000) (i32.const 0x38210) (i32.const 3500))
    (call $draw_keyword (local.get $elapsed) (i32.const 0x10964) (i32.const 3)
      (i32.const 232) (i32.const 152) (i32.const 2000) (i32.const 0x38220) (i32.const 4500))
    (call $draw_keyword (local.get $elapsed) (i32.const 0x10968) (i32.const 8)
      (i32.const 176) (i32.const 32) (i32.const 3000) (i32.const 0x38230) (i32.const 5500))
  )

  ;; =========================================================
  ;; SECTION 1: Graveyard  (placeholder)
  ;; =========================================================
  ;; Fire color ramp: maps intensity 0..84 to RGB
  ;; Separated from alpha — color is always vivid, never near-black
  ;; Ramp: deep red (80,0,0) → bright red → orange → yellow → white
  ;; Returns via memory scratch at 0x3FF00 (3 bytes: r,g,b)
  (func $fire_color (param $i i32)
    (local $r i32) (local $g i32) (local $b i32)
    ;; 0-27: deep red to bright red (80+6*i, 0, 0)
    (if (i32.lt_u (local.get $i) (i32.const 28))
      (then
        (local.set $r (i32.add (i32.const 80) (i32.mul (local.get $i) (i32.const 6))))
        (local.set $g (i32.const 0))
        (local.set $b (i32.const 0)))
      (else (if (i32.lt_u (local.get $i) (i32.const 56))
        (then ;; 28-55: red to yellow
          (local.set $r (i32.const 255))
          (local.set $g (i32.mul (i32.sub (local.get $i) (i32.const 28)) (i32.const 9)))
          (local.set $b (i32.const 0)))
        (else ;; 56-84: yellow to white
          (local.set $r (i32.const 255))
          (local.set $g (i32.const 255))
          (local.set $b (i32.mul (i32.sub (local.get $i) (i32.const 56)) (i32.const 9)))))))
    (if (i32.gt_u (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))
    (if (i32.gt_u (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
    (if (i32.gt_u (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
    (i32.store8 (i32.const 0x3FF00) (local.get $r))
    (i32.store8 (i32.const 0x3FF01) (local.get $g))
    (i32.store8 (i32.const 0x3FF02) (local.get $b))
  )

  ;; Fire alpha curve: intensity 0..84 → alpha 0..84 (out of 84)
  ;; Ramps linearly over first 21 steps, then fully opaque
  (func $fire_alpha (param $i i32) (result i32)
    (select (i32.mul (local.get $i) (i32.const 4)) (i32.const 84)
      (i32.lt_u (local.get $i) (i32.const 21)))
  )

  ;; Generate translucent fire entries blended against a background color
  ;; base_idx: first palette index, bg_r/g/b: background
  ;; Produces 21 entries (i=0..20) where alpha < 1
  (func $gen_fire_blend (param $base_idx i32) (param $bg_r i32) (param $bg_g i32) (param $bg_b i32)
    (local $i i32) (local $a i32)
    (local $r i32) (local $g i32) (local $b i32)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.gt_u (local.get $i) (i32.const 20)))
      (call $fire_color (local.get $i))
      (local.set $a (call $fire_alpha (local.get $i)))
      ;; Blend: result = (fire * a + bg * (84 - a)) / 84
      (local.set $r (i32.div_u
        (i32.add (i32.mul (i32.load8_u (i32.const 0x3FF00)) (local.get $a))
                 (i32.mul (local.get $bg_r) (i32.sub (i32.const 84) (local.get $a))))
        (i32.const 84)))
      (local.set $g (i32.div_u
        (i32.add (i32.mul (i32.load8_u (i32.const 0x3FF01)) (local.get $a))
                 (i32.mul (local.get $bg_g) (i32.sub (i32.const 84) (local.get $a))))
        (i32.const 84)))
      (local.set $b (i32.div_u
        (i32.add (i32.mul (i32.load8_u (i32.const 0x3FF02)) (local.get $a))
                 (i32.mul (local.get $bg_b) (i32.sub (i32.const 84) (local.get $a))))
        (i32.const 84)))
      (call $set_pal (i32.add (local.get $base_idx) (local.get $i))
        (local.get $r) (local.get $g) (local.get $b))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)
    ))
  )

  (func $pal_grave
    (local $i i32)
    ;; 0 = dark purple sky
    (call $set_pal (i32.const 0) (i32.const 15) (i32.const 8) (i32.const 30))
    ;; 1-3: stars (set by $draw_stars each frame)

    ;; 10-73: opaque fire (intensity 21..84), shared across all backgrounds
    ;; At i=21, alpha=1.0 so color is pure fire_color — same regardless of bg
    (local.set $i (i32.const 21))
    (block $done (loop $lp
      (br_if $done (i32.gt_u (local.get $i) (i32.const 84)))
      (call $fire_color (local.get $i))
      ;; palette index = i - 21 + 10 = i - 11
      (call $set_pal (i32.sub (local.get $i) (i32.const 11))
        (i32.load8_u (i32.const 0x3FF00))
        (i32.load8_u (i32.const 0x3FF01))
        (i32.load8_u (i32.const 0x3FF02)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)
    ))

    ;; 74-94: dim fire (intensity 0..20) blended over sky (15,8,30)
    (call $gen_fire_blend (i32.const 74) (i32.const 15) (i32.const 8) (i32.const 30))
    ;; 100-120: dim fire (intensity 0..20) blended over stone (70,70,80)
    (call $gen_fire_blend (i32.const 100) (i32.const 70) (i32.const 70) (i32.const 80))
    ;; 121-141: dim fire (intensity 0..20) blended over white text (255,255,255)
    (call $gen_fire_blend (i32.const 121) (i32.const 255) (i32.const 255) (i32.const 255))

    ;; 95 = dark brown ground
    (call $set_pal (i32.const 95) (i32.const 50) (i32.const 28) (i32.const 10))
    ;; 96 = gray tombstone
    (call $set_pal (i32.const 96) (i32.const 70) (i32.const 70) (i32.const 80))
    ;; 97 = lighter tombstone edge
    (call $set_pal (i32.const 97) (i32.const 110) (i32.const 110) (i32.const 120))
    ;; 98 = white for text
    (call $set_pal (i32.const 98) (i32.const 255) (i32.const 255) (i32.const 255))
    ;; 99 = berrry green
    (call $set_pal (i32.const 99) (i32.const 0) (i32.const 221) (i32.const 136))
  )

  (func $render_grave (param $elapsed i32)
    (local $t i32) (local $i i32) (local $x i32) (local $y i32)
    (local $rise i32) (local $tx i32) (local $ty i32) (local $tw i32) (local $th i32)
    (local $ti i32) (local $heat i32) (local $v1 i32) (local $v2 i32)

    ;; t = ms into this section
    (local.set $t (i32.sub (local.get $elapsed) (i32.const 8000)))

    ;; Fill screen with sky color (0)
    (call $clear_fb)

    ;; Draw stars (static positions, palette-animated twinkle)
    (call $draw_stars (i32.const 130) (local.get $t))

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

    ;; Doom-style fire simulation in buffer at 0x38100 (320×104, rows 0-103 map to y=96-199)
    ;; Seed bottom row (row 103) with random hot values
    (local.set $x (i32.const 0))
    (block $sd (loop $sl
      (br_if $sd (i32.ge_u (local.get $x) (i32.const 320)))
      (i32.store8 (i32.add (i32.const 0x38100) (i32.add (i32.mul (i32.const 103) (i32.const 320)) (local.get $x)))
        (i32.rem_u (i32.and (call $rand) (i32.const 127)) (i32.const 85)))
      (local.set $x (i32.add (local.get $x) (i32.const 1)))
      (br $sl)
    ))
    ;; Propagate fire upward: for each pixel (x, row) where row < 103
    ;; new[row][x] = avg(old[row+1][x-1], old[row+1][x], old[row+1][x+1], old[row+2][x]) - decay
    (local.set $y (i32.const 0))
    (block $fd (loop $fl
      (br_if $fd (i32.ge_u (local.get $y) (i32.const 103)))
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
        ;; two-below (or bottom row if near end)
        (local.set $heat (i32.shr_u
          (i32.add (i32.add (local.get $v1) (local.get $v2))
            (i32.add (local.get $heat)
              (i32.load8_u (i32.add (i32.const 0x38100)
                (i32.add (i32.mul
                  (select (i32.add (local.get $y) (i32.const 2)) (i32.const 103)
                    (i32.lt_u (local.get $y) (i32.const 102)))
                  (i32.const 320)) (local.get $x))))))
          (i32.const 2)))
        ;; random decay: -1 with 25% probability (slower decay = taller flames)
        (local.set $heat (i32.sub (local.get $heat)
          (i32.eqz (i32.and (call $rand) (i32.const 3)))))
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
    ;; Overlay fire buffer onto framebuffer with alpha-blended palette bands
    ;; heat >= 21 → opaque fire at palette (heat - 11)  [indices 10-73]
    ;; heat 1..20 → blended band: 74+heat (sky), 100+heat (stone), 121+heat (white text)
    (local.set $y (i32.const 0))
    (block $od (loop $ol
      (br_if $od (i32.ge_u (local.get $y) (i32.const 104)))
      (local.set $x (i32.const 0))
      (block $oxd (loop $oxl
        (br_if $oxd (i32.ge_u (local.get $x) (i32.const 320)))
        (local.set $heat (i32.load8_u (i32.add (i32.const 0x38100)
          (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x)))))
        (if (i32.gt_u (local.get $heat) (i32.const 0))
          (then
            (if (i32.ge_u (local.get $heat) (i32.const 21))
              (then
                ;; Opaque fire — same for all backgrounds
                (i32.store8 (i32.add (i32.const 0x0340)
                  (i32.add (i32.mul (i32.add (local.get $y) (i32.const 96)) (i32.const 320)) (local.get $x)))
                  (i32.sub (local.get $heat) (i32.const 11))))
              (else
                ;; Translucent fire — read bg pixel to pick blend band
                (local.set $v1 (i32.load8_u (i32.add (i32.const 0x0340)
                  (i32.add (i32.mul (i32.add (local.get $y) (i32.const 96)) (i32.const 320)) (local.get $x)))))
                ;; base: 74 (sky), 100 (stone 96/97), 121 (white text 98)
                (local.set $v2 (i32.const 74))  ;; default: sky
                (if (i32.or (i32.eq (local.get $v1) (i32.const 96))
                            (i32.eq (local.get $v1) (i32.const 97)))
                  (then (local.set $v2 (i32.const 100))))
                (if (i32.eq (local.get $v1) (i32.const 98))
                  (then (local.set $v2 (i32.const 121))))
                (i32.store8 (i32.add (i32.const 0x0340)
                  (i32.add (i32.mul (i32.add (local.get $y) (i32.const 96)) (i32.const 320)) (local.get $x)))
                  (i32.add (local.get $v2) (local.get $heat)))))))
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br $oxl)
      ))
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br $ol)
    ))

    ;; "CODING IS OVER" at 2x scale, centered above tombstones
    ;; 14 * 9 * 2 = 252px. x = (320-252)/2 = 34
    ;; Fade in after 3s into section
    (if (i32.gt_u (local.get $t) (i32.const 3000))
      (then
        (call $draw_text (i32.const 0x10740) (i32.const 14)
          (i32.const 34) (i32.const 55) (i32.const 2) (i32.const 98))))

    ;; "BERRRY.APP PRESENTS" at top center, 1x scale
    ;; 19 chars * 9px = 171px. centered: (320-171)/2 = 74
    (if (i32.gt_u (local.get $t) (i32.const 2000))
      (then
        (call $draw_text (i32.const 0x10760) (i32.const 19)
          (i32.const 74) (i32.const 8) (i32.const 1) (i32.const 99))))
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
                  (select (i32.const 97) (i32.const 96)
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
          (local.get $text_x) (local.get $text_y) (i32.const 1) (i32.const 98))))
  )

  ;; =========================================================
  ;; SECTION 2: "INTENT NOT SYNTAX" — dramatic reveal
  ;; =========================================================
  (func $pal_plasma
    ;; 0 = black
    (call $set_pal (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))
    ;; 10 = white text
    (call $set_pal (i32.const 10) (i32.const 255) (i32.const 255) (i32.const 255))
    ;; 11 = berrry green
    (call $set_pal (i32.const 11) (i32.const 0) (i32.const 221) (i32.const 136))
    ;; 12 = glitch bright
    (call $set_pal (i32.const 12) (i32.const 200) (i32.const 200) (i32.const 220))
    ;; 13 = dim pulse
    (call $set_pal (i32.const 13) (i32.const 40) (i32.const 40) (i32.const 50))
    ;; 14 = red accent
    (call $set_pal (i32.const 14) (i32.const 200) (i32.const 30) (i32.const 30))
  )

  (func $render_plasma (param $elapsed i32)
    (local $t i32) (local $x i32) (local $y i32)
    (local $glitch_y i32) (local $gx i32) (local $glitch_w i32)
    (local $shake_x i32) (local $shake_y i32) (local $pulse i32)

    (local.set $t (i32.sub (local.get $elapsed) (i32.const 20000)))

    (call $clear_fb)

    ;; Phase 1 (0-800ms): Glitch static buildup — random blocks intensifying
    (if (i32.lt_u (local.get $t) (i32.const 800))
      (then
        ;; Number of glitch blocks increases with time
        (local.set $y (i32.const 0))
        (block $gd (loop $gl
          (br_if $gd (i32.ge_u (local.get $y) (i32.shr_u (local.get $t) (i32.const 4))))
          (local.set $glitch_y (i32.rem_u
            (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 200)))
          (local.set $gx (i32.rem_u
            (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 280)))
          (local.set $glitch_w (i32.add
            (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 60)) (i32.const 5)))
          (local.set $x (local.get $gx))
          (block $gwd (loop $gwl
            (br_if $gwd (i32.ge_u (local.get $x)
              (i32.add (local.get $gx) (local.get $glitch_w))))
            (if (i32.lt_u (local.get $x) (i32.const 320))
              (then
                (i32.store8 (i32.add (i32.const 0x0340)
                  (i32.add (i32.mul (local.get $glitch_y) (i32.const 320)) (local.get $x)))
                  (select (i32.const 12) (i32.const 13)
                    (i32.lt_u (i32.and (call $rand) (i32.const 3)) (i32.const 2))))))
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $gwl)
          ))
          (local.set $y (i32.add (local.get $y) (i32.const 1)))
          (br $gl)
        ))
        (return)
      ))

    ;; Phase 2 (800ms-1200ms): White flash → text slam
    (if (i32.lt_u (local.get $t) (i32.const 1200))
      (then
        ;; Brief white flash at 800ms, fading to black by 1200ms
        (local.set $pulse (i32.div_u
          (i32.mul (i32.sub (i32.const 1200) (local.get $t)) (i32.const 255))
          (i32.const 400)))
        (call $set_pal (i32.const 13) (local.get $pulse) (local.get $pulse) (local.get $pulse))
        ;; Fill with flash color
        (local.set $y (i32.const 0))
        (block $fd (loop $fl
          (br_if $fd (i32.ge_u (local.get $y) (i32.const 64000)))
          (i32.store8 (i32.add (i32.const 0x0340) (local.get $y)) (i32.const 13))
          (local.set $y (i32.add (local.get $y) (i32.const 1)))
          (br $fl)
        ))
      ))

    ;; Phase 3 (1200ms+): Text on black with subtle glitch bars
    ;; "INTENT NOT SYNTAX" at 2x, centered: 17*9*2=306px, x=7
    ;; Screen shake in first 500ms after slam
    (local.set $shake_x (i32.const 0))
    (local.set $shake_y (i32.const 0))
    (if (i32.lt_u (local.get $t) (i32.const 1700))
      (then
        (local.set $shake_x (i32.sub
          (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 7)) (i32.const 3)))
        (local.set $shake_y (i32.sub
          (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 5)) (i32.const 2)))))

    (if (i32.ge_u (local.get $t) (i32.const 1200))
      (then
        (call $draw_text (i32.const 0x10780) (i32.const 17)
          (i32.add (i32.const 7) (local.get $shake_x))
          (i32.add (i32.const 88) (local.get $shake_y))
          (i32.const 2) (i32.const 10))

        ;; Occasional glitch bars
        (if (i32.lt_u (i32.and (local.get $t) (i32.const 255)) (i32.const 12))
          (then
            (local.set $y (i32.const 0))
            (block $hd (loop $hl
              (br_if $hd (i32.ge_u (local.get $y) (i32.const 2)))
              (local.set $glitch_y (i32.rem_u
                (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 200)))
              (local.set $x (i32.const 0))
              (block $hxd (loop $hxl
                (br_if $hxd (i32.ge_u (local.get $x) (i32.const 320)))
                (i32.store8 (i32.add (i32.const 0x0340)
                  (i32.add (i32.mul (local.get $glitch_y) (i32.const 320)) (local.get $x)))
                  (select (i32.const 12) (i32.const 0)
                    (i32.lt_u (i32.and (call $rand) (i32.const 7)) (i32.const 2))))
                (local.set $x (i32.add (local.get $x) (i32.const 1)))
                (br $hxl)
              ))
              (local.set $y (i32.add (local.get $y) (i32.const 1)))
              (br $hl)
            ))
          ))
      ))
  )

  ;; =========================================================
  ;; SECTION 3: Scroller
  ;; =========================================================
  (func $pal_scroll
    (local $i i32)
    ;; 0 = deep blue-black
    (call $set_pal (i32.const 0) (i32.const 4) (i32.const 4) (i32.const 16))
    ;; Stars at 1-3 set by $draw_stars (no conflict)
    ;; 240-255: text brightness ramp from background (4,4,16) to white (255,255,255)
    ;; index 240 = background, 255 = full white
    (local.set $i (i32.const 0))
    (block $td (loop $tl
      (br_if $td (i32.gt_u (local.get $i) (i32.const 15)))
      (call $set_pal (i32.add (i32.const 240) (local.get $i))
        ;; R: 4 + i * 251 / 15
        (i32.add (i32.const 4) (i32.div_u (i32.mul (local.get $i) (i32.const 251)) (i32.const 15)))
        ;; G: 4 + i * 251 / 15
        (i32.add (i32.const 4) (i32.div_u (i32.mul (local.get $i) (i32.const 251)) (i32.const 15)))
        ;; B: 16 + i * 239 / 15
        (i32.add (i32.const 16) (i32.div_u (i32.mul (local.get $i) (i32.const 239)) (i32.const 15))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $tl)
    ))
  )

  ;; Bilinear sample the text texture at fixed-point coords (tx_fp, ty_fp)
  ;; Returns 0-256 brightness. Samples 4 neighboring integer texels and blends.
  ;; Nearest-neighbor texture lookup (pixelated text, smooth perspective)
  ;; Returns 0 or 255 — sharp texel edges, no bilinear blending
  (func $text_texel_fp (param $tx_fp i32) (param $ty_fp i32) (result i32)
    (i32.mul (call $text_texel
      (i32.shr_s (i32.add (local.get $tx_fp) (i32.const 128)) (i32.const 8))
      (i32.shr_s (i32.add (local.get $ty_fp) (i32.const 128)) (i32.const 8)))
      (i32.const 255))
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
            (if (result i32) (i32.ge_u (local.get $ci) (i32.const 252))
              (then (i32.const 0))
              (else
                (local.set $ch (i32.load8_u (i32.add (i32.const 0x107C0) (local.get $ci))))
                (if (result i32) (i32.eq (local.get $ch) (i32.const 32))
                  (then (i32.const 0))
                  (else (call $font_pixel (local.get $ch) (local.get $fr)
                    (i32.rem_u (local.get $tx) (i32.const 8))))))))))))

  (func $render_scroll (param $elapsed i32)
    (local $t i32) (local $i i32)
    (local $sy i32) (local $sx i32) (local $df i32)
    (local $scroll i32) (local $screen_half i32) (local $left i32)
    (local $right i32) (local $color i32)
    ;; Fixed-point 8-bit fraction
    (local $ty_fp i32) (local $tx_fp i32)
    (local $bright i32) (local $depth_bright i32)
    (local $step i32) (local $sum i32) (local $vstep i32)
    (local $left_fp i32)

    (local.set $t (i32.sub (local.get $elapsed) (i32.const 32000)))

    ;; Clear to background
    (call $clear_fb)

    ;; Draw starfield (static positions, palette-animated twinkle)
    (call $draw_stars (i32.const 200) (local.get $t))

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
          ;; left_fp in fixed-point: ~1.275x wider chars (85% of 1.5x)
          ;; = 40960 - df*48960/169
          (local.set $left_fp (i32.sub (i32.const 40960)
            (i32.div_u (i32.mul (local.get $df) (i32.const 48960)) (i32.const 169))))
          ;; Integer left/right for loop bounds only
          (local.set $left (i32.shr_s (local.get $left_fp) (i32.const 8)))
          (local.set $screen_half (i32.div_u
            (i32.mul (local.get $df) (i32.const 191)) (i32.const 169)))
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
            ;; tx_fp = (sx*256 - left_fp) * 253 / (df * 3)  [~1.275x wider chars (85% of 1.5x)]
            (local.set $tx_fp (i32.div_u
              (i32.mul (i32.sub (i32.mul (local.get $sx) (i32.const 256)) (local.get $left_fp)) (i32.const 253))
              (i32.mul (local.get $df) (i32.const 3))))

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
  ;; SECTION 4: Berrry Finale
  ;; =========================================================
  (func $pal_berrry
    ;; 0 = black background
    (call $set_pal (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))
    ;; 1-3 = stars (set by $draw_stars)
    ;; 34 = berrry brand green
    (call $set_pal (i32.const 34) (i32.const 0) (i32.const 221) (i32.const 136))
    ;; 38 = sparkle
    (call $set_pal (i32.const 38) (i32.const 200) (i32.const 200) (i32.const 255))
    ;; 39 = dim text
    (call $set_pal (i32.const 39) (i32.const 100) (i32.const 100) (i32.const 100))

    ;; 48-71 = red body ramp (24 shades: near-black → red → pink → white)
    (call $set_pal (i32.const 48) (i32.const 12)  (i32.const 1)   (i32.const 2))
    (call $set_pal (i32.const 49) (i32.const 22)  (i32.const 2)   (i32.const 4))
    (call $set_pal (i32.const 50) (i32.const 35)  (i32.const 3)   (i32.const 6))
    (call $set_pal (i32.const 51) (i32.const 50)  (i32.const 4)   (i32.const 8))
    (call $set_pal (i32.const 52) (i32.const 68)  (i32.const 5)   (i32.const 10))
    (call $set_pal (i32.const 53) (i32.const 88)  (i32.const 7)   (i32.const 14))
    (call $set_pal (i32.const 54) (i32.const 108) (i32.const 10)  (i32.const 18))
    (call $set_pal (i32.const 55) (i32.const 128) (i32.const 14)  (i32.const 22))
    (call $set_pal (i32.const 56) (i32.const 148) (i32.const 20)  (i32.const 30))
    (call $set_pal (i32.const 57) (i32.const 165) (i32.const 28)  (i32.const 38))
    (call $set_pal (i32.const 58) (i32.const 182) (i32.const 38)  (i32.const 48))
    (call $set_pal (i32.const 59) (i32.const 196) (i32.const 50)  (i32.const 58))
    (call $set_pal (i32.const 60) (i32.const 210) (i32.const 62)  (i32.const 68))
    (call $set_pal (i32.const 61) (i32.const 222) (i32.const 78)  (i32.const 80))
    (call $set_pal (i32.const 62) (i32.const 232) (i32.const 95)  (i32.const 92))
    (call $set_pal (i32.const 63) (i32.const 240) (i32.const 112) (i32.const 105))
    (call $set_pal (i32.const 64) (i32.const 248) (i32.const 132) (i32.const 120))
    (call $set_pal (i32.const 65) (i32.const 252) (i32.const 155) (i32.const 140))
    (call $set_pal (i32.const 66) (i32.const 255) (i32.const 175) (i32.const 160))
    (call $set_pal (i32.const 67) (i32.const 255) (i32.const 195) (i32.const 182))
    (call $set_pal (i32.const 68) (i32.const 255) (i32.const 212) (i32.const 202))
    (call $set_pal (i32.const 69) (i32.const 255) (i32.const 228) (i32.const 222))
    (call $set_pal (i32.const 70) (i32.const 255) (i32.const 242) (i32.const 240))
    (call $set_pal (i32.const 71) (i32.const 255) (i32.const 255) (i32.const 255))

    ;; 72-83 = seed yellow ramp (12 shades: dark olive → yellow → pale → white)
    (call $set_pal (i32.const 72) (i32.const 12)  (i32.const 10)  (i32.const 2))
    (call $set_pal (i32.const 73) (i32.const 30)  (i32.const 25)  (i32.const 5))
    (call $set_pal (i32.const 74) (i32.const 55)  (i32.const 45)  (i32.const 10))
    (call $set_pal (i32.const 75) (i32.const 85)  (i32.const 70)  (i32.const 18))
    (call $set_pal (i32.const 76) (i32.const 115) (i32.const 98)  (i32.const 28))
    (call $set_pal (i32.const 77) (i32.const 150) (i32.const 130) (i32.const 40))
    (call $set_pal (i32.const 78) (i32.const 185) (i32.const 165) (i32.const 55))
    (call $set_pal (i32.const 79) (i32.const 215) (i32.const 195) (i32.const 75))
    (call $set_pal (i32.const 80) (i32.const 235) (i32.const 218) (i32.const 100))
    (call $set_pal (i32.const 81) (i32.const 245) (i32.const 235) (i32.const 160))
    (call $set_pal (i32.const 82) (i32.const 250) (i32.const 245) (i32.const 210))
    (call $set_pal (i32.const 83) (i32.const 255) (i32.const 255) (i32.const 255))

    ;; 84-95 = green leaf ramp (12 shades: dark → bright green, matte)
    ;; Bottom shades double as vein color
    (call $set_pal (i32.const 84) (i32.const 5)   (i32.const 15)  (i32.const 3))
    (call $set_pal (i32.const 85) (i32.const 10)  (i32.const 28)  (i32.const 6))
    (call $set_pal (i32.const 86) (i32.const 16)  (i32.const 45)  (i32.const 10))
    (call $set_pal (i32.const 87) (i32.const 24)  (i32.const 65)  (i32.const 16))
    (call $set_pal (i32.const 88) (i32.const 34)  (i32.const 88)  (i32.const 24))
    (call $set_pal (i32.const 89) (i32.const 45)  (i32.const 115) (i32.const 32))
    (call $set_pal (i32.const 90) (i32.const 55)  (i32.const 142) (i32.const 40))
    (call $set_pal (i32.const 91) (i32.const 68)  (i32.const 168) (i32.const 50))
    (call $set_pal (i32.const 92) (i32.const 82)  (i32.const 192) (i32.const 62))
    (call $set_pal (i32.const 93) (i32.const 95)  (i32.const 215) (i32.const 75))
    (call $set_pal (i32.const 94) (i32.const 108) (i32.const 232) (i32.const 88))
    (call $set_pal (i32.const 95) (i32.const 120) (i32.const 245) (i32.const 100))

    ;; 96-101 = stem brown ramp (6 shades)
    (call $set_pal (i32.const 96)  (i32.const 15)  (i32.const 8)   (i32.const 3))
    (call $set_pal (i32.const 97)  (i32.const 32)  (i32.const 18)  (i32.const 7))
    (call $set_pal (i32.const 98)  (i32.const 52)  (i32.const 32)  (i32.const 12))
    (call $set_pal (i32.const 99)  (i32.const 80)  (i32.const 50)  (i32.const 20))
    (call $set_pal (i32.const 100) (i32.const 110) (i32.const 72)  (i32.const 32))
    (call $set_pal (i32.const 101) (i32.const 145) (i32.const 100) (i32.const 50))
  )

  (func $render_berrry (param $elapsed i32)
    (local $t i32) (local $text_color i32) (local $bob i32)

    (local.set $t (i32.sub (local.get $elapsed) (i32.const 44000)))

    ;; Clear
    (call $clear_fb)

    ;; Text color: berrry brand green
    (local.set $text_color (i32.const 34))

    ;; Starfield background (behind strawberry)
    (call $draw_stars (i32.const 200) (local.get $t))

    ;; Bob: sin_tab gives 0-255; subtract 128 → -128..127; >>4 → ±8 pixels
    (local.set $bob (i32.shr_s
      (i32.sub (call $sin_tab (i32.shr_u (local.get $t) (i32.const 4))) (i32.const 128))
      (i32.const 4)))

    ;; "BERRRY.APP" at 3x scale, centered at top
    ;; 10 chars * 8px * 3 = 240px, x = (320-240)/2 = 40
    (call $draw_text (i32.const 0x10750) (i32.const 10)
      (i32.const 40) (i32.const 10) (i32.const 3) (local.get $text_color))

    ;; Draw 3D Phong-shaded strawberry in middle
    (call $draw_strawberry (i32.const 160) (i32.add (i32.const 115) (local.get $bob)) (local.get $t))

    ;; "WASMVGA-DEMOS.BERRRY.APP" at 1x, centered at bottom
    ;; 24 chars * 8px = 192px, x = (320-192)/2 = 64
    (call $draw_text (i32.const 0x108C0) (i32.const 24)
      (i32.const 64) (i32.const 180) (i32.const 1) (i32.const 39))
  )

  ;; Proper strawberry shape: two-part profile + elongated petals + seeds with dimples + rim glow
  (func $draw_strawberry (param $cx i32) (param $cy i32) (param $t i32)
    (local $dx i32) (local $dy i32) (local $px i32) (local $py i32)
    (local $nx128 i32) (local $ny128 i32) (local $nz128 i32)
    (local $dot_diff i32) (local $dot_spec i32)
    (local $norm_sq i32) (local $guess i32)
    (local $col i32)
    ;; in_leaf: 0=berry, 1=seed-inner, 2=leaf/calyx, 3=seed-shadow, 4=stem
    (local $in_leaf i32)
    (local $sdx i32) (local $sdy i32) (local $sdsq i32)
    (local $lx128 i32) (local $ly128 i32) (local $lz128 i32)
    (local $shade i32)
    ;; for upper/lower body test
    (local $in_body i32)
    ;; Saved petal sin/cos for per-petal leaf normals
    (local $leaf_sin128 i32) (local $leaf_cos128 i32)
    ;; petal locals
    (local $u_raw i32) (local $v_raw i32) (local $u7 i32) (local $v7 i32)
    (local $ddx i32) (local $ddy i32)
    (local $rx i32)
    (local $seed_cx i32) (local $seed_cy i32) (local $si i32) (local $rot i32) (local $cos_val i32)

    ;; Seed rotation offset: slow spin, full revolution in ~4096 frames
    (local.set $rot (i32.and (i32.shr_u (local.get $t) (i32.const 4)) (i32.const 255)))

    ;; Orbiting light: circles around berry to showcase Phong
    ;; Orbiting light, 50% further: reduced amplitude, higher z ratio
    ;; sin_tab returns 0-255, subtract 128 → -128..127, *135/128 ≈ *17>>4
    (local.set $lx128 (i32.shr_s (i32.mul
      (i32.sub (call $sin_tab (i32.shr_u (local.get $t) (i32.const 4))) (i32.const 128))
      (i32.const 24)) (i32.const 4)))
    (local.set $ly128 (i32.shr_s (i32.mul
      (i32.sub (call $sin_tab (i32.add (i32.shr_u (local.get $t) (i32.const 4)) (i32.const 64))) (i32.const 128))
      (i32.const 24)) (i32.const 4)))
    (local.set $lz128 (i32.const 130))

    ;; Bounding box: dy -72..+47, dx -40..+40
    (local.set $dy (i32.const -72))
    (block $yd (loop $yl
      (br_if $yd (i32.gt_s (local.get $dy) (i32.const 47)))
      (local.set $dx (i32.const -40))
      (block $xd (loop $xl
        (br_if $xd (i32.gt_s (local.get $dx) (i32.const 40)))

        ;; ---- Shape test via radius profile table at 0x10A00 ----
        ;; 91 entries for dy=-45..+45 (index = dy+45), each byte = max rx at that height
        (local.set $in_body (i32.const 0))
        (local.set $rx (i32.const 0))

        (if (i32.and
              (i32.ge_s (local.get $dy) (i32.const -45))
              (i32.le_s (local.get $dy) (i32.const 45)))
          (then
            (local.set $rx (i32.load8_u (i32.add (i32.const 0x10A00)
              (i32.add (local.get $dy) (i32.const 45)))))
            (if (i32.and
                  (i32.gt_s (local.get $rx) (i32.const 0))
                  (i32.le_s (i32.mul (local.get $dx) (local.get $dx))
                            (i32.mul (local.get $rx) (local.get $rx))))
              (then (local.set $in_body (i32.const 1))))))

        ;; ---- Leaf petal test ----
        ;; 5 petals: elongated ellipses in petal-local space
        ;; in_leaf values: 0=none, 1=seed-inner, 2=leaf, 3=seed-shadow, 4=stem
        (local.set $in_leaf (i32.const 0))

        ;; Petal 0: angle=0°, sin128=0, cos128=128, center=(0,-57)
        (local.set $ddx (local.get $dx))
        (local.set $ddy (i32.sub (local.get $dy) (i32.const -57)))
        ;; u_raw = ddx*sin128 + ddy*(-cos128) = ddx*0 + ddy*(-128) = -ddy*128
        (local.set $u_raw (i32.mul (i32.sub (i32.const 0) (local.get $ddy)) (i32.const 128)))
        ;; v_raw = ddx*cos128 + ddy*sin128 = ddx*128 + ddy*0 = ddx*128
        (local.set $v_raw (i32.mul (local.get $ddx) (i32.const 128)))
        (local.set $u7 (i32.shr_s (local.get $u_raw) (i32.const 7)))
        (local.set $v7 (i32.shr_s (local.get $v_raw) (i32.const 7)))
        (if (i32.le_s
              (i32.add (i32.mul (i32.mul (local.get $u7) (local.get $u7)) (i32.const 16))
                       (i32.mul (i32.mul (local.get $v7) (local.get $v7)) (i32.const 196)))
              (i32.const 3136))
          (then
            (local.set $in_leaf (i32.const 2))
            (local.set $leaf_sin128 (i32.const 0))
            (local.set $leaf_cos128 (i32.const 128))
            ;; Vein: |v7|<=1 and |u7|>3
            (if (i32.and
                  (i32.le_s (select (local.get $v7) (i32.sub (i32.const 0) (local.get $v7)) (i32.ge_s (local.get $v7) (i32.const 0))) (i32.const 1))
                  (i32.gt_s (select (local.get $u7) (i32.sub (i32.const 0) (local.get $u7)) (i32.ge_s (local.get $u7) (i32.const 0))) (i32.const 3)))
              (then (local.set $in_leaf (i32.const 5))))))

        ;; Petal 1: angle=30°, sin128=64, cos128=111, center=(6,-55)
        (local.set $ddx (i32.sub (local.get $dx) (i32.const 6)))
        (local.set $ddy (i32.sub (local.get $dy) (i32.const -55)))
        (local.set $u_raw (i32.add (i32.mul (local.get $ddx) (i32.const 64)) (i32.mul (local.get $ddy) (i32.sub (i32.const 0) (i32.const 111)))))
        (local.set $v_raw (i32.add (i32.mul (local.get $ddx) (i32.const 111)) (i32.mul (local.get $ddy) (i32.const 64))))
        (local.set $u7 (i32.shr_s (local.get $u_raw) (i32.const 7)))
        (local.set $v7 (i32.shr_s (local.get $v_raw) (i32.const 7)))
        (if (i32.le_s
              (i32.add (i32.mul (i32.mul (local.get $u7) (local.get $u7)) (i32.const 16))
                       (i32.mul (i32.mul (local.get $v7) (local.get $v7)) (i32.const 196)))
              (i32.const 3136))
          (then
            (if (i32.eqz (local.get $in_leaf))
              (then
                (local.set $in_leaf (i32.const 2))
                (local.set $leaf_sin128 (i32.const 64))
                (local.set $leaf_cos128 (i32.const 111))))
            (if (i32.and
                  (i32.le_s (select (local.get $v7) (i32.sub (i32.const 0) (local.get $v7)) (i32.ge_s (local.get $v7) (i32.const 0))) (i32.const 1))
                  (i32.gt_s (select (local.get $u7) (i32.sub (i32.const 0) (local.get $u7)) (i32.ge_s (local.get $u7) (i32.const 0))) (i32.const 3)))
              (then (local.set $in_leaf (i32.const 5))))))

        ;; Petal 2: angle=-30°, sin128=-64, cos128=111, center=(-6,-55)
        (local.set $ddx (i32.sub (local.get $dx) (i32.const -6)))
        (local.set $ddy (i32.sub (local.get $dy) (i32.const -55)))
        (local.set $u_raw (i32.add (i32.mul (local.get $ddx) (i32.sub (i32.const 0) (i32.const 64))) (i32.mul (local.get $ddy) (i32.sub (i32.const 0) (i32.const 111)))))
        (local.set $v_raw (i32.add (i32.mul (local.get $ddx) (i32.const 111)) (i32.mul (local.get $ddy) (i32.sub (i32.const 0) (i32.const 64)))))
        (local.set $u7 (i32.shr_s (local.get $u_raw) (i32.const 7)))
        (local.set $v7 (i32.shr_s (local.get $v_raw) (i32.const 7)))
        (if (i32.le_s
              (i32.add (i32.mul (i32.mul (local.get $u7) (local.get $u7)) (i32.const 16))
                       (i32.mul (i32.mul (local.get $v7) (local.get $v7)) (i32.const 196)))
              (i32.const 3136))
          (then
            (if (i32.eqz (local.get $in_leaf))
              (then
                (local.set $in_leaf (i32.const 2))
                (local.set $leaf_sin128 (i32.const -64))
                (local.set $leaf_cos128 (i32.const 111))))
            (if (i32.and
                  (i32.le_s (select (local.get $v7) (i32.sub (i32.const 0) (local.get $v7)) (i32.ge_s (local.get $v7) (i32.const 0))) (i32.const 1))
                  (i32.gt_s (select (local.get $u7) (i32.sub (i32.const 0) (local.get $u7)) (i32.ge_s (local.get $u7) (i32.const 0))) (i32.const 3)))
              (then (local.set $in_leaf (i32.const 5))))))

        ;; Petal 3: angle=55°, sin128=105, cos128=73, center=(10,-51)
        (local.set $ddx (i32.sub (local.get $dx) (i32.const 10)))
        (local.set $ddy (i32.sub (local.get $dy) (i32.const -51)))
        (local.set $u_raw (i32.add (i32.mul (local.get $ddx) (i32.const 105)) (i32.mul (local.get $ddy) (i32.sub (i32.const 0) (i32.const 73)))))
        (local.set $v_raw (i32.add (i32.mul (local.get $ddx) (i32.const 73)) (i32.mul (local.get $ddy) (i32.const 105))))
        (local.set $u7 (i32.shr_s (local.get $u_raw) (i32.const 7)))
        (local.set $v7 (i32.shr_s (local.get $v_raw) (i32.const 7)))
        (if (i32.le_s
              (i32.add (i32.mul (i32.mul (local.get $u7) (local.get $u7)) (i32.const 16))
                       (i32.mul (i32.mul (local.get $v7) (local.get $v7)) (i32.const 196)))
              (i32.const 3136))
          (then
            (if (i32.eqz (local.get $in_leaf))
              (then
                (local.set $in_leaf (i32.const 2))
                (local.set $leaf_sin128 (i32.const 105))
                (local.set $leaf_cos128 (i32.const 73))))
            (if (i32.and
                  (i32.le_s (select (local.get $v7) (i32.sub (i32.const 0) (local.get $v7)) (i32.ge_s (local.get $v7) (i32.const 0))) (i32.const 1))
                  (i32.gt_s (select (local.get $u7) (i32.sub (i32.const 0) (local.get $u7)) (i32.ge_s (local.get $u7) (i32.const 0))) (i32.const 3)))
              (then (local.set $in_leaf (i32.const 5))))))

        ;; Petal 4: angle=-55°, sin128=-105, cos128=73, center=(-10,-51)
        (local.set $ddx (i32.sub (local.get $dx) (i32.const -10)))
        (local.set $ddy (i32.sub (local.get $dy) (i32.const -51)))
        (local.set $u_raw (i32.add (i32.mul (local.get $ddx) (i32.sub (i32.const 0) (i32.const 105))) (i32.mul (local.get $ddy) (i32.sub (i32.const 0) (i32.const 73)))))
        (local.set $v_raw (i32.add (i32.mul (local.get $ddx) (i32.const 73)) (i32.mul (local.get $ddy) (i32.sub (i32.const 0) (i32.const 105)))))
        (local.set $u7 (i32.shr_s (local.get $u_raw) (i32.const 7)))
        (local.set $v7 (i32.shr_s (local.get $v_raw) (i32.const 7)))
        (if (i32.le_s
              (i32.add (i32.mul (i32.mul (local.get $u7) (local.get $u7)) (i32.const 16))
                       (i32.mul (i32.mul (local.get $v7) (local.get $v7)) (i32.const 196)))
              (i32.const 3136))
          (then
            (if (i32.eqz (local.get $in_leaf))
              (then
                (local.set $in_leaf (i32.const 2))
                (local.set $leaf_sin128 (i32.const -105))
                (local.set $leaf_cos128 (i32.const 73))))
            (if (i32.and
                  (i32.le_s (select (local.get $v7) (i32.sub (i32.const 0) (local.get $v7)) (i32.ge_s (local.get $v7) (i32.const 0))) (i32.const 1))
                  (i32.gt_s (select (local.get $u7) (i32.sub (i32.const 0) (local.get $u7)) (i32.ge_s (local.get $u7) (i32.const 0))) (i32.const 3)))
              (then (local.set $in_leaf (i32.const 5))))))

        ;; Stem zone: |dx|<=1, dy in [-61,-55], not in a leaf petal
        (if (i32.and
              (i32.le_s (select (local.get $dx) (i32.sub (i32.const 0) (local.get $dx)) (i32.ge_s (local.get $dx) (i32.const 0))) (i32.const 1))
              (i32.and
                (i32.ge_s (local.get $dy) (i32.const -61))
                (i32.le_s (local.get $dy) (i32.const -55))))
          (then
            (if (i32.eqz (local.get $in_leaf))
              (then (local.set $in_leaf (i32.const 4))))))

        ;; Only render if inside berry body OR leaf/stem
        (if (i32.or
              (i32.gt_s (local.get $in_body) (i32.const 0))
              (i32.gt_s (local.get $in_leaf) (i32.const 0)))
          (then
            (local.set $px (i32.add (local.get $cx) (local.get $dx)))
            (local.set $py (i32.add (local.get $cy) (local.get $dy)))

            ;; Bounds check
            (if (i32.and
              (i32.and (i32.ge_s (local.get $px) (i32.const 0))
                       (i32.lt_s (local.get $px) (i32.const 320)))
              (i32.and (i32.ge_s (local.get $py) (i32.const 0))
                       (i32.lt_s (local.get $py) (i32.const 200))))
              (then
                ;; Surface normal approximation
                ;; nx uses actual local radius for accurate curvature (fallback 38 for leaves)
                (local.set $nx128 (i32.div_s (i32.mul (local.get $dx) (i32.const 128))
                  (select (local.get $rx) (i32.const 38) (i32.gt_s (local.get $rx) (i32.const 0)))))
                ;; ny: blend profile slope with spherical position for 3D look
                ;; ny128 = (slope*3 + dy*128/45) / 2
                (if (i32.and
                      (i32.ge_s (local.get $dy) (i32.const -44))
                      (i32.le_s (local.get $dy) (i32.const 44)))
                  (then
                    (local.set $ny128 (i32.shr_s (i32.add
                      ;; slope component: (table[i-1] - table[i+1]) * 3
                      (i32.mul (i32.const 3) (i32.sub
                        (i32.load8_u (i32.add (i32.const 0x10A00) (i32.add (local.get $dy) (i32.const 44))))
                        (i32.load8_u (i32.add (i32.const 0x10A00) (i32.add (local.get $dy) (i32.const 46))))))
                      ;; spherical component: dy * 128 / 45 ≈ dy * 3
                      (i32.mul (local.get $dy) (i32.const 3)))
                      (i32.const 1))))
                  (else
                    (local.set $ny128 (i32.div_s (i32.mul (local.get $dy) (i32.const 128)) (i32.const 45)))))
                ;; Clamp ny128 to ±127
                (if (i32.gt_s (local.get $ny128) (i32.const 127))
                  (then (local.set $ny128 (i32.const 127))))
                (if (i32.lt_s (local.get $ny128) (i32.const -127))
                  (then (local.set $ny128 (i32.const -127))))

                ;; nz128 = sqrt(max(1, 16384 - nx128² - ny128²))
                (local.set $norm_sq
                  (i32.sub (i32.const 16384)
                    (i32.add
                      (i32.mul (local.get $nx128) (local.get $nx128))
                      (i32.mul (local.get $ny128) (local.get $ny128)))))
                (if (i32.lt_s (local.get $norm_sq) (i32.const 1))
                  (then (local.set $norm_sq (i32.const 1))))
                (local.set $guess (i32.const 64))
                (local.set $guess (i32.shr_u (i32.add (local.get $guess) (i32.div_u (local.get $norm_sq) (local.get $guess))) (i32.const 1)))
                (local.set $guess (i32.shr_u (i32.add (local.get $guess) (i32.div_u (local.get $norm_sq) (local.get $guess))) (i32.const 1)))
                (local.set $guess (i32.shr_u (i32.add (local.get $guess) (i32.div_u (local.get $norm_sq) (local.get $guess))) (i32.const 1)))
                (local.set $guess (i32.shr_u (i32.add (local.get $guess) (i32.div_u (local.get $norm_sq) (local.get $guess))) (i32.const 1)))
                (local.set $guess (i32.shr_u (i32.add (local.get $guess) (i32.div_u (local.get $norm_sq) (local.get $guess))) (i32.const 1)))
                (local.set $guess (i32.shr_u (i32.add (local.get $guess) (i32.div_u (local.get $norm_sq) (local.get $guess))) (i32.const 1)))
                (local.set $nz128 (local.get $guess))

                ;; Override normals for leaf/calyx: each petal tilts in its own direction
                ;; Petal u-axis in world = (sin128, -cos128), so normal tilts that way
                ;; nx = leaf_sin128 * 60 >> 7  (tilt outward along petal axis)
                ;;    + dx * 4                  (cross-petal curvature)
                ;; ny = -leaf_cos128 * 60 >> 7  (tilt outward along petal axis)
                ;;    + (dy+50) * 2             (base-to-tip variation)
                (if (i32.or (i32.eq (local.get $in_leaf) (i32.const 2))
                            (i32.eq (local.get $in_leaf) (i32.const 5)))
                  (then
                    (local.set $nx128 (i32.add
                      (i32.shr_s (i32.mul (local.get $leaf_sin128) (i32.const 60)) (i32.const 7))
                      (i32.mul (local.get $dx) (i32.const 4))))
                    (local.set $ny128 (i32.add
                      (i32.shr_s (i32.mul (i32.sub (i32.const 0) (local.get $leaf_cos128)) (i32.const 60)) (i32.const 7))
                      (i32.mul (i32.add (local.get $dy) (i32.const 50)) (i32.const 2))))
                    ;; Clamp ±127
                    (if (i32.gt_s (local.get $nx128) (i32.const 127))
                      (then (local.set $nx128 (i32.const 127))))
                    (if (i32.lt_s (local.get $nx128) (i32.const -127))
                      (then (local.set $nx128 (i32.const -127))))
                    (if (i32.gt_s (local.get $ny128) (i32.const 127))
                      (then (local.set $ny128 (i32.const 127))))
                    (if (i32.lt_s (local.get $ny128) (i32.const -127))
                      (then (local.set $ny128 (i32.const -127))))
                    ;; Recompute nz
                    (local.set $norm_sq
                      (i32.sub (i32.const 16384)
                        (i32.add
                          (i32.mul (local.get $nx128) (local.get $nx128))
                          (i32.mul (local.get $ny128) (local.get $ny128)))))
                    (if (i32.lt_s (local.get $norm_sq) (i32.const 1))
                      (then (local.set $norm_sq (i32.const 1))))
                    (local.set $guess (i32.const 64))
                    (local.set $guess (i32.shr_u (i32.add (local.get $guess) (i32.div_u (local.get $norm_sq) (local.get $guess))) (i32.const 1)))
                    (local.set $guess (i32.shr_u (i32.add (local.get $guess) (i32.div_u (local.get $norm_sq) (local.get $guess))) (i32.const 1)))
                    (local.set $guess (i32.shr_u (i32.add (local.get $guess) (i32.div_u (local.get $norm_sq) (local.get $guess))) (i32.const 1)))
                    (local.set $nz128 (local.get $guess))))

                ;; Diffuse: dot(N, L) >> 7
                (local.set $dot_diff
                  (i32.shr_s
                    (i32.add
                      (i32.add
                        (i32.mul (local.get $nx128) (local.get $lx128))
                        (i32.mul (local.get $ny128) (local.get $ly128)))
                      (i32.mul (local.get $nz128) (local.get $lz128)))
                    (i32.const 7)))
                (if (i32.lt_s (local.get $dot_diff) (i32.const 0))
                  (then (local.set $dot_diff (i32.const 0))))

                ;; Specular: 2*diffuse*nz>>7 - lz, clamped >=0, >>1, clamped <=255, ^2 (glossy)
                (local.set $dot_spec
                  (i32.sub
                    (i32.shr_s
                      (i32.mul (i32.mul (i32.const 2) (local.get $dot_diff)) (local.get $nz128))
                      (i32.const 7))
                    (local.get $lz128)))
                (if (i32.lt_s (local.get $dot_spec) (i32.const 0))
                  (then (local.set $dot_spec (i32.const 0))))
                (local.set $dot_spec (i32.shr_s (local.get $dot_spec) (i32.const 1)))
                (if (i32.gt_s (local.get $dot_spec) (i32.const 255))
                  (then (local.set $dot_spec (i32.const 255))))
                (local.set $dot_spec (i32.shr_u (i32.mul (local.get $dot_spec) (local.get $dot_spec)) (i32.const 8)))

                ;; Calyx zone: body pixels dy < -44 → green (just 1 row)
                (if (i32.and
                      (i32.gt_s (local.get $in_body) (i32.const 0))
                      (i32.lt_s (local.get $dy) (i32.const -44)))
                  (then
                    (if (i32.eqz (local.get $in_leaf))
                      (then (local.set $in_leaf (i32.const 2))))))

                ;; Seeds: read from precomputed+relaxed table at 0x10B00
                ;; Table: u16 count, then count*(dy:i8, angle:u8)
                (if (i32.and
                      (i32.gt_s (local.get $in_body) (i32.const 0))
                      (i32.eqz (local.get $in_leaf)))
                  (then
                    (local.set $sdsq (i32.load16_u (i32.const 0x10B00)))
                    (local.set $si (i32.const 0))
                    (block $sdone (loop $slp
                      (br_if $sdone (i32.or
                        (i32.ge_u (local.get $si) (local.get $sdsq))
                        (i32.gt_s (local.get $in_leaf) (i32.const 0))))
                      ;; Load seed (dy, angle) from table
                      (local.set $seed_cy (i32.load8_s (i32.add (i32.const 0x10B02) (i32.shl (local.get $si) (i32.const 1)))))
                      (local.set $seed_cx (i32.load8_u (i32.add (i32.add (i32.const 0x10B02) (i32.shl (local.get $si) (i32.const 1))) (i32.const 1))))
                      ;; Skip if pixel dy too far
                      (if (i32.le_s
                            (select
                              (i32.sub (local.get $dy) (local.get $seed_cy))
                              (i32.sub (local.get $seed_cy) (local.get $dy))
                              (i32.ge_s (local.get $dy) (local.get $seed_cy)))
                            (i32.const 4))
                        (then
                          ;; Radius at seed Y
                          (local.set $rx (i32.load8_u (i32.add (i32.const 0x10A00)
                            (i32.add (local.get $seed_cy) (i32.const 45)))))
                          (if (i32.gt_s (local.get $rx) (i32.const 0))
                            (then
                              ;; sin/cos for seed angle + rotation
                              ;; $seed_cx has angle; save sin_val in $sdx temporarily
                              (local.set $sdx (i32.sub (call $sin_tab (i32.and (i32.add (local.get $seed_cx) (local.get $rot)) (i32.const 255))) (i32.const 128)))
                              (local.set $cos_val (i32.sub (call $sin_tab (i32.and (i32.add (i32.add (local.get $seed_cx) (local.get $rot)) (i32.const 64)) (i32.const 255))) (i32.const 128)))
                              (if (i32.gt_s (local.get $cos_val) (i32.const 0))
                                (then
                                  ;; Screen x at 128x: dx*128 - rx*sin_val
                                  (local.set $norm_sq (i32.sub (i32.mul (local.get $dx) (i32.const 128))
                                    (i32.mul (local.get $rx) (local.get $sdx))))
                                  ;; sdy at 128x
                                  (local.set $guess (i32.mul (i32.sub (local.get $dy) (local.get $seed_cy)) (i32.const 128)))

                                  ;; Profile slope at seed_cy: slope = profile[idx-1] - profile[idx+1]
                                  ;; Then tilt: sdx_adj = sdx_128 - (sdy_128 * slope * sin_val) >> 7
                                  (if (i32.and
                                        (i32.ge_s (local.get $seed_cy) (i32.const -43))
                                        (i32.le_s (local.get $seed_cy) (i32.const 43)))
                                    (then
                                      ;; slope = (profile[idx+2] - profile[idx-2]) over 4 samples
                                      ;; Wider window smooths integer staircase in profile
                                      ;; cross = sdy_128 * slope * sin_val / 128
                                      ;; Reuse $seed_cx for (prof[idx+2] - prof[idx-2])
                                      (local.set $seed_cx (i32.sub
                                        (i32.load8_u (i32.add (i32.const 0x10A00) (i32.add (local.get $seed_cy) (i32.const 47))))
                                        (i32.load8_u (i32.add (i32.const 0x10A00) (i32.add (local.get $seed_cy) (i32.const 43))))))
                                      ;; Clamp slope to [-4, 4] to prevent over-tilt at steep shoulder/tip
                                      (if (i32.gt_s (local.get $seed_cx) (i32.const 4))
                                        (then (local.set $seed_cx (i32.const 4))))
                                      (if (i32.lt_s (local.get $seed_cx) (i32.const -4))
                                        (then (local.set $seed_cx (i32.const -4))))
                                      ;; sdx_adj = norm_sq - (guess * diff * sin_val) >> 9
                                      ;; ±2 window gives 2x larger diff, so shift 5+4 instead of 4+4
                                      (local.set $norm_sq (i32.sub (local.get $norm_sq)
                                        (i32.shr_s
                                          (i32.mul
                                            (i32.shr_s (i32.mul (local.get $guess) (local.get $seed_cx)) (i32.const 5))
                                            (local.get $sdx))
                                          (i32.const 4))))
                                    ))

                                  ;; Tilted foreshortened ellipse:
                                  ;; (sdx_adj)² + (sdy*cos/128)² < (R*cos/128)²
                                  (local.set $seed_cx (i32.add
                                    (i32.mul (local.get $norm_sq) (local.get $norm_sq))
                                    (i32.mul
                                      (i32.shr_s (i32.mul (local.get $guess) (local.get $cos_val)) (i32.const 7))
                                      (i32.shr_s (i32.mul (local.get $guess) (local.get $cos_val)) (i32.const 7)))))
                                  ;; R_seed=280, R_groove=440, scaled by cos
                                  (local.set $cos_val (i32.shr_s (i32.mul (i32.const 280) (local.get $cos_val)) (i32.const 7)))
                                  (if (i32.lt_u (local.get $seed_cx) (i32.mul (local.get $cos_val) (local.get $cos_val)))
                                    (then (local.set $in_leaf (i32.const 1)))
                                    (else
                                      ;; Groove: 440/280 ≈ 11/7
                                      (local.set $cos_val (i32.div_u (i32.mul (local.get $cos_val) (i32.const 11)) (i32.const 7)))
                                      (if (i32.lt_u (local.get $seed_cx) (i32.mul (local.get $cos_val) (local.get $cos_val)))
                                        (then (local.set $in_leaf (i32.const 3))))))
                                  ;; sdx/sdy at 2x for bump mapping (use adjusted sdx for tilt)
                                  (local.set $sdx (i32.shr_s (local.get $norm_sq) (i32.const 6)))
                                  (local.set $sdy (i32.shr_s (local.get $guess) (i32.const 6)))
                                ))
                            ))
                        ))
                      (local.set $si (i32.add (local.get $si) (i32.const 1)))
                      (br $slp)
                    ))
                  ))

                ;; Bump-map: seed=raised bump inside recessed groove
                ;; Groove (in_leaf==3): tilt normal TOWARD seed center (depression)
                ;; Seed (in_leaf==1): tilt normal AWAY from center (raised bump)
                (if (i32.or (i32.eq (local.get $in_leaf) (i32.const 3))
                            (i32.eq (local.get $in_leaf) (i32.const 1)))
                  (then
                    ;; Groove: -sdx (inward=pit), Seed: +sdx (outward=bump)
                    (if (i32.eq (local.get $in_leaf) (i32.const 3))
                      (then
                        ;; Depression: normals tilt toward center (sdx/sdy are 2x scaled)
                        (local.set $nx128 (i32.sub (local.get $nx128)
                          (i32.mul (local.get $sdx) (i32.const 14))))
                        (local.set $ny128 (i32.sub (local.get $ny128)
                          (i32.mul (local.get $sdy) (i32.const 14)))))
                      (else
                        ;; Raised seed: subtle outward tilt
                        (local.set $nx128 (i32.add (local.get $nx128)
                          (i32.mul (local.get $sdx) (i32.const 10))))
                        (local.set $ny128 (i32.add (local.get $ny128)
                          (i32.mul (local.get $sdy) (i32.const 10))))))
                    ;; Clamp
                    (if (i32.gt_s (local.get $nx128) (i32.const 127))
                      (then (local.set $nx128 (i32.const 127))))
                    (if (i32.lt_s (local.get $nx128) (i32.const -127))
                      (then (local.set $nx128 (i32.const -127))))
                    (if (i32.gt_s (local.get $ny128) (i32.const 127))
                      (then (local.set $ny128 (i32.const 127))))
                    (if (i32.lt_s (local.get $ny128) (i32.const -127))
                      (then (local.set $ny128 (i32.const -127))))
                    ;; Recompute nz
                    (local.set $norm_sq
                      (i32.sub (i32.const 16384)
                        (i32.add
                          (i32.mul (local.get $nx128) (local.get $nx128))
                          (i32.mul (local.get $ny128) (local.get $ny128)))))
                    (if (i32.lt_s (local.get $norm_sq) (i32.const 1))
                      (then (local.set $norm_sq (i32.const 1))))
                    (local.set $guess (i32.const 64))
                    (local.set $guess (i32.shr_u (i32.add (local.get $guess) (i32.div_u (local.get $norm_sq) (local.get $guess))) (i32.const 1)))
                    (local.set $guess (i32.shr_u (i32.add (local.get $guess) (i32.div_u (local.get $norm_sq) (local.get $guess))) (i32.const 1)))
                    (local.set $guess (i32.shr_u (i32.add (local.get $guess) (i32.div_u (local.get $norm_sq) (local.get $guess))) (i32.const 1)))
                    (local.set $nz128 (local.get $guess))
                    ;; Recompute diffuse with perturbed normal
                    (local.set $dot_diff
                      (i32.shr_s
                        (i32.add
                          (i32.add
                            (i32.mul (local.get $nx128) (local.get $lx128))
                            (i32.mul (local.get $ny128) (local.get $ly128)))
                          (i32.mul (local.get $nz128) (local.get $lz128)))
                        (i32.const 7)))
                    (if (i32.lt_s (local.get $dot_diff) (i32.const 0))
                      (then (local.set $dot_diff (i32.const 0))))
                    ;; Groove → berry body red ramp; seed keeps in_leaf=1
                    (if (i32.eq (local.get $in_leaf) (i32.const 3))
                      (then (local.set $in_leaf (i32.const 0))))
                  ))

                ;; ---- Color determination ----
                ;; All materials use full ramps with specular baked in (dark → color → white)
                ;; Priority: leaf/calyx (2,5) > stem (4) > seed (1) > berry body (0)
                (local.set $col (i32.const 48))

                (if (i32.or (i32.eq (local.get $in_leaf) (i32.const 2)) (i32.eq (local.get $in_leaf) (i32.const 5)))
                  (then
                    ;; Green leaf: 12-shade ramp (84-95), matte (no spec), vein uses bottom half
                    (local.set $shade (i32.div_u (local.get $dot_diff) (i32.const 21)))
                    ;; Vein: cap at shade 4 (dark end of ramp)
                    (if (i32.eq (local.get $in_leaf) (i32.const 5))
                      (then
                        (if (i32.gt_s (local.get $shade) (i32.const 4))
                          (then (local.set $shade (i32.const 4))))))
                    (if (i32.gt_s (local.get $shade) (i32.const 11))
                      (then (local.set $shade (i32.const 11))))
                    (if (i32.lt_s (local.get $shade) (i32.const 0))
                      (then (local.set $shade (i32.const 0))))
                    (local.set $col (i32.add (i32.const 84) (local.get $shade))))
                  (else (if (i32.eq (local.get $in_leaf) (i32.const 4))
                    (then
                      ;; Stem: 6-shade brown ramp (96-101)
                      (local.set $shade (i32.div_u (local.get $dot_diff) (i32.const 42)))
                      (if (i32.gt_s (local.get $shade) (i32.const 5))
                        (then (local.set $shade (i32.const 5))))
                      (local.set $col (i32.add (i32.const 96) (local.get $shade))))
                    (else (if (i32.eq (local.get $in_leaf) (i32.const 1))
                      (then
                        ;; Seed: 12-shade yellow ramp (72-83)
                        ;; shade = dot_diff / 21 + spec/24
                        (local.set $shade (i32.div_u (local.get $dot_diff) (i32.const 21)))
                        (local.set $shade (i32.add (local.get $shade)
                          (i32.div_u (local.get $dot_spec) (i32.const 24))))
                        (if (i32.gt_s (local.get $shade) (i32.const 11))
                          (then (local.set $shade (i32.const 11))))
                        (if (i32.lt_s (local.get $shade) (i32.const 0))
                          (then (local.set $shade (i32.const 0))))
                        (local.set $col (i32.add (i32.const 72) (local.get $shade))))
                      (else
                          ;; Berry body: 24-shade red ramp (48-71) with glossy specular
                          ;; shade = dot_diff / 11 + dither + spec/12
                          (local.set $shade (i32.div_u (local.get $dot_diff) (i32.const 11)))
                          ;; Specular boost
                          (local.set $shade (i32.add (local.get $shade)
                            (i32.div_u (local.get $dot_spec) (i32.const 12))))
                          (if (i32.gt_s (local.get $shade) (i32.const 23))
                            (then (local.set $shade (i32.const 23))))
                          (if (i32.lt_s (local.get $shade) (i32.const 0))
                            (then (local.set $shade (i32.const 0))))
                          (local.set $col (i32.add (i32.const 48) (local.get $shade)))
                    ))
                  ))
                ))

                ;; Ambient occlusion under calyx: smooth gradient darkening
                ;; dy -44 to -36: darken by (44+dy) inverted, so -44→4, -43→3, -42→2, ..., -37→1, -36→0
                (if (i32.and
                      (i32.gt_s (local.get $in_body) (i32.const 0))
                      (i32.and
                        (i32.eqz (local.get $in_leaf))
                        (i32.and
                          (i32.ge_s (local.get $dy) (i32.const -44))
                          (i32.le_s (local.get $dy) (i32.const -37)))))
                  (then
                    ;; darken = (-37 - dy) / 2  → -44→3, -43→3, -42→2, -41→2, -40→1, -39→1, -38→0, -37→0
                    (local.set $shade (i32.shr_u (i32.sub (i32.const -37) (local.get $dy)) (i32.const 1)))
                    (if (i32.and
                          (i32.gt_s (local.get $shade) (i32.const 0))
                          (i32.and
                            (i32.ge_s (local.get $col) (i32.add (i32.const 48) (local.get $shade)))
                            (i32.le_s (local.get $col) (i32.const 71))))
                      (then (local.set $col (i32.sub (local.get $col) (local.get $shade)))))))

                ;; Write pixel
                (i32.store8
                  (i32.add (i32.const 0x0340)
                    (i32.add (i32.mul (local.get $py) (i32.const 320)) (local.get $px)))
                  (local.get $col))
              ))
          ))

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

    ;; Strawberry radius profile is stored as a data segment at 0x10A00 (91 bytes)
    ;; Hand-tuned smooth curve: quick widen, holds width, very gentle taper to soft tip
    ;; No formula — just the right shape, guaranteed smooth.

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

    ;; Generate seed table for strawberry
    (call $init_seeds)
  )

  ;; =========================================================
  ;; Generate strawberry seed positions with relaxation
  ;; Table at 0x10B00: u16 count, then count*(dy:i8, angle:u8)
  ;; =========================================================
  (func $init_seeds
    (local $row_y i32) (local $num i32) (local $idx i32) (local $si i32)
    (local $rx i32) (local $angle i32) (local $base i32) (local $count i32)
    (local $pass i32) (local $j i32) (local $addr_i i32) (local $addr_j i32)
    (local $dy_i i32) (local $a_i i32) (local $dy_j i32) (local $a_j i32)
    (local $dd i32) (local $da i32) (local $dist_sq i32) (local $rx_avg i32)
    (local $circ i32)

    (local.set $count (i32.const 0))

    ;; Generate seeds: rows from -35 to 38, step 7
    (local.set $row_y (i32.const -42))
    (block $rdone (loop $rlp
      (br_if $rdone (i32.gt_s (local.get $row_y) (i32.const 38)))

      ;; Get radius at row midpoint for seed count
      (local.set $rx (i32.const 10))
      (if (i32.and
            (i32.ge_s (i32.add (local.get $row_y) (i32.const 3)) (i32.const -45))
            (i32.le_s (i32.add (local.get $row_y) (i32.const 3)) (i32.const 45)))
        (then
          (local.set $rx (i32.load8_u (i32.add (i32.const 0x10A00)
            (i32.add (i32.add (local.get $row_y) (i32.const 3)) (i32.const 45)))))))

      ;; num = rx/2, clamped 5..20
      (local.set $num (i32.shr_u (local.get $rx) (i32.const 1)))
      (if (i32.lt_s (local.get $num) (i32.const 5))
        (then (local.set $num (i32.const 5))))
      (if (i32.gt_s (local.get $num) (i32.const 20))
        (then (local.set $num (i32.const 20))))

      ;; Base angle: row_index * 6
      (local.set $base (i32.and
        (i32.mul
          (i32.div_u (i32.add (local.get $row_y) (i32.const 42)) (i32.const 7))
          (i32.const 6))
        (i32.const 255)))

      ;; Generate seeds for this row
      (local.set $si (i32.const 0))
      (block $sdone (loop $slp
        (br_if $sdone (i32.ge_u (local.get $si) (local.get $num)))

        ;; angle = (base + i * 256 / num) & 255
        (local.set $angle (i32.and
          (i32.add (local.get $base)
            (i32.div_u (i32.mul (local.get $si) (i32.const 256)) (local.get $num)))
          (i32.const 255)))

        ;; dy = row_y + angle*7/256 (spiral offset)
        (local.set $idx (i32.add (local.get $row_y)
          (i32.shr_u (i32.mul (local.get $angle) (i32.const 7)) (i32.const 8))))

        ;; Only store if within profile range and radius > 0
        (if (i32.and
              (i32.ge_s (local.get $idx) (i32.const -45))
              (i32.le_s (local.get $idx) (i32.const 45)))
          (then
            (if (i32.gt_s (i32.load8_u (i32.add (i32.const 0x10A00)
                  (i32.add (local.get $idx) (i32.const 45)))) (i32.const 0))
              (then
                ;; Store: 0x10B02 + count*2 = (dy, angle)
                (i32.store8 (i32.add (i32.const 0x10B02) (i32.shl (local.get $count) (i32.const 1)))
                  (local.get $idx))
                (i32.store8 (i32.add (i32.add (i32.const 0x10B02) (i32.shl (local.get $count) (i32.const 1))) (i32.const 1))
                  (local.get $angle))
                (local.set $count (i32.add (local.get $count) (i32.const 1)))
              ))))

        (local.set $si (i32.add (local.get $si) (i32.const 1)))
        (br $slp)
      ))

      (local.set $row_y (i32.add (local.get $row_y) (i32.const 7)))
      (br $rlp)
    ))

    ;; Store count
    (i32.store16 (i32.const 0x10B00) (local.get $count))

    ;; Sort seeds by dy (bubble sort — small N, runs once at init)
    (local.set $pass (i32.const 1))
    (block $sdone2 (loop $slp2
      (br_if $sdone2 (i32.eqz (local.get $pass)))
      (local.set $pass (i32.const 0))
      (local.set $si (i32.const 0))
      (block $idone2 (loop $ilp2
        (br_if $idone2 (i32.ge_u (local.get $si) (i32.sub (local.get $count) (i32.const 1))))
        (local.set $addr_i (i32.add (i32.const 0x10B02) (i32.shl (local.get $si) (i32.const 1))))
        (local.set $addr_j (i32.add (local.get $addr_i) (i32.const 2)))
        (if (i32.gt_s (i32.load8_s (local.get $addr_i)) (i32.load8_s (local.get $addr_j)))
          (then
            ;; Swap 2-byte entries
            (local.set $dy_i (i32.load16_u (local.get $addr_i)))
            (i32.store16 (local.get $addr_i) (i32.load16_u (local.get $addr_j)))
            (i32.store16 (local.get $addr_j) (local.get $dy_i))
            (local.set $pass (i32.const 1))))
        (local.set $si (i32.add (local.get $si) (i32.const 1)))
        (br $ilp2)
      ))
      (br $slp2)
    ))

    ;; Relaxation: 6 passes, push overlapping seeds apart
    (local.set $pass (i32.const 0))
    (block $pdone (loop $plp
      (br_if $pdone (i32.ge_u (local.get $pass) (i32.const 6)))

      (local.set $si (i32.const 0))
      (block $idone (loop $ilp
        (br_if $idone (i32.ge_u (local.get $si) (local.get $count)))
        (local.set $addr_i (i32.add (i32.const 0x10B02) (i32.shl (local.get $si) (i32.const 1))))
        (local.set $dy_i (i32.load8_s (local.get $addr_i)))
        (local.set $a_i (i32.load8_u (i32.add (local.get $addr_i) (i32.const 1))))

        ;; Compare with next 15 seeds (sorted by dy, so nearby = nearby on surface)
        (local.set $j (i32.add (local.get $si) (i32.const 1)))
        (block $jdone (loop $jlp
          (br_if $jdone (i32.or
            (i32.ge_u (local.get $j) (local.get $count))
            (i32.gt_u (i32.sub (local.get $j) (local.get $si)) (i32.const 15))))
          (local.set $addr_j (i32.add (i32.const 0x10B02) (i32.shl (local.get $j) (i32.const 1))))
          (local.set $dy_j (i32.load8_s (local.get $addr_j)))
          (local.set $a_j (i32.load8_u (i32.add (local.get $addr_j) (i32.const 1))))

          ;; dy distance
          (local.set $dd (i32.sub (local.get $dy_i) (local.get $dy_j)))
          ;; Skip if dy too far (> 8)
          (if (i32.le_s
                (select (local.get $dd) (i32.sub (i32.const 0) (local.get $dd)) (i32.ge_s (local.get $dd) (i32.const 0)))
                (i32.const 8))
            (then
              ;; Angular distance (shortest arc on 256-circle)
              (local.set $da (i32.sub (local.get $a_i) (local.get $a_j)))
              (if (i32.gt_s (local.get $da) (i32.const 128))
                (then (local.set $da (i32.sub (local.get $da) (i32.const 256)))))
              (if (i32.lt_s (local.get $da) (i32.const -128))
                (then (local.set $da (i32.add (local.get $da) (i32.const 256)))))

              ;; Surface distance²: dd² + (da * rx_avg / 41)²
              ;; rx_avg from profile at midpoint dy
              (local.set $rx_avg (i32.const 20))
              (local.set $idx (i32.shr_s (i32.add (local.get $dy_i) (local.get $dy_j)) (i32.const 1)))
              (if (i32.and (i32.ge_s (local.get $idx) (i32.const -45)) (i32.le_s (local.get $idx) (i32.const 45)))
                (then (local.set $rx_avg (i32.load8_u (i32.add (i32.const 0x10A00) (i32.add (local.get $idx) (i32.const 45)))))))
              ;; circ_dist = da * rx_avg / 41 (arc length in pixels)
              (local.set $circ (i32.div_s (i32.mul (local.get $da) (local.get $rx_avg)) (i32.const 41)))
              (local.set $dist_sq (i32.add (i32.mul (local.get $dd) (local.get $dd)) (i32.mul (local.get $circ) (local.get $circ))))

              ;; If too close (< 6²=36 pixels), push angles apart by 2
              (if (i32.lt_s (local.get $dist_sq) (i32.const 36))
                (then
                  ;; Push i's angle away from j (direction based on da sign)
                  (if (i32.ge_s (local.get $da) (i32.const 0))
                    (then
                      (i32.store8 (i32.add (local.get $addr_i) (i32.const 1))
                        (i32.and (i32.add (local.get $a_i) (i32.const 2)) (i32.const 255)))
                      (i32.store8 (i32.add (local.get $addr_j) (i32.const 1))
                        (i32.and (i32.sub (local.get $a_j) (i32.const 2)) (i32.const 255))))
                    (else
                      (i32.store8 (i32.add (local.get $addr_i) (i32.const 1))
                        (i32.and (i32.sub (local.get $a_i) (i32.const 2)) (i32.const 255)))
                      (i32.store8 (i32.add (local.get $addr_j) (i32.const 1))
                        (i32.and (i32.add (local.get $a_j) (i32.const 2)) (i32.const 255)))))
                  ;; Reload a_i since it may have changed
                  (local.set $a_i (i32.load8_u (i32.add (local.get $addr_i) (i32.const 1))))
                ))
            ))

          (local.set $j (i32.add (local.get $j) (i32.const 1)))
          (br $jlp)
        ))

        (local.set $si (i32.add (local.get $si) (i32.const 1)))
        (br $ilp)
      ))

      (local.set $pass (i32.add (local.get $pass) (i32.const 1)))
      (br $plp)
    ))
  )

  ;; =========================================================
  ;; UTILITY: apply fade to entire palette (factor 0-255)
  ;; =========================================================
  (func $apply_fade (param $factor i32)
    (local $i i32) (local $addr i32) (local $r i32) (local $g i32) (local $b i32)
    (if (i32.ge_u (local.get $factor) (i32.const 255)) (then (return)))
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 256)))
      (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
      (local.set $r (i32.load8_u (local.get $addr)))
      (local.set $g (i32.load8_u (i32.add (local.get $addr) (i32.const 1))))
      (local.set $b (i32.load8_u (i32.add (local.get $addr) (i32.const 2))))
      (i32.store8 (local.get $addr) (i32.shr_u (i32.mul (local.get $r) (local.get $factor)) (i32.const 8)))
      (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (i32.shr_u (i32.mul (local.get $g) (local.get $factor)) (i32.const 8)))
      (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (i32.shr_u (i32.mul (local.get $b) (local.get $factor)) (i32.const 8)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)
    ))
  )

  ;; =========================================================
  ;; FRAME — main dispatcher
  ;; =========================================================
  (func (export "frame")
    (local $tick_ms i32) (local $elapsed i32) (local $section i32)
    (local $last_section i32) (local $input i32) (local $prev_input i32)
    (local $next_boundary i32) (local $sec_start i32) (local $sec_end i32)
    (local $t_in i32) (local $t_left i32) (local $fade i32)

    ;; Read current tick
    (local.set $tick_ms (i32.load (i32.const 0x0C)))

    ;; Compute elapsed time since init (no modulo — last scene stays forever)
    (local.set $elapsed
      (i32.sub (local.get $tick_ms) (i32.load (i32.const 0x38004))))

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
          (then (local.set $next_boundary (i32.const 0))))  ;; section 4: restart to beginning
        ;; Shift start_tick backward so elapsed jumps to next_boundary
        (i32.store (i32.const 0x38004)
          (i32.sub (local.get $tick_ms) (local.get $next_boundary)))
        ;; Recompute elapsed and section
        (local.set $elapsed
          (i32.sub (local.get $tick_ms) (i32.load (i32.const 0x38004))))
        (local.set $section (i32.const 0))
        (if (i32.ge_u (local.get $elapsed) (i32.const 8000))
          (then (local.set $section (i32.const 1))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 20000))
          (then (local.set $section (i32.const 2))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 32000))
          (then (local.set $section (i32.const 3))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 44000))
          (then (local.set $section (i32.const 4))))
      ))

    ;; Rising edge on left(4) → previous section
    (if (i32.and
      (i32.and (local.get $input) (i32.xor (local.get $prev_input) (i32.const 0xFFFFFFFF)))
      (i32.const 4))
      (then
        ;; Compute previous section boundary
        (local.set $next_boundary (i32.const 44000))  ;; wrap to last section
        (if (i32.ge_u (local.get $elapsed) (i32.const 8000))
          (then (local.set $next_boundary (i32.const 0))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 20000))
          (then (local.set $next_boundary (i32.const 8000))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 32000))
          (then (local.set $next_boundary (i32.const 20000))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 44000))
          (then (local.set $next_boundary (i32.const 32000))))
        ;; Shift start_tick so elapsed jumps to prev boundary
        (i32.store (i32.const 0x38004)
          (i32.sub (local.get $tick_ms) (local.get $next_boundary)))
        ;; Recompute elapsed and section
        (local.set $elapsed
          (i32.sub (local.get $tick_ms) (i32.load (i32.const 0x38004))))
        (local.set $section (i32.const 0))
        (if (i32.ge_u (local.get $elapsed) (i32.const 8000))
          (then (local.set $section (i32.const 1))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 20000))
          (then (local.set $section (i32.const 2))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 32000))
          (then (local.set $section (i32.const 3))))
        (if (i32.ge_u (local.get $elapsed) (i32.const 44000))
          (then (local.set $section (i32.const 4))))
      ))

    ;; On section change: set up palette and re-init PRNG for consistency
    (local.set $last_section (i32.load (i32.const 0x38008)))
    (if (i32.ne (local.get $section) (local.get $last_section))
      (then
        (i32.store (i32.const 0x38008) (local.get $section))
        ;; dispatch palette setup
        (if (i32.eqz (local.get $section))            (then (call $pal_rain)))
        (if (i32.eq (local.get $section) (i32.const 1)) (then (call $pal_grave)))
        (if (i32.eq (local.get $section) (i32.const 2)) (then (call $pal_plasma)))
        (if (i32.eq (local.get $section) (i32.const 3)) (then (call $pal_scroll)))
        (if (i32.eq (local.get $section) (i32.const 4)) (then (call $pal_berrry)))
        ;; start music: load address from lookup table at 0x10900
        (call $music (i32.load (i32.add (i32.const 0x10900) (i32.mul (local.get $section) (i32.const 4)))))
      )
    )

    ;; Dispatch render
    (if (i32.eqz (local.get $section))            (then (call $render_rain (local.get $elapsed))))
    (if (i32.eq (local.get $section) (i32.const 1)) (then (call $render_grave (local.get $elapsed))))
    (if (i32.eq (local.get $section) (i32.const 2)) (then (call $render_plasma (local.get $elapsed))))
    (if (i32.eq (local.get $section) (i32.const 3)) (then (call $render_scroll (local.get $elapsed))))
    (if (i32.eq (local.get $section) (i32.const 4)) (then (call $render_berrry (local.get $elapsed))))

    ;; Global fade: fade in first 500ms, fade out last 500ms of each section
    ;; Compute section start/end boundaries
    (local.set $sec_start (i32.const 0))
    (local.set $sec_end (i32.const 8000))
    (if (i32.ge_u (local.get $section) (i32.const 1))
      (then (local.set $sec_start (i32.const 8000)) (local.set $sec_end (i32.const 20000))))
    (if (i32.ge_u (local.get $section) (i32.const 2))
      (then (local.set $sec_start (i32.const 20000)) (local.set $sec_end (i32.const 32000))))
    (if (i32.ge_u (local.get $section) (i32.const 3))
      (then (local.set $sec_start (i32.const 32000)) (local.set $sec_end (i32.const 44000))))
    (if (i32.ge_u (local.get $section) (i32.const 4))
      (then (local.set $sec_start (i32.const 44000)) (local.set $sec_end (i32.const 0x7FFFFFFF))))

    (local.set $t_in (i32.sub (local.get $elapsed) (local.get $sec_start)))
    (local.set $t_left (i32.sub (local.get $sec_end) (local.get $elapsed)))
    (local.set $fade (i32.const 255))

    ;; Fade in: first 500ms
    (if (i32.lt_u (local.get $t_in) (i32.const 500))
      (then (local.set $fade (i32.div_u (i32.mul (local.get $t_in) (i32.const 255)) (i32.const 500)))))
    ;; Fade out: last 500ms (use minimum of fade-in and fade-out)
    (if (i32.lt_u (local.get $t_left) (i32.const 500))
      (then (local.set $fade (select
        (local.get $fade)
        (i32.div_u (i32.mul (local.get $t_left) (i32.const 255)) (i32.const 500))
        (i32.lt_u (local.get $fade)
          (i32.div_u (i32.mul (local.get $t_left) (i32.const 255)) (i32.const 500)))))))

    ;; Only apply fade when actually fading (not at full brightness)
    ;; Must re-setup palette first since fade is destructive
    (if (i32.lt_u (local.get $fade) (i32.const 255))
      (then
        (if (i32.eqz (local.get $section))            (then (call $pal_rain)))
        (if (i32.eq (local.get $section) (i32.const 1)) (then (call $pal_grave)))
        (if (i32.eq (local.get $section) (i32.const 2)) (then (call $pal_plasma)))
        (if (i32.eq (local.get $section) (i32.const 3)) (then (call $pal_scroll)))
        (if (i32.eq (local.get $section) (i32.const 4)) (then (call $pal_berrry)))
        (call $apply_fade (local.get $fade))))
  )

  ;; =========================================================
  ;; DATA SEGMENTS
  ;; =========================================================

  ;; 8x8 bitmap font at 0x10440: 96 chars (ASCII 32-127), 8 bytes each
  ;; (copied from scroller.wat)
  (data (i32.const 0x10440) "\00\00\00\00\00\00\00\00\00\18\00\18\18\18\18\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00<\00\00\00\00\18\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00<fffff<\00~\18\18\18\188\18\00~`0\0c\06f<\00<f\06\1c\06f<\00\0c\0c~L,\1c\0c\00<f\06\06|`~\00<ff|``<\00000\18\0c\06~\00<ff<ff<\00<\06\06>ff<\00\00\18\00\00\18\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00ff~ff<\18\00|ff|ff|\00<f```f<\00|fcccf|\00~``|``~\00```|``~\00<ffn`f<\00fff~fff\00<\18\18\18\18\18<\00<f\06\06\06\06\06\00flxpxlf\00~``````\00ccck\7fwc\00fnn~vvf\00<fffff<\00```|ff|\00\0e<nfff<\00ffl|ff|\00<f\06<`f<\00\18\18\18\18\18\18~\00<ffffff\00\18<fffff\00cw\7fkccc\00ff<\18<ff\00\18\18\18<fff\00~`0\18\0c\06~\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00")

  ;; Strings
  (data (i32.const 0x10740) "CODING IS OVER")
  (data (i32.const 0x10750) "BERRRY.APP")
  (data (i32.const 0x10760) "BERRRY.APP PRESENTS")
  (data (i32.const 0x10780) "INTENT NOT SYNTAX")
  (data (i32.const 0x107C0) "  YOU DESCRIBE IT             THE MACHINE WRITES          ASSEMBLY                    NOT CODE   ASSEMBLY         EVERY LINE OF THIS DEMO     WRITTEN FROM INTENT         NO LANGUAGE IN BETWEEN      ENGLISH IN WEBASSEMBLY OUT  TRY IT ON BERRRY.APP      ")
  (data (i32.const 0x108C0) "WASMVGA-DEMOS.BERRRY.APP")
  (data (i32.const 0x108E0) "C\00JAVA\00PYTHON\00RUST\00JS\00GO\00")
  (data (i32.const 0x10960) "WASM")
  (data (i32.const 0x10964) "VGA")
  (data (i32.const 0x10968) "MODE 13H")

  ;; Music pattern address lookup table (5 entries × 4 bytes at 0x10900)
  ;; section 0→0x20000, 1→0x20100, 2→0x20200, 3→0x20300, 4→0x20400
  (data (i32.const 0x10900) "\00\00\02\00\00\01\02\00\00\02\02\00\00\03\02\00\00\04\02\00")

  ;; Strawberry radius profile: 91 bytes at 0x10A00 (dy=-45..+45)
  ;; Traced from photo reference, smoothed monotonic.
  ;; Widest belt at dy=-24..-13, smooth taper to point at bottom.
  ;; i: 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19
  ;; r: 0 15 24 27 28 29 30 31 32 33 34 34 35 35 36 36 36 37 37 37
  ;; i:20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39
  ;; r:37 38 38 38 38 38 38 38 38 38 38 38 38 37 37 37 37 37 36 36
  ;; i:40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59
  ;; r:36 36 35 35 35 34 34 34 33 33 32 32 31 31 30 30 29 29 28 28
  ;; i:60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79
  ;; r:27 26 25 25 24 23 23 22 21 21 20 19 19 18 18 17 16 15 15 14
  ;; i:80 81 82 83 84 85 86 87 88 89 90
  ;; r:13 12 12 11 10  9  7  6  4  2  0
  (data (i32.const 0x10A00) "\00\0f\18\1b\1c\1d\1e\1f\20\21\22\22\23\23\24\24\24\25\25\25\25\26\26\26\26\26\26\26\26\26\26\26\26\25\25\25\25\25\24\24\24\24\23\23\23\22\22\22\21\21\20\20\1f\1f\1e\1e\1d\1d\1c\1c\1b\1a\19\19\18\17\17\16\15\15\14\13\13\12\12\11\10\0f\0f\0e\0d\0c\0c\0b\0a\09\07\06\04\02\00")

  ;; Strawberry seed table at 0x10B00 — generated by $init_seeds at runtime
  ;; Format: u16 count, then count*(dy:i8, angle:u8)

  ;; Music patterns (MIDI-note format, read by harness from memory)
  ;; Pattern 5: CODE RAIN (90 BPM, Am)
  ;; Bass: A2/D2/E2 pulse. Arp: Am/F/Dm arps. Lead: sparse A5/E5/D5.
  ;; Bar 3 uses Dm arp to foreshadow graveyard section.
  (data (i32.const 0x20000) "\5a\00\40\03\03\8c\23\00\00\50\0f\00\01\3c\05\00\2d\00\00\00\00\00\2d\00\00\00\00\00\2d\00\00\00\26\00\00\00\00\00\26\00\00\00\00\00\26\00\00\00\28\00\00\00\00\00\28\00\00\00\00\00\28\00\00\00\2d\00\00\00\00\00\00\00\2d\00\00\00\00\00\2d\00\45\00\40\00\3c\00\39\00\3c\00\40\00\45\00\00\00\41\00\3c\00\39\00\35\00\39\00\3c\00\41\00\00\00\4a\00\45\00\41\00\3e\00\41\00\45\00\4a\00\00\00\45\00\40\00\3c\00\39\00\34\00\00\00\39\00\3c\00\00\00\00\00\00\00\51\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\4c\00\00\00\00\00\00\00\00\00\00\00\4a\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\51\00")
  ;; Pattern 6: GRAVEYARD (65 BPM)
  (data (i32.const 0x20100) "\41\00\40\03\02\b4\32\00\00\8c\3c\00\03\78\28\00\26\00\00\00\00\00\00\00\26\00\00\00\00\00\26\00\22\00\00\00\00\00\00\00\22\00\00\00\00\00\00\00\1f\00\00\00\00\00\00\00\1f\00\00\00\00\00\1f\00\26\00\00\00\00\00\26\00\00\00\00\00\26\00\00\00\3e\00\00\00\41\00\00\00\00\00\00\00\3c\00\00\00\3a\00\00\00\3d\00\00\00\00\00\00\00\41\00\00\00\37\00\00\00\3a\00\00\00\00\00\00\00\3e\00\00\00\3e\00\00\00\3c\00\00\00\00\00\00\00\39\00\00\00\4a\00\00\00\00\00\00\00\48\00\00\00\00\00\00\00\46\00\00\00\00\00\00\00\00\00\00\00\41\00\00\00\43\00\00\00\00\00\00\00\41\00\00\00\00\00\00\00\4a\00\00\00\00\00\48\00\00\00\00\00\45\00\00\00")
  ;; Pattern 8: INTENT NOT SYNTAX — industrial (80 BPM)
  ;; Key: Dm→Am. Bar1 sparse (glitch), bars 2-4 heavy driving (text on screen).
  ;; Bass: D2 sparse → A2 relentless. Stabs: F4/E4/A4 building. Texture: A5/E5/D5 saw.
  (data (i32.const 0x20200) "\50\00\40\03\03\55\28\00\01\37\0c\00\02\23\14\00\26\00\00\00\00\00\00\00\26\00\00\00\00\00\00\00\2d\00\2d\00\00\00\2d\00\2d\00\00\00\2d\00\2d\00\2d\00\2d\00\2d\00\00\00\2d\00\2d\00\2d\00\00\00\2d\2d\00\00\2d\2d\00\00\2d\00\00\00\26\00\2d\00\00\00\00\00\00\00\00\00\00\00\00\00\3a\00\00\00\41\00\00\00\40\00\00\00\41\00\00\00\40\00\00\00\45\00\00\00\41\00\00\00\40\00\00\00\3c\00\00\00\45\00\40\00\45\00\00\00\40\00\45\00\00\00\40\00\00\00\00\00\00\00\00\00\4a\00\00\00\00\00\00\00\45\00\00\00\00\00\00\00\4c\00\00\00\00\00\00\00\00\00\00\00\51\00\00\00\00\00\00\00\4c\00\00\00\51\00\00\00\00\00\51\00\00\00\4c\00\51\00\00\00")
  ;; Pattern 9: SCROLLER (105 BPM, Am→Dm→Em→Am)
  ;; Bass: Am/Dm/Em root pulse. Arp: continuous 16th arps. Lead: melody connecting sections.
  (data (i32.const 0x20300) "\69\00\40\03\03\46\1e\00\00\14\12\00\03\28\19\00\2d\00\00\00\2d\00\00\00\00\00\2d\00\00\00\2d\00\26\00\00\00\26\00\00\00\00\00\26\00\00\00\26\00\28\00\00\00\28\00\00\00\00\00\28\00\00\00\28\00\2d\00\00\00\2d\00\00\00\2d\00\00\2d\00\00\2d\00\39\40\45\40\39\45\48\45\40\39\45\40\48\45\40\39\32\39\3e\39\32\3e\41\3e\39\32\3e\39\41\3e\39\32\34\3b\40\3b\34\40\43\40\3b\34\40\3b\43\40\3b\34\39\40\45\40\39\45\4c\45\40\39\45\40\4c\45\40\39\45\00\48\00\4c\00\00\00\48\00\45\00\00\00\00\00\3e\00\41\00\45\00\00\00\41\00\3e\00\00\00\00\00\40\00\43\00\47\00\00\00\43\00\40\00\00\00\00\00\45\00\40\00\3c\00\00\00\3e\00\40\00\45\00\48\00")
  ;; Pattern 10: BERRRY FINALE (130 BPM, Am triumphant)
  ;; Bass: driving Am→C→F→E with walkup ending. Arp: bright 16th arps.
  ;; Lead: triumphant melody resolving to Am. Bar4 walks E→G→A back to loop.
  (data (i32.const 0x20400) "\82\00\40\03\03\32\0c\00\01\16\08\00\01\23\0a\00\2d\00\2d\00\00\00\2d\2d\2d\00\2d\00\00\2d\00\00\30\00\30\00\00\00\30\30\30\00\30\00\00\30\00\00\29\00\29\00\00\00\29\29\29\00\29\00\00\29\00\00\28\00\28\00\00\00\28\28\28\00\28\00\2b\00\2d\00\45\48\4c\51\4c\48\45\4c\51\4c\48\4c\51\00\4c\48\48\4c\4f\54\4f\4c\48\4c\4f\4c\48\4c\4f\00\4c\48\41\45\48\4d\48\45\41\45\48\45\41\45\48\00\45\41\40\43\47\4c\47\43\40\43\4c\47\43\47\4c\00\48\45\51\00\00\51\00\00\54\00\51\00\00\00\4c\00\51\00\4f\00\00\4c\00\00\4f\00\00\4c\00\48\00\00\00\00\4d\00\00\51\00\00\4d\00\00\48\00\45\00\00\00\00\4c\00\4f\00\51\00\00\00\4f\00\4c\00\48\00\45\00")
)
