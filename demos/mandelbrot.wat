(module
  (import "env" "memory" (memory 4))

  ;; Mandelbrot fractal with palette cycling
  ;; Fixed-point 12.20 arithmetic for precision
  ;; Palette rotation each frame creates fluid animation
  ;;
  ;; Guest memory usage:
  ;;   0x10340 - 0x10340+767 : saved base palette (256*3 bytes)
  ;;   0x3FF00 : palette rotation offset (u32)

  ;; Fixed-point constants (12.20 format: multiply real by 1048576)
  ;; Center: (-0.75, 0.0), width ~3.0 in real axis
  ;; x range: -2.25 to 0.75, y range: -0.9375 to 0.9375
  ;; step_x = 3.0/320 = 0.009375 => 9830 in 20-bit fixed
  ;; step_y = 1.875/200 = 0.009375 => 9830 in 20-bit fixed
  ;; x_min = -2.25 => -2359296    y_min = -0.9375 => -983040

  (func (export "init")
    (local $px i32) (local $py i32) (local $addr i32)
    (local $cr i32) (local $ci i32)
    (local $zr i32) (local $zi i32)
    (local $zr2 i32) (local $zi2 i32)
    (local $tr i32)
    (local $iter i32)
    (local $i i32)
    (local $max_iter i32)

    ;; Init palette rotation offset to 0
    (i32.store (i32.const 0x3FF00) (i32.const 0))

    ;; Set up rainbow palette: index 0 = black (inside set), 1-255 = smooth rainbow
    ;; Palette at 0x0040, 256 entries * 3 bytes
    ;; Index 0: black
    (i32.store8 (i32.const 0x0040) (i32.const 0))
    (i32.store8 (i32.const 0x0041) (i32.const 0))
    (i32.store8 (i32.const 0x0042) (i32.const 0))

    ;; Indices 1-255: smooth HSV rainbow via sine approximation
    ;; Use integer sine table: sin(i) = 128 + 127*sin(2*pi*i/256)
    ;; We build the palette with phase-shifted sines for R, G, B
    (local.set $i (i32.const 1))
    (block $pdone
      (loop $plp
        (br_if $pdone (i32.ge_u (local.get $i) (i32.const 256)))
        (call $set_rainbow_color (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $plp)
      )
    )

    ;; Save base palette to guest area at 0x10340 (256*3=768 bytes)
    (local.set $i (i32.const 0))
    (block $sdone
      (loop $slp
        (br_if $sdone (i32.ge_u (local.get $i) (i32.const 768)))
        (i32.store8
          (i32.add (i32.const 0x10340) (local.get $i))
          (i32.load8_u (i32.add (i32.const 0x0040) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $slp)
      )
    )

    ;; Compute Mandelbrot set into framebuffer
    ;; 12.20 fixed point: 1.0 = 1048576
    ;; Center (-0.75, 0.0), zoom showing main cardioid + period-2 bulb
    ;; x: -2.25 to 0.75 (width 3.0), y: -0.9375 to 0.9375 (height 1.875)
    (local.set $max_iter (i32.const 96))

    (local.set $py (i32.const 0))
    (block $ydone
      (loop $yloop
        (br_if $ydone (i32.ge_u (local.get $py) (i32.const 200)))

        (local.set $px (i32.const 0))
        (block $xdone
          (loop $xloop
            (br_if $xdone (i32.ge_u (local.get $px) (i32.const 320)))

            ;; cr = x_min + px * step_x = -2359296 + px * 9830
            (local.set $cr (i32.add (i32.const -2359296)
              (i32.mul (local.get $px) (i32.const 9830))))
            ;; ci = y_min + py * step_y = -983040 + py * 9830
            (local.set $ci (i32.add (i32.const -983040)
              (i32.mul (local.get $py) (i32.const 9830))))

            ;; z = 0
            (local.set $zr (i32.const 0))
            (local.set $zi (i32.const 0))
            (local.set $iter (i32.const 0))

            ;; Iterate: z = z^2 + c while |z|^2 < 4.0 (4194304 in 20-bit)
            (block $escape
              (loop $iter_loop
                ;; zr2 = (zr * zr) >> 20
                (local.set $zr2 (i32.wrap_i64 (i64.shr_s
                  (i64.mul (i64.extend_i32_s (local.get $zr)) (i64.extend_i32_s (local.get $zr)))
                  (i64.const 20))))
                ;; zi2 = (zi * zi) >> 20
                (local.set $zi2 (i32.wrap_i64 (i64.shr_s
                  (i64.mul (i64.extend_i32_s (local.get $zi)) (i64.extend_i32_s (local.get $zi)))
                  (i64.const 20))))

                ;; if zr2 + zi2 > 4.0 (4194304) => escape
                (br_if $escape (i32.gt_s (i32.add (local.get $zr2) (local.get $zi2)) (i32.const 4194304)))
                ;; if iter >= max_iter => inside set
                (br_if $escape (i32.ge_u (local.get $iter) (local.get $max_iter)))

                ;; tr = zr2 - zi2 + cr
                (local.set $tr (i32.add (i32.sub (local.get $zr2) (local.get $zi2)) (local.get $cr)))
                ;; zi = 2*zr*zi/2^20 + ci = ((zr*zi) >> 19) + ci
                (local.set $zi (i32.add
                  (i32.wrap_i64 (i64.shr_s
                    (i64.mul (i64.extend_i32_s (local.get $zr)) (i64.extend_i32_s (local.get $zi)))
                    (i64.const 19)))
                  (local.get $ci)))
                (local.set $zr (local.get $tr))

                (local.set $iter (i32.add (local.get $iter) (i32.const 1)))
                (br $iter_loop)
              )
            )

            ;; Write pixel: if iter >= max_iter => 0 (black/inside), else map to 1-255
            (local.set $addr (i32.add (i32.const 0x0340)
              (i32.add (i32.mul (local.get $py) (i32.const 320)) (local.get $px))))

            (if (i32.ge_u (local.get $iter) (local.get $max_iter))
              (then
                (i32.store8 (local.get $addr) (i32.const 0))
              )
              (else
                ;; Map iteration count to palette indices 1-255
                ;; Multiply by ~2.6 to spread across range: (iter * 170) / max_iter + 1
                ;; Simpler: (iter * 255 / max_iter) but avoid 0 => use (iter*254/96)+1
                (i32.store8 (local.get $addr)
                  (i32.add
                    (i32.div_u (i32.mul (local.get $iter) (i32.const 254)) (local.get $max_iter))
                    (i32.const 1)))
              )
            )

            (local.set $px (i32.add (local.get $px) (i32.const 1)))
            (br $xloop)
          )
        )

        (local.set $py (i32.add (local.get $py) (i32.const 1)))
        (br $yloop)
      )
    )
  )

  ;; Set a rainbow palette color for index i (1-255)
  ;; Uses simple sine-wave RGB with phase offsets
  (func $set_rainbow_color (param $i i32)
    (local $addr i32)
    (local $t i32) (local $r i32) (local $g i32) (local $b i32)
    (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))

    ;; Map i (1-255) to a smooth cycle
    ;; t = (i-1) * 256 / 255 ~ i-1 for simplicity (0..254)
    (local.set $t (i32.sub (local.get $i) (i32.const 1)))

    ;; R: peaks at t=0 (red), using cosine-like shape
    ;; R = max(0, 255 - |t*6 mod 1536 - 768| * 255/256)
    ;; Simpler: use 3-phase triangle waves
    ;; Phase 0: R = ramp(t, 0)
    ;; Phase 85: G = ramp(t, 85)
    ;; Phase 170: B = ramp(t, 170)
    (local.set $r (call $tri_wave (local.get $t) (i32.const 0)))
    (local.set $g (call $tri_wave (local.get $t) (i32.const 85)))
    (local.set $b (call $tri_wave (local.get $t) (i32.const 170)))

    (i32.store8 (local.get $addr) (local.get $r))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
    (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
  )

  ;; Triangle wave for palette generation
  ;; Returns 0-255, peaking at phase offset
  ;; t: 0-254, phase: offset (0, 85, 170)
  (func $tri_wave (param $t i32) (param $phase i32) (result i32)
    (local $d i32)
    ;; d = abs((t - phase + 255) % 255 - 127)
    ;; distance from peak, wrapped
    (local.set $d (i32.rem_u
      (i32.add (i32.sub (local.get $t) (local.get $phase)) (i32.const 255))
      (i32.const 255)))
    ;; fold: if d > 127, d = 255 - d
    (if (i32.gt_u (local.get $d) (i32.const 127))
      (then (local.set $d (i32.sub (i32.const 255) (local.get $d)))))
    ;; scale to 0-255: d * 2, clamped
    (local.set $d (i32.mul (local.get $d) (i32.const 2)))
    (if (i32.gt_u (local.get $d) (i32.const 255))
      (then (local.set $d (i32.const 255))))
    (local.get $d)
  )

  (func (export "frame")
    (local $offset i32) (local $i i32)
    (local $src_idx i32) (local $src_addr i32) (local $dst_addr i32)

    ;; Increment palette rotation offset
    (local.set $offset (i32.add (i32.load (i32.const 0x3FF00)) (i32.const 1)))
    (i32.store (i32.const 0x3FF00) (local.get $offset))

    ;; Rotate palette: for indices 1-255, shift by offset
    ;; Index 0 stays black (inside the set)
    ;; Read from saved base palette at 0x10340, write to active palette at 0x0040
    (local.set $i (i32.const 1))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 256)))

        ;; Source index: ((i - 1 + offset) % 255) + 1
        (local.set $src_idx (i32.add
          (i32.rem_u
            (i32.add (i32.sub (local.get $i) (i32.const 1)) (local.get $offset))
            (i32.const 255))
          (i32.const 1)))

        (local.set $src_addr (i32.add (i32.const 0x10340)
          (i32.mul (local.get $src_idx) (i32.const 3))))
        (local.set $dst_addr (i32.add (i32.const 0x0040)
          (i32.mul (local.get $i) (i32.const 3))))

        ;; Copy 3 bytes (R, G, B)
        (i32.store8 (local.get $dst_addr)
          (i32.load8_u (local.get $src_addr)))
        (i32.store8 (i32.add (local.get $dst_addr) (i32.const 1))
          (i32.load8_u (i32.add (local.get $src_addr) (i32.const 1))))
        (i32.store8 (i32.add (local.get $dst_addr) (i32.const 2))
          (i32.load8_u (i32.add (local.get $src_addr) (i32.const 2))))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )
  )
)
