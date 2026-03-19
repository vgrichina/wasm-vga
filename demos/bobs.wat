(module
  (import "env" "memory" (memory 4))

  ;; Bobs — bouncing circles with palette-cycled trails
  ;; Bob state at 0x10340: 10 bobs * 16 bytes = 160 bytes
  ;;   each bob: x(f32), y(f32), vx(f32), vy(f32)
  ;; Color offset at 0x103E0: u32 (increments each frame)
  ;; Palette backup at 0x10400: 255*3 = 765 bytes (indices 1-255)

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

  (func (export "init")
    (local $i i32)
    (local $addr i32)
    (local $f f64) (local $v f64)
    (local $r i32) (local $g i32) (local $b i32)

    ;; Set up rainbow palette: index 0 = black, indices 1-255 = rainbow
    ;; Index 0: black (already zeroed)
    (i32.store8 (i32.const 0x0040) (i32.const 0))
    (i32.store8 (i32.const 0x0041) (i32.const 0))
    (i32.store8 (i32.const 0x0042) (i32.const 0))

    ;; Indices 1-255: smooth rainbow via sin waves offset by 2pi/3
    (local.set $i (i32.const 1))
    (block $pdone
      (loop $plp
        (br_if $pdone (i32.ge_u (local.get $i) (i32.const 256)))
        (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
        (local.set $f (f64.div (f64.convert_i32_u (local.get $i)) (f64.const 255.0)))
        ;; R
        (local.set $v (f64.add (f64.mul (call $sin_approx (f64.mul (local.get $f) (f64.const 6.2832))) (f64.const 127.0)) (f64.const 128.0)))
        (local.set $r (i32.trunc_f64_s (local.get $v)))
        (if (i32.lt_s (local.get $r) (i32.const 0)) (then (local.set $r (i32.const 0))))
        (if (i32.gt_s (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))
        ;; G
        (local.set $v (f64.add (f64.mul (call $sin_approx (f64.add (f64.mul (local.get $f) (f64.const 6.2832)) (f64.const 2.094))) (f64.const 127.0)) (f64.const 128.0)))
        (local.set $g (i32.trunc_f64_s (local.get $v)))
        (if (i32.lt_s (local.get $g) (i32.const 0)) (then (local.set $g (i32.const 0))))
        (if (i32.gt_s (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
        ;; B
        (local.set $v (f64.add (f64.mul (call $sin_approx (f64.add (f64.mul (local.get $f) (f64.const 6.2832)) (f64.const 4.189))) (f64.const 127.0)) (f64.const 128.0)))
        (local.set $b (i32.trunc_f64_s (local.get $v)))
        (if (i32.lt_s (local.get $b) (i32.const 0)) (then (local.set $b (i32.const 0))))
        (if (i32.gt_s (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
        (i32.store8 (local.get $addr) (local.get $r))
        (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
        (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $plp)
      )
    )

    ;; Clear framebuffer to 0 (black)
    (local.set $i (i32.const 0))
    (block $fbdone
      (loop $fblp
        (br_if $fbdone (i32.ge_u (local.get $i) (i32.const 64000)))
        (i32.store8 (i32.add (i32.const 0x0340) (local.get $i)) (i32.const 0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $fblp)
      )
    )

    ;; Init color offset to 1
    (i32.store (i32.const 0x103E0) (i32.const 1))

    ;; Init 10 bobs at 0x10340, 16 bytes each: x, y, vx, vy (f32)
    ;; bob 0
    (f32.store (i32.const 0x10340) (f32.const 50.0))
    (f32.store (i32.const 0x10344) (f32.const 30.0))
    (f32.store (i32.const 0x10348) (f32.const 1.7))
    (f32.store (i32.const 0x1034C) (f32.const 1.1))
    ;; bob 1
    (f32.store (i32.const 0x10350) (f32.const 270.0))
    (f32.store (i32.const 0x10354) (f32.const 170.0))
    (f32.store (i32.const 0x10358) (f32.const -1.3))
    (f32.store (i32.const 0x1035C) (f32.const 0.9))
    ;; bob 2
    (f32.store (i32.const 0x10360) (f32.const 160.0))
    (f32.store (i32.const 0x10364) (f32.const 100.0))
    (f32.store (i32.const 0x10368) (f32.const 0.8))
    (f32.store (i32.const 0x1036C) (f32.const -1.5))
    ;; bob 3
    (f32.store (i32.const 0x10370) (f32.const 80.0))
    (f32.store (i32.const 0x10374) (f32.const 150.0))
    (f32.store (i32.const 0x10378) (f32.const 1.4))
    (f32.store (i32.const 0x1037C) (f32.const 0.6))
    ;; bob 4
    (f32.store (i32.const 0x10380) (f32.const 200.0))
    (f32.store (i32.const 0x10384) (f32.const 50.0))
    (f32.store (i32.const 0x10388) (f32.const -0.9))
    (f32.store (i32.const 0x1038C) (f32.const 1.3))
    ;; bob 5
    (f32.store (i32.const 0x10390) (f32.const 140.0))
    (f32.store (i32.const 0x10394) (f32.const 80.0))
    (f32.store (i32.const 0x10398) (f32.const 1.1))
    (f32.store (i32.const 0x1039C) (f32.const -0.7))
    ;; bob 6
    (f32.store (i32.const 0x103A0) (f32.const 250.0))
    (f32.store (i32.const 0x103A4) (f32.const 120.0))
    (f32.store (i32.const 0x103A8) (f32.const -1.6))
    (f32.store (i32.const 0x103AC) (f32.const -1.0))
    ;; bob 7
    (f32.store (i32.const 0x103B0) (f32.const 30.0))
    (f32.store (i32.const 0x103B4) (f32.const 90.0))
    (f32.store (i32.const 0x103B8) (f32.const 1.2))
    (f32.store (i32.const 0x103BC) (f32.const 1.4))
    ;; bob 8
    (f32.store (i32.const 0x103C0) (f32.const 300.0))
    (f32.store (i32.const 0x103C4) (f32.const 40.0))
    (f32.store (i32.const 0x103C8) (f32.const -1.0))
    (f32.store (i32.const 0x103CC) (f32.const 0.8))
    ;; bob 9
    (f32.store (i32.const 0x103D0) (f32.const 110.0))
    (f32.store (i32.const 0x103D4) (f32.const 160.0))
    (f32.store (i32.const 0x103D8) (f32.const 0.7))
    (f32.store (i32.const 0x103DC) (f32.const -1.2))
  )

  ;; Update bob positions, bounce off walls (radius 8), attract toward mouse
  (func $update_bobs
    (local $i i32) (local $addr i32)
    (local $x f32) (local $y f32) (local $vx f32) (local $vy f32)
    (local $mx f32) (local $my f32) (local $dx f32) (local $dy f32)
    (local $dist f32) (local $force f32) (local $clicked i32)

    ;; Read mouse position and button state
    (local.set $mx (f32.convert_i32_u (i32.load16_u (i32.const 0x04))))
    (local.set $my (f32.convert_i32_u (i32.load16_u (i32.const 0x06))))
    (local.set $clicked (i32.and (i32.load8_u (i32.const 0x08)) (i32.const 1)))

    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 10)))
        (local.set $addr (i32.add (i32.const 0x10340) (i32.mul (local.get $i) (i32.const 16))))
        (local.set $x (f32.load (local.get $addr)))
        (local.set $y (f32.load (i32.add (local.get $addr) (i32.const 4))))
        (local.set $vx (f32.load (i32.add (local.get $addr) (i32.const 8))))
        (local.set $vy (f32.load (i32.add (local.get $addr) (i32.const 12))))

        ;; Compute direction toward mouse
        (local.set $dx (f32.sub (local.get $mx) (local.get $x)))
        (local.set $dy (f32.sub (local.get $my) (local.get $y)))

        ;; Distance = sqrt(dx*dx + dy*dy), clamped to min 1.0 to avoid division by zero
        (local.set $dist (f32.sqrt (f32.add
          (f32.mul (local.get $dx) (local.get $dx))
          (f32.mul (local.get $dy) (local.get $dy)))))
        (if (f32.lt (local.get $dist) (f32.const 1.0))
          (then (local.set $dist (f32.const 1.0))))

        ;; Force: gentle=0.03, strong (click)=0.25
        (if (local.get $clicked)
          (then (local.set $force (f32.const 0.25)))
          (else (local.set $force (f32.const 0.03))))

        ;; Apply attraction: vx += dx/dist * force, vy += dy/dist * force
        (local.set $vx (f32.add (local.get $vx)
          (f32.mul (f32.div (local.get $dx) (local.get $dist)) (local.get $force))))
        (local.set $vy (f32.add (local.get $vy)
          (f32.mul (f32.div (local.get $dy) (local.get $dist)) (local.get $force))))

        ;; Dampen velocity slightly to prevent infinite acceleration (0.995)
        (local.set $vx (f32.mul (local.get $vx) (f32.const 0.995)))
        (local.set $vy (f32.mul (local.get $vy) (f32.const 0.995)))

        ;; move
        (local.set $x (f32.add (local.get $x) (local.get $vx)))
        (local.set $y (f32.add (local.get $y) (local.get $vy)))
        ;; bounce X (keep radius 8 from edges)
        (if (f32.lt (local.get $x) (f32.const 8.0))
          (then (local.set $x (f32.const 8.0)) (local.set $vx (f32.neg (local.get $vx)))))
        (if (f32.gt (local.get $x) (f32.const 311.0))
          (then (local.set $x (f32.const 311.0)) (local.set $vx (f32.neg (local.get $vx)))))
        ;; bounce Y
        (if (f32.lt (local.get $y) (f32.const 8.0))
          (then (local.set $y (f32.const 8.0)) (local.set $vy (f32.neg (local.get $vy)))))
        (if (f32.gt (local.get $y) (f32.const 191.0))
          (then (local.set $y (f32.const 191.0)) (local.set $vy (f32.neg (local.get $vy)))))
        ;; store back
        (f32.store (local.get $addr) (local.get $x))
        (f32.store (i32.add (local.get $addr) (i32.const 4)) (local.get $y))
        (f32.store (i32.add (local.get $addr) (i32.const 8)) (local.get $vx))
        (f32.store (i32.add (local.get $addr) (i32.const 12)) (local.get $vy))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )
  )

  ;; Draw filled circle at (cx, cy) with radius 8, palette index $color
  (func $draw_bob (param $cx i32) (param $cy i32) (param $color i32)
    (local $dy i32) (local $dx i32)
    (local $px i32) (local $py i32)
    (local $r2 i32)
    (local.set $dy (i32.const -8))
    (block $ydone
      (loop $yloop
        (br_if $ydone (i32.gt_s (local.get $dy) (i32.const 8)))
        (local.set $py (i32.add (local.get $cy) (local.get $dy)))
        (if (i32.and (i32.ge_s (local.get $py) (i32.const 0)) (i32.lt_s (local.get $py) (i32.const 200)))
          (then
            (local.set $dx (i32.const -8))
            (block $xdone
              (loop $xloop
                (br_if $xdone (i32.gt_s (local.get $dx) (i32.const 8)))
                (local.set $px (i32.add (local.get $cx) (local.get $dx)))
                (if (i32.and (i32.ge_s (local.get $px) (i32.const 0)) (i32.lt_s (local.get $px) (i32.const 320)))
                  (then
                    ;; Check if inside circle: dx*dx + dy*dy <= 64 (radius 8)
                    (local.set $r2 (i32.add (i32.mul (local.get $dx) (local.get $dx))
                                             (i32.mul (local.get $dy) (local.get $dy))))
                    (if (i32.le_s (local.get $r2) (i32.const 64))
                      (then
                        (i32.store8
                          (i32.add (i32.const 0x0340)
                            (i32.add (i32.mul (local.get $py) (i32.const 320)) (local.get $px)))
                          (local.get $color))
                      )
                    )
                  )
                )
                (local.set $dx (i32.add (local.get $dx) (i32.const 1)))
                (br $xloop)
              )
            )
          )
        )
        (local.set $dy (i32.add (local.get $dy) (i32.const 1)))
        (br $yloop)
      )
    )
  )

  ;; Rotate palette: shift indices 1-255 by one position
  (func $rotate_palette
    (local $i i32)
    (local $save_r i32) (local $save_g i32) (local $save_b i32)
    (local $src i32) (local $dst i32)

    ;; Save palette entry 1
    (local.set $save_r (i32.load8_u (i32.const 0x0043)))
    (local.set $save_g (i32.load8_u (i32.const 0x0044)))
    (local.set $save_b (i32.load8_u (i32.const 0x0045)))

    ;; Shift entries 1-254 down by one: entry[i] = entry[i+1]
    (local.set $i (i32.const 1))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 255)))
        (local.set $dst (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
        (local.set $src (i32.add (local.get $dst) (i32.const 3)))
        (i32.store8 (local.get $dst) (i32.load8_u (local.get $src)))
        (i32.store8 (i32.add (local.get $dst) (i32.const 1)) (i32.load8_u (i32.add (local.get $src) (i32.const 1))))
        (i32.store8 (i32.add (local.get $dst) (i32.const 2)) (i32.load8_u (i32.add (local.get $src) (i32.const 2))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )

    ;; Put saved entry 1 into entry 255
    (i32.store8 (i32.add (i32.const 0x0040) (i32.mul (i32.const 255) (i32.const 3))) (local.get $save_r))
    (i32.store8 (i32.add (i32.const 0x0040) (i32.add (i32.mul (i32.const 255) (i32.const 3)) (i32.const 1))) (local.get $save_g))
    (i32.store8 (i32.add (i32.const 0x0040) (i32.add (i32.mul (i32.const 255) (i32.const 3)) (i32.const 2))) (local.get $save_b))
  )

  (func (export "frame")
    (local $i i32) (local $addr i32)
    (local $bx i32) (local $by i32)
    (local $color_offset i32)

    ;; Update bob positions
    (call $update_bobs)

    ;; Get current color offset (which palette index to draw bobs with)
    (local.set $color_offset (i32.load (i32.const 0x103E0)))

    ;; Draw each bob as a filled circle
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 10)))
        (local.set $addr (i32.add (i32.const 0x10340) (i32.mul (local.get $i) (i32.const 16))))
        (local.set $bx (i32.trunc_f32_s (f32.load (local.get $addr))))
        (local.set $by (i32.trunc_f32_s (f32.load (i32.add (local.get $addr) (i32.const 4)))))
        (call $draw_bob (local.get $bx) (local.get $by) (local.get $color_offset))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )

    ;; Increment color offset, wrap 1-255 (skip 0)
    (local.set $color_offset (i32.add (local.get $color_offset) (i32.const 1)))
    (if (i32.ge_u (local.get $color_offset) (i32.const 256))
      (then (local.set $color_offset (i32.const 1))))
    (i32.store (i32.const 0x103E0) (local.get $color_offset))

    ;; Rotate palette by 1 (indices 1-255)
    (call $rotate_palette)
  )
)
