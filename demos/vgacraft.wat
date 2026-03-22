(module
  (import "env" "memory" (memory 8))
  (import "env" "sfx" (func $sfx (param i32)))
  (import "env" "note" (func $note (param i32 i32 i32 i32)))

  ;; ============================================================
  ;; VGACraft — Duke Nukem 3D meets Minecraft
  ;; ============================================================
  ;; Infinite procedural voxel world with billboard sprite monsters
  ;; Raycasting engine renders terrain columns with block textures
  ;; WASD to move, Left/Right arrows to turn, Space to dig/place
  ;; Mouse click to dig block, Shift+click to place
  ;;
  ;; Memory layout:
  ;;   0x10040  Palette setup area
  ;;   0x10340  PRNG state (4 bytes)
  ;;   0x10344  Player state (64 bytes)
  ;;     +0: px (f64) world X
  ;;     +8: py (f64) world Y (horizontal plane)
  ;;     +16: angle (f64) facing direction
  ;;     +24: pz (f64) player Z height
  ;;     +32: vz (f64) vertical velocity
  ;;     +40: on_ground (i32)
  ;;     +44: bob_phase (f64) - actually at +48
  ;;   0x10390  Game state (32 bytes)
  ;;     +0: mod_count (i32) - number of modifications stored
  ;;     +4: max_mods (i32) - max modifications allowed
  ;;     +8: gods_angry (i32) - 1 if memory full
  ;;     +12: msg_timer (i32) - frames to show message
  ;;     +16: dig_cooldown (i32)
  ;;     +20: prev_mouse (i32) - previous mouse button state
  ;;     +24: selected_block (i32) - block type to place
  ;;   0x103B0  zbuffer (320 * 8 = 2560 bytes) → ends at 0x10DB0
  ;;   0x10E00  Monster array (32 monsters * 32 bytes = 1024) → ends at 0x11200
  ;;     per monster: active(i32), type(i32), wx(f64), wy(f64), hp(i32), anim(i32), pad
  ;;   0x11200  Modification table (max ~2048 entries * 16 bytes = 32768) → ends at 0x19200
  ;;     per mod: chunk_x(i32), chunk_y(i32), local_idx(i32), block_type(i32)
  ;;   0x19200  Font data (reuse from other demos)
  ;;   0x19600  Scratch/temp
  ;; ============================================================

  ;; Constants
  ;; Block types: 0=air, 1=grass, 2=dirt, 3=stone, 4=sand, 5=water, 6=wood, 7=leaves, 8=coal
  ;; Heights: terrain is 0-15 blocks tall, player eye level ~2.5 blocks above ground

  ;; ---- PRNG (xorshift32) ----
  (func $rand (result i32)
    (local $s i32)
    (local.set $s (i32.load (i32.const 0x10340)))
    (if (i32.eqz (local.get $s)) (then (local.set $s (i32.const 2654435761))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 13))))
    (local.set $s (i32.xor (local.get $s) (i32.shr_u (local.get $s) (i32.const 17))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 5))))
    (i32.store (i32.const 0x10340) (local.get $s))
    (local.get $s)
  )

  ;; ---- Hash function for procedural terrain ----
  ;; Returns a deterministic pseudo-random value for world coords
  ;; Uses constant seed mixing so hash2d(0,0) != 0
  (func $hash2d (param $x i32) (param $y i32) (result i32)
    (local $h i32)
    ;; Start with a nonzero seed to prevent hash(0,0)=0
    (local.set $h (i32.const 0x27d4eb2d))
    (local.set $h (i32.xor (local.get $h) (i32.mul (local.get $x) (i32.const 374761393))))
    (local.set $h (i32.xor (local.get $h) (i32.mul (local.get $y) (i32.const 668265263))))
    (local.set $h (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 13))))
    (local.set $h (i32.mul (local.get $h) (i32.const 1274126177)))
    (local.set $h (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 16))))
    (local.set $h (i32.mul (local.get $h) (i32.const 2654435761)))
    (local.set $h (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 13))))
    (local.get $h)
  )

  ;; ---- Smooth noise interpolation helper ----
  ;; Returns 0-255 smoothed noise value at (wx, wy) with given period
  (func $smooth_hash (param $wx i32) (param $wy i32) (param $period i32) (result i32)
    (local $gx i32) (local $gy i32)
    (local $fx i32) (local $fy i32)
    (local $h00 i32) (local $h10 i32) (local $h01 i32) (local $h11 i32)
    (local $top i32) (local $bot i32) (local $result i32)
    ;; Grid coords
    (local.set $gx (i32.div_s (local.get $wx) (local.get $period)))
    ;; Fix negative division: if wx < 0 and wx not divisible, subtract 1
    (if (i32.and (i32.lt_s (local.get $wx) (i32.const 0))
                 (i32.ne (i32.mul (local.get $gx) (local.get $period)) (local.get $wx)))
      (then (local.set $gx (i32.sub (local.get $gx) (i32.const 1)))))
    (local.set $gy (i32.div_s (local.get $wy) (local.get $period)))
    (if (i32.and (i32.lt_s (local.get $wy) (i32.const 0))
                 (i32.ne (i32.mul (local.get $gy) (local.get $period)) (local.get $wy)))
      (then (local.set $gy (i32.sub (local.get $gy) (i32.const 1)))))
    ;; Fractional part (0 to period-1)
    (local.set $fx (i32.sub (local.get $wx) (i32.mul (local.get $gx) (local.get $period))))
    (local.set $fy (i32.sub (local.get $wy) (i32.mul (local.get $gy) (local.get $period))))
    ;; Four corner hashes
    (local.set $h00 (i32.and (call $hash2d (local.get $gx) (local.get $gy)) (i32.const 255)))
    (local.set $h10 (i32.and (call $hash2d (i32.add (local.get $gx) (i32.const 1)) (local.get $gy)) (i32.const 255)))
    (local.set $h01 (i32.and (call $hash2d (local.get $gx) (i32.add (local.get $gy) (i32.const 1))) (i32.const 255)))
    (local.set $h11 (i32.and (call $hash2d (i32.add (local.get $gx) (i32.const 1)) (i32.add (local.get $gy) (i32.const 1))) (i32.const 255)))
    ;; Bilinear interpolation (integer math, scale by period)
    (local.set $top (i32.div_u
      (i32.add (i32.mul (local.get $h00) (i32.sub (local.get $period) (local.get $fx)))
               (i32.mul (local.get $h10) (local.get $fx)))
      (local.get $period)))
    (local.set $bot (i32.div_u
      (i32.add (i32.mul (local.get $h01) (i32.sub (local.get $period) (local.get $fx)))
               (i32.mul (local.get $h11) (local.get $fx)))
      (local.get $period)))
    (local.set $result (i32.div_u
      (i32.add (i32.mul (local.get $top) (i32.sub (local.get $period) (local.get $fy)))
               (i32.mul (local.get $bot) (local.get $fy)))
      (local.get $period)))
    (local.get $result)
  )

  ;; ---- Noise-like height function for world coords ----
  ;; Returns terrain height 1-12 for a given (wx, wy) world block position
  ;; Uses smoothed multi-octave noise for rolling hills
  (func $terrain_height (param $wx i32) (param $wy i32) (result i32)
    (local $h1 i32) (local $h2 i32) (local $h3 i32) (local $result i32)
    ;; Octave 1: large scale rolling hills (period=16 blocks, smoothed)
    ;; Returns 0-255, we want 0-7
    (local.set $h1 (i32.shr_u (call $smooth_hash (local.get $wx) (local.get $wy) (i32.const 16)) (i32.const 5)))
    ;; Octave 2: medium bumps (period=6 blocks, smoothed)
    ;; Returns 0-255, we want 0-3
    (local.set $h2 (i32.shr_u
      (call $smooth_hash
        (i32.add (local.get $wx) (i32.const 1000))
        (i32.add (local.get $wy) (i32.const 2000))
        (i32.const 6))
      (i32.const 6)))
    ;; Octave 3: fine detail per block (unsmoothed hash, 0-1)
    (local.set $h3 (i32.and
      (call $hash2d (i32.add (local.get $wx) (i32.const 5000))
                    (i32.add (local.get $wy) (i32.const 7000)))
      (i32.const 1)))
    ;; Combine: base 3 + large hills(0-7) + medium(0-3) + fine(0-1) = 3..14
    (local.set $result (i32.add (i32.add (i32.const 3) (local.get $h1))
                                (i32.add (local.get $h2) (local.get $h3))))
    ;; Clamp to 1-12
    (if (i32.gt_s (local.get $result) (i32.const 12))
      (then (local.set $result (i32.const 12))))
    (if (i32.lt_s (local.get $result) (i32.const 1))
      (then (local.set $result (i32.const 1))))
    (local.get $result)
  )

  ;; ---- Get block type at world position (wx, wy, wz) ----
  ;; First checks modification table, then procedural generation
  (func $get_block (param $wx i32) (param $wy i32) (param $wz i32) (result i32)
    (local $i i32) (local $count i32) (local $addr i32)
    (local $th i32) (local $h i32) (local $block_hash i32)
    ;; Check modification table first
    (local.set $count (i32.load (i32.const 0x10390)))
    (local.set $i (i32.const 0))
    (block $mod_done
      (loop $mod_loop
        (br_if $mod_done (i32.ge_u (local.get $i) (local.get $count)))
        (local.set $addr (i32.add (i32.const 0x11200) (i32.mul (local.get $i) (i32.const 16))))
        (if (i32.and
              (i32.and
                (i32.eq (i32.load (local.get $addr)) (local.get $wx))
                (i32.eq (i32.load (i32.add (local.get $addr) (i32.const 4))) (local.get $wy)))
              (i32.eq (i32.load (i32.add (local.get $addr) (i32.const 8))) (local.get $wz)))
          (then
            (return (i32.load (i32.add (local.get $addr) (i32.const 12))))
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $mod_loop)
      )
    )
    ;; Not modified — generate procedurally
    ;; z < 0 always bedrock (stone)
    (if (i32.lt_s (local.get $wz) (i32.const 0))
      (then (return (i32.const 3))))
    ;; Get terrain height at this column
    (local.set $th (call $terrain_height (local.get $wx) (local.get $wy)))
    ;; Above terrain = air
    (if (i32.gt_s (local.get $wz) (local.get $th))
      (then (return (i32.const 0))))
    ;; Top block = grass
    (if (i32.eq (local.get $wz) (local.get $th))
      (then
        ;; Some areas are sand (near "water level" = height 3)
        (if (i32.le_s (local.get $th) (i32.const 3))
          (then (return (i32.const 4))))  ;; sand
        (return (i32.const 1))  ;; grass
      )
    )
    ;; 1-2 blocks below top = dirt
    (if (i32.gt_s (local.get $wz) (i32.sub (local.get $th) (i32.const 3)))
      (then (return (i32.const 2))))
    ;; Occasional coal ore
    (local.set $block_hash (i32.and (call $hash2d
      (i32.add (local.get $wx) (i32.mul (local.get $wz) (i32.const 13)))
      (i32.add (local.get $wy) (i32.mul (local.get $wz) (i32.const 7))))
      (i32.const 31)))
    (if (i32.eqz (local.get $block_hash))
      (then (return (i32.const 8))))  ;; coal
    ;; Everything else = stone
    (i32.const 3)
  )

  ;; ---- Store a block modification ----
  (func $set_block (param $wx i32) (param $wy i32) (param $wz i32) (param $type i32)
    (local $i i32) (local $count i32) (local $addr i32) (local $max_mods i32)
    ;; Check if already modified at this position
    (local.set $count (i32.load (i32.const 0x10390)))
    (local.set $i (i32.const 0))
    (block $search_done
      (loop $search
        (br_if $search_done (i32.ge_u (local.get $i) (local.get $count)))
        (local.set $addr (i32.add (i32.const 0x11200) (i32.mul (local.get $i) (i32.const 16))))
        (if (i32.and
              (i32.and
                (i32.eq (i32.load (local.get $addr)) (local.get $wx))
                (i32.eq (i32.load (i32.add (local.get $addr) (i32.const 4))) (local.get $wy)))
              (i32.eq (i32.load (i32.add (local.get $addr) (i32.const 8))) (local.get $wz)))
          (then
            ;; Update existing entry
            (i32.store (i32.add (local.get $addr) (i32.const 12)) (local.get $type))
            (return)
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $search)
      )
    )
    ;; Check if we have room
    (local.set $max_mods (i32.load (i32.const 0x10394)))
    (if (i32.ge_u (local.get $count) (local.get $max_mods))
      (then
        ;; GODS ARE ANGRY
        (i32.store (i32.const 0x10398) (i32.const 1))
        (i32.store (i32.const 0x1039C) (i32.const 300)) ;; show message for 300 frames
        (return)
      )
    )
    ;; Add new entry
    (local.set $addr (i32.add (i32.const 0x11200) (i32.mul (local.get $count) (i32.const 16))))
    (i32.store (local.get $addr) (local.get $wx))
    (i32.store (i32.add (local.get $addr) (i32.const 4)) (local.get $wy))
    (i32.store (i32.add (local.get $addr) (i32.const 8)) (local.get $wz))
    (i32.store (i32.add (local.get $addr) (i32.const 12)) (local.get $type))
    (i32.store (i32.const 0x10390) (i32.add (local.get $count) (i32.const 1)))
  )

  ;; ---- sin/cos approximation (Taylor) ----
  (func $sin_a (param $x f64) (result f64)
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

  (func $cos_a (param $x f64) (result f64)
    (call $sin_a (f64.add (local.get $x) (f64.const 1.5707963267948966)))
  )

  ;; ---- Absolute value ----
  (func $abs_f (param $x f64) (result f64)
    (if (result f64) (f64.lt (local.get $x) (f64.const 0.0))
      (then (f64.neg (local.get $x)))
      (else (local.get $x)))
  )

  ;; ---- Set palette entry ----
  (func $set_pal (param $idx i32) (param $r i32) (param $g i32) (param $b i32)
    (local $a i32)
    (local.set $a (i32.add (i32.const 0x0040) (i32.mul (local.get $idx) (i32.const 3))))
    (i32.store8 (local.get $a) (local.get $r))
    (i32.store8 (i32.add (local.get $a) (i32.const 1)) (local.get $g))
    (i32.store8 (i32.add (local.get $a) (i32.const 2)) (local.get $b))
  )

  ;; ---- put_pixel ----
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

  ;; ---- fill_rect ----
  (func $fill_rect (param $x i32) (param $y i32) (param $w i32) (param $h i32) (param $c i32)
    (local $ix i32) (local $iy i32)
    (local.set $iy (i32.const 0))
    (block $done (loop $ly
      (br_if $done (i32.ge_s (local.get $iy) (local.get $h)))
      (local.set $ix (i32.const 0))
      (block $done2 (loop $lx
        (br_if $done2 (i32.ge_s (local.get $ix) (local.get $w)))
        (call $put_pixel
          (i32.add (local.get $x) (local.get $ix))
          (i32.add (local.get $y) (local.get $iy))
          (local.get $c))
        (local.set $ix (i32.add (local.get $ix) (i32.const 1)))
        (br $lx)))
      (local.set $iy (i32.add (local.get $iy) (i32.const 1)))
      (br $ly)))
  )

  ;; ---- Get block color for a given block type and face ----
  ;; face: 0=top, 1=side, 2=bottom, 3=side-dark
  ;; Returns palette index
  (func $block_color (param $type i32) (param $face i32) (param $shade i32) (result i32)
    (local $base i32)
    ;; Each block type uses a range of 8 palette entries (type*8 + 16)
    ;; shade 0-7: dark to bright
    (local.set $base (i32.add (i32.const 16) (i32.mul (local.get $type) (i32.const 8))))
    ;; Face modifies shade
    (if (i32.eq (local.get $face) (i32.const 0))
      (then ;; top face - brightest
        (local.set $shade (i32.add (local.get $shade) (i32.const 2))))
      (else (if (i32.eq (local.get $face) (i32.const 3))
        (then ;; dark side
          (local.set $shade (i32.sub (local.get $shade) (i32.const 2))))
      ))
    )
    ;; Clamp shade 0-7
    (if (i32.lt_s (local.get $shade) (i32.const 0))
      (then (local.set $shade (i32.const 0))))
    (if (i32.gt_s (local.get $shade) (i32.const 7))
      (then (local.set $shade (i32.const 7))))
    (i32.add (local.get $base) (local.get $shade))
  )

  ;; ---- Font: 4x5 mini font stored inline ----
  ;; We'll draw text character by character using simple pixel patterns

  ;; Draw a single character (simplified 4x6 font)
  (func $draw_char (param $ch i32) (param $dx i32) (param $dy i32) (param $color i32)
    (local $addr i32) (local $row i32) (local $col i32) (local $bits i32)
    ;; Font at 0x19200, each char 6 bytes (6 rows of 4-bit patterns stored in low nibble)
    ;; char index = ch - 32
    (if (i32.lt_u (local.get $ch) (i32.const 32)) (then (return)))
    (if (i32.gt_u (local.get $ch) (i32.const 127)) (then (return)))
    (local.set $addr (i32.add (i32.const 0x19200)
      (i32.mul (i32.sub (local.get $ch) (i32.const 32)) (i32.const 6))))
    (local.set $row (i32.const 0))
    (block $done (loop $lr
      (br_if $done (i32.ge_s (local.get $row) (i32.const 6)))
      (local.set $bits (i32.load8_u (i32.add (local.get $addr) (local.get $row))))
      (local.set $col (i32.const 0))
      (block $done2 (loop $lc
        (br_if $done2 (i32.ge_s (local.get $col) (i32.const 4)))
        (if (i32.and (local.get $bits) (i32.shr_u (i32.const 8) (local.get $col)))
          (then
            (call $put_pixel
              (i32.add (local.get $dx) (local.get $col))
              (i32.add (local.get $dy) (local.get $row))
              (local.get $color))
          )
        )
        (local.set $col (i32.add (local.get $col) (i32.const 1)))
        (br $lc)))
      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br $lr)))
  )

  ;; Draw null-terminated string
  (func $draw_str (param $addr i32) (param $x i32) (param $y i32) (param $color i32)
    (local $ch i32) (local $ox i32)
    (local.set $ox (local.get $x))
    (block $done (loop $lp
      (local.set $ch (i32.load8_u (local.get $addr)))
      (br_if $done (i32.eqz (local.get $ch)))
      (call $draw_char (local.get $ch) (local.get $ox) (local.get $y) (local.get $color))
      (local.set $ox (i32.add (local.get $ox) (i32.const 5)))
      (local.set $addr (i32.add (local.get $addr) (i32.const 1)))
      (br $lp)))
  )

  ;; Draw number
  (func $draw_num (param $val i32) (param $x i32) (param $y i32) (param $color i32)
    (local $digits i32) (local $d i32) (local $v i32) (local $ox i32)
    ;; Count digits
    (local.set $v (local.get $val))
    (local.set $digits (i32.const 1))
    (block $cd (loop $cl
      (local.set $v (i32.div_u (local.get $v) (i32.const 10)))
      (br_if $cd (i32.eqz (local.get $v)))
      (local.set $digits (i32.add (local.get $digits) (i32.const 1)))
      (br $cl)))
    ;; Draw right to left
    (local.set $ox (i32.add (local.get $x) (i32.mul (i32.sub (local.get $digits) (i32.const 1)) (i32.const 5))))
    (local.set $v (local.get $val))
    (block $dd (loop $dl
      (local.set $d (i32.rem_u (local.get $v) (i32.const 10)))
      (call $draw_char (i32.add (local.get $d) (i32.const 48)) (local.get $ox) (local.get $y) (local.get $color))
      (local.set $v (i32.div_u (local.get $v) (i32.const 10)))
      (local.set $ox (i32.sub (local.get $ox) (i32.const 5)))
      (br_if $dd (i32.eqz (local.get $v)))
      (br $dl)))
  )

  ;; ============================================================
  ;; INIT
  ;; ============================================================
  (func (export "init")
    (local $i i32) (local $r i32) (local $g i32) (local $b i32)
    (local $shade i32) (local $base_r i32) (local $base_g i32) (local $base_b i32)

    ;; PRNG seed
    (i32.store (i32.const 0x10340) (i32.const 42069))

    ;; Setup palette
    ;; 0: black, 1-15: sky gradient (blue to light blue)
    (call $set_pal (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))
    (local.set $i (i32.const 1))
    (block $sky_done (loop $sky_lp
      (br_if $sky_done (i32.ge_u (local.get $i) (i32.const 16)))
      (call $set_pal (local.get $i)
        (i32.add (i32.const 40) (i32.mul (local.get $i) (i32.const 8)))
        (i32.add (i32.const 100) (i32.mul (local.get $i) (i32.const 6)))
        (i32.add (i32.const 160) (i32.mul (local.get $i) (i32.const 6))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sky_lp)))

    ;; Block palettes: 8 shades per block type, starting at index 16
    ;; Type 0: air (unused, but fill with dark)
    ;; Type 1: grass (green)
    (local.set $i (i32.const 0))
    (block $g_done (loop $g_lp
      (br_if $g_done (i32.ge_u (local.get $i) (i32.const 8)))
      (call $set_pal (i32.add (i32.const 16) (local.get $i))
        (i32.add (i32.const 20) (i32.mul (local.get $i) (i32.const 8)))
        (i32.add (i32.const 60) (i32.mul (local.get $i) (i32.const 20)))
        (i32.add (i32.const 10) (i32.mul (local.get $i) (i32.const 4))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $g_lp)))

    ;; Type 2: dirt (brown)
    (local.set $i (i32.const 0))
    (block $d_done (loop $d_lp
      (br_if $d_done (i32.ge_u (local.get $i) (i32.const 8)))
      (call $set_pal (i32.add (i32.const 24) (local.get $i))
        (i32.add (i32.const 60) (i32.mul (local.get $i) (i32.const 14)))
        (i32.add (i32.const 30) (i32.mul (local.get $i) (i32.const 10)))
        (i32.add (i32.const 10) (i32.mul (local.get $i) (i32.const 4))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $d_lp)))

    ;; Type 3: stone (gray)
    (local.set $i (i32.const 0))
    (block $s_done (loop $s_lp
      (br_if $s_done (i32.ge_u (local.get $i) (i32.const 8)))
      (call $set_pal (i32.add (i32.const 32) (local.get $i))
        (i32.add (i32.const 50) (i32.mul (local.get $i) (i32.const 18)))
        (i32.add (i32.const 50) (i32.mul (local.get $i) (i32.const 18)))
        (i32.add (i32.const 55) (i32.mul (local.get $i) (i32.const 18))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $s_lp)))

    ;; Type 4: sand (yellow)
    (local.set $i (i32.const 0))
    (block $sa_done (loop $sa_lp
      (br_if $sa_done (i32.ge_u (local.get $i) (i32.const 8)))
      (call $set_pal (i32.add (i32.const 40) (local.get $i))
        (i32.add (i32.const 130) (i32.mul (local.get $i) (i32.const 14)))
        (i32.add (i32.const 110) (i32.mul (local.get $i) (i32.const 14)))
        (i32.add (i32.const 50) (i32.mul (local.get $i) (i32.const 8))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sa_lp)))

    ;; Type 5: water (blue)
    (local.set $i (i32.const 0))
    (block $w_done (loop $w_lp
      (br_if $w_done (i32.ge_u (local.get $i) (i32.const 8)))
      (call $set_pal (i32.add (i32.const 48) (local.get $i))
        (i32.add (i32.const 10) (i32.mul (local.get $i) (i32.const 6)))
        (i32.add (i32.const 30) (i32.mul (local.get $i) (i32.const 12)))
        (i32.add (i32.const 100) (i32.mul (local.get $i) (i32.const 18))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $w_lp)))

    ;; Type 6: wood (dark brown)
    (local.set $i (i32.const 0))
    (block $wd_done (loop $wd_lp
      (br_if $wd_done (i32.ge_u (local.get $i) (i32.const 8)))
      (call $set_pal (i32.add (i32.const 56) (local.get $i))
        (i32.add (i32.const 50) (i32.mul (local.get $i) (i32.const 10)))
        (i32.add (i32.const 25) (i32.mul (local.get $i) (i32.const 8)))
        (i32.add (i32.const 5) (i32.mul (local.get $i) (i32.const 3))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $wd_lp)))

    ;; Type 7: leaves (dark green)
    (local.set $i (i32.const 0))
    (block $lv_done (loop $lv_lp
      (br_if $lv_done (i32.ge_u (local.get $i) (i32.const 8)))
      (call $set_pal (i32.add (i32.const 64) (local.get $i))
        (i32.add (i32.const 10) (i32.mul (local.get $i) (i32.const 6)))
        (i32.add (i32.const 50) (i32.mul (local.get $i) (i32.const 18)))
        (i32.add (i32.const 5) (i32.mul (local.get $i) (i32.const 4))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lv_lp)))

    ;; Type 8: coal ore (dark with specks)
    (local.set $i (i32.const 0))
    (block $co_done (loop $co_lp
      (br_if $co_done (i32.ge_u (local.get $i) (i32.const 8)))
      (call $set_pal (i32.add (i32.const 72) (local.get $i))
        (i32.add (i32.const 30) (i32.mul (local.get $i) (i32.const 10)))
        (i32.add (i32.const 30) (i32.mul (local.get $i) (i32.const 10)))
        (i32.add (i32.const 35) (i32.mul (local.get $i) (i32.const 10))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $co_lp)))

    ;; Palette 128-143: Monster colors (Creeper green)
    (local.set $i (i32.const 0))
    (block $mc_done (loop $mc_lp
      (br_if $mc_done (i32.ge_u (local.get $i) (i32.const 16)))
      (call $set_pal (i32.add (i32.const 128) (local.get $i))
        (i32.mul (local.get $i) (i32.const 4))
        (i32.add (i32.const 40) (i32.mul (local.get $i) (i32.const 12)))
        (i32.mul (local.get $i) (i32.const 2)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $mc_lp)))

    ;; Palette 144-159: Zombie colors (brownish)
    (local.set $i (i32.const 0))
    (block $mz_done (loop $mz_lp
      (br_if $mz_done (i32.ge_u (local.get $i) (i32.const 16)))
      (call $set_pal (i32.add (i32.const 144) (local.get $i))
        (i32.add (i32.const 40) (i32.mul (local.get $i) (i32.const 8)))
        (i32.add (i32.const 50) (i32.mul (local.get $i) (i32.const 6)))
        (i32.add (i32.const 20) (i32.mul (local.get $i) (i32.const 3))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $mz_lp)))

    ;; Palette 160-175: Skeleton (white/bone)
    (local.set $i (i32.const 0))
    (block $ms_done (loop $ms_lp
      (br_if $ms_done (i32.ge_u (local.get $i) (i32.const 16)))
      (call $set_pal (i32.add (i32.const 160) (local.get $i))
        (i32.add (i32.const 120) (i32.mul (local.get $i) (i32.const 8)))
        (i32.add (i32.const 115) (i32.mul (local.get $i) (i32.const 8)))
        (i32.add (i32.const 100) (i32.mul (local.get $i) (i32.const 8))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $ms_lp)))

    ;; Palette 240-255: HUD / text (white-ish, red for health)
    (local.set $i (i32.const 0))
    (block $hud_done (loop $hud_lp
      (br_if $hud_done (i32.ge_u (local.get $i) (i32.const 8)))
      ;; 240-247: white range
      (call $set_pal (i32.add (i32.const 240) (local.get $i))
        (i32.add (i32.const 128) (i32.mul (local.get $i) (i32.const 16)))
        (i32.add (i32.const 128) (i32.mul (local.get $i) (i32.const 16)))
        (i32.add (i32.const 128) (i32.mul (local.get $i) (i32.const 16))))
      ;; 248-255: red range
      (call $set_pal (i32.add (i32.const 248) (local.get $i))
        (i32.add (i32.const 128) (i32.mul (local.get $i) (i32.const 16)))
        (i32.mul (local.get $i) (i32.const 4))
        (i32.mul (local.get $i) (i32.const 4)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $hud_lp)))

    ;; Fog/distance palette 80-95 (gray-blue fog)
    (local.set $i (i32.const 0))
    (block $fg_done (loop $fg_lp
      (br_if $fg_done (i32.ge_u (local.get $i) (i32.const 16)))
      (call $set_pal (i32.add (i32.const 80) (local.get $i))
        (i32.add (i32.const 70) (i32.mul (local.get $i) (i32.const 6)))
        (i32.add (i32.const 90) (i32.mul (local.get $i) (i32.const 5)))
        (i32.add (i32.const 120) (i32.mul (local.get $i) (i32.const 5))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $fg_lp)))

    ;; Crosshair palette 176: bright white
    (call $set_pal (i32.const 176) (i32.const 255) (i32.const 255) (i32.const 255))
    ;; Sun/highlight 177: yellow
    (call $set_pal (i32.const 177) (i32.const 255) (i32.const 255) (i32.const 100))
    ;; Dark overlay 178
    (call $set_pal (i32.const 178) (i32.const 20) (i32.const 15) (i32.const 15))
    ;; Red text 179
    (call $set_pal (i32.const 179) (i32.const 255) (i32.const 50) (i32.const 50))
    ;; Green text 180
    (call $set_pal (i32.const 180) (i32.const 50) (i32.const 255) (i32.const 100))

    ;; Initialize player position
    (f64.store (i32.const 0x10344) (f64.const 32.5))   ;; px - start further out for terrain variety
    (f64.store (i32.const 0x1034C) (f64.const 32.5))   ;; py
    (f64.store (i32.const 0x10354) (f64.const 0.5))    ;; angle - look slightly right
    ;; Compute correct starting height: terrain height at (32,32) + 1.7 for eye level
    (f64.store (i32.const 0x1035C)
      (f64.add (f64.convert_i32_s (call $terrain_height (i32.const 32) (i32.const 32))) (f64.const 1.7)))
    (f64.store (i32.const 0x10364) (f64.const 0.0))    ;; vz
    (i32.store (i32.const 0x1036C) (i32.const 1))      ;; on_ground
    (f64.store (i32.const 0x10374) (f64.const 0.0))    ;; bob_phase

    ;; Game state
    (i32.store (i32.const 0x10390) (i32.const 0))      ;; mod_count
    (i32.store (i32.const 0x10394) (i32.const 1900))    ;; max_mods (limited to avoid overwriting string data)
    (i32.store (i32.const 0x10398) (i32.const 0))      ;; gods_angry
    (i32.store (i32.const 0x1039C) (i32.const 0))      ;; msg_timer
    (i32.store (i32.const 0x103A0) (i32.const 0))      ;; dig_cooldown
    (i32.store (i32.const 0x103A4) (i32.const 0))      ;; prev_mouse
    (i32.store (i32.const 0x103A8) (i32.const 1))      ;; selected_block (dirt)

    ;; Spawn some monsters
    (call $spawn_monsters)

    ;; Init mini font data at 0x19200
    (call $init_font)
  )

  ;; ---- Spawn monsters around the player ----
  (func $spawn_monsters
    (local $i i32) (local $addr i32) (local $angle f64) (local $dist f64)
    (local $mx f64) (local $my f64) (local $px f64) (local $py f64)
    (local.set $px (f64.load (i32.const 0x10344)))
    (local.set $py (f64.load (i32.const 0x1034C)))
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 24)))
      (local.set $addr (i32.add (i32.const 0x10E00) (i32.mul (local.get $i) (i32.const 32))))
      ;; Place at random positions around player
      (local.set $angle (f64.mul (f64.convert_i32_u (local.get $i)) (f64.const 0.2618)))
      (local.set $dist (f64.add (f64.const 8.0)
        (f64.mul (f64.convert_i32_u (i32.and (call $rand) (i32.const 15))) (f64.const 1.5))))
      (local.set $mx (f64.add (local.get $px)
        (f64.mul (call $cos_a (local.get $angle)) (local.get $dist))))
      (local.set $my (f64.add (local.get $py)
        (f64.mul (call $sin_a (local.get $angle)) (local.get $dist))))
      ;; active
      (i32.store (local.get $addr) (i32.const 1))
      ;; type: 0=creeper, 1=zombie, 2=skeleton
      (i32.store (i32.add (local.get $addr) (i32.const 4))
        (i32.rem_u (local.get $i) (i32.const 3)))
      ;; wx, wy
      (f64.store (i32.add (local.get $addr) (i32.const 8)) (local.get $mx))
      (f64.store (i32.add (local.get $addr) (i32.const 16)) (local.get $my))
      ;; hp
      (i32.store (i32.add (local.get $addr) (i32.const 24)) (i32.const 3))
      ;; anim counter
      (i32.store (i32.add (local.get $addr) (i32.const 28)) (i32.and (call $rand) (i32.const 255)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; ---- Initialize mini 4x6 bitmap font ----
  (func $init_font
    (local $base i32)
    (local.set $base (i32.const 0x19200))
    ;; Space (32) = all zeros (already 0)
    ;; We only need digits 0-9, A-Z, and a few punctuation
    ;; Encoding: 4 bits per row, stored in low nibble, 6 rows per char
    ;; bit3=leftmost pixel, bit0=rightmost

    ;; '!' (33)
    (i32.store8 (i32.add (local.get $base) (i32.const 6)) (i32.const 0x04))   ;; .X..
    (i32.store8 (i32.add (local.get $base) (i32.const 7)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 8)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 9)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 10)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 11)) (i32.const 0x00))

    ;; Numbers 0-9 starting at char 48, offset = (48-32)*6 = 96
    ;; '0'
    (i32.store8 (i32.add (local.get $base) (i32.const 96)) (i32.const 0x06))   ;; .XX.
    (i32.store8 (i32.add (local.get $base) (i32.const 97)) (i32.const 0x09))   ;; X..X
    (i32.store8 (i32.add (local.get $base) (i32.const 98)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 99)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 100)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 101)) (i32.const 0x00))
    ;; '1'
    (i32.store8 (i32.add (local.get $base) (i32.const 102)) (i32.const 0x02))
    (i32.store8 (i32.add (local.get $base) (i32.const 103)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 104)) (i32.const 0x02))
    (i32.store8 (i32.add (local.get $base) (i32.const 105)) (i32.const 0x02))
    (i32.store8 (i32.add (local.get $base) (i32.const 106)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 107)) (i32.const 0x00))
    ;; '2'
    (i32.store8 (i32.add (local.get $base) (i32.const 108)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 109)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 110)) (i32.const 0x02))
    (i32.store8 (i32.add (local.get $base) (i32.const 111)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 112)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 113)) (i32.const 0x00))
    ;; '3'
    (i32.store8 (i32.add (local.get $base) (i32.const 114)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 115)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 116)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 117)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 118)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 119)) (i32.const 0x00))
    ;; '4'
    (i32.store8 (i32.add (local.get $base) (i32.const 120)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 121)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 122)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 123)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 124)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 125)) (i32.const 0x00))
    ;; '5'
    (i32.store8 (i32.add (local.get $base) (i32.const 126)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 127)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 128)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 129)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 130)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 131)) (i32.const 0x00))
    ;; '6'
    (i32.store8 (i32.add (local.get $base) (i32.const 132)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 133)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 134)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 135)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 136)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 137)) (i32.const 0x00))
    ;; '7'
    (i32.store8 (i32.add (local.get $base) (i32.const 138)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 139)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 140)) (i32.const 0x02))
    (i32.store8 (i32.add (local.get $base) (i32.const 141)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 142)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 143)) (i32.const 0x00))
    ;; '8'
    (i32.store8 (i32.add (local.get $base) (i32.const 144)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 145)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 146)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 147)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 148)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 149)) (i32.const 0x00))
    ;; '9'
    (i32.store8 (i32.add (local.get $base) (i32.const 150)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 151)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 152)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 153)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 154)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 155)) (i32.const 0x00))

    ;; Letters A-Z starting at char 65, offset = (65-32)*6 = 198
    ;; 'A'
    (i32.store8 (i32.add (local.get $base) (i32.const 198)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 199)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 200)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 201)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 202)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 203)) (i32.const 0x00))
    ;; 'B'
    (i32.store8 (i32.add (local.get $base) (i32.const 204)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 205)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 206)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 207)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 208)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 209)) (i32.const 0x00))
    ;; 'C'
    (i32.store8 (i32.add (local.get $base) (i32.const 210)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 211)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 212)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 213)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 214)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 215)) (i32.const 0x00))
    ;; 'D'
    (i32.store8 (i32.add (local.get $base) (i32.const 216)) (i32.const 0x0C))
    (i32.store8 (i32.add (local.get $base) (i32.const 217)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 218)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 219)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 220)) (i32.const 0x0C))
    (i32.store8 (i32.add (local.get $base) (i32.const 221)) (i32.const 0x00))
    ;; 'E'
    (i32.store8 (i32.add (local.get $base) (i32.const 222)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 223)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 224)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 225)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 226)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 227)) (i32.const 0x00))
    ;; 'F'
    (i32.store8 (i32.add (local.get $base) (i32.const 228)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 229)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 230)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 231)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 232)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 233)) (i32.const 0x00))
    ;; 'G'
    (i32.store8 (i32.add (local.get $base) (i32.const 234)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 235)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 236)) (i32.const 0x0B))
    (i32.store8 (i32.add (local.get $base) (i32.const 237)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 238)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 239)) (i32.const 0x00))
    ;; 'H'
    (i32.store8 (i32.add (local.get $base) (i32.const 240)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 241)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 242)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 243)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 244)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 245)) (i32.const 0x00))
    ;; 'I'
    (i32.store8 (i32.add (local.get $base) (i32.const 246)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 247)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 248)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 249)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 250)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 251)) (i32.const 0x00))
    ;; 'K'  (char 75, offset = (75-32)*6 = 258)
    (i32.store8 (i32.add (local.get $base) (i32.const 258)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 259)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 260)) (i32.const 0x0C))
    (i32.store8 (i32.add (local.get $base) (i32.const 261)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 262)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 263)) (i32.const 0x00))
    ;; 'L' (76, offset=264)
    (i32.store8 (i32.add (local.get $base) (i32.const 264)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 265)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 266)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 267)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 268)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 269)) (i32.const 0x00))
    ;; 'M' (77, offset=270)
    (i32.store8 (i32.add (local.get $base) (i32.const 270)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 271)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 272)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 273)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 274)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 275)) (i32.const 0x00))
    ;; 'N' (78, offset=276)
    (i32.store8 (i32.add (local.get $base) (i32.const 276)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 277)) (i32.const 0x0D))
    (i32.store8 (i32.add (local.get $base) (i32.const 278)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 279)) (i32.const 0x0B))
    (i32.store8 (i32.add (local.get $base) (i32.const 280)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 281)) (i32.const 0x00))
    ;; 'O' (79, offset=282)
    (i32.store8 (i32.add (local.get $base) (i32.const 282)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 283)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 284)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 285)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 286)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 287)) (i32.const 0x00))
    ;; 'P' (80, offset=288)
    (i32.store8 (i32.add (local.get $base) (i32.const 288)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 289)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 290)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 291)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 292)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 293)) (i32.const 0x00))
    ;; 'R' (82, offset=300)
    (i32.store8 (i32.add (local.get $base) (i32.const 300)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 301)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 302)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 303)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 304)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 305)) (i32.const 0x00))
    ;; 'S' (83, offset=306)
    (i32.store8 (i32.add (local.get $base) (i32.const 306)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 307)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 308)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 309)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 310)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 311)) (i32.const 0x00))
    ;; 'T' (84, offset=312)
    (i32.store8 (i32.add (local.get $base) (i32.const 312)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 313)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 314)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 315)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 316)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 317)) (i32.const 0x00))
    ;; 'U' (85, offset=318)
    (i32.store8 (i32.add (local.get $base) (i32.const 318)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 319)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 320)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 321)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 322)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 323)) (i32.const 0x00))
    ;; 'V' (86, offset=324)
    (i32.store8 (i32.add (local.get $base) (i32.const 324)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 325)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 326)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 327)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 328)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 329)) (i32.const 0x00))
    ;; 'W' (87, offset=330)
    (i32.store8 (i32.add (local.get $base) (i32.const 330)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 331)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 332)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 333)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 334)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 335)) (i32.const 0x00))
    ;; 'X' (88, offset=336)
    (i32.store8 (i32.add (local.get $base) (i32.const 336)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 337)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 338)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 339)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 340)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 341)) (i32.const 0x00))
    ;; 'Y' (89, offset=342)
    (i32.store8 (i32.add (local.get $base) (i32.const 342)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 343)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 344)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 345)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 346)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 347)) (i32.const 0x00))

    ;; Lowercase letters: just map to uppercase offsets would be complex
    ;; Instead let's add key lowercase: a-z at offsets (97-32)*6=390+
    ;; 'a' (97, offset=390) - copy same as A
    (i32.store8 (i32.add (local.get $base) (i32.const 390)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 391)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 392)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 393)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 394)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 395)) (i32.const 0x00))
    ;; 'c' (99, offset=402)
    (i32.store8 (i32.add (local.get $base) (i32.const 402)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 403)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 404)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 405)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 406)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 407)) (i32.const 0x00))
    ;; 'd' (100, offset=408)
    (i32.store8 (i32.add (local.get $base) (i32.const 408)) (i32.const 0x0C))
    (i32.store8 (i32.add (local.get $base) (i32.const 409)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 410)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 411)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 412)) (i32.const 0x0C))
    (i32.store8 (i32.add (local.get $base) (i32.const 413)) (i32.const 0x00))
    ;; 'e' (101, offset=414)
    (i32.store8 (i32.add (local.get $base) (i32.const 414)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 415)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 416)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 417)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 418)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 419)) (i32.const 0x00))
    ;; 'g' (103, offset=426)
    (i32.store8 (i32.add (local.get $base) (i32.const 426)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 427)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 428)) (i32.const 0x0B))
    (i32.store8 (i32.add (local.get $base) (i32.const 429)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 430)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 431)) (i32.const 0x00))
    ;; 'h' (104, offset=432)
    (i32.store8 (i32.add (local.get $base) (i32.const 432)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 433)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 434)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 435)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 436)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 437)) (i32.const 0x00))
    ;; 'i' (105, offset=438)
    (i32.store8 (i32.add (local.get $base) (i32.const 438)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 439)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 440)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 441)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 442)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 443)) (i32.const 0x00))
    ;; 'm' (109, offset=462)
    (i32.store8 (i32.add (local.get $base) (i32.const 462)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 463)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 464)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 465)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 466)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 467)) (i32.const 0x00))
    ;; 'n' (110, offset=468)
    (i32.store8 (i32.add (local.get $base) (i32.const 468)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 469)) (i32.const 0x0D))
    (i32.store8 (i32.add (local.get $base) (i32.const 470)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 471)) (i32.const 0x0B))
    (i32.store8 (i32.add (local.get $base) (i32.const 472)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 473)) (i32.const 0x00))
    ;; 'o' (111, offset=474)
    (i32.store8 (i32.add (local.get $base) (i32.const 474)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 475)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 476)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 477)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 478)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 479)) (i32.const 0x00))
    ;; 'r' (114, offset=492)
    (i32.store8 (i32.add (local.get $base) (i32.const 492)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 493)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 494)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 495)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 496)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 497)) (i32.const 0x00))
    ;; 's' (115, offset=498)
    (i32.store8 (i32.add (local.get $base) (i32.const 498)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 499)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 500)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 501)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 502)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 503)) (i32.const 0x00))
    ;; 't' (116, offset=504)
    (i32.store8 (i32.add (local.get $base) (i32.const 504)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 505)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 506)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 507)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 508)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 509)) (i32.const 0x00))
    ;; 'u' (117, offset=510)
    (i32.store8 (i32.add (local.get $base) (i32.const 510)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 511)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 512)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 513)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 514)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 515)) (i32.const 0x00))
    ;; 'y' (121, offset=534)
    (i32.store8 (i32.add (local.get $base) (i32.const 534)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 535)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 536)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 537)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 538)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 539)) (i32.const 0x00))

    ;; 'b' (98, offset=396)
    (i32.store8 (i32.add (local.get $base) (i32.const 396)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 397)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 398)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 399)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 400)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 401)) (i32.const 0x00))

    ;; 'l' (108, offset=456)
    (i32.store8 (i32.add (local.get $base) (i32.const 456)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 457)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 458)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 459)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 460)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 461)) (i32.const 0x00))

    ;; 'k' (107, offset=450)
    (i32.store8 (i32.add (local.get $base) (i32.const 450)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 451)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 452)) (i32.const 0x0C))
    (i32.store8 (i32.add (local.get $base) (i32.const 453)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 454)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 455)) (i32.const 0x00))

    ;; 'p' (112, offset=480)
    (i32.store8 (i32.add (local.get $base) (i32.const 480)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 481)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 482)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 483)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 484)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 485)) (i32.const 0x00))

    ;; 'w' (119, offset=522)
    (i32.store8 (i32.add (local.get $base) (i32.const 522)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 523)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 524)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 525)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 526)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 527)) (i32.const 0x00))

    ;; 'f' (102, offset=420)
    (i32.store8 (i32.add (local.get $base) (i32.const 420)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 421)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 422)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 423)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 424)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 425)) (i32.const 0x00))

    ;; 'v' (118, offset=516)
    (i32.store8 (i32.add (local.get $base) (i32.const 516)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 517)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 518)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 519)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 520)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 521)) (i32.const 0x00))

    ;; 'x' (120, offset=528)
    (i32.store8 (i32.add (local.get $base) (i32.const 528)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 529)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 530)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 531)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 532)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 533)) (i32.const 0x00))
    ;; 'j' (106, offset=444)
    (i32.store8 (i32.add (local.get $base) (i32.const 444)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 445)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 446)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 447)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 448)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 449)) (i32.const 0x00))

    ;; 'q' (113, offset=486)
    (i32.store8 (i32.add (local.get $base) (i32.const 486)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 487)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 488)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 489)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 490)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 491)) (i32.const 0x00))
    ;; ':' (58, offset = (58-32)*6 = 156)
    (i32.store8 (i32.add (local.get $base) (i32.const 156)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 157)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 158)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 159)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 160)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 161)) (i32.const 0x00))
    ;; '/' (47, offset = (47-32)*6 = 90)
    (i32.store8 (i32.add (local.get $base) (i32.const 90)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 91)) (i32.const 0x02))
    (i32.store8 (i32.add (local.get $base) (i32.const 92)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 93)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 94)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 95)) (i32.const 0x00))
    ;; 'J' (74, offset=252)
    (i32.store8 (i32.add (local.get $base) (i32.const 252)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 253)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 254)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 255)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 256)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 257)) (i32.const 0x00))
    ;; 'Q' (81, offset=294)
    (i32.store8 (i32.add (local.get $base) (i32.const 294)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 295)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 296)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 297)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 298)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 299)) (i32.const 0x00))
    ;; 'Z' (90, offset=348)
    (i32.store8 (i32.add (local.get $base) (i32.const 348)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 349)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 350)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 351)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 352)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 353)) (i32.const 0x00))
    ;; 'z' (122, offset=540)
    (i32.store8 (i32.add (local.get $base) (i32.const 540)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 541)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 542)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 543)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 544)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 545)) (i32.const 0x00))
  )

  ;; ============================================================
  ;; Strings stored at 0x19000+
  ;; ============================================================
  (data (i32.const 0x19000) "VGACRAFT\00")
  (data (i32.const 0x19010) "WASD:move LR:turn\00")
  (data (i32.const 0x19030) "CLICK:dig SHIFT:place\00")
  (data (i32.const 0x19050) "You angered the\00")
  (data (i32.const 0x19070) "Minecraft gods by\00")
  (data (i32.const 0x19090) "digging too much!\00")
  (data (i32.const 0x190B0) "Blocks:\00")
  (data (i32.const 0x190C0) "Mods:\00")
  (data (i32.const 0x190D0) "/\00")

  ;; ============================================================
  ;; FRAME — main rendering loop
  ;; ============================================================
  (func (export "frame")
    (local $col i32) (local $tick i32) (local $keys i32)
    (local $px f64) (local $py f64) (local $pz f64) (local $angle f64)
    (local $cos_a f64) (local $sin_a f64)
    (local $move_x f64) (local $move_y f64) (local $speed f64)
    (local $ray_angle f64) (local $ray_dx f64) (local $ray_dy f64)
    (local $t f64) (local $step f64)
    (local $hit_type i32) (local $hit_face i32) (local $sample_z i32)
    (local $proj_height i32) (local $screen_top i32) (local $screen_bot i32)
    (local $row i32) (local $color i32) (local $shade i32)
    (local $wx i32) (local $wy i32) (local $wz i32)
    (local $prev_wx i32) (local $prev_wy i32) (local $prev_wz i32)
    (local $horizon i32) (local $fb_addr i32)
    (local $mouse_btn i32) (local $prev_mouse i32)
    (local $msg_timer i32) (local $dig_cd i32)
    (local $vz f64) (local $on_ground i32) (local $ground_h i32)
    (local $bob f64) (local $bob_phase f64)
    (local $frac_x f64) (local $frac_y f64)
    (local $tex_u i32) (local $tex_v i32)
    (local $i i32) (local $m_addr i32) (local $m_active i32)
    (local $m_type i32) (local $m_wx f64) (local $m_wy f64)
    (local $dx f64) (local $dy f64) (local $dist f64) (local $m_angle f64)
    (local $rel_angle f64) (local $screen_x i32) (local $sprite_h i32)
    (local $sprite_top i32) (local $sprite_bot i32) (local $sx i32)
    (local $sy i32) (local $sp_color i32) (local $m_anim i32)
    (local $m_dist f64) (local $zbuf_val f64)
    (local $cx f64) (local $cy f64)
    (local $new_px f64) (local $new_py f64)
    (local $check_x i32) (local $check_y i32) (local $check_h i32)
    (local $floor_color i32) (local $sky_idx i32)
    (local $frame_ct i32)

    (local.set $tick (i32.load (i32.const 12)))
    (local.set $frame_ct (i32.load (i32.const 0)))
    (local.set $keys (i32.load8_u (i32.const 0x10)))
    (local.set $mouse_btn (i32.load8_u (i32.const 0x08)))
    (local.set $prev_mouse (i32.load (i32.const 0x103A4)))

    ;; Load player state
    (local.set $px (f64.load (i32.const 0x10344)))
    (local.set $py (f64.load (i32.const 0x1034C)))
    (local.set $angle (f64.load (i32.const 0x10354)))
    (local.set $pz (f64.load (i32.const 0x1035C)))
    (local.set $vz (f64.load (i32.const 0x10364)))
    (local.set $on_ground (i32.load (i32.const 0x1036C)))
    (local.set $bob_phase (f64.load (i32.const 0x10374)))

    ;; ---- Input handling ----
    (local.set $speed (f64.const 0.06))

    ;; Turn: Left (bit2), Right (bit3)
    (if (i32.and (local.get $keys) (i32.const 4))
      (then (local.set $angle (f64.sub (local.get $angle) (f64.const 0.04)))))
    (if (i32.and (local.get $keys) (i32.const 8))
      (then (local.set $angle (f64.add (local.get $angle) (f64.const 0.04)))))

    (local.set $cos_a (call $cos_a (local.get $angle)))
    (local.set $sin_a (call $sin_a (local.get $angle)))

    ;; Forward/back movement with collision
    (local.set $move_x (f64.const 0.0))
    (local.set $move_y (f64.const 0.0))

    ;; Up/W (bit0): forward
    (if (i32.and (local.get $keys) (i32.const 1))
      (then
        (local.set $move_x (f64.add (local.get $move_x) (f64.mul (local.get $cos_a) (local.get $speed))))
        (local.set $move_y (f64.add (local.get $move_y) (f64.mul (local.get $sin_a) (local.get $speed))))
      )
    )
    ;; Down/S (bit1): backward
    (if (i32.and (local.get $keys) (i32.const 2))
      (then
        (local.set $move_x (f64.sub (local.get $move_x) (f64.mul (local.get $cos_a) (local.get $speed))))
        (local.set $move_y (f64.sub (local.get $move_y) (f64.mul (local.get $sin_a) (local.get $speed))))
      )
    )

    ;; Apply movement with simple collision check
    (local.set $new_px (f64.add (local.get $px) (local.get $move_x)))
    (local.set $new_py (f64.add (local.get $py) (local.get $move_y)))

    ;; Check if new position is walkable (terrain height at feet < player eye - 1)
    (local.set $check_x (i32.trunc_f64_s (f64.floor (local.get $new_px))))
    (local.set $check_y (i32.trunc_f64_s (f64.floor (local.get $new_py))))
    (local.set $check_h (call $terrain_height (local.get $check_x) (local.get $check_y)))
    ;; Allow movement if ground is not more than 1 block above current foot level
    (if (i32.le_s (local.get $check_h) (i32.add (i32.trunc_f64_s (local.get $pz)) (i32.const 1)))
      (then
        (local.set $px (local.get $new_px))
        (local.set $py (local.get $new_py))
      )
    )

    ;; Gravity and ground collision
    ;; Player foot height = pz - 1.7 (eye height above feet)
    (local.set $ground_h (call $terrain_height
      (i32.trunc_f64_s (f64.floor (local.get $px)))
      (i32.trunc_f64_s (f64.floor (local.get $py)))))
    ;; Target eye height = ground_h + 1.7
    (local.set $vz (f64.sub (local.get $vz) (f64.const 0.015)))  ;; gravity
    (local.set $pz (f64.add (local.get $pz) (local.get $vz)))

    ;; Ground collision
    (if (f64.le (local.get $pz) (f64.add (f64.convert_i32_s (local.get $ground_h)) (f64.const 1.7)))
      (then
        (local.set $pz (f64.add (f64.convert_i32_s (local.get $ground_h)) (f64.const 1.7)))
        (local.set $vz (f64.const 0.0))
        (local.set $on_ground (i32.const 1))
      )
      (else (local.set $on_ground (i32.const 0)))
    )

    ;; Jump: Space (bit4)
    (if (i32.and (i32.and (local.get $keys) (i32.const 16)) (local.get $on_ground))
      (then (local.set $vz (f64.const 0.18))))

    ;; Head bob when moving on ground
    (if (i32.and (local.get $on_ground)
          (i32.or (i32.and (local.get $keys) (i32.const 1))
                  (i32.and (local.get $keys) (i32.const 2))))
      (then
        (local.set $bob_phase (f64.add (local.get $bob_phase) (f64.const 0.15)))
        (local.set $bob (f64.mul (call $sin_a (local.get $bob_phase)) (f64.const 0.08)))
      )
      (else (local.set $bob (f64.const 0.0)))
    )

    ;; Digging: mouse click (bit0 set, was 0)
    (local.set $dig_cd (i32.load (i32.const 0x103A0)))
    (if (i32.gt_s (local.get $dig_cd) (i32.const 0))
      (then (i32.store (i32.const 0x103A0) (i32.sub (local.get $dig_cd) (i32.const 1)))))

    (if (i32.and
          (i32.and (local.get $mouse_btn) (i32.const 1))
          (i32.eqz (i32.and (local.get $prev_mouse) (i32.const 1))))
      (then
        (if (i32.eqz (i32.load (i32.const 0x103A0)))
          (then
            ;; Raycast to find block in front of player
            (call $dig_or_place (local.get $px) (local.get $py) (local.get $pz) (local.get $angle)
              (i32.and (local.get $keys) (i32.const 128)))  ;; shift = place mode
            (i32.store (i32.const 0x103A0) (i32.const 10))  ;; cooldown
          )
        )
      )
    )
    (i32.store (i32.const 0x103A4) (i32.load8_u (i32.const 0x08)))

    ;; Store player state
    (f64.store (i32.const 0x10344) (local.get $px))
    (f64.store (i32.const 0x1034C) (local.get $py))
    (f64.store (i32.const 0x10354) (local.get $angle))
    (f64.store (i32.const 0x1035C) (local.get $pz))
    (f64.store (i32.const 0x10364) (local.get $vz))
    (i32.store (i32.const 0x1036C) (local.get $on_ground))
    (f64.store (i32.const 0x10374) (local.get $bob_phase))

    ;; ---- Clear framebuffer: sky gradient ----
    (local.set $row (i32.const 0))
    (block $sky_done (loop $sky_lp
      (br_if $sky_done (i32.ge_u (local.get $row) (i32.const 200)))
      ;; Sky: top half gradient, bottom half = fog color
      (local.set $sky_idx
        (if (result i32) (i32.lt_u (local.get $row) (i32.const 100))
          (then (i32.add (i32.const 1) (i32.shr_u (local.get $row) (i32.const 3))))
          (else (i32.const 87))  ;; fog palette
        )
      )
      ;; Fill entire row
      (local.set $col (i32.const 0))
      (block $row_done (loop $row_lp
        (br_if $row_done (i32.ge_u (local.get $col) (i32.const 320)))
        (i32.store8
          (i32.add (i32.const 0x0340) (i32.add (i32.mul (local.get $row) (i32.const 320)) (local.get $col)))
          (local.get $sky_idx))
        (local.set $col (i32.add (local.get $col) (i32.const 1)))
        (br $row_lp)))
      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br $sky_lp)))

    ;; ---- Clear z-buffer ----
    (local.set $i (i32.const 0))
    (block $zb_done (loop $zb_lp
      (br_if $zb_done (i32.ge_u (local.get $i) (i32.const 320)))
      (f64.store (i32.add (i32.const 0x103B0) (i32.mul (local.get $i) (i32.const 8))) (f64.const 999.0))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $zb_lp)))

    ;; Horizon depends on player height
    (local.set $horizon (i32.const 100))

    ;; ---- Render terrain columns via raycasting ----
    (local.set $col (i32.const 0))
    (block $render_done (loop $render_lp
      (br_if $render_done (i32.ge_u (local.get $col) (i32.const 320)))

      ;; Ray angle for this column (FOV ~70 degrees)
      (local.set $ray_angle (f64.add (local.get $angle)
        (f64.mul (f64.div (f64.sub (f64.convert_i32_s (local.get $col)) (f64.const 160.0)) (f64.const 320.0))
                 (f64.const 1.22))))
      (local.set $ray_dx (call $cos_a (local.get $ray_angle)))
      (local.set $ray_dy (call $sin_a (local.get $ray_angle)))

      ;; March along ray, sampling terrain
      (local.set $t (f64.const 0.3))
      (local.set $step (f64.const 0.15))
      (local.set $hit_type (i32.const 0))

      (block $ray_done (loop $ray_lp
        (br_if $ray_done (f64.gt (local.get $t) (f64.const 32.0)))

        ;; World position of sample
        (local.set $cx (f64.add (local.get $px) (f64.mul (local.get $ray_dx) (local.get $t))))
        (local.set $cy (f64.add (local.get $py) (f64.mul (local.get $ray_dy) (local.get $t))))
        (local.set $wx (i32.trunc_f64_s (f64.floor (local.get $cx))))
        (local.set $wy (i32.trunc_f64_s (f64.floor (local.get $cy))))

        ;; Get terrain height at this column
        (local.set $ground_h (call $terrain_height (local.get $wx) (local.get $wy)))

        ;; Check each block in column from top to scan for visible faces
        ;; Simplified: check the top block
        (local.set $wz (local.get $ground_h))

        ;; Check if block exists (not modified to air)
        (local.set $hit_type (call $get_block (local.get $wx) (local.get $wy) (local.get $wz)))

        (if (i32.and (i32.ne (local.get $hit_type) (i32.const 0))
              (i32.const 1))
          (then
            ;; Calculate projected height of this block column
            ;; fisheye correction
            (local.set $dist (f64.mul (local.get $t)
              (call $cos_a (f64.sub (local.get $ray_angle) (local.get $angle)))))

            (if (f64.gt (local.get $dist) (f64.const 0.1))
              (then
                ;; Project block top and bottom
                ;; block_top_z = ground_h + 1, block_bot_z = ground_h
                ;; screen_y = horizon - (block_z - pz) * scale / dist
                (local.set $proj_height (i32.trunc_f64_s (f64.div (f64.const 160.0) (local.get $dist))))

                ;; Top of topmost block
                (local.set $screen_top (i32.sub (local.get $horizon)
                  (i32.trunc_f64_s (f64.div
                    (f64.mul (f64.sub (f64.add (f64.convert_i32_s (local.get $ground_h)) (f64.const 1.0))
                      (f64.add (local.get $pz) (local.get $bob)))
                      (f64.const 160.0))
                    (local.get $dist)))))

                ;; Bottom of bottom block (ground level 0 or bedrock)
                ;; We render from ground_h down to max(0, ground_h - visible_depth)
                (local.set $screen_bot (i32.sub (local.get $horizon)
                  (i32.trunc_f64_s (f64.div
                    (f64.mul (f64.sub (f64.const 0.0)
                      (f64.add (local.get $pz) (local.get $bob)))
                      (f64.const 160.0))
                    (local.get $dist)))))

                ;; Clamp
                (if (i32.lt_s (local.get $screen_top) (i32.const 0))
                  (then (local.set $screen_top (i32.const 0))))
                (if (i32.gt_s (local.get $screen_bot) (i32.const 200))
                  (then (local.set $screen_bot (i32.const 200))))

                ;; Determine face for shading
                (local.set $frac_x (f64.sub (local.get $cx) (f64.floor (local.get $cx))))
                (local.set $frac_y (f64.sub (local.get $cy) (f64.floor (local.get $cy))))

                ;; Face: check which axis we're closest to a block boundary
                (local.set $hit_face (i32.const 1))  ;; default: side
                (if (i32.or
                      (f64.lt (local.get $frac_x) (f64.const 0.05))
                      (f64.gt (local.get $frac_x) (f64.const 0.95)))
                  (then (local.set $hit_face (i32.const 3))))  ;; dark side (x-facing)

                ;; Distance-based shade (closer = brighter)
                (local.set $shade (i32.sub (i32.const 7)
                  (i32.shr_u (i32.trunc_f64_s (f64.mul (local.get $dist) (f64.const 0.8))) (i32.const 0))))
                (if (i32.lt_s (local.get $shade) (i32.const 1))
                  (then (local.set $shade (i32.const 1))))
                (if (i32.gt_s (local.get $shade) (i32.const 7))
                  (then (local.set $shade (i32.const 7))))

                ;; Draw column: render each block layer
                (local.set $sample_z (local.get $ground_h))
                (block $blk_done (loop $blk_lp
                  (br_if $blk_done (i32.lt_s (local.get $sample_z) (i32.const 0)))

                  (local.set $hit_type (call $get_block (local.get $wx) (local.get $wy) (local.get $sample_z)))
                  (if (i32.ne (local.get $hit_type) (i32.const 0))
                    (then
                      ;; Calculate screen rows for this specific block
                      (local.set $screen_top (i32.sub (local.get $horizon)
                        (i32.trunc_f64_s (f64.div
                          (f64.mul (f64.sub (f64.add (f64.convert_i32_s (local.get $sample_z)) (f64.const 1.0))
                            (f64.add (local.get $pz) (local.get $bob)))
                            (f64.const 160.0))
                          (local.get $dist)))))
                      (local.set $screen_bot (i32.sub (local.get $horizon)
                        (i32.trunc_f64_s (f64.div
                          (f64.mul (f64.sub (f64.convert_i32_s (local.get $sample_z))
                            (f64.add (local.get $pz) (local.get $bob)))
                            (f64.const 160.0))
                          (local.get $dist)))))

                      ;; Clamp
                      (if (i32.lt_s (local.get $screen_top) (i32.const 0))
                        (then (local.set $screen_top (i32.const 0))))
                      (if (i32.gt_s (local.get $screen_bot) (i32.const 200))
                        (then (local.set $screen_bot (i32.const 200))))

                      ;; Top face color for top block
                      (if (i32.eq (local.get $sample_z) (local.get $ground_h))
                        (then (local.set $color (call $block_color (local.get $hit_type) (i32.const 0) (local.get $shade))))
                        (else (local.set $color (call $block_color (local.get $hit_type) (local.get $hit_face) (local.get $shade)))))

                      ;; Apply distance fog
                      (if (f64.gt (local.get $dist) (f64.const 20.0))
                        (then (local.set $color (i32.add (i32.const 80)
                          (i32.shr_u (i32.trunc_f64_s (f64.mul (local.get $dist) (f64.const 0.3))) (i32.const 0))))))
                      (if (i32.gt_s (local.get $color) (i32.const 95)) (then (local.set $color (i32.const 95))))

                      ;; Draw the block stripe
                      (local.set $row (local.get $screen_top))
                      (block $stripe_done (loop $stripe_lp
                        (br_if $stripe_done (i32.ge_s (local.get $row) (local.get $screen_bot)))
                        (if (i32.and (i32.ge_s (local.get $row) (i32.const 0)) (i32.lt_s (local.get $row) (i32.const 200)))
                          (then
                            ;; Add block texture detail: alternate shade based on position within block
                            (local.set $tex_u (i32.and
                              (i32.trunc_f64_s (f64.mul (local.get $frac_x) (f64.const 8.0)))
                              (i32.const 7)))
                            (local.set $tex_v (i32.and (local.get $row) (i32.const 3)))
                            ;; Simple dither pattern for texture
                            (local.set $sp_color (local.get $color))
                            (if (i32.and (i32.xor (local.get $tex_u) (local.get $tex_v)) (i32.const 1))
                              (then
                                (if (i32.gt_s (local.get $sp_color) (i32.const 16))
                                  (then (local.set $sp_color (i32.sub (local.get $sp_color) (i32.const 1)))))))
                            (i32.store8
                              (i32.add (i32.const 0x0340) (i32.add (i32.mul (local.get $row) (i32.const 320)) (local.get $col)))
                              (local.get $sp_color))
                          )
                        )
                        (local.set $row (i32.add (local.get $row) (i32.const 1)))
                        (br $stripe_lp)))
                    )
                  )
                  (local.set $sample_z (i32.sub (local.get $sample_z) (i32.const 1)))
                  ;; Only draw a few blocks deep for performance
                  (br_if $blk_done (i32.lt_s (local.get $sample_z) (i32.sub (local.get $ground_h) (i32.const 4))))
                  (br $blk_lp)))

                ;; Store z-distance for sprite occlusion
                (f64.store (i32.add (i32.const 0x103B0) (i32.mul (local.get $col) (i32.const 8))) (local.get $dist))
                (br $ray_done)  ;; found terrain for this column
              )
            )
          )
        )

        ;; Adaptive step size
        (local.set $step (select (f64.const 0.15) (select (f64.const 0.3) (f64.const 0.5)
          (f64.lt (local.get $t) (f64.const 16.0)))
          (f64.lt (local.get $t) (f64.const 6.0))))
        (local.set $t (f64.add (local.get $t) (local.get $step)))
        (br $ray_lp)))

      (local.set $col (i32.add (local.get $col) (i32.const 1)))
      (br $render_lp)))

    ;; ---- Render billboard sprites (monsters) ----
    (local.set $i (i32.const 0))
    (block $mob_done (loop $mob_lp
      (br_if $mob_done (i32.ge_u (local.get $i) (i32.const 24)))
      (local.set $m_addr (i32.add (i32.const 0x10E00) (i32.mul (local.get $i) (i32.const 32))))
      (local.set $m_active (i32.load (local.get $m_addr)))
      (if (local.get $m_active)
        (then
          (local.set $m_type (i32.load (i32.add (local.get $m_addr) (i32.const 4))))
          (local.set $m_wx (f64.load (i32.add (local.get $m_addr) (i32.const 8))))
          (local.set $m_wy (f64.load (i32.add (local.get $m_addr) (i32.const 16))))
          (local.set $m_anim (i32.load (i32.add (local.get $m_addr) (i32.const 28))))

          ;; Simple monster AI: walk toward player slowly
          (local.set $dx (f64.sub (local.get $px) (local.get $m_wx)))
          (local.set $dy (f64.sub (local.get $py) (local.get $m_wy)))
          (local.set $m_dist (f64.sqrt (f64.add (f64.mul (local.get $dx) (local.get $dx))
                                                 (f64.mul (local.get $dy) (local.get $dy)))))
          ;; Move toward player if far enough
          (if (f64.gt (local.get $m_dist) (f64.const 3.0))
            (then
              (local.set $m_wx (f64.add (local.get $m_wx)
                (f64.mul (f64.div (local.get $dx) (local.get $m_dist)) (f64.const 0.01))))
              (local.set $m_wy (f64.add (local.get $m_wy)
                (f64.mul (f64.div (local.get $dy) (local.get $m_dist)) (f64.const 0.01))))
              (f64.store (i32.add (local.get $m_addr) (i32.const 8)) (local.get $m_wx))
              (f64.store (i32.add (local.get $m_addr) (i32.const 16)) (local.get $m_wy))
            )
          )

          ;; Increment anim counter
          (i32.store (i32.add (local.get $m_addr) (i32.const 28))
            (i32.add (local.get $m_anim) (i32.const 1)))

          ;; Calculate screen position
          (local.set $dx (f64.sub (local.get $m_wx) (local.get $px)))
          (local.set $dy (f64.sub (local.get $m_wy) (local.get $py)))
          (local.set $m_dist (f64.sqrt (f64.add (f64.mul (local.get $dx) (local.get $dx))
                                                 (f64.mul (local.get $dy) (local.get $dy)))))

          (if (f64.gt (local.get $m_dist) (f64.const 0.5))
            (then
              ;; Angle to monster relative to player facing
              ;; atan2 approximation: just use the projection method
              ;; Project onto view plane
              ;; view_x = dx * cos(angle) + dy * sin(angle) (depth)
              ;; view_y = -dx * sin(angle) + dy * cos(angle) (lateral)
              (local.set $cx (f64.add (f64.mul (local.get $dx) (local.get $cos_a))
                                      (f64.mul (local.get $dy) (local.get $sin_a))))
              (local.set $cy (f64.add (f64.mul (f64.neg (local.get $dx)) (local.get $sin_a))
                                      (f64.mul (local.get $dy) (local.get $cos_a))))

              ;; Only draw if in front of player
              (if (f64.gt (local.get $cx) (f64.const 0.3))
                (then
                  ;; Screen X from lateral offset
                  (local.set $screen_x (i32.add (i32.const 160)
                    (i32.trunc_f64_s (f64.div (f64.mul (local.get $cy) (f64.const 320.0)) (local.get $cx)))))

                  ;; Sprite size based on distance
                  (local.set $sprite_h (i32.trunc_f64_s (f64.div (f64.const 120.0) (local.get $cx))))
                  (if (i32.gt_s (local.get $sprite_h) (i32.const 120))
                    (then (local.set $sprite_h (i32.const 120))))

                  ;; Monster height on terrain
                  (local.set $ground_h (call $terrain_height
                    (i32.trunc_f64_s (f64.floor (local.get $m_wx)))
                    (i32.trunc_f64_s (f64.floor (local.get $m_wy)))))

                  ;; Screen Y for monster feet (ground level)
                  (local.set $sprite_bot (i32.sub (local.get $horizon)
                    (i32.trunc_f64_s (f64.div
                      (f64.mul (f64.sub (f64.add (f64.convert_i32_s (local.get $ground_h)) (f64.const 1.0))
                        (f64.add (local.get $pz) (local.get $bob)))
                        (f64.const 160.0))
                      (local.get $cx)))))
                  (local.set $sprite_top (i32.sub (local.get $sprite_bot) (local.get $sprite_h)))

                  ;; Draw billboard sprite
                  ;; Base palette depends on type: 0=creeper(128), 1=zombie(144), 2=skeleton(160)
                  (local.set $sp_color (i32.add
                    (select (i32.const 128) (select (i32.const 144) (i32.const 160)
                      (i32.eq (local.get $m_type) (i32.const 1)))
                      (i32.eqz (local.get $m_type)))
                    (i32.const 0)))

                  ;; Draw sprite columns
                  (local.set $sx (i32.sub (local.get $screen_x) (i32.shr_s (local.get $sprite_h) (i32.const 1))))
                  (local.set $col (i32.const 0))
                  (block $sp_done (loop $sp_lp
                    (br_if $sp_done (i32.ge_s (local.get $col) (local.get $sprite_h)))
                    (local.set $check_x (i32.add (local.get $sx) (local.get $col)))
                    (if (i32.and (i32.ge_s (local.get $check_x) (i32.const 0))
                                 (i32.lt_s (local.get $check_x) (i32.const 320)))
                      (then
                        ;; Check z-buffer
                        (local.set $zbuf_val (f64.load (i32.add (i32.const 0x103B0)
                          (i32.mul (local.get $check_x) (i32.const 8)))))
                        (if (f64.lt (local.get $cx) (local.get $zbuf_val))
                          (then
                            ;; Draw this sprite column
                            ;; Sprite pattern: body shape
                            (local.set $tex_u (i32.div_u (i32.mul (local.get $col) (i32.const 8)) (local.get $sprite_h)))
                            (local.set $sy (local.get $sprite_top))
                            (block $spy_done (loop $spy_lp
                              (br_if $spy_done (i32.ge_s (local.get $sy) (local.get $sprite_bot)))
                              (if (i32.and (i32.ge_s (local.get $sy) (i32.const 0))
                                           (i32.lt_s (local.get $sy) (i32.const 200)))
                                (then
                                  ;; Calculate v position in sprite (0-7)
                                  (local.set $tex_v (i32.div_u
                                    (i32.mul (i32.sub (local.get $sy) (local.get $sprite_top)) (i32.const 8))
                                    (i32.add (i32.const 1) (i32.sub (local.get $sprite_bot) (local.get $sprite_top)))))

                                  ;; Simple sprite shape: rectangular body with head
                                  ;; head: rows 0-2, cols 2-5
                                  ;; body: rows 3-5, cols 1-6
                                  ;; legs: rows 6-7, cols 2-3, 4-5
                                  (local.set $color (i32.const 0))  ;; transparent by default
                                  ;; Head (top rows)
                                  (if (i32.and (i32.lt_u (local.get $tex_v) (i32.const 3))
                                               (i32.and (i32.ge_u (local.get $tex_u) (i32.const 2))
                                                        (i32.lt_u (local.get $tex_u) (i32.const 6))))
                                    (then
                                      (local.set $color (i32.add (local.get $sp_color) (i32.const 10)))
                                      ;; Eyes: dark pixels at specific positions
                                      (if (i32.and (i32.eq (local.get $tex_v) (i32.const 1))
                                                   (i32.or (i32.eq (local.get $tex_u) (i32.const 3))
                                                           (i32.eq (local.get $tex_u) (i32.const 4))))
                                        (then (local.set $color (i32.add (local.get $sp_color) (i32.const 2)))))
                                    )
                                  )
                                  ;; Body
                                  (if (i32.and (i32.and (i32.ge_u (local.get $tex_v) (i32.const 3))
                                                        (i32.lt_u (local.get $tex_v) (i32.const 6)))
                                               (i32.and (i32.ge_u (local.get $tex_u) (i32.const 1))
                                                        (i32.lt_u (local.get $tex_u) (i32.const 7))))
                                    (then
                                      (local.set $color (i32.add (local.get $sp_color)
                                        (i32.const 8)))
                                    )
                                  )
                                  ;; Legs (animated)
                                  (if (i32.ge_u (local.get $tex_v) (i32.const 6))
                                    (then
                                      ;; Walking animation: legs alternate
                                      (if (i32.or
                                            (i32.and (i32.ge_u (local.get $tex_u) (i32.const 2))
                                                     (i32.lt_u (local.get $tex_u) (i32.const 4)))
                                            (i32.and (i32.ge_u (local.get $tex_u) (i32.const 4))
                                                     (i32.lt_u (local.get $tex_u) (i32.const 6))))
                                        (then
                                          (local.set $color (i32.add (local.get $sp_color) (i32.const 6)))
                                        )
                                      )
                                    )
                                  )

                                  ;; Only draw non-transparent pixels
                                  (if (local.get $color)
                                    (then
                                      ;; Distance-based darkening
                                      (if (f64.gt (local.get $cx) (f64.const 15.0))
                                        (then (local.set $color (i32.sub (local.get $color) (i32.const 3)))
                                          (if (i32.lt_s (local.get $color) (local.get $sp_color))
                                            (then (local.set $color (local.get $sp_color))))))
                                      (i32.store8
                                        (i32.add (i32.const 0x0340)
                                          (i32.add (i32.mul (local.get $sy) (i32.const 320)) (local.get $check_x)))
                                        (local.get $color))
                                    )
                                  )
                                )
                              )
                              (local.set $sy (i32.add (local.get $sy) (i32.const 1)))
                              (br $spy_lp)))
                          )
                        )
                      )
                    )
                    (local.set $col (i32.add (local.get $col) (i32.const 1)))
                    (br $sp_lp)))
                )
              )
            )
          )
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $mob_lp)))

    ;; ---- Draw crosshair ----
    (call $put_pixel (i32.const 160) (i32.const 98) (i32.const 176))
    (call $put_pixel (i32.const 160) (i32.const 99) (i32.const 176))
    (call $put_pixel (i32.const 160) (i32.const 101) (i32.const 176))
    (call $put_pixel (i32.const 160) (i32.const 102) (i32.const 176))
    (call $put_pixel (i32.const 158) (i32.const 100) (i32.const 176))
    (call $put_pixel (i32.const 159) (i32.const 100) (i32.const 176))
    (call $put_pixel (i32.const 161) (i32.const 100) (i32.const 176))
    (call $put_pixel (i32.const 162) (i32.const 100) (i32.const 176))

    ;; ---- HUD: block count / mod count ----
    (call $draw_str (i32.const 0x190C0) (i32.const 2) (i32.const 2) (i32.const 247))
    (call $draw_num (i32.load (i32.const 0x10390)) (i32.const 32) (i32.const 2) (i32.const 247))
    (call $draw_str (i32.const 0x190D0) (i32.const 57) (i32.const 2) (i32.const 245))
    (call $draw_num (i32.load (i32.const 0x10394)) (i32.const 62) (i32.const 2) (i32.const 245))

    ;; ---- "Gods angry" message ----
    (local.set $msg_timer (i32.load (i32.const 0x1039C)))
    (if (i32.gt_s (local.get $msg_timer) (i32.const 0))
      (then
        (i32.store (i32.const 0x1039C) (i32.sub (local.get $msg_timer) (i32.const 1)))
        ;; Draw dark overlay in center
        (call $fill_rect (i32.const 55) (i32.const 70) (i32.const 210) (i32.const 50) (i32.const 178))
        ;; Draw red text
        (call $draw_str (i32.const 0x19050) (i32.const 80) (i32.const 78) (i32.const 179))
        (call $draw_str (i32.const 0x19070) (i32.const 72) (i32.const 90) (i32.const 179))
        (call $draw_str (i32.const 0x19090) (i32.const 72) (i32.const 102) (i32.const 179))
        ;; Play angry sound effect occasionally
        (if (i32.eq (i32.and (local.get $msg_timer) (i32.const 31)) (i32.const 0))
          (then (call $note (i32.const 2) (i32.const 80) (i32.const 200) (i32.const 180))))
      )
    )

    ;; ---- Title text (first 180 frames) ----
    (if (i32.lt_u (local.get $frame_ct) (i32.const 180))
      (then
        (call $draw_str (i32.const 0x19000) (i32.const 115) (i32.const 30) (i32.const 180))
        (call $draw_str (i32.const 0x19010) (i32.const 70) (i32.const 180) (i32.const 245))
        (call $draw_str (i32.const 0x19030) (i32.const 60) (i32.const 190) (i32.const 245))
      )
    )

    ;; Digging sound on click
    (if (i32.and
          (i32.and (local.get $mouse_btn) (i32.const 1))
          (i32.eqz (i32.and (local.get $prev_mouse) (i32.const 1))))
      (then
        (call $note (i32.const 3) (i32.const 200) (i32.const 50) (i32.const 150))
      )
    )
  )

  ;; ---- Dig or place block ----
  (func $dig_or_place (param $px f64) (param $py f64) (param $pz f64) (param $angle f64) (param $place_mode i32)
    (local $t f64) (local $cx f64) (local $cy f64)
    (local $wx i32) (local $wy i32) (local $wz i32)
    (local $ground_h i32) (local $block i32)
    (local $prev_wx i32) (local $prev_wy i32) (local $prev_wz i32)
    (local $ray_dx f64) (local $ray_dy f64)

    (local.set $ray_dx (call $cos_a (local.get $angle)))
    (local.set $ray_dy (call $sin_a (local.get $angle)))
    (local.set $prev_wx (i32.const -999))
    (local.set $prev_wy (i32.const -999))
    (local.set $prev_wz (i32.const -999))

    ;; Cast ray to find the first solid block
    (local.set $t (f64.const 0.5))
    (block $done (loop $lp
      (br_if $done (f64.gt (local.get $t) (f64.const 6.0)))

      (local.set $cx (f64.add (local.get $px) (f64.mul (local.get $ray_dx) (local.get $t))))
      (local.set $cy (f64.add (local.get $py) (f64.mul (local.get $ray_dy) (local.get $t))))
      (local.set $wx (i32.trunc_f64_s (f64.floor (local.get $cx))))
      (local.set $wy (i32.trunc_f64_s (f64.floor (local.get $cy))))
      (local.set $ground_h (call $terrain_height (local.get $wx) (local.get $wy)))

      ;; Check the top block
      (local.set $wz (local.get $ground_h))
      (local.set $block (call $get_block (local.get $wx) (local.get $wy) (local.get $wz)))

      (if (i32.ne (local.get $block) (i32.const 0))
        (then
          (if (local.get $place_mode)
            (then
              ;; Place block on top
              (call $set_block (local.get $wx) (local.get $wy)
                (i32.add (local.get $wz) (i32.const 1))
                (i32.const 2))  ;; place dirt
              (call $note (i32.const 1) (i32.const 300) (i32.const 60) (i32.const 120))
            )
            (else
              ;; Dig: remove top block
              (call $set_block (local.get $wx) (local.get $wy) (local.get $wz) (i32.const 0))
              (call $note (i32.const 3) (i32.const 150) (i32.const 80) (i32.const 100))
            )
          )
          (return)
        )
      )

      (local.set $prev_wx (local.get $wx))
      (local.set $prev_wy (local.get $wy))
      (local.set $prev_wz (local.get $wz))
      (local.set $t (f64.add (local.get $t) (f64.const 0.2)))
      (br $lp)))
  )
)