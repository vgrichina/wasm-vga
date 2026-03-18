(module
  (import "env" "memory" (memory 4))

  ;; Set up a rainbow palette and fill screen with horizontal gradient
  (func (export "init")
    (local $i i32)
    ;; Write a rainbow palette: hue sweep across 256 entries
    ;; Palette at 0x0040, each entry 3 bytes (R,G,B)
    (local.set $i (i32.const 0))
    (block $break
      (loop $pal
        (br_if $break (i32.ge_u (local.get $i) (i32.const 256)))
        ;; Simple rainbow: R = sin-ish, G = sin-ish shifted, B = sin-ish shifted more
        ;; Use piecewise linear for simplicity
        (call $set_palette_entry (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $pal)
      )
    )
  )

  (func $set_palette_entry (param $i i32)
    (local $addr i32)
    (local $r i32) (local $g i32) (local $b i32)
    (local $phase i32)
    (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
    (local.set $phase (local.get $i))
    ;; R: ramp up 0-85, hold 85-170, ramp down 170-255
    (if (i32.lt_u (local.get $phase) (i32.const 85))
      (then (local.set $r (i32.mul (local.get $phase) (i32.const 3))))
      (else (if (i32.lt_u (local.get $phase) (i32.const 170))
        (then (local.set $r (i32.const 255)))
        (else (local.set $r (i32.mul (i32.sub (i32.const 255) (local.get $phase)) (i32.const 3))))
      ))
    )
    ;; G: shifted by 85
    (local.set $phase (i32.rem_u (i32.add (local.get $i) (i32.const 85)) (i32.const 256)))
    (if (i32.lt_u (local.get $phase) (i32.const 85))
      (then (local.set $g (i32.mul (local.get $phase) (i32.const 3))))
      (else (if (i32.lt_u (local.get $phase) (i32.const 170))
        (then (local.set $g (i32.const 255)))
        (else (local.set $g (i32.mul (i32.sub (i32.const 255) (local.get $phase)) (i32.const 3))))
      ))
    )
    ;; B: shifted by 170
    (local.set $phase (i32.rem_u (i32.add (local.get $i) (i32.const 170)) (i32.const 256)))
    (if (i32.lt_u (local.get $phase) (i32.const 85))
      (then (local.set $b (i32.mul (local.get $phase) (i32.const 3))))
      (else (if (i32.lt_u (local.get $phase) (i32.const 170))
        (then (local.set $b (i32.const 255)))
        (else (local.set $b (i32.mul (i32.sub (i32.const 255) (local.get $phase)) (i32.const 3))))
      ))
    )
    ;; clamp
    (if (i32.gt_u (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))
    (if (i32.gt_u (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
    (if (i32.gt_u (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
    (i32.store8 (local.get $addr) (local.get $r))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
    (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
  )

  (func (export "frame")
    (local $x i32) (local $y i32) (local $addr i32)
    (local $tick i32)
    ;; read tick from control block offset 12
    (local.set $tick (i32.load (i32.const 12)))
    (local.set $y (i32.const 0))
    (block $ybreak
      (loop $yloop
        (br_if $ybreak (i32.ge_u (local.get $y) (i32.const 200)))
        (local.set $x (i32.const 0))
        (block $xbreak
          (loop $xloop
            (br_if $xbreak (i32.ge_u (local.get $x) (i32.const 320)))
            (local.set $addr (i32.add (i32.const 0x0340)
              (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x))))
            ;; color = (x + y + tick/16) mod 256
            (i32.store8 (local.get $addr)
              (i32.and
                (i32.add (i32.add (local.get $x) (local.get $y))
                  (i32.shr_u (local.get $tick) (i32.const 4)))
                (i32.const 255)))
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
