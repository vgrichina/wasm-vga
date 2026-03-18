(module
  (import "env" "memory" (memory 4))

  ;; 3D starfield effect
  ;; Star data at 0x10040: each star = 6 bytes (x:i16, y:i16, z:i16) * 256 stars = 1536 bytes
  ;; PRNG state at 0x10000

  (func $rand (result i32)
    (local $s i32)
    (local.set $s (i32.load (i32.const 0x10000)))
    (if (i32.eqz (local.get $s)) (then (local.set $s (i32.const 7654321))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 13))))
    (local.set $s (i32.xor (local.get $s) (i32.shr_u (local.get $s) (i32.const 17))))
    (local.set $s (i32.xor (local.get $s) (i32.shl (local.get $s) (i32.const 5))))
    (i32.store (i32.const 0x10000) (local.get $s))
    (local.get $s)
  )

  ;; random in range -range..+range
  (func $rand_range (param $range i32) (result i32)
    (local $v i32)
    (local.set $v (i32.rem_s (call $rand) (i32.mul (local.get $range) (i32.const 2))))
    (if (i32.lt_s (local.get $v) (i32.const 0))
      (then (local.set $v (i32.sub (i32.const 0) (local.get $v)))))
    (i32.sub (local.get $v) (local.get $range))
  )

  (func $init_star (param $idx i32)
    (local $addr i32)
    (local.set $addr (i32.add (i32.const 0x10040) (i32.mul (local.get $idx) (i32.const 6))))
    ;; x: -500..500
    (i32.store16 (local.get $addr) (call $rand_range (i32.const 500)))
    ;; y: -500..500
    (i32.store16 (i32.add (local.get $addr) (i32.const 2)) (call $rand_range (i32.const 500)))
    ;; z: 1..1000
    (i32.store16 (i32.add (local.get $addr) (i32.const 4))
      (i32.add (i32.rem_u (call $rand) (i32.const 999)) (i32.const 1)))
  )

  (func (export "init")
    (local $i i32)
    ;; Set palette: grayscale
    (local.set $i (i32.const 0))
    (block $pdone
      (loop $plp
        (br_if $pdone (i32.ge_u (local.get $i) (i32.const 256)))
        (i32.store8 (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))) (local.get $i))
        (i32.store8 (i32.add (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))) (i32.const 1)) (local.get $i))
        (i32.store8 (i32.add (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))) (i32.const 2)) (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $plp)
      )
    )
    ;; Init 256 stars
    (local.set $i (i32.const 0))
    (block $sdone
      (loop $slp
        (br_if $sdone (i32.ge_u (local.get $i) (i32.const 256)))
        (call $init_star (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $slp)
      )
    )
  )

  (func (export "frame")
    (local $i i32) (local $addr i32)
    (local $sx i32) (local $sy i32) (local $sz i32)
    (local $px i32) (local $py i32) (local $brightness i32)
    (local $fb_addr i32)

    ;; Clear framebuffer to black
    (local.set $i (i32.const 0))
    (block $cdone
      (loop $clp
        (br_if $cdone (i32.ge_u (local.get $i) (i32.const 64000)))
        (i32.store8 (i32.add (i32.const 0x0340) (local.get $i)) (i32.const 0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $clp)
      )
    )

    ;; Update and draw each star
    (local.set $i (i32.const 0))
    (block $sdone
      (loop $slp
        (br_if $sdone (i32.ge_u (local.get $i) (i32.const 256)))
        (local.set $addr (i32.add (i32.const 0x10040) (i32.mul (local.get $i) (i32.const 6))))
        (local.set $sx (i32.extend16_s (i32.load16_s (local.get $addr))))
        (local.set $sy (i32.extend16_s (i32.load16_s (i32.add (local.get $addr) (i32.const 2)))))
        (local.set $sz (i32.load16_u (i32.add (local.get $addr) (i32.const 4))))

        ;; Move star closer (decrease z)
        (local.set $sz (i32.sub (local.get $sz) (i32.const 3)))

        ;; Reset if too close or behind
        (if (i32.le_s (local.get $sz) (i32.const 0))
          (then
            (call $init_star (local.get $i))
            ;; force far z
            (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (i32.const 999))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $slp)
          )
        )
        ;; Save new z
        (i32.store16 (i32.add (local.get $addr) (i32.const 4)) (local.get $sz))

        ;; Project: px = sx * 160 / sz + 160, py = sy * 100 / sz + 100
        (local.set $px (i32.add (i32.div_s (i32.mul (local.get $sx) (i32.const 160)) (local.get $sz)) (i32.const 160)))
        (local.set $py (i32.add (i32.div_s (i32.mul (local.get $sy) (i32.const 100)) (local.get $sz)) (i32.const 100)))

        ;; Brightness based on distance (closer = brighter)
        (local.set $brightness (i32.sub (i32.const 255) (i32.shr_u (local.get $sz) (i32.const 2))))
        (if (i32.lt_s (local.get $brightness) (i32.const 32))
          (then (local.set $brightness (i32.const 32))))

        ;; Draw if on screen
        (if (i32.and
              (i32.and (i32.ge_s (local.get $px) (i32.const 0)) (i32.lt_s (local.get $px) (i32.const 320)))
              (i32.and (i32.ge_s (local.get $py) (i32.const 0)) (i32.lt_s (local.get $py) (i32.const 200))))
          (then
            (local.set $fb_addr (i32.add (i32.const 0x0340)
              (i32.add (i32.mul (local.get $py) (i32.const 320)) (local.get $px))))
            (i32.store8 (local.get $fb_addr) (local.get $brightness))
          )
        )

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $slp)
      )
    )
  )
)
