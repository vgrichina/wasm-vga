(module
  (import "env" "memory" (memory 4))

  ;; Comanche-style voxel landscape renderer
  ;; Memory:
  ;;   0x10040  heightmap 128x128 (16384 bytes)
  ;;   0x14040  colormap  128x128 (16384 bytes)
  ;;   0x18040  PRNG state (4 bytes)

  (func $rand (result i32)
    (local $s i32)
    (local.set $s (i32.load (i32.const 0x18040)))
    (if (i32.eqz (local.get $s)) (then (local.set $s (i32.const 48271))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 13))))
    (local.set $s (i32.xor (local.get $s) (i32.shr_u (local.get $s) (i32.const 17))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 5))))
    (i32.store (i32.const 0x18040) (local.get $s))
    (local.get $s)
  )

  (func $hm_addr (param $x i32) (param $y i32) (result i32)
    (i32.add (i32.const 0x10040)
      (i32.add (i32.mul (i32.and (local.get $y) (i32.const 127)) (i32.const 128))
               (i32.and (local.get $x) (i32.const 127))))
  )

  (func $cm_addr (param $x i32) (param $y i32) (result i32)
    (i32.add (i32.const 0x14040)
      (i32.add (i32.mul (i32.and (local.get $y) (i32.const 127)) (i32.const 128))
               (i32.and (local.get $x) (i32.const 127))))
  )

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

  (func $cos_approx (param $x f64) (result f64)
    (call $sin_approx (f64.add (local.get $x) (f64.const 1.5707963)))
  )

  ;; Palette: full 0-255 range maps terrain types
  ;; 0-49: water (blue)
  ;; 50-69: sand (tan)
  ;; 70-170: grass (green)
  ;; 171-220: rock (gray)
  ;; 221-255: snow (white)
  (func $set_landscape_pal (param $i i32)
    (local $addr i32) (local $r i32) (local $g i32) (local $b i32) (local $t i32)
    (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
    (if (i32.lt_u (local.get $i) (i32.const 50))
      (then
        ;; Water: dark blue to medium blue
        (local.set $t (i32.mul (local.get $i) (i32.const 2)))
        (local.set $r (i32.shr_u (local.get $t) (i32.const 3)))
        (local.set $g (i32.add (i32.const 30) (local.get $t)))
        (local.set $b (i32.add (i32.const 100) (local.get $t)))
      )
      (else (if (i32.lt_u (local.get $i) (i32.const 70))
        (then
          ;; Sand
          (local.set $t (i32.sub (local.get $i) (i32.const 50)))
          (local.set $r (i32.add (i32.const 194) (i32.mul (local.get $t) (i32.const 2))))
          (local.set $g (i32.add (i32.const 178) (i32.mul (local.get $t) (i32.const 2))))
          (local.set $b (i32.add (i32.const 128) (local.get $t)))
        )
        (else (if (i32.lt_u (local.get $i) (i32.const 171))
          (then
            ;; Grass: varies from light to dark green
            (local.set $t (i32.sub (local.get $i) (i32.const 70)))
            (local.set $r (i32.add (i32.const 30) (i32.shr_u (local.get $t) (i32.const 2))))
            (local.set $g (i32.add (i32.const 90) (i32.shr_u (local.get $t) (i32.const 1))))
            (local.set $b (i32.add (i32.const 15) (i32.shr_u (local.get $t) (i32.const 3))))
          )
          (else (if (i32.lt_u (local.get $i) (i32.const 221))
            (then
              ;; Rock: brown-gray
              (local.set $t (i32.sub (local.get $i) (i32.const 171)))
              (local.set $r (i32.add (i32.const 110) (local.get $t)))
              (local.set $g (i32.add (i32.const 100) (local.get $t)))
              (local.set $b (i32.add (i32.const 85) (local.get $t)))
            )
            (else
              ;; Snow
              (local.set $t (i32.sub (local.get $i) (i32.const 221)))
              (local.set $r (i32.add (i32.const 210) (local.get $t)))
              (local.set $g (i32.add (i32.const 215) (local.get $t)))
              (local.set $b (i32.add (i32.const 225) (i32.shr_u (local.get $t) (i32.const 1))))
            )
          ))
        ))
      ))
    )
    (if (i32.gt_u (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))
    (if (i32.gt_u (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
    (if (i32.gt_u (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
    (i32.store8 (local.get $addr) (local.get $r))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
    (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
  )

  ;; Dynamic camera state (top of guest area)
  ;; 0x3F000: cam_x (f64)
  ;; 0x3F008: cam_y (f64)
  ;; 0x3F010: cam_angle (f64)
  ;; 0x3F018: speed (f64)

  (func (export "init")
    (local $i i32) (local $x i32) (local $y i32) (local $pass i32)
    (local $h i32) (local $avg i32)

    (i32.store (i32.const 0x18040) (i32.const 314159))

    ;; Initialize camera state
    (f64.store (i32.const 0x3F000) (f64.const 64.0))   ;; cam_x = center
    (f64.store (i32.const 0x3F008) (f64.const 64.0))   ;; cam_y = center
    (f64.store (i32.const 0x3F010) (f64.const 0.0))    ;; cam_angle = 0
    (f64.store (i32.const 0x3F018) (f64.const 0.3))    ;; speed = base forward speed

    ;; Setup palette
    (local.set $i (i32.const 0))
    (block $pdone (loop $plp (br_if $pdone (i32.ge_u (local.get $i) (i32.const 256)))
      (call $set_landscape_pal (local.get $i))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $plp)))

    ;; Fill heightmap with random values
    (local.set $i (i32.const 0))
    (block $hdone (loop $hlp (br_if $hdone (i32.ge_u (local.get $i) (i32.const 16384)))
      (i32.store8 (i32.add (i32.const 0x10040) (local.get $i))
        (i32.and (call $rand) (i32.const 255)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $hlp)))

    ;; Smooth heightmap: 5 blur passes, average of 4 neighbors only (no center bias)
    (local.set $pass (i32.const 0))
    (block $sdone (loop $slp (br_if $sdone (i32.ge_u (local.get $pass) (i32.const 5)))
      (local.set $y (i32.const 0))
      (block $sy (loop $syl (br_if $sy (i32.ge_u (local.get $y) (i32.const 128)))
        (local.set $x (i32.const 0))
        (block $sx (loop $sxl (br_if $sx (i32.ge_u (local.get $x) (i32.const 128)))
          ;; Average of 4 cardinal neighbors
          (local.set $avg (i32.shr_u (i32.add
            (i32.add
              (i32.load8_u (call $hm_addr (i32.add (local.get $x) (i32.const 1)) (local.get $y)))
              (i32.load8_u (call $hm_addr (i32.sub (local.get $x) (i32.const 1)) (local.get $y))))
            (i32.add
              (i32.load8_u (call $hm_addr (local.get $x) (i32.add (local.get $y) (i32.const 1))))
              (i32.load8_u (call $hm_addr (local.get $x) (i32.sub (local.get $y) (i32.const 1))))))
            (i32.const 2)))
          (i32.store8 (call $hm_addr (local.get $x) (local.get $y)) (local.get $avg))
          (local.set $x (i32.add (local.get $x) (i32.const 1)))
          (br $sxl)))
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $syl)))
      (local.set $pass (i32.add (local.get $pass) (i32.const 1)))
      (br $slp)))

    ;; Generate colormap: height value IS the palette index directly
    (local.set $y (i32.const 0))
    (block $cy (loop $cyl (br_if $cy (i32.ge_u (local.get $y) (i32.const 128)))
      (local.set $x (i32.const 0))
      (block $cx (loop $cxl (br_if $cx (i32.ge_u (local.get $x) (i32.const 128)))
        (local.set $h (i32.load8_u (call $hm_addr (local.get $x) (local.get $y))))
        (i32.store8 (call $cm_addr (local.get $x) (local.get $y)) (local.get $h))
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br $cxl)))
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br $cyl)))
  )

  (func (export "frame")
    (local $col i32) (local $tick i32)
    (local $cam_x f64) (local $cam_y f64) (local $cam_h f64) (local $cam_angle f64)
    (local $cos_a f64) (local $sin_a f64)
    (local $ray_dx f64) (local $ray_dy f64)
    (local $z i32) (local $sample_x i32) (local $sample_y i32)
    (local $height i32) (local $proj_y i32) (local $max_y i32)
    (local $color i32) (local $row i32)
    (local $fz f64) (local $inv_z f64)
    (local $rx f64) (local $ry f64)
    (local $angle_offset f64)
    (local $sky_r i32) (local $sky_g i32) (local $sky_b i32)
    (local $keys i32) (local $mouse_y i32) (local $speed f64)

    (local.set $tick (i32.load (i32.const 12)))

    ;; Read keyboard state (0x10): bit0=Up, bit1=Down, bit2=Left, bit3=Right
    (local.set $keys (i32.load8_u (i32.const 0x10)))
    ;; Read mouse y (u16 at 0x06)
    (local.set $mouse_y (i32.load16_u (i32.const 0x06)))

    ;; Load camera state from memory
    (local.set $cam_x (f64.load (i32.const 0x3F000)))
    (local.set $cam_y (f64.load (i32.const 0x3F008)))
    (local.set $cam_angle (f64.load (i32.const 0x3F010)))
    (local.set $speed (f64.load (i32.const 0x3F018)))

    ;; Left arrow (bit2): turn left
    (if (i32.and (local.get $keys) (i32.const 4))
      (then (local.set $cam_angle (f64.sub (local.get $cam_angle) (f64.const 0.03)))))
    ;; Right arrow (bit3): turn right
    (if (i32.and (local.get $keys) (i32.const 8))
      (then (local.set $cam_angle (f64.add (local.get $cam_angle) (f64.const 0.03)))))

    ;; Up arrow (bit0): accelerate forward
    (if (i32.and (local.get $keys) (i32.const 1))
      (then (local.set $speed (f64.min (f64.add (local.get $speed) (f64.const 0.02)) (f64.const 1.5))))
      (else
        ;; Down arrow (bit1): brake/slow down
        (if (i32.and (local.get $keys) (i32.const 2))
          (then (local.set $speed (f64.max (f64.sub (local.get $speed) (f64.const 0.03)) (f64.const 0.0))))
          (else
            ;; No up/down: drift toward base speed
            (if (f64.gt (local.get $speed) (f64.const 0.3))
              (then (local.set $speed (f64.sub (local.get $speed) (f64.const 0.005)))))
          )
        )
      )
    )

    ;; Move camera forward based on angle and speed
    (local.set $cam_x (f64.add (local.get $cam_x)
      (f64.mul (call $cos_approx (local.get $cam_angle)) (local.get $speed))))
    (local.set $cam_y (f64.add (local.get $cam_y)
      (f64.mul (call $sin_approx (local.get $cam_angle)) (local.get $speed))))

    ;; Store updated camera state
    (f64.store (i32.const 0x3F000) (local.get $cam_x))
    (f64.store (i32.const 0x3F008) (local.get $cam_y))
    (f64.store (i32.const 0x3F010) (local.get $cam_angle))
    (f64.store (i32.const 0x3F018) (local.get $speed))

    ;; Camera height from mouse y: mouse_y 0..199 maps to height 280..100
    ;; height = 280 - mouse_y * 0.9
    (local.set $cam_h (f64.sub (f64.const 280.0)
      (f64.mul (f64.convert_i32_u (local.get $mouse_y)) (f64.const 0.9))))

    ;; Look direction
    (local.set $cos_a (call $cos_approx (local.get $cam_angle)))
    (local.set $sin_a (call $sin_approx (local.get $cam_angle)))

    ;; Clear framebuffer to sky blue (palette index 30 = nice blue)
    (local.set $row (i32.const 0))
    (block $cdone (loop $clp (br_if $cdone (i32.ge_u (local.get $row) (i32.const 64000)))
      ;; Gradient sky: top = index 10 (dark blue), bottom = index 45 (lighter)
      (i32.store8 (i32.add (i32.const 0x0340) (local.get $row))
        (i32.add (i32.const 10) (i32.shr_u (i32.div_u (local.get $row) (i32.const 320)) (i32.const 3))))
      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br $clp)))

    ;; Render terrain: for each screen column
    (local.set $col (i32.const 0))
    (block $rdone (loop $rlp (br_if $rdone (i32.ge_u (local.get $col) (i32.const 320)))
      ;; Ray angle offset for this column, FOV ~90 degrees
      (local.set $angle_offset (f64.mul
        (f64.div (f64.sub (f64.convert_i32_s (local.get $col)) (f64.const 160.0)) (f64.const 320.0))
        (f64.const 1.5)))
      (local.set $ray_dx (f64.sub
        (f64.mul (local.get $cos_a) (call $cos_approx (local.get $angle_offset)))
        (f64.mul (local.get $sin_a) (call $sin_approx (local.get $angle_offset)))))
      (local.set $ray_dy (f64.add
        (f64.mul (local.get $sin_a) (call $cos_approx (local.get $angle_offset)))
        (f64.mul (local.get $cos_a) (call $sin_approx (local.get $angle_offset)))))

      ;; March ray front-to-back
      (local.set $max_y (i32.const 200))
      (local.set $z (i32.const 1))
      (block $zdone (loop $zlp
        (br_if $zdone (i32.or
          (i32.ge_u (local.get $z) (i32.const 250))
          (i32.le_s (local.get $max_y) (i32.const 0))))
        (local.set $fz (f64.convert_i32_u (local.get $z)))
        ;; Sample position on map
        (local.set $rx (f64.add (local.get $cam_x) (f64.mul (local.get $ray_dx) (local.get $fz))))
        (local.set $ry (f64.add (local.get $cam_y) (f64.mul (local.get $ray_dy) (local.get $fz))))
        ;; Wrap to 0-127 using AND (works for positive and negative due to two's complement)
        (local.set $sample_x (i32.and (i32.trunc_f64_s (f64.floor (local.get $rx))) (i32.const 127)))
        (local.set $sample_y (i32.and (i32.trunc_f64_s (f64.floor (local.get $ry))) (i32.const 127)))

        ;; Get terrain height (0-255)
        (local.set $height (i32.load8_u (call $hm_addr (local.get $sample_x) (local.get $sample_y))))

        ;; Project: screen_y = (cam_h - height) * projection_scale / distance + horizon
        ;; Higher projection scale = taller mountains
        (local.set $inv_z (f64.div (f64.const 120.0) (local.get $fz)))
        (local.set $proj_y (i32.trunc_f64_s (f64.add
          (f64.mul (f64.sub (local.get $cam_h) (f64.convert_i32_u (local.get $height))) (local.get $inv_z))
          (f64.const 60.0))))

        ;; Clamp to screen
        (if (i32.lt_s (local.get $proj_y) (i32.const 0))
          (then (local.set $proj_y (i32.const 0))))
        (if (i32.gt_s (local.get $proj_y) (i32.const 200))
          (then (local.set $proj_y (i32.const 200))))

        ;; Only draw if this column extends above previous highest point
        (if (i32.lt_s (local.get $proj_y) (local.get $max_y))
          (then
            ;; Get terrain color from colormap
            (local.set $color (i32.load8_u (call $cm_addr (local.get $sample_x) (local.get $sample_y))))

            ;; Distance fog: blend color toward sky (index ~30) at far distances
            ;; fog_amount = z / 4, capped at 200
            ;; color = color + (sky_color - color) * fog / 256
            (if (i32.gt_u (local.get $z) (i32.const 20))
              (then
                (local.set $color (i32.add (local.get $color)
                  (i32.shr_s
                    (i32.mul (i32.sub (i32.const 30) (local.get $color)) (i32.shr_u (local.get $z) (i32.const 1)))
                    (i32.const 8))))
                (if (i32.lt_s (local.get $color) (i32.const 0))
                  (then (local.set $color (i32.const 0))))
                (if (i32.gt_s (local.get $color) (i32.const 255))
                  (then (local.set $color (i32.const 255))))
              )
            )

            ;; Draw vertical strip from proj_y to max_y
            (local.set $row (local.get $proj_y))
            (block $vdone (loop $vlp
              (br_if $vdone (i32.ge_u (local.get $row) (local.get $max_y)))
              (i32.store8 (i32.add (i32.const 0x0340)
                (i32.add (i32.mul (local.get $row) (i32.const 320)) (local.get $col)))
                (local.get $color))
              (local.set $row (i32.add (local.get $row) (i32.const 1)))
              (br $vlp)))
            (local.set $max_y (local.get $proj_y))
          )
        )
        ;; Adaptive step: fine near, coarse far
        (local.set $z (i32.add (local.get $z)
          (select (i32.const 1) (select (i32.const 2) (i32.const 3)
            (i32.lt_u (local.get $z) (i32.const 120)))
            (i32.lt_u (local.get $z) (i32.const 50)))))
        (br $zlp)))

      (local.set $col (i32.add (local.get $col) (i32.const 1)))
      (br $rlp)))
  )
)
