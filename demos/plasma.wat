(module
  (import "env" "memory" (memory 4))

  ;; Classic plasma effect using a precomputed sin table
  ;; Sin table at 0x10040 (256 bytes, values 0-255 representing sin*127+128)

  (func (export "init")
    (local $i i32)
    (local $angle f64)
    (local $val i32)

    ;; Build sin lookup table at 0x10040 (256 entries)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 256)))
        (local.set $angle (f64.mul
          (f64.div (f64.convert_i32_u (local.get $i)) (f64.const 256.0))
          (f64.const 6.283185307)))
        ;; sin(angle) * 127 + 128
        (local.set $val (i32.trunc_f64_s
          (f64.add (f64.mul (f64.nearest (f64.mul (f64.const 127.0)
            (call $sin_approx (local.get $angle)))) (f64.const 1.0)) (f64.const 128.0))))
        (if (i32.lt_s (local.get $val) (i32.const 0)) (then (local.set $val (i32.const 0))))
        (if (i32.gt_s (local.get $val) (i32.const 255)) (then (local.set $val (i32.const 255))))
        (i32.store8 (i32.add (i32.const 0x10040) (local.get $i)) (local.get $val))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )

    ;; Set up plasma palette — psychedelic cycling colors
    (local.set $i (i32.const 0))
    (block $pdone
      (loop $plp
        (br_if $pdone (i32.ge_u (local.get $i) (i32.const 256)))
        (call $set_plasma_pal (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $plp)
      )
    )
  )

  ;; sin approximation using Taylor series (good enough for table building)
  (func $sin_approx (param $x f64) (result f64)
    (local $x2 f64) (local $x3 f64) (local $x5 f64) (local $x7 f64)
    ;; normalize to -pi..pi
    ;; x = x - floor(x / (2*pi)) * 2*pi
    (local.set $x (f64.sub (local.get $x)
      (f64.mul (f64.floor (f64.div (local.get $x) (f64.const 6.283185307))) (f64.const 6.283185307))))
    (if (f64.gt (local.get $x) (f64.const 3.141592653))
      (then (local.set $x (f64.sub (local.get $x) (f64.const 6.283185307)))))
    (local.set $x2 (f64.mul (local.get $x) (local.get $x)))
    (local.set $x3 (f64.mul (local.get $x2) (local.get $x)))
    (local.set $x5 (f64.mul (local.get $x3) (local.get $x2)))
    (local.set $x7 (f64.mul (local.get $x5) (local.get $x2)))
    ;; x - x^3/6 + x^5/120 - x^7/5040
    (f64.add (f64.sub (f64.add (local.get $x)
      (f64.div (local.get $x5) (f64.const 120.0)))
      (f64.div (local.get $x3) (f64.const 6.0)))
      (f64.neg (f64.div (local.get $x7) (f64.const 5040.0))))
  )

  (func $set_plasma_pal (param $i i32)
    (local $addr i32) (local $r i32) (local $g i32) (local $b i32)
    (local $f f64) (local $v f64)
    (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
    (local.set $f (f64.div (f64.convert_i32_u (local.get $i)) (f64.const 256.0)))
    ;; R = sin(f * 2pi) * 127 + 128
    (local.set $v (f64.add (f64.mul (call $sin_approx (f64.mul (local.get $f) (f64.const 6.2832))) (f64.const 127.0)) (f64.const 128.0)))
    (local.set $r (i32.trunc_f64_s (local.get $v)))
    ;; G = sin(f * 2pi + 2.094) * 127 + 128
    (local.set $v (f64.add (f64.mul (call $sin_approx (f64.add (f64.mul (local.get $f) (f64.const 6.2832)) (f64.const 2.094))) (f64.const 127.0)) (f64.const 128.0)))
    (local.set $g (i32.trunc_f64_s (local.get $v)))
    ;; B = sin(f * 2pi + 4.189) * 127 + 128
    (local.set $v (f64.add (f64.mul (call $sin_approx (f64.add (f64.mul (local.get $f) (f64.const 6.2832)) (f64.const 4.189))) (f64.const 127.0)) (f64.const 128.0)))
    (local.set $b (i32.trunc_f64_s (local.get $v)))
    (if (i32.lt_s (local.get $r) (i32.const 0)) (then (local.set $r (i32.const 0))))
    (if (i32.gt_s (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))
    (if (i32.lt_s (local.get $g) (i32.const 0)) (then (local.set $g (i32.const 0))))
    (if (i32.gt_s (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
    (if (i32.lt_s (local.get $b) (i32.const 0)) (then (local.set $b (i32.const 0))))
    (if (i32.gt_s (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
    (i32.store8 (local.get $addr) (local.get $r))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
    (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
  )

  ;; sin table lookup: index 0-255, returns 0-255
  (func $sin_tab (param $idx i32) (result i32)
    (i32.load8_u (i32.add (i32.const 0x10040) (i32.and (local.get $idx) (i32.const 255))))
  )

  (func (export "frame")
    (local $x i32) (local $y i32) (local $addr i32) (local $tick i32)
    (local $v1 i32) (local $v2 i32) (local $v3 i32) (local $v4 i32) (local $color i32)
    (local $mx i32) (local $my i32)
    (local.set $tick (i32.shr_u (i32.load (i32.const 12)) (i32.const 4)))
    ;; Read mouse position from control block
    (local.set $mx (i32.load16_u (i32.const 0x04)))
    (local.set $my (i32.load16_u (i32.const 0x06)))
    (local.set $y (i32.const 0))
    (block $ydone
      (loop $yloop
        (br_if $ydone (i32.ge_u (local.get $y) (i32.const 200)))
        (local.set $x (i32.const 0))
        (block $xdone
          (loop $xloop
            (br_if $xdone (i32.ge_u (local.get $x) (i32.const 320)))
            ;; plasma = sum of several sin lookups, mouse shifts offsets
            (local.set $v1 (call $sin_tab (i32.add (i32.add (local.get $x) (local.get $tick))
              (i32.shr_u (local.get $mx) (i32.const 2)))))
            (local.set $v2 (call $sin_tab (i32.add (i32.add (local.get $y) (i32.shl (local.get $tick) (i32.const 1)))
              (i32.shr_u (local.get $my) (i32.const 2)))))
            (local.set $v3 (call $sin_tab (i32.add (i32.add (local.get $x) (local.get $y))
              (i32.add (local.get $tick) (i32.shr_u (i32.add (local.get $mx) (local.get $my)) (i32.const 3))))))
            (local.set $v4 (call $sin_tab (i32.add
              (i32.add (i32.mul (local.get $x) (i32.const 2)) (i32.mul (local.get $y) (i32.const 3)))
              (i32.add (i32.mul (local.get $tick) (i32.const 3))
                (i32.shr_u (i32.mul (local.get $mx) (local.get $my)) (i32.const 8))))))
            (local.set $color (i32.and
              (i32.shr_u (i32.add (i32.add (local.get $v1) (local.get $v2))
                (i32.add (local.get $v3) (local.get $v4))) (i32.const 2))
              (i32.const 255)))
            (local.set $addr (i32.add (i32.const 0x0340)
              (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x))))
            (i32.store8 (local.get $addr) (local.get $color))
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $xloop)
          )
        )
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $yloop)
      )
    )
  )
)
