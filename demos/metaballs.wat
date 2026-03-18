(module
  (import "env" "memory" (memory 4))

  ;; Metaballs — 5 blobs, per-pixel distance field
  ;; Blob state at 0x10040: 5 blobs * 16 bytes = 80 bytes
  ;;   each blob: x(f32), y(f32), vx(f32), vy(f32)

  (func (export "init")
    (local $i i32)
    ;; Set up hot-glow palette: black -> red -> yellow -> white
    (local.set $i (i32.const 0))
    (block $pdone
      (loop $plp
        (br_if $pdone (i32.ge_u (local.get $i) (i32.const 256)))
        (call $set_meta_pal (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $plp)
      )
    )
    ;; Init blob positions and velocities
    ;; blob 0: (80, 60) vel (1.5, 0.9)
    (f32.store (i32.const 0x10040) (f32.const 80.0))
    (f32.store (i32.const 0x10044) (f32.const 60.0))
    (f32.store (i32.const 0x10048) (f32.const 1.5))
    (f32.store (i32.const 0x1004C) (f32.const 0.9))
    ;; blob 1: (200, 120) vel (-1.2, 0.7)
    (f32.store (i32.const 0x10050) (f32.const 200.0))
    (f32.store (i32.const 0x10054) (f32.const 120.0))
    (f32.store (i32.const 0x10058) (f32.const -1.2))
    (f32.store (i32.const 0x1005C) (f32.const 0.7))
    ;; blob 2: (160, 100) vel (0.8, -1.3)
    (f32.store (i32.const 0x10060) (f32.const 160.0))
    (f32.store (i32.const 0x10064) (f32.const 100.0))
    (f32.store (i32.const 0x10068) (f32.const 0.8))
    (f32.store (i32.const 0x1006C) (f32.const -1.3))
    ;; blob 3: (100, 150) vel (1.1, 1.4)
    (f32.store (i32.const 0x10070) (f32.const 100.0))
    (f32.store (i32.const 0x10074) (f32.const 150.0))
    (f32.store (i32.const 0x10078) (f32.const 1.1))
    (f32.store (i32.const 0x1007C) (f32.const 1.4))
    ;; blob 4: (250, 40) vel (-0.9, -0.6)
    (f32.store (i32.const 0x10080) (f32.const 250.0))
    (f32.store (i32.const 0x10084) (f32.const 40.0))
    (f32.store (i32.const 0x10088) (f32.const -0.9))
    (f32.store (i32.const 0x1008C) (f32.const -0.6))
  )

  (func $set_meta_pal (param $i i32)
    (local $addr i32) (local $r i32) (local $g i32) (local $b i32)
    (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
    ;; 0-63: black to dark purple
    (if (i32.lt_u (local.get $i) (i32.const 64))
      (then
        (local.set $r (i32.shr_u (local.get $i) (i32.const 1)))
        (local.set $g (i32.const 0))
        (local.set $b (i32.mul (local.get $i) (i32.const 2)))
      )
      (else (if (i32.lt_u (local.get $i) (i32.const 128))
        (then
          ;; 64-127: purple to red
          (local.set $r (i32.add (i32.const 32) (i32.mul (i32.sub (local.get $i) (i32.const 64)) (i32.const 3))))
          (if (i32.gt_u (local.get $r) (i32.const 255)) (then (local.set $r (i32.const 255))))
          (local.set $g (i32.const 0))
          (local.set $b (i32.sub (i32.const 128) (i32.mul (i32.sub (local.get $i) (i32.const 64)) (i32.const 2))))
          (if (i32.lt_s (local.get $b) (i32.const 0)) (then (local.set $b (i32.const 0))))
        )
        (else (if (i32.lt_u (local.get $i) (i32.const 192))
          (then
            ;; 128-191: red to yellow
            (local.set $r (i32.const 255))
            (local.set $g (i32.mul (i32.sub (local.get $i) (i32.const 128)) (i32.const 4)))
            (if (i32.gt_u (local.get $g) (i32.const 255)) (then (local.set $g (i32.const 255))))
            (local.set $b (i32.const 0))
          )
          (else
            ;; 192-255: yellow to white
            (local.set $r (i32.const 255))
            (local.set $g (i32.const 255))
            (local.set $b (i32.mul (i32.sub (local.get $i) (i32.const 192)) (i32.const 4)))
            (if (i32.gt_u (local.get $b) (i32.const 255)) (then (local.set $b (i32.const 255))))
          )
        ))
      ))
    )
    (i32.store8 (local.get $addr) (local.get $r))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
    (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
  )

  ;; Update blob positions, bounce off walls
  (func $update_blobs
    (local $i i32) (local $addr i32)
    (local $x f32) (local $y f32) (local $vx f32) (local $vy f32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 5)))
        (local.set $addr (i32.add (i32.const 0x10040) (i32.mul (local.get $i) (i32.const 16))))
        (local.set $x (f32.load (local.get $addr)))
        (local.set $y (f32.load (i32.add (local.get $addr) (i32.const 4))))
        (local.set $vx (f32.load (i32.add (local.get $addr) (i32.const 8))))
        (local.set $vy (f32.load (i32.add (local.get $addr) (i32.const 12))))
        ;; move
        (local.set $x (f32.add (local.get $x) (local.get $vx)))
        (local.set $y (f32.add (local.get $y) (local.get $vy)))
        ;; bounce X
        (if (f32.lt (local.get $x) (f32.const 0.0))
          (then (local.set $x (f32.const 0.0)) (local.set $vx (f32.neg (local.get $vx)))))
        (if (f32.gt (local.get $x) (f32.const 319.0))
          (then (local.set $x (f32.const 319.0)) (local.set $vx (f32.neg (local.get $vx)))))
        ;; bounce Y
        (if (f32.lt (local.get $y) (f32.const 0.0))
          (then (local.set $y (f32.const 0.0)) (local.set $vy (f32.neg (local.get $vy)))))
        (if (f32.gt (local.get $y) (f32.const 199.0))
          (then (local.set $y (f32.const 199.0)) (local.set $vy (f32.neg (local.get $vy)))))
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

  (func (export "frame")
    (local $px i32) (local $py i32) (local $fb_idx i32)
    (local $bx f32) (local $by f32) (local $dx f32) (local $dy f32)
    (local $dist_sq f32) (local $sum f32)
    (local $b i32) (local $baddr i32)
    (local $color i32)

    (call $update_blobs)

    ;; For each pixel, compute metaball field
    (local.set $py (i32.const 0))
    (block $ydone
      (loop $yloop
        (br_if $ydone (i32.ge_u (local.get $py) (i32.const 200)))
        (local.set $px (i32.const 0))
        (block $xdone
          (loop $xloop
            (br_if $xdone (i32.ge_u (local.get $px) (i32.const 320)))
            ;; Sample every other pixel for speed, stepping by 2 on x
            (local.set $sum (f32.const 0.0))
            ;; Sum contribution from each blob: radius² / dist²
            (local.set $b (i32.const 0))
            (block $bdone
              (loop $blp
                (br_if $bdone (i32.ge_u (local.get $b) (i32.const 5)))
                (local.set $baddr (i32.add (i32.const 0x10040) (i32.mul (local.get $b) (i32.const 16))))
                (local.set $bx (f32.load (local.get $baddr)))
                (local.set $by (f32.load (i32.add (local.get $baddr) (i32.const 4))))
                (local.set $dx (f32.sub (f32.convert_i32_s (local.get $px)) (local.get $bx)))
                (local.set $dy (f32.sub (f32.convert_i32_s (local.get $py)) (local.get $by)))
                (local.set $dist_sq (f32.add (f32.mul (local.get $dx) (local.get $dx))
                                              (f32.mul (local.get $dy) (local.get $dy))))
                (if (f32.lt (local.get $dist_sq) (f32.const 1.0))
                  (then (local.set $dist_sq (f32.const 1.0))))
                ;; blob radius² = 2000
                (local.set $sum (f32.add (local.get $sum)
                  (f32.div (f32.const 2000.0) (local.get $dist_sq))))
                (local.set $b (i32.add (local.get $b) (i32.const 1)))
                (br $blp)
              )
            )
            ;; Map sum to color (0..255)
            (local.set $color (i32.trunc_f32_s (f32.mul (local.get $sum) (f32.const 40.0))))
            (if (i32.gt_s (local.get $color) (i32.const 255))
              (then (local.set $color (i32.const 255))))
            (if (i32.lt_s (local.get $color) (i32.const 0))
              (then (local.set $color (i32.const 0))))
            (local.set $fb_idx (i32.add (i32.const 0x0340)
              (i32.add (i32.mul (local.get $py) (i32.const 320)) (local.get $px))))
            (i32.store8 (local.get $fb_idx) (local.get $color))
            (local.set $px (i32.add (local.get $px) (i32.const 1)))
            (br $xloop)
          )
        )
        (local.set $py (i32.add (local.get $py) (i32.const 1)))
        (br $yloop)
      )
    )
  )
)
