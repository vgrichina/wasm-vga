(module
  (import "env" "memory" (memory 4))

  ;; Interference / moiré pattern with palette cycling
  ;; Third wave source follows mouse cursor for real-time interactivity.
  ;; Framebuffer recomputed every frame.

  (func $isqrt (param $n i32) (result i32)
    ;; Integer square root via Newton's method
    (local $x i32) (local $x1 i32)
    (if (i32.eqz (local.get $n)) (then (return (i32.const 0))))
    (local.set $x (local.get $n))
    (local.set $x1 (i32.shr_u (i32.add (local.get $x) (i32.const 1)) (i32.const 1)))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $x1) (local.get $x)))
        (local.set $x (local.get $x1))
        (local.set $x1 (i32.shr_u (i32.add (local.get $x1)
          (i32.div_u (local.get $n) (local.get $x1))) (i32.const 1)))
        (br $lp)
      )
    )
    (local.get $x)
  )

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

  (func $compute_framebuffer (param $mx i32) (param $my i32)
    (local $x i32) (local $y i32) (local $addr i32)
    (local $dx1 i32) (local $dy1 i32) (local $dx2 i32) (local $dy2 i32) (local $dx3 i32) (local $dy3 i32)
    (local $d1 i32) (local $d2 i32) (local $d3 i32) (local $val i32)

    ;; Source 1: (80, 60)   Source 2: (240, 140)   Source 3: (mx, my)
    (local.set $y (i32.const 0))
    (block $ydone
      (loop $yloop
        (br_if $ydone (i32.ge_u (local.get $y) (i32.const 200)))
        (local.set $x (i32.const 0))
        (block $xdone
          (loop $xloop
            (br_if $xdone (i32.ge_u (local.get $x) (i32.const 320)))

            ;; Distance to source 1 (80, 60)
            (local.set $dx1 (i32.sub (local.get $x) (i32.const 80)))
            (local.set $dy1 (i32.sub (local.get $y) (i32.const 60)))
            (local.set $d1 (call $isqrt (i32.add
              (i32.mul (local.get $dx1) (local.get $dx1))
              (i32.mul (local.get $dy1) (local.get $dy1)))))

            ;; Distance to source 2 (240, 140)
            (local.set $dx2 (i32.sub (local.get $x) (i32.const 240)))
            (local.set $dy2 (i32.sub (local.get $y) (i32.const 140)))
            (local.set $d2 (call $isqrt (i32.add
              (i32.mul (local.get $dx2) (local.get $dx2))
              (i32.mul (local.get $dy2) (local.get $dy2)))))

            ;; Distance to source 3 (mouse position)
            (local.set $dx3 (i32.sub (local.get $x) (local.get $mx)))
            (local.set $dy3 (i32.sub (local.get $y) (local.get $my)))
            (local.set $d3 (call $isqrt (i32.add
              (i32.mul (local.get $dx3) (local.get $dx3))
              (i32.mul (local.get $dy3) (local.get $dy3)))))

            ;; Combine: scale distances for ring density, then mask to 0-255
            (local.set $val (i32.and
              (i32.add (i32.add
                (i32.mul (local.get $d1) (i32.const 3))
                (i32.mul (local.get $d2) (i32.const 3)))
                (i32.mul (local.get $d3) (i32.const 3)))
              (i32.const 255)))

            (local.set $addr (i32.add (i32.const 0x0340)
              (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x))))
            (i32.store8 (local.get $addr) (local.get $val))

            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $xloop)
          )
        )
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $yloop)
      )
    )
  )

  (func (export "init")
    (local $i i32)
    (local $f f64) (local $v f64) (local $r i32) (local $g i32) (local $b i32) (local $paddr i32)

    ;; === Set up palette: smooth multi-hue rainbow with extra saturation ===
    (local.set $i (i32.const 0))
    (block $pdone
      (loop $plp
        (br_if $pdone (i32.ge_u (local.get $i) (i32.const 256)))
        (local.set $paddr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
        (local.set $f (f64.div (f64.convert_i32_u (local.get $i)) (f64.const 256.0)))

        ;; R = sin(f * 2pi) * 127 + 128
        (local.set $v (f64.add (f64.mul (call $sin_approx
          (f64.mul (local.get $f) (f64.const 6.2832))) (f64.const 127.0)) (f64.const 128.0)))
        (local.set $r (i32.trunc_f64_s (local.get $v)))
        (if (i32.lt_s (local.get $r) (i32.const 0)) (then (local.set $r (i32.const 0))))
        (if (i32.gt_s (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))

        ;; G = sin(f * 2pi + 2.094) * 127 + 128
        (local.set $v (f64.add (f64.mul (call $sin_approx
          (f64.add (f64.mul (local.get $f) (f64.const 6.2832)) (f64.const 2.094))) (f64.const 127.0)) (f64.const 128.0)))
        (local.set $g (i32.trunc_f64_s (local.get $v)))
        (if (i32.lt_s (local.get $g) (i32.const 0)) (then (local.set $g (i32.const 0))))
        (if (i32.gt_s (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))

        ;; B = sin(f * 2pi + 4.189) * 127 + 128
        (local.set $v (f64.add (f64.mul (call $sin_approx
          (f64.add (f64.mul (local.get $f) (f64.const 6.2832)) (f64.const 4.189))) (f64.const 127.0)) (f64.const 128.0)))
        (local.set $b (i32.trunc_f64_s (local.get $v)))
        (if (i32.lt_s (local.get $b) (i32.const 0)) (then (local.set $b (i32.const 0))))
        (if (i32.gt_s (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))

        (i32.store8 (local.get $paddr) (local.get $r))
        (i32.store8 (i32.add (local.get $paddr) (i32.const 1)) (local.get $g))
        (i32.store8 (i32.add (local.get $paddr) (i32.const 2)) (local.get $b))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $plp)
      )
    )

    ;; Initial framebuffer with default third source at (160, 30)
    (call $compute_framebuffer (i32.const 160) (i32.const 30))
  )

  (func (export "frame")
    (local $i i32) (local $r i32) (local $g i32) (local $b i32)
    (local $src i32)

    ;; Recompute framebuffer with third source at mouse position
    (call $compute_framebuffer
      (i32.load16_u (i32.const 0x04))   ;; mouse x
      (i32.load16_u (i32.const 0x06)))  ;; mouse y

    ;; === Palette cycling: rotate all 256 entries by 1 ===

    ;; Save color 0 (first entry) to temp
    (local.set $r (i32.load8_u (i32.const 0x0040)))
    (local.set $g (i32.load8_u (i32.const 0x0041)))
    (local.set $b (i32.load8_u (i32.const 0x0042)))

    ;; Shift palette entries: color[i] = color[i+1] for i=0..254
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 255)))
        (local.set $src (i32.add (i32.const 0x0043) (i32.mul (local.get $i) (i32.const 3))))
        (i32.store8 (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3)))
          (i32.load8_u (local.get $src)))
        (i32.store8 (i32.add (i32.const 0x0041) (i32.mul (local.get $i) (i32.const 3)))
          (i32.load8_u (i32.add (local.get $src) (i32.const 1))))
        (i32.store8 (i32.add (i32.const 0x0042) (i32.mul (local.get $i) (i32.const 3)))
          (i32.load8_u (i32.add (local.get $src) (i32.const 2))))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )

    ;; Wrap: color[255] = saved color 0
    (i32.store8 (i32.add (i32.const 0x0040) (i32.const 765)) (local.get $r))
    (i32.store8 (i32.add (i32.const 0x0040) (i32.const 766)) (local.get $g))
    (i32.store8 (i32.add (i32.const 0x0040) (i32.const 767)) (local.get $b))
  )
)
