(module
  (import "env" "memory" (memory 4))

  ;; Wolfenstein-style raycaster with procedural wall textures
  ;; Memory layout:
  ;;   0x10040  Map 16x16 (256 bytes)
  ;;   0x10140  Player: px(f32), py(f32), angle(f32)
  ;;   0x1014C  Prev mouse X (i32, for relative mouse turning)
  ;;   0x10200  Textures: 4 * 64*64 = 16384 bytes (indexed color 0-255)
  ;;   0x14200  PRNG state (4 bytes)

  ;; ---- Math helpers ----

  (func $sin_approx (param $x f64) (result f64)
    (local $x2 f64) (local $x3 f64) (local $x5 f64) (local $x7 f64)
    (local $sign f64)
    (local.set $sign (f64.const 1.0))
    ;; Reduce to [0, 2pi)
    (local.set $x (f64.sub (local.get $x)
      (f64.mul (f64.floor (f64.div (local.get $x) (f64.const 6.283185307179586))) (f64.const 6.283185307179586))))
    ;; Reduce to [0, pi) by using sin(x) = -sin(x - pi) for x in [pi, 2pi)
    (if (f64.ge (local.get $x) (f64.const 3.141592653589793))
      (then
        (local.set $x (f64.sub (local.get $x) (f64.const 3.141592653589793)))
        (local.set $sign (f64.const -1.0))))
    ;; Reduce to [-pi/4, pi/4] by using sin(x) = cos(pi/2 - x) for x in (pi/4, 3pi/4]
    ;; Actually, simpler: reduce to [0, pi/2] using sin(x) = sin(pi - x) for x in (pi/2, pi)
    (if (f64.gt (local.get $x) (f64.const 1.5707963267948966))
      (then (local.set $x (f64.sub (f64.const 3.141592653589793) (local.get $x)))))
    ;; Now x is in [0, pi/2], Taylor series is accurate here
    (local.set $x2 (f64.mul (local.get $x) (local.get $x)))
    (local.set $x3 (f64.mul (local.get $x2) (local.get $x)))
    (local.set $x5 (f64.mul (local.get $x3) (local.get $x2)))
    (local.set $x7 (f64.mul (local.get $x5) (local.get $x2)))
    (f64.mul (local.get $sign)
      (f64.sub (f64.add (local.get $x) (f64.div (local.get $x5) (f64.const 120.0)))
        (f64.add (f64.div (local.get $x3) (f64.const 6.0)) (f64.div (local.get $x7) (f64.const 5040.0)))))
  )

  (func $cos_approx (param $x f64) (result f64)
    (call $sin_approx (f64.add (local.get $x) (f64.const 1.5707963)))
  )

  (func $rand (result i32)
    (local $s i32)
    (local.set $s (i32.load (i32.const 0x14200)))
    (if (i32.eqz (local.get $s)) (then (local.set $s (i32.const 987654321))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 13))))
    (local.set $s (i32.xor (local.get $s) (i32.shr_u (local.get $s) (i32.const 17))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 5))))
    (i32.store (i32.const 0x14200) (local.get $s))
    (local.get $s)
  )

  ;; ---- Texture address: tex_id(0-3), u(0-63), v(0-63) ----
  (func $tex_addr (param $id i32) (param $u i32) (param $v i32) (result i32)
    (i32.add (i32.const 0x10200)
      (i32.add (i32.mul (local.get $id) (i32.const 4096))
        (i32.add (i32.mul (i32.and (local.get $v) (i32.const 63)) (i32.const 64))
                 (i32.and (local.get $u) (i32.const 63)))))
  )

  ;; ---- Generate brick texture (id 0) ----
  ;; Red/brown bricks with mortar lines
  (func $gen_tex_brick
    (local $u i32) (local $v i32) (local $c i32)
    (local $brick_u i32) (local $brick_v i32) (local $is_mortar i32)
    (local $row i32) (local $offset i32) (local $noise i32)
    (local.set $v (i32.const 0))
    (block $vdone (loop $vlp (br_if $vdone (i32.ge_u (local.get $v) (i32.const 64)))
      (local.set $u (i32.const 0))
      (block $udone (loop $ulp (br_if $udone (i32.ge_u (local.get $u) (i32.const 64)))
        ;; Brick pattern: rows of 8px tall, offset every other row
        (local.set $row (i32.shr_u (local.get $v) (i32.const 3)))
        ;; Offset odd rows by 16 pixels
        (local.set $offset (i32.mul (i32.and (local.get $row) (i32.const 1)) (i32.const 16)))
        (local.set $brick_u (i32.add (local.get $u) (local.get $offset)))
        ;; Mortar: 1px at brick boundaries
        (local.set $is_mortar (i32.const 0))
        ;; Horizontal mortar every 8 rows
        (if (i32.eqz (i32.rem_u (local.get $v) (i32.const 8)))
          (then (local.set $is_mortar (i32.const 1))))
        ;; Vertical mortar every 32 cols
        (if (i32.eqz (i32.rem_u (local.get $brick_u) (i32.const 32)))
          (then (local.set $is_mortar (i32.const 1))))
        (if (local.get $is_mortar)
          (then
            ;; Mortar color: gray ~160-170
            (local.set $c (i32.add (i32.const 160) (i32.and (call $rand) (i32.const 7))))
          )
          (else
            ;; Brick face: reddish-brown with noise, palette 64-120
            (local.set $noise (i32.and (call $rand) (i32.const 15)))
            (local.set $c (i32.add (i32.const 80) (local.get $noise)))
            ;; Slight gradient within brick for depth
            (local.set $c (i32.add (local.get $c)
              (i32.shr_u (i32.rem_u (local.get $v) (i32.const 8)) (i32.const 1))))
          )
        )
        (if (i32.gt_u (local.get $c) (i32.const 255)) (then (local.set $c (i32.const 255))))
        (i32.store8 (call $tex_addr (i32.const 0) (local.get $u) (local.get $v)) (local.get $c))
        (local.set $u (i32.add (local.get $u) (i32.const 1)))
        (br $ulp)))
      (local.set $v (i32.add (local.get $v) (i32.const 1)))
      (br $vlp)))
  )

  ;; ---- Generate stone texture (id 1) ----
  ;; Gray stone blocks with cracks/variation
  (func $gen_tex_stone
    (local $u i32) (local $v i32) (local $c i32)
    (local $block_u i32) (local $block_v i32) (local $hash i32)
    (local $edge i32)
    (local.set $v (i32.const 0))
    (block $vdone (loop $vlp (br_if $vdone (i32.ge_u (local.get $v) (i32.const 64)))
      (local.set $u (i32.const 0))
      (block $udone (loop $ulp (br_if $udone (i32.ge_u (local.get $u) (i32.const 64)))
        ;; Large irregular blocks: 16x16 base with hash-based color
        (local.set $block_u (i32.shr_u (local.get $u) (i32.const 4)))
        (local.set $block_v (i32.shr_u (local.get $v) (i32.const 4)))
        ;; Hash for block base color
        (local.set $hash (i32.xor
          (i32.mul (local.get $block_u) (i32.const 7919))
          (i32.mul (local.get $block_v) (i32.const 6271))))
        ;; Base gray 130-180
        (local.set $c (i32.add (i32.const 130) (i32.rem_u (i32.and (local.get $hash) (i32.const 0x7FFFFFFF)) (i32.const 50))))
        ;; Per-pixel noise
        (local.set $c (i32.add (local.get $c) (i32.sub (i32.and (call $rand) (i32.const 15)) (i32.const 7))))
        ;; Edge darkening: if near block boundary
        (local.set $edge (i32.const 0))
        (if (i32.le_u (i32.rem_u (local.get $u) (i32.const 16)) (i32.const 1))
          (then (local.set $edge (i32.const 1))))
        (if (i32.le_u (i32.rem_u (local.get $v) (i32.const 16)) (i32.const 1))
          (then (local.set $edge (i32.const 1))))
        (if (local.get $edge)
          (then (local.set $c (i32.sub (local.get $c) (i32.const 40)))))
        ;; Occasional dark crack
        (if (i32.eqz (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 30)))
          (then (local.set $c (i32.sub (local.get $c) (i32.const 30)))))
        (if (i32.lt_s (local.get $c) (i32.const 0)) (then (local.set $c (i32.const 0))))
        (if (i32.gt_s (local.get $c) (i32.const 255)) (then (local.set $c (i32.const 255))))
        (i32.store8 (call $tex_addr (i32.const 1) (local.get $u) (local.get $v)) (local.get $c))
        (local.set $u (i32.add (local.get $u) (i32.const 1)))
        (br $ulp)))
      (local.set $v (i32.add (local.get $v) (i32.const 1)))
      (br $vlp)))
  )

  ;; ---- Generate wood texture (id 2) ----
  ;; Vertical planks with wood grain
  (func $gen_tex_wood
    (local $u i32) (local $v i32) (local $c i32)
    (local $plank i32) (local $plank_edge i32) (local $grain i32)
    (local $base i32)
    (local.set $v (i32.const 0))
    (block $vdone (loop $vlp (br_if $vdone (i32.ge_u (local.get $v) (i32.const 64)))
      (local.set $u (i32.const 0))
      (block $udone (loop $ulp (br_if $udone (i32.ge_u (local.get $u) (i32.const 64)))
        ;; Vertical planks, ~16px wide
        (local.set $plank (i32.shr_u (local.get $u) (i32.const 4)))
        ;; Plank edge (dark line between planks)
        (local.set $plank_edge (i32.rem_u (local.get $u) (i32.const 16)))
        ;; Base brown, varies per plank
        (local.set $base (i32.add (i32.const 100)
          (i32.mul (i32.and (i32.mul (local.get $plank) (i32.const 37)) (i32.const 15)) (i32.const 2))))
        ;; Wood grain: horizontal waviness based on v
        (local.set $grain (i32.and
          (i32.add (local.get $v) (i32.mul (local.get $plank) (i32.const 11)))
          (i32.const 7)))
        (local.set $c (i32.add (local.get $base) (i32.mul (local.get $grain) (i32.const 3))))
        ;; Knot: small dark circle
        (if (i32.and
              (i32.eq (i32.and (local.get $v) (i32.const 63)) (i32.add (i32.mul (local.get $plank) (i32.const 17)) (i32.const 20)))
              (i32.lt_u (i32.sub (local.get $plank_edge) (i32.const 8)) (i32.const 4)))
          (then (local.set $c (i32.sub (local.get $c) (i32.const 45)))))
        ;; Per-pixel noise
        (local.set $c (i32.add (local.get $c) (i32.sub (i32.and (call $rand) (i32.const 7)) (i32.const 3))))
        ;; Plank edges dark
        (if (i32.or (i32.eqz (local.get $plank_edge))
                    (i32.eq (local.get $plank_edge) (i32.const 15)))
          (then (local.set $c (i32.sub (local.get $c) (i32.const 35)))))
        (if (i32.lt_s (local.get $c) (i32.const 0)) (then (local.set $c (i32.const 0))))
        (if (i32.gt_s (local.get $c) (i32.const 255)) (then (local.set $c (i32.const 255))))
        (i32.store8 (call $tex_addr (i32.const 2) (local.get $u) (local.get $v)) (local.get $c))
        (local.set $u (i32.add (local.get $u) (i32.const 1)))
        (br $ulp)))
      (local.set $v (i32.add (local.get $v) (i32.const 1)))
      (br $vlp)))
  )

  ;; ---- Generate slime/moss texture (id 3) ----
  ;; Greenish with bubbly noise
  (func $gen_tex_slime
    (local $u i32) (local $v i32) (local $c i32)
    (local $n1 i32) (local $n2 i32) (local $bubble i32)
    (local.set $v (i32.const 0))
    (block $vdone (loop $vlp (br_if $vdone (i32.ge_u (local.get $v) (i32.const 64)))
      (local.set $u (i32.const 0))
      (block $udone (loop $ulp (br_if $udone (i32.ge_u (local.get $u) (i32.const 64)))
        ;; Two overlapping noise patterns at different scales
        (local.set $n1 (i32.xor
          (i32.mul (i32.shr_u (local.get $u) (i32.const 2)) (i32.const 2713))
          (i32.mul (i32.shr_u (local.get $v) (i32.const 2)) (i32.const 5381))))
        (local.set $n2 (i32.xor
          (i32.mul (i32.shr_u (local.get $u) (i32.const 1)) (i32.const 1619))
          (i32.mul (i32.shr_u (local.get $v) (i32.const 1)) (i32.const 3571))))
        ;; Combine
        (local.set $c (i32.add (i32.const 60)
          (i32.add
            (i32.and (local.get $n1) (i32.const 31))
            (i32.and (local.get $n2) (i32.const 15)))))
        ;; Bubble highlights: periodic bright spots
        (local.set $bubble (i32.add
          (i32.mul (i32.rem_u (local.get $u) (i32.const 13)) (i32.rem_u (local.get $u) (i32.const 13)))
          (i32.mul (i32.rem_u (local.get $v) (i32.const 11)) (i32.rem_u (local.get $v) (i32.const 11)))))
        (if (i32.lt_u (local.get $bubble) (i32.const 8))
          (then (local.set $c (i32.add (local.get $c) (i32.const 50)))))
        ;; Per-pixel noise
        (local.set $c (i32.add (local.get $c) (i32.sub (i32.and (call $rand) (i32.const 11)) (i32.const 5))))
        (if (i32.lt_s (local.get $c) (i32.const 0)) (then (local.set $c (i32.const 0))))
        (if (i32.gt_s (local.get $c) (i32.const 255)) (then (local.set $c (i32.const 255))))
        (i32.store8 (call $tex_addr (i32.const 3) (local.get $u) (local.get $v)) (local.get $c))
        (local.set $u (i32.add (local.get $u) (i32.const 1)))
        (br $ulp)))
      (local.set $v (i32.add (local.get $v) (i32.const 1)))
      (br $vlp)))
  )

  ;; ---- Palette: texture-aware ----
  ;; 0-63:    brick (red/brown ramp)
  ;; 64-127:  stone (gray ramp)
  ;; 128-191: wood (brown/tan ramp)
  ;; 192-255: slime (green ramp)
  ;; Textures store values 0-255; we use them as direct palette index
  ;; So palette needs to cover the full range intelligently
  (func $setup_palette
    (local $i i32) (local $addr i32)
    (local $r i32) (local $g i32) (local $b i32)
    (local $t f64)
    (local.set $i (i32.const 0))
    (block $done (loop $lp (br_if $done (i32.ge_u (local.get $i) (i32.const 256)))
      (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
      (local.set $t (f64.div (f64.convert_i32_u (local.get $i)) (f64.const 255.0)))
      ;; Warm palette: dark brown -> brick red -> orange -> light tan
      ;; R: ramps up
      (local.set $r (i32.trunc_f64_s (f64.add
        (f64.mul (local.get $t) (f64.const 200.0)) (f64.const 30.0))))
      ;; G: slower ramp, gives brown then tan
      (local.set $g (i32.trunc_f64_s (f64.add
        (f64.mul (f64.mul (local.get $t) (local.get $t)) (f64.const 180.0)) (f64.const 15.0))))
      ;; B: very low, slight blue in darks
      (local.set $b (i32.trunc_f64_s (f64.add
        (f64.mul (f64.mul (local.get $t) (local.get $t)) (f64.const 80.0)) (f64.const 10.0))))
      (if (i32.gt_s (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))
      (if (i32.gt_s (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
      (if (i32.gt_s (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
      (i32.store8 (local.get $addr) (local.get $r))
      (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
      (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  )

  ;; ---- Map access ----
  (func $map_get (param $mx i32) (param $my i32) (result i32)
    (if (result i32) (i32.or
          (i32.or (i32.lt_s (local.get $mx) (i32.const 0)) (i32.ge_s (local.get $mx) (i32.const 16)))
          (i32.or (i32.lt_s (local.get $my) (i32.const 0)) (i32.ge_s (local.get $my) (i32.const 16))))
      (then (i32.const 1))
      (else (i32.load8_u (i32.add (i32.const 0x10040)
        (i32.add (i32.mul (local.get $my) (i32.const 16)) (local.get $mx)))))
    )
  )

  ;; ---- Map data (16x16, initialized via data segment) ----
  ;; Wall types: 0=empty, 1=brick, 2=stone, 3=wood, 4=slime

  ;; ---- Autopilot state ----
  ;; 0x14204  idle_counter (i32) — frames since last input
  ;; 0x14208  autopilot flag (i32) — 1=autopilot active
  ;; 0x1420C  prev_mouse_x for input detection (i32)
  ;; 0x14210  turn_dir (i32) — current preferred turn direction (1 or -1)

  ;; Check if a map cell ahead of player is a wall
  ;; Returns 1 if wall, 0 if clear. Checks at distance $dist along angle $angle from ($px,$py)
  (func $wall_ahead (param $px f64) (param $py f64) (param $angle f64) (param $dist f64) (result i32)
    (i32.ne (i32.const 0)
      (call $map_get
        (i32.trunc_f64_s (f64.add (local.get $px)
          (f64.mul (call $cos_approx (local.get $angle)) (local.get $dist))))
        (i32.trunc_f64_s (f64.add (local.get $py)
          (f64.mul (call $sin_approx (local.get $angle)) (local.get $dist)))))))

  ;; ---- INIT ----
  (func (export "init")
    ;; Seed PRNG
    (i32.store (i32.const 0x14200) (i32.const 42424242))
    ;; Generate textures
    (call $gen_tex_brick)
    (call $gen_tex_stone)
    (call $gen_tex_wood)
    (call $gen_tex_slime)
    ;; Setup palette and map
    (call $setup_palette)
    ;; Map is initialized via data segment
    ;; Player start
    (f32.store (i32.const 0x10140) (f32.const 2.5))
    (f32.store (i32.const 0x10144) (f32.const 2.5))
    (f32.store (i32.const 0x10148) (f32.const 0.0))
    ;; Start in autopilot mode
    (i32.store (i32.const 0x14204) (i32.const 60))  ;; idle counter starts high
    (i32.store (i32.const 0x14208) (i32.const 1))   ;; autopilot on
    (i32.store (i32.const 0x1420C) (i32.const 0))   ;; prev mouse x
    (i32.store (i32.const 0x14210) (i32.const 1))   ;; turn dir: right
  )

  ;; ---- DDA Raycaster with texture mapping ----
  (func (export "frame")
    (local $col i32)
    (local $player_angle f64) (local $px f64) (local $py f64)
    (local $ray_angle f64) (local $ray_dx f64) (local $ray_dy f64)
    (local $map_x i32) (local $map_y i32)
    (local $step_x i32) (local $step_y i32)
    (local $side_dist_x f64) (local $side_dist_y f64)
    (local $delta_dist_x f64) (local $delta_dist_y f64)
    (local $side i32) (local $wall_type i32) (local $hit i32) (local $dda_steps i32)
    (local $perp_dist f64) (local $wall_h i32)
    (local $draw_start i32) (local $draw_end i32)
    (local $wall_x f64) (local $tex_u i32) (local $tex_v i32)
    (local $tex_id i32) (local $tex_color i32)
    (local $row i32) (local $fb_addr i32)
    (local $tick i32)
    (local $shade f64) (local $shaded_color i32)
    (local $ceil_color i32) (local $floor_color i32)
    (local $keys i32) (local $mouse_x i32) (local $prev_mouse_x i32)
    (local $move_dx f64) (local $move_dy f64)
    (local $new_px f64) (local $new_py f64)
    (local $cos_a f64) (local $sin_a f64)
    (local $move_speed f64) (local $turn_speed f64)

    (local.set $tick (i32.shr_u (i32.load (i32.const 12)) (i32.const 4)))

    ;; Load player state from memory
    (local.set $px (f64.promote_f32 (f32.load (i32.const 0x10140))))
    (local.set $py (f64.promote_f32 (f32.load (i32.const 0x10144))))
    (local.set $player_angle (f64.promote_f32 (f32.load (i32.const 0x10148))))

    ;; Read input
    (local.set $keys (i32.load8_u (i32.const 0x10)))
    (local.set $mouse_x (i32.load16_u (i32.const 0x04)))
    (local.set $prev_mouse_x (i32.load (i32.const 0x1014C)))

    ;; Movement/turn speeds
    (local.set $move_speed (f64.const 0.06))
    (local.set $turn_speed (f64.const 0.04))

    ;; --- Autopilot/manual mode detection ---
    ;; Check if user is providing any input: keyboard or mouse movement
    (if (i32.or
          (local.get $keys)
          (i32.and
            (i32.ne (local.get $prev_mouse_x) (i32.const 0))
            (i32.ne (local.get $mouse_x) (i32.load (i32.const 0x1420C)))))
      (then
        ;; Input detected: reset idle counter, switch to manual
        (i32.store (i32.const 0x14204) (i32.const 0))
        (i32.store (i32.const 0x14208) (i32.const 0))
      )
      (else
        ;; No input: increment idle counter
        (i32.store (i32.const 0x14204)
          (i32.add (i32.load (i32.const 0x14204)) (i32.const 1)))
        ;; If idle for 60+ frames, switch to autopilot
        (if (i32.ge_u (i32.load (i32.const 0x14204)) (i32.const 60))
          (then (i32.store (i32.const 0x14208) (i32.const 1))))
      )
    )
    ;; Save mouse x for next frame's input detection
    (i32.store (i32.const 0x1420C) (local.get $mouse_x))

    ;; Precompute direction
    (local.set $cos_a (call $cos_approx (local.get $player_angle)))
    (local.set $sin_a (call $sin_approx (local.get $player_angle)))

    ;; Branch: autopilot vs manual control
    (if (i32.load (i32.const 0x14208))
      (then
        ;; === AUTOPILOT MODE ===
        ;; Move forward at steady pace
        (local.set $move_dx (f64.mul (local.get $cos_a) (f64.const 0.04)))
        (local.set $move_dy (f64.mul (local.get $sin_a) (f64.const 0.04)))

        ;; Check wall ahead at distance 1.0
        (if (call $wall_ahead (local.get $px) (local.get $py) (local.get $player_angle) (f64.const 1.0))
          (then
            ;; Wall ahead — stop moving forward, turn instead
            (local.set $move_dx (f64.const 0.0))
            (local.set $move_dy (f64.const 0.0))

            ;; Try current preferred turn direction; if that's also blocked, flip
            (if (call $wall_ahead (local.get $px) (local.get $py)
                  (f64.add (local.get $player_angle)
                    (f64.mul (f64.convert_i32_s (i32.load (i32.const 0x14210))) (f64.const 1.57)))
                  (f64.const 1.0))
              (then
                ;; Preferred direction blocked too — flip turn direction
                (i32.store (i32.const 0x14210)
                  (i32.sub (i32.const 0) (i32.load (i32.const 0x14210))))))

            ;; Turn in preferred direction
            (local.set $player_angle (f64.add (local.get $player_angle)
              (f64.mul (f64.convert_i32_s (i32.load (i32.const 0x14210))) (f64.const 0.05))))
          )
          (else
            ;; No wall ahead — add gentle random drift for natural movement
            (if (i32.eqz (i32.rem_u (i32.and (call $rand) (i32.const 0x7FFFFFFF)) (i32.const 90)))
              (then
                ;; Occasionally flip turn preference for variety
                (i32.store (i32.const 0x14210)
                  (i32.sub (i32.const 0) (i32.load (i32.const 0x14210))))))
            ;; Very slight turn for wandering feel
            (local.set $player_angle (f64.add (local.get $player_angle)
              (f64.mul (f64.convert_i32_s (i32.load (i32.const 0x14210))) (f64.const 0.003))))
          )
        )
      )
      (else
        ;; === MANUAL MODE ===
        ;; --- Turning: Left/Right keys (bits 2,3) ---
        (if (i32.and (local.get $keys) (i32.const 4))
          (then (local.set $player_angle (f64.sub (local.get $player_angle) (local.get $turn_speed)))))
        (if (i32.and (local.get $keys) (i32.const 8))
          (then (local.set $player_angle (f64.add (local.get $player_angle) (local.get $turn_speed)))))

        ;; --- Mouse turning ---
        (if (local.get $prev_mouse_x)
          (then
            (local.set $player_angle (f64.add (local.get $player_angle)
              (f64.mul (f64.convert_i32_s (i32.sub (local.get $mouse_x) (local.get $prev_mouse_x)))
                       (f64.const 0.01))))))

        ;; Recompute direction after turning
        (local.set $cos_a (call $cos_approx (local.get $player_angle)))
        (local.set $sin_a (call $sin_approx (local.get $player_angle)))

        ;; --- Movement: Forward/Back (bits 0,1) ---
        (local.set $move_dx (f64.const 0.0))
        (local.set $move_dy (f64.const 0.0))
        (if (i32.and (local.get $keys) (i32.const 1))
          (then
            (local.set $move_dx (f64.add (local.get $move_dx) (f64.mul (local.get $cos_a) (local.get $move_speed))))
            (local.set $move_dy (f64.add (local.get $move_dy) (f64.mul (local.get $sin_a) (local.get $move_speed))))))
        (if (i32.and (local.get $keys) (i32.const 2))
          (then
            (local.set $move_dx (f64.sub (local.get $move_dx) (f64.mul (local.get $cos_a) (local.get $move_speed))))
            (local.set $move_dy (f64.sub (local.get $move_dy) (f64.mul (local.get $sin_a) (local.get $move_speed))))))
      )
    )
    ;; Store current mouse_x as prev for mouse turning
    (i32.store (i32.const 0x1014C) (local.get $mouse_x))

    ;; --- Collision detection: try X and Y independently with 0.2 margin ---
    ;; Try X movement
    (local.set $new_px (f64.add (local.get $px) (local.get $move_dx)))
    (if (i32.eqz (call $map_get
          (i32.trunc_f64_s (f64.add (local.get $new_px) (select (f64.const 0.2) (f64.const -0.2) (f64.gt (local.get $move_dx) (f64.const 0.0)))))
          (i32.trunc_f64_s (local.get $py))))
      (then (local.set $px (local.get $new_px))))
    ;; Try Y movement
    (local.set $new_py (f64.add (local.get $py) (local.get $move_dy)))
    (if (i32.eqz (call $map_get
          (i32.trunc_f64_s (local.get $px))
          (i32.trunc_f64_s (f64.add (local.get $new_py) (select (f64.const 0.2) (f64.const -0.2) (f64.gt (local.get $move_dy) (f64.const 0.0)))))))
      (then (local.set $py (local.get $new_py))))

    ;; Store updated player state
    (f32.store (i32.const 0x10140) (f32.demote_f64 (local.get $px)))
    (f32.store (i32.const 0x10144) (f32.demote_f64 (local.get $py)))
    (f32.store (i32.const 0x10148) (f32.demote_f64 (local.get $player_angle)))

    ;; Clear framebuffer: gradient ceiling and floor
    (local.set $row (i32.const 0))
    (block $cdone (loop $clp (br_if $cdone (i32.ge_u (local.get $row) (i32.const 200)))
      ;; ceiling: dark blue-gray gradient, floor: dark brown gradient
      (if (i32.lt_u (local.get $row) (i32.const 100))
        (then
          ;; Ceiling: darker toward horizon (row 99), lighter up top
          (local.set $ceil_color (i32.shr_u (i32.sub (i32.const 99) (local.get $row)) (i32.const 2)))
        )
        (else
          ;; Floor: darker toward horizon, brighter at bottom
          (local.set $ceil_color (i32.shr_u (i32.sub (local.get $row) (i32.const 100)) (i32.const 2)))
        )
      )
      ;; Fill entire row
      (local.set $col (i32.const 0))
      (block $rcdone (loop $rclp (br_if $rcdone (i32.ge_u (local.get $col) (i32.const 320)))
        (i32.store8 (i32.add (i32.const 0x0340)
          (i32.add (i32.mul (local.get $row) (i32.const 320)) (local.get $col)))
          (local.get $ceil_color))
        (local.set $col (i32.add (local.get $col) (i32.const 1)))
        (br $rclp)))
      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br $clp)))

    ;; Cast rays — one per column, DDA algorithm
    (local.set $col (i32.const 0))
    (block $rdone (loop $rlp (br_if $rdone (i32.ge_u (local.get $col) (i32.const 320)))
      ;; Ray angle: FOV ~60 degrees (1.047 rad)
      (local.set $ray_angle (f64.add (local.get $player_angle)
        (f64.mul (f64.sub (f64.convert_i32_s (local.get $col)) (f64.const 160.0))
                 (f64.div (f64.const 1.047) (f64.const 320.0)))))
      (local.set $ray_dx (call $cos_approx (local.get $ray_angle)))
      (local.set $ray_dy (call $sin_approx (local.get $ray_angle)))

      ;; Starting map cell
      (local.set $map_x (i32.trunc_f64_s (local.get $px)))
      (local.set $map_y (i32.trunc_f64_s (local.get $py)))

      ;; Delta distances (|1/component|)
      (local.set $delta_dist_x
        (if (result f64) (f64.eq (local.get $ray_dx) (f64.const 0.0))
          (then (f64.const 1000000.0))
          (else (f64.abs (f64.div (f64.const 1.0) (local.get $ray_dx))))))
      (local.set $delta_dist_y
        (if (result f64) (f64.eq (local.get $ray_dy) (f64.const 0.0))
          (then (f64.const 1000000.0))
          (else (f64.abs (f64.div (f64.const 1.0) (local.get $ray_dy))))))

      ;; Step direction and initial side distances
      (if (f64.lt (local.get $ray_dx) (f64.const 0.0))
        (then
          (local.set $step_x (i32.const -1))
          (local.set $side_dist_x (f64.mul
            (f64.sub (local.get $px) (f64.convert_i32_s (local.get $map_x)))
            (local.get $delta_dist_x)))
        )
        (else
          (local.set $step_x (i32.const 1))
          (local.set $side_dist_x (f64.mul
            (f64.sub (f64.add (f64.convert_i32_s (local.get $map_x)) (f64.const 1.0)) (local.get $px))
            (local.get $delta_dist_x)))
        )
      )
      (if (f64.lt (local.get $ray_dy) (f64.const 0.0))
        (then
          (local.set $step_y (i32.const -1))
          (local.set $side_dist_y (f64.mul
            (f64.sub (local.get $py) (f64.convert_i32_s (local.get $map_y)))
            (local.get $delta_dist_y)))
        )
        (else
          (local.set $step_y (i32.const 1))
          (local.set $side_dist_y (f64.mul
            (f64.sub (f64.add (f64.convert_i32_s (local.get $map_y)) (f64.const 1.0)) (local.get $py))
            (local.get $delta_dist_y)))
        )
      )

      ;; DDA loop
      (local.set $hit (i32.const 0))
      (local.set $side (i32.const 0))
      (local.set $dda_steps (i32.const 0))
      (block $hloop_done (loop $hloop
        (br_if $hloop_done (i32.or (local.get $hit) (i32.ge_u (local.get $dda_steps) (i32.const 64))))
        ;; Step to next cell boundary
        (if (f64.lt (local.get $side_dist_x) (local.get $side_dist_y))
          (then
            (local.set $side_dist_x (f64.add (local.get $side_dist_x) (local.get $delta_dist_x)))
            (local.set $map_x (i32.add (local.get $map_x) (local.get $step_x)))
            (local.set $side (i32.const 0))
          )
          (else
            (local.set $side_dist_y (f64.add (local.get $side_dist_y) (local.get $delta_dist_y)))
            (local.set $map_y (i32.add (local.get $map_y) (local.get $step_y)))
            (local.set $side (i32.const 1))
          )
        )
        (local.set $wall_type (call $map_get (local.get $map_x) (local.get $map_y)))
        (if (i32.gt_u (local.get $wall_type) (i32.const 0))
          (then (local.set $hit (i32.const 1))))
        (local.set $dda_steps (i32.add (local.get $dda_steps) (i32.const 1)))
        (br $hloop)
      ))

      ;; Perpendicular distance (avoids fisheye)
      (if (i32.eqz (local.get $side))
        (then
          (local.set $perp_dist (f64.sub (local.get $side_dist_x) (local.get $delta_dist_x)))
        )
        (else
          (local.set $perp_dist (f64.sub (local.get $side_dist_y) (local.get $delta_dist_y)))
        )
      )
      (if (f64.lt (local.get $perp_dist) (f64.const 0.001))
        (then (local.set $perp_dist (f64.const 0.001))))

      ;; Wall strip height
      (local.set $wall_h (i32.trunc_f64_s (f64.div (f64.const 200.0) (local.get $perp_dist))))
      (if (i32.gt_s (local.get $wall_h) (i32.const 400))
        (then (local.set $wall_h (i32.const 400))))
      (local.set $draw_start (i32.sub (i32.const 100) (i32.shr_u (local.get $wall_h) (i32.const 1))))
      (local.set $draw_end (i32.add (i32.const 100) (i32.shr_u (local.get $wall_h) (i32.const 1))))

      ;; Texture U coordinate: fractional wall hit position
      (if (i32.eqz (local.get $side))
        (then
          (local.set $wall_x (f64.add (local.get $py)
            (f64.mul (local.get $perp_dist) (local.get $ray_dy))))
        )
        (else
          (local.set $wall_x (f64.add (local.get $px)
            (f64.mul (local.get $perp_dist) (local.get $ray_dx))))
        )
      )
      ;; Get fractional part
      (local.set $wall_x (f64.sub (local.get $wall_x) (f64.floor (local.get $wall_x))))
      (local.set $tex_u (i32.and (i32.trunc_f64_s (f64.mul (local.get $wall_x) (f64.const 64.0))) (i32.const 63)))

      ;; Texture ID from wall type (1-4 -> 0-3)
      (local.set $tex_id (i32.sub (local.get $wall_type) (i32.const 1)))
      (if (i32.lt_s (local.get $tex_id) (i32.const 0)) (then (local.set $tex_id (i32.const 0))))
      (if (i32.gt_s (local.get $tex_id) (i32.const 3)) (then (local.set $tex_id (i32.const 3))))

      ;; Distance-based shading: closer = brighter
      (local.set $shade (f64.div (f64.const 1.0)
        (f64.add (f64.const 1.0) (f64.mul (local.get $perp_dist) (f64.const 0.15)))))
      (if (f64.gt (local.get $shade) (f64.const 1.0))
        (then (local.set $shade (f64.const 1.0))))
      ;; Side hit is darker (fake lighting)
      (if (local.get $side)
        (then (local.set $shade (f64.mul (local.get $shade) (f64.const 0.7)))))

      ;; Draw textured wall strip
      (local.set $row (select (local.get $draw_start) (i32.const 0) (i32.ge_s (local.get $draw_start) (i32.const 0))))
      (block $vdone (loop $vlp
        (br_if $vdone (i32.or
          (i32.ge_s (local.get $row) (local.get $draw_end))
          (i32.ge_s (local.get $row) (i32.const 200))))
        ;; Texture V: map row position to 0-63
        (local.set $tex_v (i32.and
          (i32.div_s
            (i32.mul (i32.sub (local.get $row) (local.get $draw_start)) (i32.const 64))
            (local.get $wall_h))
          (i32.const 63)))
        ;; Sample texture
        (local.set $tex_color (i32.load8_u (call $tex_addr (local.get $tex_id) (local.get $tex_u) (local.get $tex_v))))
        ;; Apply distance shading
        (local.set $shaded_color (i32.trunc_f64_s (f64.mul
          (f64.convert_i32_u (local.get $tex_color))
          (local.get $shade))))
        (if (i32.gt_s (local.get $shaded_color) (i32.const 255))
          (then (local.set $shaded_color (i32.const 255))))
        ;; Write to framebuffer
        (i32.store8 (i32.add (i32.const 0x0340)
          (i32.add (i32.mul (local.get $row) (i32.const 320)) (local.get $col)))
          (local.get $shaded_color))
        (local.set $row (i32.add (local.get $row) (i32.const 1)))
        (br $vlp)))

      (local.set $col (i32.add (local.get $col) (i32.const 1)))
      (br $rlp)))
  )

  ;; 16x16 map at 0x10040 (256 bytes)
  ;; Row 0/15: brick(1) borders, Col 0/15: stone(2) borders, interior walls: wood(3), slime(4)
  (data (i32.const 0x10040)
    "\02\01\01\01\01\01\01\01\01\01\01\01\01\01\01\02"  ;; row 0
    "\02\00\00\00\00\00\00\00\00\00\00\00\00\00\00\02"  ;; row 1
    "\02\00\00\00\00\00\00\00\00\00\00\00\00\00\00\02"  ;; row 2
    "\02\00\00\00\00\00\00\00\00\00\04\00\00\00\00\02"  ;; row 3
    "\02\00\03\03\03\03\03\00\00\00\04\00\00\00\00\02"  ;; row 4
    "\02\00\00\00\00\00\00\00\00\00\04\00\00\00\00\02"  ;; row 5
    "\02\00\00\04\00\00\00\00\00\00\04\00\00\00\00\02"  ;; row 6
    "\02\00\00\00\00\00\00\01\00\00\04\00\00\00\00\02"  ;; row 7
    "\02\00\00\00\00\00\00\00\00\00\04\00\00\04\00\02"  ;; row 8
    "\02\00\00\00\00\00\00\00\00\00\00\00\00\00\00\02"  ;; row 9
    "\02\00\00\00\03\00\00\00\00\00\02\02\02\02\00\02"  ;; row 10
    "\02\00\00\00\03\00\00\00\00\00\02\00\00\00\00\02"  ;; row 11
    "\02\00\00\00\03\03\03\03\00\00\00\00\00\00\00\02"  ;; row 12
    "\02\00\00\00\00\00\00\00\00\00\02\00\00\00\00\02"  ;; row 13
    "\02\00\00\00\00\00\00\00\00\00\00\00\00\00\00\02"  ;; row 14
    "\02\01\01\01\01\01\01\01\01\01\01\01\01\01\01\02"  ;; row 15
  )
)
