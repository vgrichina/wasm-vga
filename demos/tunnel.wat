(module
  (import "env" "memory" (memory 4))

  ;; Tunnel effect with precalculated angle + distance tables
  ;; Memory layout:
  ;;   0x10040 - angle table (64000 bytes, one per pixel)
  ;;   0x20040 - distance table (64000 bytes, one per pixel)
  ;; Needs: memory pages >= 4 (256KB)

  (func $sqrt_approx (param $v f64) (result f64)
    ;; Newton's method, 6 iterations
    (local $g f64)
    (if (f64.le (local.get $v) (f64.const 0.0)) (then (return (f64.const 0.0))))
    (local.set $g (f64.mul (local.get $v) (f64.const 0.5)))
    (local.set $g (f64.mul (f64.const 0.5) (f64.add (local.get $g) (f64.div (local.get $v) (local.get $g)))))
    (local.set $g (f64.mul (f64.const 0.5) (f64.add (local.get $g) (f64.div (local.get $v) (local.get $g)))))
    (local.set $g (f64.mul (f64.const 0.5) (f64.add (local.get $g) (f64.div (local.get $v) (local.get $g)))))
    (local.set $g (f64.mul (f64.const 0.5) (f64.add (local.get $g) (f64.div (local.get $v) (local.get $g)))))
    (local.set $g (f64.mul (f64.const 0.5) (f64.add (local.get $g) (f64.div (local.get $v) (local.get $g)))))
    (local.get $g)
  )

  (func $atan2_approx (param $y f64) (param $x f64) (result f64)
    ;; Returns 0..255 (mapped from -pi..pi)
    (local $angle f64) (local $abs_x f64) (local $abs_y f64) (local $min_v f64) (local $max_v f64) (local $a f64)
    (local.set $abs_x (f64.abs (local.get $x)))
    (local.set $abs_y (f64.abs (local.get $y)))
    (if (f64.gt (local.get $abs_x) (local.get $abs_y))
      (then
        (local.set $min_v (local.get $abs_y))
        (local.set $max_v (local.get $abs_x))
      )
      (else
        (local.set $min_v (local.get $abs_x))
        (local.set $max_v (local.get $abs_y))
      )
    )
    (if (f64.eq (local.get $max_v) (f64.const 0.0))
      (then (return (f64.const 0.0)))
    )
    (local.set $a (f64.div (local.get $min_v) (local.get $max_v)))
    ;; approximate atan(a) ≈ a * (0.9998 - 0.3316 * a * a)  (for 0..1)
    (local.set $angle (f64.mul (local.get $a)
      (f64.sub (f64.const 0.9998) (f64.mul (f64.const 0.3316) (f64.mul (local.get $a) (local.get $a))))))
    ;; adjust quadrant
    (if (f64.ge (local.get $abs_y) (local.get $abs_x))
      (then (local.set $angle (f64.sub (f64.const 1.5708) (local.get $angle)))))
    (if (f64.lt (local.get $x) (f64.const 0.0))
      (then (local.set $angle (f64.sub (f64.const 3.14159) (local.get $angle)))))
    (if (f64.lt (local.get $y) (f64.const 0.0))
      (then (local.set $angle (f64.neg (local.get $angle)))))
    ;; map -pi..pi to 0..255
    (f64.mul (f64.div (f64.add (local.get $angle) (f64.const 3.14159)) (f64.const 6.28318)) (f64.const 256.0))
  )

  (func (export "init")
    (local $x i32) (local $y i32) (local $idx i32)
    (local $dx f64) (local $dy f64) (local $dist f64) (local $angle f64)
    (local $d_byte i32) (local $a_byte i32)
    (local $i i32)

    ;; Build palette: blue/purple tunnel look
    (local.set $i (i32.const 0))
    (block $pdone
      (loop $plp
        (br_if $pdone (i32.ge_u (local.get $i) (i32.const 256)))
        (call $set_tunnel_pal (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $plp)
      )
    )

    ;; Precompute angle and distance tables
    (local.set $y (i32.const 0))
    (block $ydone
      (loop $yloop
        (br_if $ydone (i32.ge_u (local.get $y) (i32.const 200)))
        (local.set $x (i32.const 0))
        (block $xdone
          (loop $xloop
            (br_if $xdone (i32.ge_u (local.get $x) (i32.const 320)))
            (local.set $idx (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x)))
            (local.set $dx (f64.sub (f64.convert_i32_s (local.get $x)) (f64.const 160.0)))
            (local.set $dy (f64.sub (f64.convert_i32_s (local.get $y)) (f64.const 100.0)))
            ;; distance
            (local.set $dist (call $sqrt_approx
              (f64.add (f64.mul (local.get $dx) (local.get $dx))
                       (f64.mul (local.get $dy) (local.get $dy)))))
            ;; map distance: 5000 / dist, clamped to 0..255
            (if (f64.gt (local.get $dist) (f64.const 1.0))
              (then
                (local.set $d_byte (i32.trunc_f64_s (f64.div (f64.const 5000.0) (local.get $dist))))
                (if (i32.gt_s (local.get $d_byte) (i32.const 255))
                  (then (local.set $d_byte (i32.const 255))))
              )
              (else (local.set $d_byte (i32.const 255)))
            )
            ;; angle
            (local.set $angle (call $atan2_approx (local.get $dy) (local.get $dx)))
            (local.set $a_byte (i32.and (i32.trunc_f64_s (local.get $angle)) (i32.const 255)))

            ;; store
            (i32.store8 (i32.add (i32.const 0x10040) (local.get $idx)) (local.get $a_byte))
            (i32.store8 (i32.add (i32.const 0x20040) (local.get $idx)) (local.get $d_byte))

            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $xloop)
          )
        )
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $yloop)
      )
    )
  )

  (func $set_tunnel_pal (param $i i32)
    (local $addr i32) (local $r i32) (local $g i32) (local $b i32)
    (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
    ;; Deep blue/teal palette with highlights
    ;; R: low
    (local.set $r (i32.shr_u (local.get $i) (i32.const 2)))
    ;; G: medium, XOR pattern for texture
    (local.set $g (i32.and (i32.mul (local.get $i) (i32.const 2)) (i32.const 255)))
    ;; B: dominant
    (local.set $b (local.get $i))
    (i32.store8 (local.get $addr) (local.get $r))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
    (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
  )

  (func (export "frame")
    (local $i i32) (local $angle i32) (local $dist i32) (local $tick i32)
    (local $u i32) (local $v i32) (local $color i32)
    (local.set $tick (i32.shr_u (i32.load (i32.const 12)) (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 64000)))
        (local.set $angle (i32.load8_u (i32.add (i32.const 0x10040) (local.get $i))))
        (local.set $dist  (i32.load8_u (i32.add (i32.const 0x20040) (local.get $i))))
        ;; texture coords with time offset
        (local.set $u (i32.and (i32.add (local.get $angle) (local.get $tick)) (i32.const 255)))
        (local.set $v (i32.and (i32.add (local.get $dist) (i32.mul (local.get $tick) (i32.const 2))) (i32.const 255)))
        ;; XOR texture
        (local.set $color (i32.and (i32.xor (local.get $u) (local.get $v)) (i32.const 255)))
        (i32.store8 (i32.add (i32.const 0x0340) (local.get $i)) (local.get $color))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )
  )
)
