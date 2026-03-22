(module
  (import "env" "memory" (memory 8))
  (import "env" "sfx" (func $sfx (param i32)))
  (import "env" "note" (func $note (param i32 i32 i32 i32)))

  ;; ============================================================
  ;; VGACraft — Proper Per-Pixel 3D Voxel Raytracer
  ;; ============================================================
  ;; True per-pixel raytracing: every pixel (320×200 = 64000 rays)
  ;; gets its own ray through the voxel world using 3D DDA
  ;; (Amanatides & Woo grid traversal).
  ;;
  ;; WASD to move, Mouse to look, Click to dig, Shift+click to place
  ;; Space to jump
  ;;
  ;; Memory layout:
  ;;   0x10340  PRNG state (4 bytes)
  ;;   0x10344  Player state (64 bytes)
  ;;     +0:  px (f64) world X
  ;;     +8:  py (f64) world Y (horizontal plane)
  ;;     +16: angle (f64) facing direction (yaw)
  ;;     +24: pz (f64) player Z height (eye level)
  ;;     +32: vz (f64) vertical velocity
  ;;     +40: on_ground (i32)
  ;;     +48: bob_phase (f64)
  ;;   0x10390  Game state (32 bytes)
  ;;     +0:  mod_count (i32)
  ;;     +4:  max_mods (i32)
  ;;     +8:  gods_angry (i32)
  ;;     +12: msg_timer (i32)
  ;;     +16: dig_cooldown (i32)
  ;;     +20: prev_mouse (i32)
  ;;     +24: selected_block (i32)
  ;;     +28: look_y (i32) - vertical look pitch
  ;;   0x103B0  zbuffer (320 * 4 = 1280 bytes) — f32 per column for sprites
  ;;   0x10900  Monster array (24 monsters * 32 bytes = 768)
  ;;   0x10C00  Modification table (max ~1900 entries * 16 bytes)
  ;;   0x19000  String data
  ;;   0x19200  Font data
  ;; ============================================================

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
  (func $hash2d (param $x i32) (param $y i32) (result i32)
    (local $h i32)
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

  ;; ---- 3-input hash ----
  (func $hash3d (param $x i32) (param $y i32) (param $z i32) (result i32)
    (local $h i32)
    (local.set $h (i32.const 0x27d4eb2d))
    (local.set $h (i32.xor (local.get $h) (i32.mul (local.get $x) (i32.const 374761393))))
    (local.set $h (i32.xor (local.get $h) (i32.mul (local.get $y) (i32.const 668265263))))
    (local.set $h (i32.xor (local.get $h) (i32.mul (local.get $z) (i32.const 1103515245))))
    (local.set $h (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 13))))
    (local.set $h (i32.mul (local.get $h) (i32.const 1274126177)))
    (local.set $h (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 16))))
    (local.get $h)
  )

  ;; ---- Smooth noise interpolation ----
  (func $smooth_hash (param $wx i32) (param $wy i32) (param $period i32) (result i32)
    (local $gx i32) (local $gy i32)
    (local $fx i32) (local $fy i32)
    (local $h00 i32) (local $h10 i32) (local $h01 i32) (local $h11 i32)
    (local $top i32) (local $bot i32) (local $result i32)
    (local.set $gx (i32.div_s (local.get $wx) (local.get $period)))
    (if (i32.and (i32.lt_s (local.get $wx) (i32.const 0))
                 (i32.ne (i32.mul (local.get $gx) (local.get $period)) (local.get $wx)))
      (then (local.set $gx (i32.sub (local.get $gx) (i32.const 1)))))
    (local.set $gy (i32.div_s (local.get $wy) (local.get $period)))
    (if (i32.and (i32.lt_s (local.get $wy) (i32.const 0))
                 (i32.ne (i32.mul (local.get $gy) (local.get $period)) (local.get $wy)))
      (then (local.set $gy (i32.sub (local.get $gy) (i32.const 1)))))
    (local.set $fx (i32.sub (local.get $wx) (i32.mul (local.get $gx) (local.get $period))))
    (local.set $fy (i32.sub (local.get $wy) (i32.mul (local.get $gy) (local.get $period))))
    (local.set $h00 (i32.and (call $hash2d (local.get $gx) (local.get $gy)) (i32.const 255)))
    (local.set $h10 (i32.and (call $hash2d (i32.add (local.get $gx) (i32.const 1)) (local.get $gy)) (i32.const 255)))
    (local.set $h01 (i32.and (call $hash2d (local.get $gx) (i32.add (local.get $gy) (i32.const 1))) (i32.const 255)))
    (local.set $h11 (i32.and (call $hash2d (i32.add (local.get $gx) (i32.const 1)) (i32.add (local.get $gy) (i32.const 1))) (i32.const 255)))
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

  ;; ---- Terrain height: returns 2-14 for given world XY ----
  (func $terrain_height (param $wx i32) (param $wy i32) (result i32)
    (local $h1 i32) (local $h2 i32) (local $h3 i32) (local $result i32)
    (local.set $h1 (i32.shr_u (call $smooth_hash (local.get $wx) (local.get $wy) (i32.const 16)) (i32.const 5)))
    (local.set $h2 (i32.shr_u
      (call $smooth_hash
        (i32.add (local.get $wx) (i32.const 1000))
        (i32.add (local.get $wy) (i32.const 2000))
        (i32.const 7))
      (i32.const 6)))
    (local.set $h3 (i32.and
      (call $hash2d (i32.add (local.get $wx) (i32.const 5000))
                    (i32.add (local.get $wy) (i32.const 7000)))
      (i32.const 1)))
    (local.set $result (i32.add (i32.add (i32.const 2) (local.get $h1))
                                (i32.add (local.get $h2) (local.get $h3))))
    (if (i32.gt_s (local.get $result) (i32.const 14))
      (then (local.set $result (i32.const 14))))
    (if (i32.lt_s (local.get $result) (i32.const 2))
      (then (local.set $result (i32.const 2))))
    (local.get $result)
  )

  ;; ---- Check if there's a tree at this position ----
  (func $has_tree (param $wx i32) (param $wy i32) (result i32)
    (local $h i32)
    (local.set $h (call $hash2d (i32.add (local.get $wx) (i32.const 3333))
                                (i32.add (local.get $wy) (i32.const 7777))))
    (i32.and
      (i32.lt_u (i32.and (local.get $h) (i32.const 255)) (i32.const 10))
      (i32.gt_s (call $terrain_height (local.get $wx) (local.get $wy)) (i32.const 5)))
  )

  ;; ---- Get block type at world position (wx, wy, wz) ----
  ;; Block types: 0=air, 1=grass, 2=dirt, 3=stone, 4=sand, 5=water, 6=wood, 7=leaves, 8=coal
  (func $get_block (param $wx i32) (param $wy i32) (param $wz i32) (result i32)
    (local $i i32) (local $count i32) (local $addr i32)
    (local $th i32) (local $block_hash i32)
    ;; Check modification table first
    (local.set $count (i32.load (i32.const 0x10390)))
    (local.set $i (i32.const 0))
    (block $mod_done
      (loop $mod_loop
        (br_if $mod_done (i32.ge_u (local.get $i) (local.get $count)))
        (local.set $addr (i32.add (i32.const 0x10C00) (i32.mul (local.get $i) (i32.const 16))))
        (if (i32.and
              (i32.and
                (i32.eq (i32.load (local.get $addr)) (local.get $wx))
                (i32.eq (i32.load (i32.add (local.get $addr) (i32.const 4))) (local.get $wy)))
              (i32.eq (i32.load (i32.add (local.get $addr) (i32.const 8))) (local.get $wz)))
          (then (return (i32.load (i32.add (local.get $addr) (i32.const 12))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $mod_loop)))
    ;; Procedural generation
    (if (i32.lt_s (local.get $wz) (i32.const 0)) (then (return (i32.const 3))))
    (local.set $th (call $terrain_height (local.get $wx) (local.get $wy)))
    ;; Tree trunk and leaves
    (if (call $has_tree (local.get $wx) (local.get $wy))
      (then
        (if (i32.and (i32.gt_s (local.get $wz) (local.get $th))
                     (i32.le_s (local.get $wz) (i32.add (local.get $th) (i32.const 4))))
          (then (return (i32.const 6))))
        (if (i32.and (i32.ge_s (local.get $wz) (i32.add (local.get $th) (i32.const 3)))
                     (i32.le_s (local.get $wz) (i32.add (local.get $th) (i32.const 6))))
          (then (return (i32.const 7))))))
    ;; Check neighbor trees for leaves
    (if (i32.and (i32.ge_s (local.get $wz) (i32.add (local.get $th) (i32.const 3)))
                 (i32.le_s (local.get $wz) (i32.add (local.get $th) (i32.const 5))))
      (then
        (if (i32.or (i32.or
              (call $has_tree (i32.add (local.get $wx) (i32.const 1)) (local.get $wy))
              (call $has_tree (i32.sub (local.get $wx) (i32.const 1)) (local.get $wy)))
              (i32.or
              (call $has_tree (local.get $wx) (i32.add (local.get $wy) (i32.const 1)))
              (call $has_tree (local.get $wx) (i32.sub (local.get $wy) (i32.const 1)))))
          (then (return (i32.const 7))))))
    ;; Above terrain = air (or water)
    (if (i32.gt_s (local.get $wz) (local.get $th))
      (then
        (if (i32.and (i32.le_s (local.get $wz) (i32.const 4))
                     (i32.le_s (local.get $th) (i32.const 4)))
          (then (return (i32.const 5))))
        (return (i32.const 0))))
    ;; Top block
    (if (i32.eq (local.get $wz) (local.get $th))
      (then
        (if (i32.le_s (local.get $th) (i32.const 4))
          (then (return (i32.const 4))))
        (return (i32.const 1))))
    ;; 1-3 below top = dirt
    (if (i32.gt_s (local.get $wz) (i32.sub (local.get $th) (i32.const 3)))
      (then (return (i32.const 2))))
    ;; Coal ore
    (local.set $block_hash (i32.and (call $hash2d
      (i32.add (local.get $wx) (i32.mul (local.get $wz) (i32.const 13)))
      (i32.add (local.get $wy) (i32.mul (local.get $wz) (i32.const 7))))
      (i32.const 31)))
    (if (i32.eqz (local.get $block_hash))
      (then (return (i32.const 8))))
    (i32.const 3)
  )

  ;; ---- Store a block modification ----
  (func $set_block (param $wx i32) (param $wy i32) (param $wz i32) (param $type i32)
    (local $i i32) (local $count i32) (local $addr i32) (local $max_mods i32)
    (local.set $count (i32.load (i32.const 0x10390)))
    (local.set $i (i32.const 0))
    (block $search_done
      (loop $search
        (br_if $search_done (i32.ge_u (local.get $i) (local.get $count)))
        (local.set $addr (i32.add (i32.const 0x10C00) (i32.mul (local.get $i) (i32.const 16))))
        (if (i32.and
              (i32.and
                (i32.eq (i32.load (local.get $addr)) (local.get $wx))
                (i32.eq (i32.load (i32.add (local.get $addr) (i32.const 4))) (local.get $wy)))
              (i32.eq (i32.load (i32.add (local.get $addr) (i32.const 8))) (local.get $wz)))
          (then
            (i32.store (i32.add (local.get $addr) (i32.const 12)) (local.get $type))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $search)))
    (local.set $max_mods (i32.load (i32.const 0x10394)))
    (if (i32.ge_u (local.get $count) (local.get $max_mods))
      (then
        (i32.store (i32.const 0x10398) (i32.const 1))
        (i32.store (i32.const 0x1039C) (i32.const 300))
        (return)))
    (local.set $addr (i32.add (i32.const 0x10C00) (i32.mul (local.get $count) (i32.const 16))))
    (i32.store (local.get $addr) (local.get $wx))
    (i32.store (i32.add (local.get $addr) (i32.const 4)) (local.get $wy))
    (i32.store (i32.add (local.get $addr) (i32.const 8)) (local.get $wz))
    (i32.store (i32.add (local.get $addr) (i32.const 12)) (local.get $type))
    (i32.store (i32.const 0x10390) (i32.add (local.get $count) (i32.const 1)))
  )

  ;; ---- sin/cos approximation ----
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
          (local.get $c))))
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

  ;; ---- Block color: returns palette index ----
  ;; face: 0=top, 1=side+X, 2=side-X, 3=side+Y, 4=side-Y, 5=bottom
  ;; We simplify to: 0=top(bright), 1=side-bright, 2=side-dim, 3=bottom(dark)
  ;; Now uses 16 shades per block type for smoother lighting
  (func $block_color (param $type i32) (param $face i32) (param $shade i32) (result i32)
    (local $base i32)
    (local.set $base (i32.sub (i32.mul (local.get $type) (i32.const 16)) (i32.const 8)))
    ;; Top face gets +4 brightness (was +2 with 8 shades)
    (if (i32.eq (local.get $face) (i32.const 0))
      (then (local.set $shade (i32.add (local.get $shade) (i32.const 4)))))
    ;; Dim side gets -2
    (if (i32.eq (local.get $face) (i32.const 2))
      (then (local.set $shade (i32.sub (local.get $shade) (i32.const 2)))))
    ;; Bottom gets -4
    (if (i32.eq (local.get $face) (i32.const 3))
      (then (local.set $shade (i32.sub (local.get $shade) (i32.const 4)))))
    (if (i32.lt_s (local.get $shade) (i32.const 0))
      (then (local.set $shade (i32.const 0))))
    (if (i32.gt_s (local.get $shade) (i32.const 15))
      (then (local.set $shade (i32.const 15))))
    (i32.add (local.get $base) (local.get $shade))
  )

  ;; ---- Mini font (4x6 bitmap) ----
  (func $draw_char (param $ch i32) (param $dx i32) (param $dy i32) (param $color i32)
    (local $addr i32) (local $row i32) (local $col i32) (local $bits i32)
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
              (local.get $color))))
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
    (local.set $v (local.get $val))
    (local.set $digits (i32.const 1))
    (block $cd (loop $cl
      (local.set $v (i32.div_u (local.get $v) (i32.const 10)))
      (br_if $cd (i32.eqz (local.get $v)))
      (local.set $digits (i32.add (local.get $digits) (i32.const 1)))
      (br $cl)))
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
    (local $i i32)

    ;; PRNG seed
    (i32.store (i32.const 0x10340) (i32.const 42069))

    ;; Palette 0: black
    (call $set_pal (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))

    ;; Palette 1-7: sky gradient
    (call $set_pal (i32.const 1) (i32.const 40) (i32.const 80) (i32.const 180))
    (call $set_pal (i32.const 2) (i32.const 50) (i32.const 95) (i32.const 190))
    (call $set_pal (i32.const 3) (i32.const 65) (i32.const 110) (i32.const 200))
    (call $set_pal (i32.const 4) (i32.const 80) (i32.const 130) (i32.const 210))
    (call $set_pal (i32.const 5) (i32.const 100) (i32.const 150) (i32.const 220))
    (call $set_pal (i32.const 6) (i32.const 120) (i32.const 170) (i32.const 230))
    (call $set_pal (i32.const 7) (i32.const 140) (i32.const 190) (i32.const 240))

    ;; ================================================================
    ;; 16-shade block palettes for smooth lighting + dithering
    ;; Each block type gets 16 entries: dark(0) → bright(15)
    ;; Layout: type*16 - 8 + shade = palette index
    ;; Type 1 (grass):  8-23
    ;; Type 2 (dirt):   24-39
    ;; Type 3 (stone):  40-55
    ;; Type 4 (sand):   56-71
    ;; Type 5 (water):  72-87
    ;; Type 6 (wood):   88-103
    ;; Type 7 (leaves): 104-119
    ;; Type 8 (coal):   120-135
    ;; ================================================================

    ;; Block type 1: grass → palette 8..23 (16 shades)
    (call $set_pal (i32.const 8)  (i32.const 12) (i32.const 30) (i32.const 5))
    (call $set_pal (i32.const 9)  (i32.const 18) (i32.const 45) (i32.const 8))
    (call $set_pal (i32.const 10) (i32.const 24) (i32.const 58) (i32.const 10))
    (call $set_pal (i32.const 11) (i32.const 30) (i32.const 72) (i32.const 14))
    (call $set_pal (i32.const 12) (i32.const 38) (i32.const 88) (i32.const 18))
    (call $set_pal (i32.const 13) (i32.const 45) (i32.const 102) (i32.const 22))
    (call $set_pal (i32.const 14) (i32.const 52) (i32.const 118) (i32.const 26))
    (call $set_pal (i32.const 15) (i32.const 60) (i32.const 132) (i32.const 30))
    (call $set_pal (i32.const 16) (i32.const 68) (i32.const 148) (i32.const 35))
    (call $set_pal (i32.const 17) (i32.const 76) (i32.const 162) (i32.const 40))
    (call $set_pal (i32.const 18) (i32.const 84) (i32.const 175) (i32.const 45))
    (call $set_pal (i32.const 19) (i32.const 92) (i32.const 188) (i32.const 50))
    (call $set_pal (i32.const 20) (i32.const 100) (i32.const 200) (i32.const 55))
    (call $set_pal (i32.const 21) (i32.const 110) (i32.const 212) (i32.const 62))
    (call $set_pal (i32.const 22) (i32.const 120) (i32.const 222) (i32.const 70))
    (call $set_pal (i32.const 23) (i32.const 132) (i32.const 232) (i32.const 80))

    ;; Block type 2: dirt → palette 24..39 (16 shades)
    (call $set_pal (i32.const 24) (i32.const 28) (i32.const 15) (i32.const 5))
    (call $set_pal (i32.const 25) (i32.const 38) (i32.const 20) (i32.const 7))
    (call $set_pal (i32.const 26) (i32.const 48) (i32.const 26) (i32.const 9))
    (call $set_pal (i32.const 27) (i32.const 58) (i32.const 32) (i32.const 12))
    (call $set_pal (i32.const 28) (i32.const 68) (i32.const 40) (i32.const 15))
    (call $set_pal (i32.const 29) (i32.const 80) (i32.const 48) (i32.const 18))
    (call $set_pal (i32.const 30) (i32.const 90) (i32.const 58) (i32.const 22))
    (call $set_pal (i32.const 31) (i32.const 102) (i32.const 68) (i32.const 26))
    (call $set_pal (i32.const 32) (i32.const 112) (i32.const 78) (i32.const 30))
    (call $set_pal (i32.const 33) (i32.const 124) (i32.const 88) (i32.const 36))
    (call $set_pal (i32.const 34) (i32.const 135) (i32.const 98) (i32.const 42))
    (call $set_pal (i32.const 35) (i32.const 146) (i32.const 108) (i32.const 48))
    (call $set_pal (i32.const 36) (i32.const 156) (i32.const 118) (i32.const 54))
    (call $set_pal (i32.const 37) (i32.const 166) (i32.const 128) (i32.const 60))
    (call $set_pal (i32.const 38) (i32.const 176) (i32.const 138) (i32.const 68))
    (call $set_pal (i32.const 39) (i32.const 186) (i32.const 148) (i32.const 76))

    ;; Block type 3: stone → palette 40..55 (16 shades)
    (call $set_pal (i32.const 40) (i32.const 30) (i32.const 30) (i32.const 34))
    (call $set_pal (i32.const 41) (i32.const 40) (i32.const 40) (i32.const 44))
    (call $set_pal (i32.const 42) (i32.const 50) (i32.const 50) (i32.const 55))
    (call $set_pal (i32.const 43) (i32.const 60) (i32.const 60) (i32.const 66))
    (call $set_pal (i32.const 44) (i32.const 70) (i32.const 70) (i32.const 77))
    (call $set_pal (i32.const 45) (i32.const 80) (i32.const 80) (i32.const 88))
    (call $set_pal (i32.const 46) (i32.const 90) (i32.const 90) (i32.const 98))
    (call $set_pal (i32.const 47) (i32.const 100) (i32.const 100) (i32.const 108))
    (call $set_pal (i32.const 48) (i32.const 110) (i32.const 110) (i32.const 118))
    (call $set_pal (i32.const 49) (i32.const 120) (i32.const 120) (i32.const 128))
    (call $set_pal (i32.const 50) (i32.const 130) (i32.const 130) (i32.const 138))
    (call $set_pal (i32.const 51) (i32.const 140) (i32.const 140) (i32.const 148))
    (call $set_pal (i32.const 52) (i32.const 150) (i32.const 150) (i32.const 158))
    (call $set_pal (i32.const 53) (i32.const 160) (i32.const 160) (i32.const 168))
    (call $set_pal (i32.const 54) (i32.const 172) (i32.const 172) (i32.const 180))
    (call $set_pal (i32.const 55) (i32.const 185) (i32.const 185) (i32.const 192))

    ;; Block type 4: sand → palette 56..71 (16 shades)
    (call $set_pal (i32.const 56) (i32.const 90) (i32.const 75) (i32.const 35))
    (call $set_pal (i32.const 57) (i32.const 105) (i32.const 88) (i32.const 42))
    (call $set_pal (i32.const 58) (i32.const 118) (i32.const 100) (i32.const 48))
    (call $set_pal (i32.const 59) (i32.const 132) (i32.const 112) (i32.const 55))
    (call $set_pal (i32.const 60) (i32.const 145) (i32.const 124) (i32.const 62))
    (call $set_pal (i32.const 61) (i32.const 158) (i32.const 136) (i32.const 70))
    (call $set_pal (i32.const 62) (i32.const 170) (i32.const 148) (i32.const 78))
    (call $set_pal (i32.const 63) (i32.const 182) (i32.const 158) (i32.const 86))
    (call $set_pal (i32.const 64) (i32.const 194) (i32.const 170) (i32.const 95))
    (call $set_pal (i32.const 65) (i32.const 205) (i32.const 180) (i32.const 104))
    (call $set_pal (i32.const 66) (i32.const 214) (i32.const 190) (i32.const 112))
    (call $set_pal (i32.const 67) (i32.const 222) (i32.const 200) (i32.const 122))
    (call $set_pal (i32.const 68) (i32.const 230) (i32.const 210) (i32.const 132))
    (call $set_pal (i32.const 69) (i32.const 236) (i32.const 218) (i32.const 142))
    (call $set_pal (i32.const 70) (i32.const 242) (i32.const 226) (i32.const 152))
    (call $set_pal (i32.const 71) (i32.const 248) (i32.const 234) (i32.const 165))

    ;; Block type 5: water → palette 72..87 (16 shades)
    (call $set_pal (i32.const 72) (i32.const 5)  (i32.const 15) (i32.const 55))
    (call $set_pal (i32.const 73) (i32.const 8)  (i32.const 22) (i32.const 70))
    (call $set_pal (i32.const 74) (i32.const 12) (i32.const 30) (i32.const 85))
    (call $set_pal (i32.const 75) (i32.const 16) (i32.const 40) (i32.const 100))
    (call $set_pal (i32.const 76) (i32.const 22) (i32.const 50) (i32.const 118))
    (call $set_pal (i32.const 77) (i32.const 28) (i32.const 62) (i32.const 135))
    (call $set_pal (i32.const 78) (i32.const 35) (i32.const 75) (i32.const 152))
    (call $set_pal (i32.const 79) (i32.const 42) (i32.const 88) (i32.const 168))
    (call $set_pal (i32.const 80) (i32.const 50) (i32.const 100) (i32.const 182))
    (call $set_pal (i32.const 81) (i32.const 58) (i32.const 112) (i32.const 195))
    (call $set_pal (i32.const 82) (i32.const 66) (i32.const 125) (i32.const 206))
    (call $set_pal (i32.const 83) (i32.const 75) (i32.const 138) (i32.const 216))
    (call $set_pal (i32.const 84) (i32.const 85) (i32.const 150) (i32.const 224))
    (call $set_pal (i32.const 85) (i32.const 95) (i32.const 162) (i32.const 232))
    (call $set_pal (i32.const 86) (i32.const 108) (i32.const 175) (i32.const 238))
    (call $set_pal (i32.const 87) (i32.const 120) (i32.const 188) (i32.const 245))

    ;; Block type 6: wood → palette 88..103 (16 shades)
    (call $set_pal (i32.const 88)  (i32.const 20) (i32.const 10) (i32.const 3))
    (call $set_pal (i32.const 89)  (i32.const 28) (i32.const 15) (i32.const 5))
    (call $set_pal (i32.const 90)  (i32.const 36) (i32.const 20) (i32.const 7))
    (call $set_pal (i32.const 91)  (i32.const 45) (i32.const 25) (i32.const 10))
    (call $set_pal (i32.const 92)  (i32.const 55) (i32.const 32) (i32.const 13))
    (call $set_pal (i32.const 93)  (i32.const 64) (i32.const 38) (i32.const 16))
    (call $set_pal (i32.const 94)  (i32.const 74) (i32.const 45) (i32.const 20))
    (call $set_pal (i32.const 95)  (i32.const 84) (i32.const 52) (i32.const 24))
    (call $set_pal (i32.const 96)  (i32.const 94) (i32.const 60) (i32.const 28))
    (call $set_pal (i32.const 97)  (i32.const 104) (i32.const 68) (i32.const 33))
    (call $set_pal (i32.const 98)  (i32.const 112) (i32.const 76) (i32.const 38))
    (call $set_pal (i32.const 99)  (i32.const 122) (i32.const 84) (i32.const 43))
    (call $set_pal (i32.const 100) (i32.const 130) (i32.const 92) (i32.const 48))
    (call $set_pal (i32.const 101) (i32.const 140) (i32.const 100) (i32.const 54))
    (call $set_pal (i32.const 102) (i32.const 148) (i32.const 108) (i32.const 60))
    (call $set_pal (i32.const 103) (i32.const 158) (i32.const 118) (i32.const 68))

    ;; Block type 7: leaves → palette 104..119 (16 shades)
    (call $set_pal (i32.const 104) (i32.const 5)  (i32.const 22) (i32.const 3))
    (call $set_pal (i32.const 105) (i32.const 8)  (i32.const 32) (i32.const 5))
    (call $set_pal (i32.const 106) (i32.const 12) (i32.const 42) (i32.const 7))
    (call $set_pal (i32.const 107) (i32.const 18) (i32.const 55) (i32.const 10))
    (call $set_pal (i32.const 108) (i32.const 24) (i32.const 68) (i32.const 14))
    (call $set_pal (i32.const 109) (i32.const 30) (i32.const 82) (i32.const 18))
    (call $set_pal (i32.const 110) (i32.const 38) (i32.const 98) (i32.const 24))
    (call $set_pal (i32.const 111) (i32.const 46) (i32.const 112) (i32.const 30))
    (call $set_pal (i32.const 112) (i32.const 55) (i32.const 128) (i32.const 36))
    (call $set_pal (i32.const 113) (i32.const 64) (i32.const 142) (i32.const 42))
    (call $set_pal (i32.const 114) (i32.const 72) (i32.const 156) (i32.const 48))
    (call $set_pal (i32.const 115) (i32.const 82) (i32.const 170) (i32.const 55))
    (call $set_pal (i32.const 116) (i32.const 90) (i32.const 182) (i32.const 62))
    (call $set_pal (i32.const 117) (i32.const 100) (i32.const 195) (i32.const 70))
    (call $set_pal (i32.const 118) (i32.const 112) (i32.const 206) (i32.const 78))
    (call $set_pal (i32.const 119) (i32.const 125) (i32.const 218) (i32.const 88))

    ;; Block type 8: coal ore → palette 120..135 (16 shades)
    (call $set_pal (i32.const 120) (i32.const 12) (i32.const 12) (i32.const 14))
    (call $set_pal (i32.const 121) (i32.const 18) (i32.const 18) (i32.const 21))
    (call $set_pal (i32.const 122) (i32.const 25) (i32.const 25) (i32.const 28))
    (call $set_pal (i32.const 123) (i32.const 32) (i32.const 32) (i32.const 36))
    (call $set_pal (i32.const 124) (i32.const 40) (i32.const 40) (i32.const 45))
    (call $set_pal (i32.const 125) (i32.const 48) (i32.const 48) (i32.const 54))
    (call $set_pal (i32.const 126) (i32.const 58) (i32.const 58) (i32.const 64))
    (call $set_pal (i32.const 127) (i32.const 66) (i32.const 66) (i32.const 74))
    (call $set_pal (i32.const 128) (i32.const 76) (i32.const 76) (i32.const 84))
    (call $set_pal (i32.const 129) (i32.const 85) (i32.const 85) (i32.const 94))
    (call $set_pal (i32.const 130) (i32.const 95) (i32.const 95) (i32.const 104))
    (call $set_pal (i32.const 131) (i32.const 105) (i32.const 105) (i32.const 114))
    (call $set_pal (i32.const 132) (i32.const 115) (i32.const 115) (i32.const 124))
    (call $set_pal (i32.const 133) (i32.const 125) (i32.const 125) (i32.const 135))
    (call $set_pal (i32.const 134) (i32.const 136) (i32.const 136) (i32.const 146))
    (call $set_pal (i32.const 135) (i32.const 148) (i32.const 148) (i32.const 158))

    ;; Fog palette 136-151 (16 shades)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 16)))
      (call $set_pal (i32.add (i32.const 136) (local.get $i))
        (i32.add (i32.const 100) (i32.mul (local.get $i) (i32.const 4)))
        (i32.add (i32.const 130) (i32.mul (local.get $i) (i32.const 4)))
        (i32.add (i32.const 170) (i32.mul (local.get $i) (i32.const 3))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))

    ;; Water shimmer 152-155
    (call $set_pal (i32.const 152) (i32.const 40) (i32.const 90) (i32.const 175))
    (call $set_pal (i32.const 153) (i32.const 55) (i32.const 115) (i32.const 200))
    (call $set_pal (i32.const 154) (i32.const 70) (i32.const 140) (i32.const 220))
    (call $set_pal (i32.const 155) (i32.const 100) (i32.const 170) (i32.const 240))

    ;; Monster palettes
    ;; 156-171: Creeper (green)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 16)))
      (call $set_pal (i32.add (i32.const 156) (local.get $i))
        (i32.mul (local.get $i) (i32.const 4))
        (i32.add (i32.const 40) (i32.mul (local.get $i) (i32.const 12)))
        (i32.mul (local.get $i) (i32.const 2)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))

    ;; 172-187: Zombie (brownish)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 16)))
      (call $set_pal (i32.add (i32.const 172) (local.get $i))
        (i32.add (i32.const 40) (i32.mul (local.get $i) (i32.const 8)))
        (i32.add (i32.const 50) (i32.mul (local.get $i) (i32.const 6)))
        (i32.add (i32.const 20) (i32.mul (local.get $i) (i32.const 3))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))

    ;; 188-203: Skeleton (bone white)
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 16)))
      (call $set_pal (i32.add (i32.const 188) (local.get $i))
        (i32.add (i32.const 120) (i32.mul (local.get $i) (i32.const 8)))
        (i32.add (i32.const 115) (i32.mul (local.get $i) (i32.const 8)))
        (i32.add (i32.const 100) (i32.mul (local.get $i) (i32.const 8))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))

    ;; HUD: 240-247 white, 248-255 red
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 8)))
      (call $set_pal (i32.add (i32.const 240) (local.get $i))
        (i32.add (i32.const 128) (i32.mul (local.get $i) (i32.const 16)))
        (i32.add (i32.const 128) (i32.mul (local.get $i) (i32.const 16)))
        (i32.add (i32.const 128) (i32.mul (local.get $i) (i32.const 16))))
      (call $set_pal (i32.add (i32.const 248) (local.get $i))
        (i32.add (i32.const 128) (i32.mul (local.get $i) (i32.const 16)))
        (i32.mul (local.get $i) (i32.const 4))
        (i32.mul (local.get $i) (i32.const 4)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))

    ;; Special colors (moved to 204+)
    (call $set_pal (i32.const 204) (i32.const 255) (i32.const 255) (i32.const 255))
    (call $set_pal (i32.const 205) (i32.const 255) (i32.const 255) (i32.const 100))
    (call $set_pal (i32.const 206) (i32.const 20) (i32.const 15) (i32.const 15))
    (call $set_pal (i32.const 207) (i32.const 255) (i32.const 50) (i32.const 50))
    (call $set_pal (i32.const 208) (i32.const 50) (i32.const 255) (i32.const 100))

    ;; Initialize player position
    (f64.store (i32.const 0x10344) (f64.const 32.5))
    (f64.store (i32.const 0x1034C) (f64.const 32.5))
    (f64.store (i32.const 0x10354) (f64.const 0.0))
    (f64.store (i32.const 0x1035C)
      (f64.add (f64.convert_i32_s (call $terrain_height (i32.const 32) (i32.const 32))) (f64.const 1.7)))
    (f64.store (i32.const 0x10364) (f64.const 0.0))
    (i32.store (i32.const 0x1036C) (i32.const 1))
    (f64.store (i32.const 0x10374) (f64.const 0.0))

    ;; Game state
    (i32.store (i32.const 0x10390) (i32.const 0))     ;; mod_count
    (i32.store (i32.const 0x10394) (i32.const 1900))   ;; max_mods
    (i32.store (i32.const 0x10398) (i32.const 0))     ;; gods_angry
    (i32.store (i32.const 0x1039C) (i32.const 0))     ;; msg_timer
    (i32.store (i32.const 0x103A0) (i32.const 0))     ;; dig_cooldown
    (i32.store (i32.const 0x103A4) (i32.const 0))     ;; prev_mouse
    (i32.store (i32.const 0x103A8) (i32.const 1))     ;; selected_block
    (i32.store (i32.const 0x103AC) (i32.const 0))     ;; look_y

    ;; Spawn monsters
    (call $spawn_monsters)
    ;; Init font
    (call $init_font)
  )

  ;; ---- Spawn monsters ----
  (func $spawn_monsters
    (local $i i32) (local $addr i32) (local $angle f64) (local $dist f64)
    (local $mx f64) (local $my f64) (local $px f64) (local $py f64)
    (local.set $px (f64.load (i32.const 0x10344)))
    (local.set $py (f64.load (i32.const 0x1034C)))
    (local.set $i (i32.const 0))
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $i) (i32.const 24)))
      (local.set $addr (i32.add (i32.const 0x10900) (i32.mul (local.get $i) (i32.const 32))))
      (local.set $angle (f64.mul (f64.convert_i32_u (local.get $i)) (f64.const 0.2618)))
      (local.set $dist (f64.add (f64.const 8.0)
        (f64.mul (f64.convert_i32_u (i32.and (call $rand) (i32.const 15))) (f64.const 1.5))))
      (local.set $mx (f64.add (local.get $px)
        (f64.mul (call $cos_a (local.get $angle)) (local.get $dist))))
      (local.set $my (f64.add (local.get $py)
        (f64.mul (call $sin_a (local.get $angle)) (local.get $dist))))
      (i32.store (local.get $addr) (i32.const 1))
      (i32.store (i32.add (local.get $addr) (i32.const 4)) (i32.rem_u (local.get $i) (i32.const 3)))
      (f64.store (i32.add (local.get $addr) (i32.const 8)) (local.get $mx))
      (f64.store (i32.add (local.get $addr) (i32.const 16)) (local.get $my))
      (i32.store (i32.add (local.get $addr) (i32.const 24)) (i32.const 3))
      (i32.store (i32.add (local.get $addr) (i32.const 28)) (i32.and (call $rand) (i32.const 255)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; ---- Font init (mini 4x6 bitmap font) ----
  (func $init_font
    (local $base i32)
    (local.set $base (i32.const 0x19200))
    ;; '!' (33) offset=6
    (i32.store8 (i32.add (local.get $base) (i32.const 6)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 7)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 8)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 9)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 10)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 11)) (i32.const 0x00))
    ;; '0' offset=96
    (i32.store8 (i32.add (local.get $base) (i32.const 96)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 97)) (i32.const 0x09))
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
    ;; ':' offset=156
    (i32.store8 (i32.add (local.get $base) (i32.const 156)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 157)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 158)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 159)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 160)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 161)) (i32.const 0x00))
    ;; '/' offset=90
    (i32.store8 (i32.add (local.get $base) (i32.const 90)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 91)) (i32.const 0x02))
    (i32.store8 (i32.add (local.get $base) (i32.const 92)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 93)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 94)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 95)) (i32.const 0x00))
    ;; Letters A-Z at offset 198..
    (i32.store8 (i32.add (local.get $base) (i32.const 198)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 199)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 200)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 201)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 202)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 203)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 204)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 205)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 206)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 207)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 208)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 209)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 210)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 211)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 212)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 213)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 214)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 215)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 216)) (i32.const 0x0C))
    (i32.store8 (i32.add (local.get $base) (i32.const 217)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 218)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 219)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 220)) (i32.const 0x0C))
    (i32.store8 (i32.add (local.get $base) (i32.const 221)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 222)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 223)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 224)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 225)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 226)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 227)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 228)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 229)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 230)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 231)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 232)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 233)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 234)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 235)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 236)) (i32.const 0x0B))
    (i32.store8 (i32.add (local.get $base) (i32.const 237)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 238)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 239)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 240)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 241)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 242)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 243)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 244)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 245)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 246)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 247)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 248)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 249)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 250)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 251)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 252)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 253)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 254)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 255)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 256)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 257)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 258)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 259)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 260)) (i32.const 0x0C))
    (i32.store8 (i32.add (local.get $base) (i32.const 261)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 262)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 263)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 264)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 265)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 266)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 267)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 268)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 269)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 270)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 271)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 272)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 273)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 274)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 275)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 276)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 277)) (i32.const 0x0D))
    (i32.store8 (i32.add (local.get $base) (i32.const 278)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 279)) (i32.const 0x0B))
    (i32.store8 (i32.add (local.get $base) (i32.const 280)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 281)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 282)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 283)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 284)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 285)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 286)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 287)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 288)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 289)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 290)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 291)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 292)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 293)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 294)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 295)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 296)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 297)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 298)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 299)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 300)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 301)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 302)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 303)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 304)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 305)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 306)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 307)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 308)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 309)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 310)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 311)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 312)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 313)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 314)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 315)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 316)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 317)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 318)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 319)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 320)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 321)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 322)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 323)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 324)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 325)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 326)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 327)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 328)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 329)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 330)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 331)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 332)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 333)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 334)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 335)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 336)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 337)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 338)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 339)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 340)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 341)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 342)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 343)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 344)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 345)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 346)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 347)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 348)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 349)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 350)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 351)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 352)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 353)) (i32.const 0x00))
    ;; Lowercase copies (a-z = same as A-Z)
    (i32.store8 (i32.add (local.get $base) (i32.const 390)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 391)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 392)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 393)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 394)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 395)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 396)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 397)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 398)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 399)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 400)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 401)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 402)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 403)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 404)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 405)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 406)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 407)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 408)) (i32.const 0x0C))
    (i32.store8 (i32.add (local.get $base) (i32.const 409)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 410)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 411)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 412)) (i32.const 0x0C))
    (i32.store8 (i32.add (local.get $base) (i32.const 413)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 414)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 415)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 416)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 417)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 418)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 419)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 420)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 421)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 422)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 423)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 424)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 425)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 426)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 427)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 428)) (i32.const 0x0B))
    (i32.store8 (i32.add (local.get $base) (i32.const 429)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 430)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 431)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 432)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 433)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 434)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 435)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 436)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 437)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 438)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 439)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 440)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 441)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 442)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 443)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 444)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 445)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 446)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 447)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 448)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 449)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 450)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 451)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 452)) (i32.const 0x0C))
    (i32.store8 (i32.add (local.get $base) (i32.const 453)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 454)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 455)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 456)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 457)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 458)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 459)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 460)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 461)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 462)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 463)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 464)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 465)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 466)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 467)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 468)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 469)) (i32.const 0x0D))
    (i32.store8 (i32.add (local.get $base) (i32.const 470)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 471)) (i32.const 0x0B))
    (i32.store8 (i32.add (local.get $base) (i32.const 472)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 473)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 474)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 475)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 476)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 477)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 478)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 479)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 480)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 481)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 482)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 483)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 484)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 485)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 486)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 487)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 488)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 489)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 490)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 491)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 492)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 493)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 494)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 495)) (i32.const 0x0A))
    (i32.store8 (i32.add (local.get $base) (i32.const 496)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 497)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 498)) (i32.const 0x07))
    (i32.store8 (i32.add (local.get $base) (i32.const 499)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 500)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 501)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 502)) (i32.const 0x0E))
    (i32.store8 (i32.add (local.get $base) (i32.const 503)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 504)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 505)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 506)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 507)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 508)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 509)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 510)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 511)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 512)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 513)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 514)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 515)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 516)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 517)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 518)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 519)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 520)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 521)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 522)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 523)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 524)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 525)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 526)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 527)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 528)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 529)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 530)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 531)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 532)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 533)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 534)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 535)) (i32.const 0x09))
    (i32.store8 (i32.add (local.get $base) (i32.const 536)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 537)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 538)) (i32.const 0x04))
    (i32.store8 (i32.add (local.get $base) (i32.const 539)) (i32.const 0x00))
    (i32.store8 (i32.add (local.get $base) (i32.const 540)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 541)) (i32.const 0x01))
    (i32.store8 (i32.add (local.get $base) (i32.const 542)) (i32.const 0x06))
    (i32.store8 (i32.add (local.get $base) (i32.const 543)) (i32.const 0x08))
    (i32.store8 (i32.add (local.get $base) (i32.const 544)) (i32.const 0x0F))
    (i32.store8 (i32.add (local.get $base) (i32.const 545)) (i32.const 0x00))
  )

  ;; ============================================================
  ;; Strings
  ;; ============================================================
  (data (i32.const 0x19000) "VGACRAFT RT\00")
  (data (i32.const 0x19010) "WASD:move LR:turn\00")
  (data (i32.const 0x19030) "CLICK:dig SHIFT:place\00")
  (data (i32.const 0x19050) "You angered the\00")
  (data (i32.const 0x19070) "Minecraft gods by\00")
  (data (i32.const 0x19090) "digging too much!\00")
  (data (i32.const 0x190B0) "Blocks:\00")
  (data (i32.const 0x190C0) "Mods:\00")
  (data (i32.const 0x190D0) "/\00")

  ;; ============================================================
  ;; 3D DDA VOXEL RAYTRACER — cast_ray
  ;; Returns: block_type in result, face via global
  ;; Amanatides & Woo grid traversal in 3D
  ;; ============================================================
  ;; Global to communicate hit face, distance, and voxel coords back
  (global $g_hit_face (mut i32) (i32.const 0))
  (global $g_hit_dist (mut f64) (f64.const 0.0))
  (global $g_hit_vx (mut i32) (i32.const 0))
  (global $g_hit_vy (mut i32) (i32.const 0))
  (global $g_hit_vz (mut i32) (i32.const 0))

  (func $cast_ray (param $ox f64) (param $oy f64) (param $oz f64)
                   (param $dx f64) (param $dy f64) (param $dz f64)
                   (result i32)
    (local $vx i32) (local $vy i32) (local $vz i32)
    (local $step_x i32) (local $step_y i32) (local $step_z i32)
    (local $t_max_x f64) (local $t_max_y f64) (local $t_max_z f64)
    (local $t_delta_x f64) (local $t_delta_y f64) (local $t_delta_z f64)
    (local $steps i32) (local $block i32) (local $face i32)
    (local $t_cur f64)

    ;; Starting voxel
    (local.set $vx (i32.trunc_f64_s (f64.floor (local.get $ox))))
    (local.set $vy (i32.trunc_f64_s (f64.floor (local.get $oy))))
    (local.set $vz (i32.trunc_f64_s (f64.floor (local.get $oz))))

    ;; Step direction and t_delta for X
    (if (f64.gt (local.get $dx) (f64.const 0.0))
      (then
        (local.set $step_x (i32.const 1))
        (local.set $t_max_x (f64.div
          (f64.sub (f64.add (f64.convert_i32_s (local.get $vx)) (f64.const 1.0)) (local.get $ox))
          (local.get $dx)))
        (local.set $t_delta_x (f64.div (f64.const 1.0) (local.get $dx))))
      (else (if (f64.lt (local.get $dx) (f64.const 0.0))
        (then
          (local.set $step_x (i32.const -1))
          (local.set $t_max_x (f64.div
            (f64.sub (f64.convert_i32_s (local.get $vx)) (local.get $ox))
            (local.get $dx)))
          (local.set $t_delta_x (f64.div (f64.const -1.0) (local.get $dx))))
        (else
          (local.set $step_x (i32.const 0))
          (local.set $t_max_x (f64.const 999999.0))
          (local.set $t_delta_x (f64.const 999999.0))))))

    ;; Step direction and t_delta for Y
    (if (f64.gt (local.get $dy) (f64.const 0.0))
      (then
        (local.set $step_y (i32.const 1))
        (local.set $t_max_y (f64.div
          (f64.sub (f64.add (f64.convert_i32_s (local.get $vy)) (f64.const 1.0)) (local.get $oy))
          (local.get $dy)))
        (local.set $t_delta_y (f64.div (f64.const 1.0) (local.get $dy))))
      (else (if (f64.lt (local.get $dy) (f64.const 0.0))
        (then
          (local.set $step_y (i32.const -1))
          (local.set $t_max_y (f64.div
            (f64.sub (f64.convert_i32_s (local.get $vy)) (local.get $oy))
            (local.get $dy)))
          (local.set $t_delta_y (f64.div (f64.const -1.0) (local.get $dy))))
        (else
          (local.set $step_y (i32.const 0))
          (local.set $t_max_y (f64.const 999999.0))
          (local.set $t_delta_y (f64.const 999999.0))))))

    ;; Step direction and t_delta for Z
    (if (f64.gt (local.get $dz) (f64.const 0.0))
      (then
        (local.set $step_z (i32.const 1))
        (local.set $t_max_z (f64.div
          (f64.sub (f64.add (f64.convert_i32_s (local.get $vz)) (f64.const 1.0)) (local.get $oz))
          (local.get $dz)))
        (local.set $t_delta_z (f64.div (f64.const 1.0) (local.get $dz))))
      (else (if (f64.lt (local.get $dz) (f64.const 0.0))
        (then
          (local.set $step_z (i32.const -1))
          (local.set $t_max_z (f64.div
            (f64.sub (f64.convert_i32_s (local.get $vz)) (local.get $oz))
            (local.get $dz)))
          (local.set $t_delta_z (f64.div (f64.const -1.0) (local.get $dz))))
        (else
          (local.set $step_z (i32.const 0))
          (local.set $t_max_z (f64.const 999999.0))
          (local.set $t_delta_z (f64.const 999999.0))))))

    (local.set $face (i32.const 0))
    (local.set $t_cur (f64.const 0.0))
    (local.set $steps (i32.const 0))

    ;; Check starting block
    (if (i32.and (i32.ge_s (local.get $vz) (i32.const -1)) (i32.le_s (local.get $vz) (i32.const 24)))
      (then
        (local.set $block (call $get_block (local.get $vx) (local.get $vy) (local.get $vz)))
        (if (i32.ne (local.get $block) (i32.const 0))
          (then
            (global.set $g_hit_face (i32.const 0))
            (global.set $g_hit_dist (f64.const 0.0))
            (global.set $g_hit_vx (local.get $vx))
            (global.set $g_hit_vy (local.get $vy))
            (global.set $g_hit_vz (local.get $vz))
            (return (local.get $block))))))

    ;; Main traversal loop — max 48 steps, view distance ~24 blocks
    (block $done (loop $lp
      (br_if $done (i32.ge_u (local.get $steps) (i32.const 48)))

      ;; Step along smallest t_max axis
      (if (f64.le (local.get $t_max_x) (local.get $t_max_y))
        (then
          (if (f64.le (local.get $t_max_x) (local.get $t_max_z))
            (then
              ;; Step X
              (local.set $t_cur (local.get $t_max_x))
              (local.set $vx (i32.add (local.get $vx) (local.get $step_x)))
              (local.set $t_max_x (f64.add (local.get $t_max_x) (local.get $t_delta_x)))
              ;; face: 1=bright(+X), 2=dim(-X)
              (if (i32.eq (local.get $step_x) (i32.const 1))
                (then (local.set $face (i32.const 2)))
                (else (local.set $face (i32.const 1)))))
            (else
              ;; Step Z
              (local.set $t_cur (local.get $t_max_z))
              (local.set $vz (i32.add (local.get $vz) (local.get $step_z)))
              (local.set $t_max_z (f64.add (local.get $t_max_z) (local.get $t_delta_z)))
              ;; face: 0=top, 3=bottom
              (if (i32.eq (local.get $step_z) (i32.const 1))
                (then (local.set $face (i32.const 3)))
                (else (local.set $face (i32.const 0)))))))
        (else
          (if (f64.le (local.get $t_max_y) (local.get $t_max_z))
            (then
              ;; Step Y
              (local.set $t_cur (local.get $t_max_y))
              (local.set $vy (i32.add (local.get $vy) (local.get $step_y)))
              (local.set $t_max_y (f64.add (local.get $t_max_y) (local.get $t_delta_y)))
              ;; face: 1=bright(+Y), 2=dim(-Y)
              (if (i32.eq (local.get $step_y) (i32.const 1))
                (then (local.set $face (i32.const 2)))
                (else (local.set $face (i32.const 1)))))
            (else
              ;; Step Z
              (local.set $t_cur (local.get $t_max_z))
              (local.set $vz (i32.add (local.get $vz) (local.get $step_z)))
              (local.set $t_max_z (f64.add (local.get $t_max_z) (local.get $t_delta_z)))
              (if (i32.eq (local.get $step_z) (i32.const 1))
                (then (local.set $face (i32.const 3)))
                (else (local.set $face (i32.const 0))))))))

      ;; Bail if too far or out of Z range
      (br_if $done (f64.gt (local.get $t_cur) (f64.const 24.0)))
      (br_if $done (i32.lt_s (local.get $vz) (i32.const -1)))
      (br_if $done (i32.gt_s (local.get $vz) (i32.const 24)))

      ;; Check block
      (local.set $block (call $get_block (local.get $vx) (local.get $vy) (local.get $vz)))
      (if (i32.ne (local.get $block) (i32.const 0))
        (then
          (global.set $g_hit_face (local.get $face))
          (global.set $g_hit_dist (local.get $t_cur))
          (global.set $g_hit_vx (local.get $vx))
          (global.set $g_hit_vy (local.get $vy))
          (global.set $g_hit_vz (local.get $vz))
          (return (local.get $block))))

      (local.set $steps (i32.add (local.get $steps) (i32.const 1)))
      (br $lp)))

    ;; No hit
    (global.set $g_hit_face (i32.const 0))
    (global.set $g_hit_dist (f64.const 999.0))
    (global.set $g_hit_vx (i32.const 0))
    (global.set $g_hit_vy (i32.const 0))
    (global.set $g_hit_vz (i32.const 0))
    (i32.const 0)
  )

  ;; ============================================================
  ;; PROCEDURAL TEXTURES — compute per-pixel shade adjustment
  ;; Uses hit voxel coords + fractional UV on face
  ;; Returns shade adjustment (-2 to +2)
  ;; ============================================================
  (func $texture_offset (param $type i32) (param $face i32)
        (param $vx i32) (param $vy i32) (param $vz i32)
        (param $fu i32) (param $fv i32) (result i32)
    (local $h i32) (local $h2 i32) (local $h3 i32)
    (local $result i32)
    ;; Base hash combining voxel + UV
    (local.set $h (i32.and (call $hash3d
      (i32.add (local.get $vx) (i32.mul (local.get $fu) (i32.const 37)))
      (i32.add (local.get $vy) (i32.mul (local.get $fv) (i32.const 53)))
      (local.get $vz)) (i32.const 255)))
    ;; Per-block-position hash for variation
    (local.set $h2 (i32.and (call $hash3d (local.get $vx) (local.get $vy) (local.get $vz)) (i32.const 255)))

    ;; Grass (type 1)
    (if (i32.eq (local.get $type) (i32.const 1))
      (then
        (if (i32.eq (local.get $face) (i32.const 0))
          (then
            ;; Top face: grass blades pattern - vertical streaks
            (local.set $h3 (i32.and (call $hash3d
              (local.get $fu)
              (i32.add (local.get $vx) (i32.mul (local.get $vy) (i32.const 17)))
              (i32.const 0)) (i32.const 15)))
            (if (i32.lt_u (local.get $h3) (i32.const 3))
              (then (return (i32.const -1))))
            (if (i32.gt_u (local.get $h3) (i32.const 12))
              (then (return (i32.const 1))))
            ;; Occasional flower/dark patch
            (if (i32.and (i32.lt_u (local.get $h) (i32.const 12)) (i32.lt_u (local.get $h2) (i32.const 40)))
              (then (return (i32.const 2))))
            (return (i32.const 0)))
          (else
            ;; Side face: dirt showing through with grass line at top
            (if (i32.eq (local.get $fv) (i32.const 0))
              (then (return (i32.const 1))))
            (if (i32.lt_u (local.get $h) (i32.const 60))
              (then (return (i32.const -1))))
            (return (i32.const 0))))))

    ;; Dirt (type 2)
    (if (i32.eq (local.get $type) (i32.const 2))
      (then
        ;; Specks and pebbles
        (if (i32.lt_u (local.get $h) (i32.const 30))
          (then (return (i32.const -1))))
        (if (i32.gt_u (local.get $h) (i32.const 230))
          (then (return (i32.const 1))))
        ;; Occasional root/dark streak
        (local.set $h3 (i32.and (call $hash3d
          (i32.add (local.get $fu) (i32.mul (local.get $vx) (i32.const 7)))
          (local.get $fv) (local.get $vz)) (i32.const 31)))
        (if (i32.eqz (local.get $h3))
          (then (return (i32.const -2))))
        (return (i32.const 0))))

    ;; Stone (type 3)
    (if (i32.eq (local.get $type) (i32.const 3))
      (then
        ;; Cracks and mineral veins
        (local.set $h3 (i32.and (call $hash3d
          (i32.add (local.get $fu) (i32.mul (local.get $vx) (i32.const 13)))
          (i32.add (local.get $fv) (i32.mul (local.get $vy) (i32.const 19)))
          (local.get $vz)) (i32.const 63)))
        (if (i32.lt_u (local.get $h3) (i32.const 3))
          (then (return (i32.const -2))))
        (if (i32.lt_u (local.get $h) (i32.const 40))
          (then (return (i32.const -1))))
        (if (i32.gt_u (local.get $h) (i32.const 220))
          (then (return (i32.const 1))))
        (return (i32.const 0))))

    ;; Sand (type 4)
    (if (i32.eq (local.get $type) (i32.const 4))
      (then
        ;; Granular - lots of tiny variation
        (local.set $result (i32.sub (i32.and (local.get $h) (i32.const 3)) (i32.const 1)))
        (return (local.get $result))))

    ;; Wood (type 6)
    (if (i32.eq (local.get $type) (i32.const 6))
      (then
        (if (i32.eq (local.get $face) (i32.const 0))
          (then
            ;; Top/bottom: ring pattern using distance from center
            (local.set $h3 (i32.and
              (i32.add
                (i32.mul (i32.sub (local.get $fu) (i32.const 4)) (i32.sub (local.get $fu) (i32.const 4)))
                (i32.mul (i32.sub (local.get $fv) (i32.const 4)) (i32.sub (local.get $fv) (i32.const 4))))
              (i32.const 3)))
            (return (i32.sub (local.get $h3) (i32.const 1))))
          (else
            ;; Side: vertical grain lines
            (local.set $h3 (i32.and (call $hash3d
              (local.get $fu)
              (i32.add (local.get $vx) (local.get $vy))
              (i32.const 6)) (i32.const 7)))
            (if (i32.lt_u (local.get $h3) (i32.const 2))
              (then (return (i32.const -1))))
            (return (i32.const 0))))))

    ;; Leaves (type 7)
    (if (i32.eq (local.get $type) (i32.const 7))
      (then
        ;; Leafy holes and variation
        (if (i32.lt_u (local.get $h) (i32.const 25))
          (then (return (i32.const -2))))
        (if (i32.gt_u (local.get $h) (i32.const 200))
          (then (return (i32.const 1))))
        (return (i32.const 0))))

    ;; Coal (type 8)
    (if (i32.eq (local.get $type) (i32.const 8))
      (then
        ;; Dark veins in stone
        (local.set $h3 (i32.and (call $hash3d
          (i32.add (local.get $fu) (i32.mul (local.get $vx) (i32.const 11)))
          (i32.add (local.get $fv) (i32.mul (local.get $vy) (i32.const 23)))
          (i32.mul (local.get $vz) (i32.const 7))) (i32.const 15)))
        (if (i32.lt_u (local.get $h3) (i32.const 4))
          (then (return (i32.const -2))))
        (if (i32.gt_u (local.get $h) (i32.const 200))
          (then (return (i32.const 1))))
        (return (i32.const 0))))

    ;; Default: no texture offset
    (i32.const 0)
  )

  ;; ============================================================
  ;; ORDERED DITHERING — 4x4 Bayer matrix
  ;; Returns 0 or 1 based on pixel position and fractional shade
  ;; frac_shade: 0-15 (sub-step within shade level), threshold against Bayer
  ;; With 16 shade levels + 16 sub-steps = 256 effective luminance levels
  ;; ============================================================
  (func $dither_test (param $px i32) (param $py i32) (param $frac i32) (result i32)
    (local $bx i32) (local $by i32) (local $threshold i32) (local $idx i32)
    ;; 4x4 Bayer matrix (thresholds 0-15)
    ;; [ 0  8  2 10]
    ;; [12  4 14  6]
    ;; [ 3 11  1  9]
    ;; [15  7 13  5]
    (local.set $bx (i32.and (local.get $px) (i32.const 3)))
    (local.set $by (i32.and (local.get $py) (i32.const 3)))
    (local.set $idx (i32.add (i32.mul (local.get $by) (i32.const 4)) (local.get $bx)))
    ;; Look up from inline table using nested ifs
    (local.set $threshold (i32.const 0))
    (if (i32.eq (local.get $idx) (i32.const 0)) (then (local.set $threshold (i32.const 0))))
    (if (i32.eq (local.get $idx) (i32.const 1)) (then (local.set $threshold (i32.const 8))))
    (if (i32.eq (local.get $idx) (i32.const 2)) (then (local.set $threshold (i32.const 2))))
    (if (i32.eq (local.get $idx) (i32.const 3)) (then (local.set $threshold (i32.const 10))))
    (if (i32.eq (local.get $idx) (i32.const 4)) (then (local.set $threshold (i32.const 12))))
    (if (i32.eq (local.get $idx) (i32.const 5)) (then (local.set $threshold (i32.const 4))))
    (if (i32.eq (local.get $idx) (i32.const 6)) (then (local.set $threshold (i32.const 14))))
    (if (i32.eq (local.get $idx) (i32.const 7)) (then (local.set $threshold (i32.const 6))))
    (if (i32.eq (local.get $idx) (i32.const 8)) (then (local.set $threshold (i32.const 3))))
    (if (i32.eq (local.get $idx) (i32.const 9)) (then (local.set $threshold (i32.const 11))))
    (if (i32.eq (local.get $idx) (i32.const 10)) (then (local.set $threshold (i32.const 1))))
    (if (i32.eq (local.get $idx) (i32.const 11)) (then (local.set $threshold (i32.const 9))))
    (if (i32.eq (local.get $idx) (i32.const 12)) (then (local.set $threshold (i32.const 15))))
    (if (i32.eq (local.get $idx) (i32.const 13)) (then (local.set $threshold (i32.const 7))))
    (if (i32.eq (local.get $idx) (i32.const 14)) (then (local.set $threshold (i32.const 13))))
    (if (i32.eq (local.get $idx) (i32.const 15)) (then (local.set $threshold (i32.const 5))))
    ;; frac is 0-15, compare with threshold to decide if we bump up
    (if (i32.gt_u (local.get $frac) (local.get $threshold))
      (then (return (i32.const 1))))
    (i32.const 0)
  )

  ;; ============================================================
  ;; FRAME — Per-pixel voxel raytracer
  ;; ============================================================
  (func (export "frame")
    (local $px_col i32) (local $px_row i32) (local $tick i32) (local $keys i32)
    (local $px f64) (local $py f64) (local $pz f64) (local $angle f64)
    (local $cos_a_v f64) (local $sin_a_v f64)
    (local $move_x f64) (local $move_y f64) (local $speed f64)
    (local $mouse_btn i32) (local $prev_mouse i32)
    (local $mouse_x i32) (local $mouse_y i32) (local $look_y i32)
    (local $msg_timer i32) (local $dig_cd i32)
    (local $vz f64) (local $on_ground i32) (local $ground_h i32)
    (local $bob f64) (local $bob_phase f64)
    (local $new_px f64) (local $new_py f64)
    (local $check_x i32) (local $check_y i32) (local $check_h i32)
    (local $frame_ct i32)
    ;; Ray-tracing locals
    (local $screen_u f64) (local $screen_v f64)
    (local $ray_dx f64) (local $ray_dy f64) (local $ray_dz f64)
    (local $fwd_x f64) (local $fwd_y f64) (local $fwd_z f64)
    (local $right_x f64) (local $right_y f64)
    (local $up_x f64) (local $up_y f64) (local $up_z f64)
    (local $pitch f64)
    (local $cos_pitch f64) (local $sin_pitch f64)
    (local $hit_type i32) (local $face i32) (local $dist f64)
    (local $shade i32) (local $color i32)
    (local $fb_addr i32)
    (local $sky_idx i32)
    (local $len f64)
    ;; Texture/dither locals
    (local $hit_vx i32) (local $hit_vy i32) (local $hit_vz i32)
    (local $hit_px f64) (local $hit_py f64) (local $hit_pz f64)
    (local $tex_u i32) (local $tex_v i32)
    (local $tex_off i32)
    (local $shade_full i32) (local $shade_frac i32)
    (local $dither_bump i32)
    ;; Monster locals
    (local $i i32) (local $m_addr i32) (local $m_active i32)
    (local $m_type i32) (local $m_wx f64) (local $m_wy f64)
    (local $dx f64) (local $dy f64) (local $m_dist f64)

    (local.set $tick (i32.load (i32.const 12)))
    (local.set $frame_ct (i32.load (i32.const 0)))
    (local.set $keys (i32.load8_u (i32.const 0x10)))
    (local.set $mouse_btn (i32.load8_u (i32.const 0x08)))
    (local.set $prev_mouse (i32.load (i32.const 0x103A4)))

    ;; Load player
    (local.set $px (f64.load (i32.const 0x10344)))
    (local.set $py (f64.load (i32.const 0x1034C)))
    (local.set $angle (f64.load (i32.const 0x10354)))
    (local.set $pz (f64.load (i32.const 0x1035C)))
    (local.set $vz (f64.load (i32.const 0x10364)))
    (local.set $on_ground (i32.load (i32.const 0x1036C)))
    (local.set $bob_phase (f64.load (i32.const 0x10374)))
    (local.set $look_y (i32.load (i32.const 0x103AC)))

    ;; ---- Mouse X → yaw (horizontal look) ----
    (local.set $mouse_x (i32.or
      (i32.load8_u (i32.const 0x04))
      (i32.shl (i32.load8_u (i32.const 0x05)) (i32.const 8))))
    ;; Map mouse_x (0..320) to angle: center=160, sensitivity ~0.01 rad/pixel
    (local.set $angle (f64.add (local.get $angle)
      (f64.mul
        (f64.sub (f64.convert_i32_s (local.get $mouse_x)) (f64.const 160.0))
        (f64.const 0.0002))))

    ;; ---- Mouse Y → look pitch ----
    (local.set $mouse_y (i32.or
      (i32.load8_u (i32.const 0x06))
      (i32.shl (i32.load8_u (i32.const 0x07)) (i32.const 8))))
    (local.set $look_y (i32.trunc_f64_s (f64.mul
      (f64.sub (f64.convert_i32_s (local.get $mouse_y)) (f64.const 100.0))
      (f64.const -0.6))))
    (if (i32.lt_s (local.get $look_y) (i32.const -60))
      (then (local.set $look_y (i32.const -60))))
    (if (i32.gt_s (local.get $look_y) (i32.const 60))
      (then (local.set $look_y (i32.const 60))))
    (i32.store (i32.const 0x103AC) (local.get $look_y))

    ;; ---- Input ----
    (local.set $speed (f64.const 0.06))
    ;; Turn (Left arrow/A = subtract angle, Right arrow/D = add angle)
    (if (i32.and (local.get $keys) (i32.const 4))
      (then (local.set $angle (f64.add (local.get $angle) (f64.const 0.04)))))
    (if (i32.and (local.get $keys) (i32.const 8))
      (then (local.set $angle (f64.sub (local.get $angle) (f64.const 0.04)))))

    (local.set $cos_a_v (call $cos_a (local.get $angle)))
    (local.set $sin_a_v (call $sin_a (local.get $angle)))

    (local.set $move_x (f64.const 0.0))
    (local.set $move_y (f64.const 0.0))
    ;; Forward
    (if (i32.and (local.get $keys) (i32.const 1))
      (then
        (local.set $move_x (f64.add (local.get $move_x) (f64.mul (local.get $cos_a_v) (local.get $speed))))
        (local.set $move_y (f64.add (local.get $move_y) (f64.mul (local.get $sin_a_v) (local.get $speed))))))
    ;; Backward
    (if (i32.and (local.get $keys) (i32.const 2))
      (then
        (local.set $move_x (f64.sub (local.get $move_x) (f64.mul (local.get $cos_a_v) (local.get $speed))))
        (local.set $move_y (f64.sub (local.get $move_y) (f64.mul (local.get $sin_a_v) (local.get $speed))))))

    ;; Collision check
    (local.set $new_px (f64.add (local.get $px) (local.get $move_x)))
    (local.set $new_py (f64.add (local.get $py) (local.get $move_y)))
    (local.set $check_x (i32.trunc_f64_s (f64.floor (local.get $new_px))))
    (local.set $check_y (i32.trunc_f64_s (f64.floor (local.get $new_py))))
    (local.set $check_h (call $terrain_height (local.get $check_x) (local.get $check_y)))
    (if (i32.le_s (local.get $check_h) (i32.add (i32.trunc_f64_s (local.get $pz)) (i32.const 1)))
      (then
        (local.set $px (local.get $new_px))
        (local.set $py (local.get $new_py))))

    ;; Gravity
    (local.set $ground_h (call $terrain_height
      (i32.trunc_f64_s (f64.floor (local.get $px)))
      (i32.trunc_f64_s (f64.floor (local.get $py)))))
    (local.set $vz (f64.sub (local.get $vz) (f64.const 0.015)))
    (local.set $pz (f64.add (local.get $pz) (local.get $vz)))
    (if (f64.le (local.get $pz) (f64.add (f64.convert_i32_s (local.get $ground_h)) (f64.const 1.7)))
      (then
        (local.set $pz (f64.add (f64.convert_i32_s (local.get $ground_h)) (f64.const 1.7)))
        (local.set $vz (f64.const 0.0))
        (local.set $on_ground (i32.const 1)))
      (else (local.set $on_ground (i32.const 0))))

    ;; Jump
    (if (i32.and (i32.and (local.get $keys) (i32.const 16)) (local.get $on_ground))
      (then (local.set $vz (f64.const 0.18))))

    ;; Head bob
    (if (i32.and (local.get $on_ground)
          (i32.or (i32.and (local.get $keys) (i32.const 1))
                  (i32.and (local.get $keys) (i32.const 2))))
      (then
        (local.set $bob_phase (f64.add (local.get $bob_phase) (f64.const 0.15)))
        (local.set $bob (f64.mul (call $sin_a (local.get $bob_phase)) (f64.const 0.08))))
      (else (local.set $bob (f64.const 0.0))))

    ;; Digging
    (local.set $dig_cd (i32.load (i32.const 0x103A0)))
    (if (i32.gt_s (local.get $dig_cd) (i32.const 0))
      (then (i32.store (i32.const 0x103A0) (i32.sub (local.get $dig_cd) (i32.const 1)))))
    (if (i32.and
          (i32.and (local.get $mouse_btn) (i32.const 1))
          (i32.eqz (i32.and (local.get $prev_mouse) (i32.const 1))))
      (then
        (if (i32.eqz (i32.load (i32.const 0x103A0)))
          (then
            (call $dig_or_place (local.get $px) (local.get $py) (local.get $pz) (local.get $angle)
              (i32.and (local.get $keys) (i32.const 128)))
            (i32.store (i32.const 0x103A0) (i32.const 10))))))
    (i32.store (i32.const 0x103A4) (i32.load8_u (i32.const 0x08)))

    ;; Store player
    (f64.store (i32.const 0x10344) (local.get $px))
    (f64.store (i32.const 0x1034C) (local.get $py))
    (f64.store (i32.const 0x10354) (local.get $angle))
    (f64.store (i32.const 0x1035C) (local.get $pz))
    (f64.store (i32.const 0x10364) (local.get $vz))
    (i32.store (i32.const 0x1036C) (local.get $on_ground))
    (f64.store (i32.const 0x10374) (local.get $bob_phase))

    ;; ---- Update monsters (AI) ----
    (local.set $i (i32.const 0))
    (block $mob_done (loop $mob_lp
      (br_if $mob_done (i32.ge_u (local.get $i) (i32.const 24)))
      (local.set $m_addr (i32.add (i32.const 0x10900) (i32.mul (local.get $i) (i32.const 32))))
      (local.set $m_active (i32.load (local.get $m_addr)))
      (if (local.get $m_active)
        (then
          (local.set $m_wx (f64.load (i32.add (local.get $m_addr) (i32.const 8))))
          (local.set $m_wy (f64.load (i32.add (local.get $m_addr) (i32.const 16))))
          (local.set $dx (f64.sub (local.get $px) (local.get $m_wx)))
          (local.set $dy (f64.sub (local.get $py) (local.get $m_wy)))
          (local.set $m_dist (f64.sqrt (f64.add (f64.mul (local.get $dx) (local.get $dx))
                                                 (f64.mul (local.get $dy) (local.get $dy)))))
          (if (f64.gt (local.get $m_dist) (f64.const 3.0))
            (then
              (f64.store (i32.add (local.get $m_addr) (i32.const 8))
                (f64.add (local.get $m_wx) (f64.mul (f64.div (local.get $dx) (local.get $m_dist)) (f64.const 0.01))))
              (f64.store (i32.add (local.get $m_addr) (i32.const 16))
                (f64.add (local.get $m_wy) (f64.mul (f64.div (local.get $dy) (local.get $m_dist)) (f64.const 0.01))))))
          (i32.store (i32.add (local.get $m_addr) (i32.const 28))
            (i32.add (i32.load (i32.add (local.get $m_addr) (i32.const 28))) (i32.const 1)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $mob_lp)))

    ;; ============================================================
    ;; PER-PIXEL RAYTRACING
    ;; ============================================================
    ;; Build camera basis vectors from yaw (angle) and pitch (look_y)
    ;; pitch = look_y * pi/180 * some scale
    (local.set $pitch (f64.mul (f64.convert_i32_s (local.get $look_y)) (f64.const 0.015)))

    (local.set $cos_pitch (call $cos_a (local.get $pitch)))
    (local.set $sin_pitch (call $sin_a (local.get $pitch)))

    ;; Forward direction in world space (yaw + pitch)
    ;; fwd = (cos(yaw)*cos(pitch), sin(yaw)*cos(pitch), sin(pitch))
    (local.set $fwd_x (f64.mul (local.get $cos_a_v) (local.get $cos_pitch)))
    (local.set $fwd_y (f64.mul (local.get $sin_a_v) (local.get $cos_pitch)))
    (local.set $fwd_z (local.get $sin_pitch))

    ;; Right = (sin(yaw), -cos(yaw), 0) — perpendicular to forward on XY plane
    (local.set $right_x (local.get $sin_a_v))
    (local.set $right_y (f64.neg (local.get $cos_a_v)))

    ;; Up = right × fwd (simplified for our coordinate system)
    ;; up = (-cos(yaw)*sin(pitch), -sin(yaw)*sin(pitch), cos(pitch))
    (local.set $up_x (f64.neg (f64.mul (local.get $cos_a_v) (local.get $sin_pitch))))
    (local.set $up_y (f64.neg (f64.mul (local.get $sin_a_v) (local.get $sin_pitch))))
    (local.set $up_z (local.get $cos_pitch))

    ;; FOV ~60 degrees → half-plane distance = 1.0 / tan(30°) ≈ 1.732
    ;; We'll use plane_dist = 1.6 for a nice FOV

    (local.set $px_row (i32.const 0))
    (block $row_done (loop $row_lp
      (br_if $row_done (i32.ge_s (local.get $px_row) (i32.const 200)))

      ;; screen_v: map row to [-0.625, 0.625] (200/320 = 0.625 aspect)
      (local.set $screen_v (f64.mul
        (f64.sub (f64.const 0.5) (f64.div (f64.convert_i32_s (local.get $px_row)) (f64.const 200.0)))
        (f64.const 1.25)))

      (local.set $px_col (i32.const 0))
      (block $col_done (loop $col_lp
        (br_if $col_done (i32.ge_s (local.get $px_col) (i32.const 320)))

        ;; screen_u: map col to [-1.0, 1.0]
        (local.set $screen_u (f64.sub
          (f64.div (f64.convert_i32_s (local.get $px_col)) (f64.const 160.0))
          (f64.const 1.0)))

        ;; Ray direction = fwd * 1.6 + right * screen_u + up * screen_v
        (local.set $ray_dx (f64.add (f64.add
          (f64.mul (local.get $fwd_x) (f64.const 1.6))
          (f64.mul (local.get $right_x) (local.get $screen_u)))
          (f64.mul (local.get $up_x) (local.get $screen_v))))
        (local.set $ray_dy (f64.add (f64.add
          (f64.mul (local.get $fwd_y) (f64.const 1.6))
          (f64.mul (local.get $right_y) (local.get $screen_u)))
          (f64.mul (local.get $up_y) (local.get $screen_v))))
        (local.set $ray_dz (f64.add
          (f64.mul (local.get $fwd_z) (f64.const 1.6))
          (f64.mul (local.get $up_z) (local.get $screen_v))))

        ;; Normalize ray direction
        (local.set $len (f64.sqrt (f64.add
          (f64.add (f64.mul (local.get $ray_dx) (local.get $ray_dx))
                   (f64.mul (local.get $ray_dy) (local.get $ray_dy)))
          (f64.mul (local.get $ray_dz) (local.get $ray_dz)))))
        (if (f64.gt (local.get $len) (f64.const 0.001))
          (then
            (local.set $ray_dx (f64.div (local.get $ray_dx) (local.get $len)))
            (local.set $ray_dy (f64.div (local.get $ray_dy) (local.get $len)))
            (local.set $ray_dz (f64.div (local.get $ray_dz) (local.get $len)))))

        ;; Cast ray
        (local.set $hit_type (call $cast_ray
          (local.get $px) (local.get $py)
          (f64.add (local.get $pz) (local.get $bob))
          (local.get $ray_dx) (local.get $ray_dy) (local.get $ray_dz)))

        (local.set $face (global.get $g_hit_face))
        (local.set $dist (global.get $g_hit_dist))
        (local.set $hit_vx (global.get $g_hit_vx))
        (local.set $hit_vy (global.get $g_hit_vy))
        (local.set $hit_vz (global.get $g_hit_vz))

        (local.set $fb_addr (i32.add (i32.const 0x0340)
          (i32.add (i32.mul (local.get $px_row) (i32.const 320)) (local.get $px_col))))

        (if (i32.ne (local.get $hit_type) (i32.const 0))
          (then
            ;; Compute hit point for texture UV
            (local.set $hit_px (f64.add (local.get $px)
              (f64.mul (local.get $ray_dx) (local.get $dist))))
            (local.set $hit_py (f64.add (local.get $py)
              (f64.mul (local.get $ray_dy) (local.get $dist))))
            (local.set $hit_pz (f64.add (f64.add (local.get $pz) (local.get $bob))
              (f64.mul (local.get $ray_dz) (local.get $dist))))

            ;; Compute texture UV (0-7) based on face
            ;; face 0=top: u=frac(x)*8, v=frac(y)*8
            ;; face 1=side-bright: u=frac(y)*8, v=(1-frac(z))*8
            ;; face 2=side-dim: u=frac(x)*8, v=(1-frac(z))*8
            ;; face 3=bottom: u=frac(x)*8, v=frac(y)*8
            (if (i32.or (i32.eq (local.get $face) (i32.const 0))
                        (i32.eq (local.get $face) (i32.const 3)))
              (then
                ;; Top/bottom face
                (local.set $tex_u (i32.and
                  (i32.trunc_f64_s (f64.mul
                    (f64.sub (local.get $hit_px) (f64.floor (local.get $hit_px)))
                    (f64.const 8.0)))
                  (i32.const 7)))
                (local.set $tex_v (i32.and
                  (i32.trunc_f64_s (f64.mul
                    (f64.sub (local.get $hit_py) (f64.floor (local.get $hit_py)))
                    (f64.const 8.0)))
                  (i32.const 7)))))
            (if (i32.eq (local.get $face) (i32.const 1))
              (then
                ;; Side bright face (±Y hit)
                (local.set $tex_u (i32.and
                  (i32.trunc_f64_s (f64.mul
                    (f64.sub (local.get $hit_px) (f64.floor (local.get $hit_px)))
                    (f64.const 8.0)))
                  (i32.const 7)))
                (local.set $tex_v (i32.and
                  (i32.trunc_f64_s (f64.mul
                    (f64.sub (f64.const 1.0) (f64.sub (local.get $hit_pz) (f64.floor (local.get $hit_pz))))
                    (f64.const 8.0)))
                  (i32.const 7)))))
            (if (i32.eq (local.get $face) (i32.const 2))
              (then
                ;; Side dim face (±X hit)
                (local.set $tex_u (i32.and
                  (i32.trunc_f64_s (f64.mul
                    (f64.sub (local.get $hit_py) (f64.floor (local.get $hit_py)))
                    (f64.const 8.0)))
                  (i32.const 7)))
                (local.set $tex_v (i32.and
                  (i32.trunc_f64_s (f64.mul
                    (f64.sub (f64.const 1.0) (f64.sub (local.get $hit_pz) (f64.floor (local.get $hit_pz))))
                    (f64.const 8.0)))
                  (i32.const 7)))))

            ;; Distance-based shade with higher precision for dithering
            ;; shade_full = 240 - dist * 10.0  (range 0..255, 16 sub-steps per shade level)
            ;; With 16 shade levels, we need shade_full in range 0..255
            (local.set $shade_full (i32.sub (i32.const 240)
              (i32.trunc_f64_s (f64.mul (local.get $dist) (f64.const 9.5)))))
            (if (i32.lt_s (local.get $shade_full) (i32.const 0))
              (then (local.set $shade_full (i32.const 0))))
            (if (i32.gt_s (local.get $shade_full) (i32.const 255))
              (then (local.set $shade_full (i32.const 255))))

            ;; Apply face lighting offset (in sub-steps, 16 per shade level)
            (if (i32.eq (local.get $face) (i32.const 0))
              (then (local.set $shade_full (i32.add (local.get $shade_full) (i32.const 32)))))
            (if (i32.eq (local.get $face) (i32.const 2))
              (then (local.set $shade_full (i32.sub (local.get $shade_full) (i32.const 16)))))
            (if (i32.eq (local.get $face) (i32.const 3))
              (then (local.set $shade_full (i32.sub (local.get $shade_full) (i32.const 32)))))

            ;; Apply texture offset (scaled for 16-shade range)
            (local.set $tex_off (call $texture_offset
              (local.get $hit_type) (local.get $face)
              (local.get $hit_vx) (local.get $hit_vy) (local.get $hit_vz)
              (local.get $tex_u) (local.get $tex_v)))
            (local.set $shade_full (i32.add (local.get $shade_full)
              (i32.mul (local.get $tex_off) (i32.const 12))))

            ;; Clamp to 0..255
            (if (i32.lt_s (local.get $shade_full) (i32.const 0))
              (then (local.set $shade_full (i32.const 0))))
            (if (i32.gt_s (local.get $shade_full) (i32.const 255))
              (then (local.set $shade_full (i32.const 255))))

            ;; Extract integer shade (0-15) and fractional part (0-15)
            (local.set $shade (i32.shr_u (local.get $shade_full) (i32.const 4)))
            (local.set $shade_frac (i32.and (local.get $shade_full) (i32.const 15)))
            ;; Use Bayer dither on the fractional part to decide if we bump up
            (local.set $dither_bump (call $dither_test
              (local.get $px_col) (local.get $px_row) (local.get $shade_frac)))
            (local.set $shade (i32.add (local.get $shade) (local.get $dither_bump)))
            ;; Clamp final shade to 0-15
            (if (i32.lt_s (local.get $shade) (i32.const 0))
              (then (local.set $shade (i32.const 0))))
            (if (i32.gt_s (local.get $shade) (i32.const 15))
              (then (local.set $shade (i32.const 15))))

            ;; Color = base for block type + shade
            ;; base = type * 16 - 8 (type 1 starts at 8, type 2 at 24, etc.)
            (local.set $color (i32.add (i32.sub (i32.mul (local.get $hit_type) (i32.const 16)) (i32.const 8)) (local.get $shade)))

            ;; Water shimmer with texture
            (if (i32.eq (local.get $hit_type) (i32.const 5))
              (then
                (local.set $color (i32.add (i32.const 152)
                  (i32.and
                    (i32.add (local.get $tex_u)
                      (i32.add (local.get $tex_v)
                        (i32.shr_u (local.get $tick) (i32.const 4))))
                    (i32.const 3))))))

            ;; Distance fog blend (fog at 136-151)
            (if (f64.gt (local.get $dist) (f64.const 18.0))
              (then
                (local.set $color (i32.add (i32.const 136)
                  (i32.trunc_f64_s (f64.mul (f64.sub (local.get $dist) (f64.const 18.0)) (f64.const 2.0)))))
                (if (i32.gt_s (local.get $color) (i32.const 151))
                  (then (local.set $color (i32.const 151))))))

            (i32.store8 (local.get $fb_addr) (local.get $color)))
          (else
            ;; Sky: gradient based on ray_dz with dithering
            ;; dz > 0 → looking up → sky, dz < 0 → looking down → dark
            (if (f64.gt (local.get $ray_dz) (f64.const 0.0))
              (then
                ;; Map dz (0..1) to sky gradient with 16 sub-steps for dithering
                ;; sky_full maps to range 0..111 (7 colors * 16 sub-steps)
                ;; We compute a high-precision value, then extract integer + fractional
                (local.set $shade_full (i32.sub (i32.const 111)
                  (i32.trunc_f64_s (f64.mul (local.get $ray_dz) (f64.const 128.0)))))
                (if (i32.lt_s (local.get $shade_full) (i32.const 0))
                  (then (local.set $shade_full (i32.const 0))))
                (if (i32.gt_s (local.get $shade_full) (i32.const 111))
                  (then (local.set $shade_full (i32.const 111))))
                ;; Integer sky index (0-6) and fractional part (0-15)
                (local.set $sky_idx (i32.add
                  (i32.shr_u (local.get $shade_full) (i32.const 4))
                  (i32.const 1)))
                (local.set $shade_frac (i32.and (local.get $shade_full) (i32.const 15)))
                ;; Dither between adjacent sky colors
                (if (i32.and
                      (call $dither_test (local.get $px_col) (local.get $px_row) (local.get $shade_frac))
                      (i32.lt_s (local.get $sky_idx) (i32.const 7)))
                  (then (local.set $sky_idx (i32.add (local.get $sky_idx) (i32.const 1)))))
                (i32.store8 (local.get $fb_addr) (local.get $sky_idx)))
              (else
                ;; Below horizon fog (now at 136+7=143)
                (i32.store8 (local.get $fb_addr) (i32.const 143))))))

        (local.set $px_col (i32.add (local.get $px_col) (i32.const 1)))
        (br $col_lp)))

      (local.set $px_row (i32.add (local.get $px_row) (i32.const 1)))
      (br $row_lp)))

    ;; ---- Crosshair ---- (special white at 204)
    (call $put_pixel (i32.const 160) (i32.const 98) (i32.const 204))
    (call $put_pixel (i32.const 160) (i32.const 99) (i32.const 204))
    (call $put_pixel (i32.const 160) (i32.const 101) (i32.const 204))
    (call $put_pixel (i32.const 160) (i32.const 102) (i32.const 204))
    (call $put_pixel (i32.const 158) (i32.const 100) (i32.const 204))
    (call $put_pixel (i32.const 159) (i32.const 100) (i32.const 204))
    (call $put_pixel (i32.const 161) (i32.const 100) (i32.const 204))
    (call $put_pixel (i32.const 162) (i32.const 100) (i32.const 204))

    ;; ---- HUD ----
    (call $draw_str (i32.const 0x190C0) (i32.const 2) (i32.const 2) (i32.const 247))
    (call $draw_num (i32.load (i32.const 0x10390)) (i32.const 32) (i32.const 2) (i32.const 247))
    (call $draw_str (i32.const 0x190D0) (i32.const 57) (i32.const 2) (i32.const 245))
    (call $draw_num (i32.load (i32.const 0x10394)) (i32.const 62) (i32.const 2) (i32.const 245))

    ;; ---- Monster sprite palette base is now 156 + type*16 ----
    ;; (updated from 128 + type*16)

    ;; ---- Gods angry message ----
    (local.set $msg_timer (i32.load (i32.const 0x1039C)))
    (if (i32.gt_s (local.get $msg_timer) (i32.const 0))
      (then
        (i32.store (i32.const 0x1039C) (i32.sub (local.get $msg_timer) (i32.const 1)))
        (call $fill_rect (i32.const 55) (i32.const 70) (i32.const 210) (i32.const 50) (i32.const 206))
        (call $draw_str (i32.const 0x19050) (i32.const 80) (i32.const 78) (i32.const 207))
        (call $draw_str (i32.const 0x19070) (i32.const 72) (i32.const 90) (i32.const 207))
        (call $draw_str (i32.const 0x19090) (i32.const 72) (i32.const 102) (i32.const 207))
        (if (i32.eq (i32.and (local.get $msg_timer) (i32.const 31)) (i32.const 0))
          (then (call $note (i32.const 2) (i32.const 80) (i32.const 200) (i32.const 180))))))

    ;; ---- Title (first 180 frames) ----
    (if (i32.lt_u (local.get $frame_ct) (i32.const 180))
      (then
        (call $draw_str (i32.const 0x19000) (i32.const 105) (i32.const 30) (i32.const 208))
        (call $draw_str (i32.const 0x19010) (i32.const 70) (i32.const 180) (i32.const 245))
        (call $draw_str (i32.const 0x19030) (i32.const 60) (i32.const 190) (i32.const 245))))

    ;; Dig sound
    (if (i32.and
          (i32.and (local.get $mouse_btn) (i32.const 1))
          (i32.eqz (i32.and (local.get $prev_mouse) (i32.const 1))))
      (then (call $note (i32.const 3) (i32.const 200) (i32.const 50) (i32.const 150))))
  )

  ;; ---- Dig or place block ----
  (func $dig_or_place (param $px f64) (param $py f64) (param $pz f64) (param $angle f64) (param $place_mode i32)
    (local $t f64) (local $cx f64) (local $cy f64) (local $cz f64)
    (local $wx i32) (local $wy i32) (local $wz i32)
    (local $block i32)
    (local $ray_dx f64) (local $ray_dy f64) (local $ray_dz f64)
    (local $look_y i32) (local $pitch f64)
    (local $cos_pitch f64)

    ;; Construct forward ray with pitch
    (local.set $look_y (i32.load (i32.const 0x103AC)))
    (local.set $pitch (f64.mul (f64.convert_i32_s (local.get $look_y)) (f64.const 0.015)))
    (local.set $cos_pitch (call $cos_a (local.get $pitch)))
    (local.set $ray_dx (f64.mul (call $cos_a (local.get $angle)) (local.get $cos_pitch)))
    (local.set $ray_dy (f64.mul (call $sin_a (local.get $angle)) (local.get $cos_pitch)))
    (local.set $ray_dz (call $sin_a (local.get $pitch)))

    (local.set $t (f64.const 0.5))
    (block $done (loop $lp
      (br_if $done (f64.gt (local.get $t) (f64.const 6.0)))

      (local.set $cx (f64.add (local.get $px) (f64.mul (local.get $ray_dx) (local.get $t))))
      (local.set $cy (f64.add (local.get $py) (f64.mul (local.get $ray_dy) (local.get $t))))
      (local.set $cz (f64.add (local.get $pz) (f64.mul (local.get $ray_dz) (local.get $t))))
      (local.set $wx (i32.trunc_f64_s (f64.floor (local.get $cx))))
      (local.set $wy (i32.trunc_f64_s (f64.floor (local.get $cy))))
      (local.set $wz (i32.trunc_f64_s (f64.floor (local.get $cz))))
      (local.set $block (call $get_block (local.get $wx) (local.get $wy) (local.get $wz)))

      (if (i32.ne (local.get $block) (i32.const 0))
        (then
          (if (local.get $place_mode)
            (then
              ;; Place block: step back slightly and place there
              (local.set $cx (f64.sub (local.get $cx) (f64.mul (local.get $ray_dx) (f64.const 0.3))))
              (local.set $cy (f64.sub (local.get $cy) (f64.mul (local.get $ray_dy) (f64.const 0.3))))
              (local.set $cz (f64.sub (local.get $cz) (f64.mul (local.get $ray_dz) (f64.const 0.3))))
              (call $set_block
                (i32.trunc_f64_s (f64.floor (local.get $cx)))
                (i32.trunc_f64_s (f64.floor (local.get $cy)))
                (i32.trunc_f64_s (f64.floor (local.get $cz)))
                (i32.const 2))
              (call $note (i32.const 1) (i32.const 300) (i32.const 60) (i32.const 120)))
            (else
              (call $set_block (local.get $wx) (local.get $wy) (local.get $wz) (i32.const 0))
              (call $note (i32.const 3) (i32.const 150) (i32.const 80) (i32.const 100))))
          (return)))

      (local.set $t (f64.add (local.get $t) (f64.const 0.2)))
      (br $lp)))
  )
)