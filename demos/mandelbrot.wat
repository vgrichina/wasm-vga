(module
  (import "env" "memory" (memory 4))

  ;; Mandelbrot fractal with palette cycling + interactive zoom/pan
  ;; Fixed-point 12.20 arithmetic for precision
  ;; Palette rotation each frame creates fluid animation
  ;;
  ;; Guest memory usage (const, bottom):
  ;;   0x10340 - 0x10340+767 : saved base palette (256*3 bytes)
  ;; Guest memory usage (dynamic, top):
  ;;   0x3FF00 : palette rotation offset (u32)
  ;;   0x3FEF0 : cx - center x (i32, 12.20 fixed-point)
  ;;   0x3FEF4 : cy - center y (i32, 12.20 fixed-point)
  ;;   0x3FEF8 : half_w - half-width of view (i32, 12.20 fixed-point)
  ;;   0x3FEFC : prev_input (u32, for rising edge detection)

  ;; Control block addresses
  ;; 0x04: mouse x (u16), 0x06: mouse y (u16)
  ;; 0x08: mouse buttons (u8, bit0=left, bit1=right)
  ;; 0x10: keyboard state (u8, bit0=Up, bit1=Down, bit2=Left, bit3=Right, bit7=Shift)

  (func (export "init")
    (local $i i32)

    ;; Init palette rotation offset to 0
    (i32.store (i32.const 0x3FF00) (i32.const 0))

    ;; Init view: center (-0.75, 0.0), half-width 1.5
    ;; -0.75 * 1048576 = -786432
    ;; 1.5 * 1048576 = 1572864
    (i32.store (i32.const 0x3FEF0) (i32.const -786432))
    (i32.store (i32.const 0x3FEF4) (i32.const 0))
    (i32.store (i32.const 0x3FEF8) (i32.const 1572864))
    (i32.store (i32.const 0x3FEFC) (i32.const 0))

    ;; Set up rainbow palette
    (i32.store8 (i32.const 0x0040) (i32.const 0))
    (i32.store8 (i32.const 0x0041) (i32.const 0))
    (i32.store8 (i32.const 0x0042) (i32.const 0))

    (local.set $i (i32.const 1))
    (block $pdone
      (loop $plp
        (br_if $pdone (i32.ge_u (local.get $i) (i32.const 256)))
        (call $set_rainbow_color (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $plp)
      )
    )

    ;; Save base palette to guest area at 0x10340
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

    ;; Compute initial framebuffer
    (call $compute_mandelbrot)
  )

  ;; Set a rainbow palette color for index i (1-255)
  (func $set_rainbow_color (param $i i32)
    (local $addr i32)
    (local $t i32) (local $r i32) (local $g i32) (local $b i32)
    (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
    (local.set $t (i32.sub (local.get $i) (i32.const 1)))
    (local.set $r (call $tri_wave (local.get $t) (i32.const 0)))
    (local.set $g (call $tri_wave (local.get $t) (i32.const 85)))
    (local.set $b (call $tri_wave (local.get $t) (i32.const 170)))
    (i32.store8 (local.get $addr) (local.get $r))
    (i32.store8 (i32.add (local.get $addr) (i32.const 1)) (local.get $g))
    (i32.store8 (i32.add (local.get $addr) (i32.const 2)) (local.get $b))
  )

  ;; Triangle wave for palette generation
  (func $tri_wave (param $t i32) (param $phase i32) (result i32)
    (local $d i32)
    (local.set $d (i32.rem_u
      (i32.add (i32.sub (local.get $t) (local.get $phase)) (i32.const 255))
      (i32.const 255)))
    (if (i32.gt_u (local.get $d) (i32.const 127))
      (then (local.set $d (i32.sub (i32.const 255) (local.get $d)))))
    (local.set $d (i32.mul (local.get $d) (i32.const 2)))
    (if (i32.gt_u (local.get $d) (i32.const 255))
      (then (local.set $d (i32.const 255))))
    (local.get $d)
  )

  ;; Compute Mandelbrot set into framebuffer using current cx, cy, half_w
  (func $compute_mandelbrot
    (local $px i32) (local $py i32) (local $addr i32)
    (local $cr i32) (local $ci i32)
    (local $zr i32) (local $zi i32)
    (local $zr2 i32) (local $zi2 i32)
    (local $tr i32)
    (local $iter i32)
    (local $max_iter i32)
    (local $cx i32) (local $cy i32) (local $half_w i32)
    (local $x_min i32) (local $y_min i32)
    (local $step_x i32) (local $step_y i32)
    (local $half_h i32)

    (local.set $max_iter (i32.const 96))

    ;; Load view parameters
    (local.set $cx (i32.load (i32.const 0x3FEF0)))
    (local.set $cy (i32.load (i32.const 0x3FEF4)))
    (local.set $half_w (i32.load (i32.const 0x3FEF8)))

    ;; half_h = half_w * 200 / 320 = half_w * 5 / 8
    (local.set $half_h (i32.div_s (i32.mul (local.get $half_w) (i32.const 5)) (i32.const 8)))

    ;; x_min = cx - half_w, y_min = cy - half_h
    (local.set $x_min (i32.sub (local.get $cx) (local.get $half_w)))
    (local.set $y_min (i32.sub (local.get $cy) (local.get $half_h)))

    ;; step_x = (2 * half_w) / 320, step_y = (2 * half_h) / 200
    ;; Both should be equal for square pixels: 2*half_w/320 = 2*(half_w*5/8)/200 = half_w*10/(8*200) = half_w/160
    ;; step_x = half_w * 2 / 320 = half_w / 160
    ;; step_y = half_h * 2 / 200 = half_h / 100 = (half_w*5/8) / 100 = half_w / 160
    (local.set $step_x (i32.div_s (local.get $half_w) (i32.const 160)))
    (local.set $step_y (i32.div_s (local.get $half_h) (i32.const 100)))

    ;; Clamp step to minimum 1 to avoid infinite zoom freeze
    (if (i32.lt_s (local.get $step_x) (i32.const 1))
      (then (local.set $step_x (i32.const 1))))
    (if (i32.lt_s (local.get $step_y) (i32.const 1))
      (then (local.set $step_y (i32.const 1))))

    (local.set $py (i32.const 0))
    (block $ydone
      (loop $yloop
        (br_if $ydone (i32.ge_u (local.get $py) (i32.const 200)))

        (local.set $px (i32.const 0))
        (block $xdone
          (loop $xloop
            (br_if $xdone (i32.ge_u (local.get $px) (i32.const 320)))

            ;; cr = x_min + px * step_x
            (local.set $cr (i32.add (local.get $x_min)
              (i32.mul (local.get $px) (local.get $step_x))))
            ;; ci = y_min + py * step_y
            (local.set $ci (i32.add (local.get $y_min)
              (i32.mul (local.get $py) (local.get $step_y))))

            (local.set $zr (i32.const 0))
            (local.set $zi (i32.const 0))
            (local.set $iter (i32.const 0))

            (block $escape
              (loop $iter_loop
                (local.set $zr2 (i32.wrap_i64 (i64.shr_s
                  (i64.mul (i64.extend_i32_s (local.get $zr)) (i64.extend_i32_s (local.get $zr)))
                  (i64.const 20))))
                (local.set $zi2 (i32.wrap_i64 (i64.shr_s
                  (i64.mul (i64.extend_i32_s (local.get $zi)) (i64.extend_i32_s (local.get $zi)))
                  (i64.const 20))))

                (br_if $escape (i32.gt_s (i32.add (local.get $zr2) (local.get $zi2)) (i32.const 4194304)))
                (br_if $escape (i32.ge_u (local.get $iter) (local.get $max_iter)))

                (local.set $tr (i32.add (i32.sub (local.get $zr2) (local.get $zi2)) (local.get $cr)))
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

            ;; Write pixel
            (local.set $addr (i32.add (i32.const 0x0340)
              (i32.add (i32.mul (local.get $py) (i32.const 320)) (local.get $px))))

            (if (i32.ge_u (local.get $iter) (local.get $max_iter))
              (then
                (i32.store8 (local.get $addr) (i32.const 0))
              )
              (else
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

  (func (export "frame")
    (local $offset i32) (local $i i32)
    (local $src_idx i32) (local $src_addr i32) (local $dst_addr i32)
    (local $input i32) (local $prev_input i32) (local $rising i32)
    (local $dirty i32)
    (local $cx i32) (local $cy i32) (local $half_w i32)
    (local $pan_step i32)
    (local $mx i32) (local $my i32)
    (local $click_cx i32) (local $click_cy i32)

    ;; --- Input handling ---
    (local.set $dirty (i32.const 0))

    ;; Read keyboard state and mouse buttons into a combined input word
    ;; Bits 0-7: keyboard (0x10), bits 8-9: mouse buttons from 0x08
    (local.set $input (i32.or
      (i32.load8_u (i32.const 0x10))
      (i32.shl (i32.load8_u (i32.const 0x08)) (i32.const 8))))

    (local.set $prev_input (i32.load (i32.const 0x3FEFC)))
    (i32.store (i32.const 0x3FEFC) (local.get $input))

    ;; Rising edge = newly pressed bits
    (local.set $rising (i32.and (local.get $input)
      (i32.xor (local.get $prev_input) (i32.const 0xFFFFFFFF))))

    ;; Load current view
    (local.set $cx (i32.load (i32.const 0x3FEF0)))
    (local.set $cy (i32.load (i32.const 0x3FEF4)))
    (local.set $half_w (i32.load (i32.const 0x3FEF8)))

    ;; Pan step = half_w / 8 (1/16th of view width per frame held)
    (local.set $pan_step (i32.div_s (local.get $half_w) (i32.const 8)))
    (if (i32.lt_s (local.get $pan_step) (i32.const 1))
      (then (local.set $pan_step (i32.const 1))))

    ;; Arrow keys: pan (continuous while held)
    ;; bit0=Up => cy -= pan_step
    (if (i32.and (local.get $input) (i32.const 1))
      (then
        (local.set $cy (i32.sub (local.get $cy) (local.get $pan_step)))
        (local.set $dirty (i32.const 1))))
    ;; bit1=Down => cy += pan_step
    (if (i32.and (local.get $input) (i32.const 2))
      (then
        (local.set $cy (i32.add (local.get $cy) (local.get $pan_step)))
        (local.set $dirty (i32.const 1))))
    ;; bit2=Left => cx -= pan_step
    (if (i32.and (local.get $input) (i32.const 4))
      (then
        (local.set $cx (i32.sub (local.get $cx) (local.get $pan_step)))
        (local.set $dirty (i32.const 1))))
    ;; bit3=Right => cx += pan_step
    (if (i32.and (local.get $input) (i32.const 8))
      (then
        (local.set $cx (i32.add (local.get $cx) (local.get $pan_step)))
        (local.set $dirty (i32.const 1))))

    ;; Left-click rising edge (bit8) => zoom in 2x, recenter on click point
    (if (i32.and (local.get $rising) (i32.const 0x100))
      (then
        ;; Read mouse position
        (local.set $mx (i32.load16_u (i32.const 0x04)))
        (local.set $my (i32.load16_u (i32.const 0x06)))

        ;; Convert mouse pixel to complex coordinate
        ;; click_cx = cx - half_w + mx * (2 * half_w) / 320
        ;; = cx - half_w + mx * half_w / 160
        (local.set $click_cx (i32.add
          (i32.sub (local.get $cx) (local.get $half_w))
          (i32.div_s (i32.mul (local.get $mx) (local.get $half_w)) (i32.const 160))))

        ;; click_cy = cy - half_h + my * (2 * half_h) / 200
        ;; half_h = half_w * 5 / 8, so 2*half_h/200 = half_w*5/(8*100) = half_w/160
        ;; click_cy = cy - half_w*5/8 + my * half_w / 160
        (local.set $click_cy (i32.add
          (i32.sub (local.get $cy) (i32.div_s (i32.mul (local.get $half_w) (i32.const 5)) (i32.const 8)))
          (i32.div_s (i32.mul (local.get $my) (local.get $half_w)) (i32.const 160))))

        ;; Recenter on click and zoom in 2x (half_w /= 2)
        (local.set $cx (local.get $click_cx))
        (local.set $cy (local.get $click_cy))
        (local.set $half_w (i32.div_s (local.get $half_w) (i32.const 2)))

        ;; Clamp minimum zoom
        (if (i32.lt_s (local.get $half_w) (i32.const 64))
          (then (local.set $half_w (i32.const 64))))

        (local.set $dirty (i32.const 1))
      )
    )

    ;; Right-click (bit9 rising) or Shift (bit7 rising) => zoom out 2x
    (if (i32.or
          (i32.and (local.get $rising) (i32.const 0x200))
          (i32.and (local.get $rising) (i32.const 0x80)))
      (then
        ;; For right-click, also recenter on click point
        (if (i32.and (local.get $rising) (i32.const 0x200))
          (then
            (local.set $mx (i32.load16_u (i32.const 0x04)))
            (local.set $my (i32.load16_u (i32.const 0x06)))
            (local.set $cx (i32.add
              (i32.sub (local.get $cx) (local.get $half_w))
              (i32.div_s (i32.mul (local.get $mx) (local.get $half_w)) (i32.const 160))))
            (local.set $cy (i32.add
              (i32.sub (local.get $cy) (i32.div_s (i32.mul (local.get $half_w) (i32.const 5)) (i32.const 8)))
              (i32.div_s (i32.mul (local.get $my) (local.get $half_w)) (i32.const 160))))
          )
        )

        ;; Zoom out: half_w *= 2
        (local.set $half_w (i32.mul (local.get $half_w) (i32.const 2)))

        ;; Clamp maximum zoom out (half_w <= 4.0 in fixed = 4194304)
        (if (i32.gt_s (local.get $half_w) (i32.const 4194304))
          (then (local.set $half_w (i32.const 4194304))))

        (local.set $dirty (i32.const 1))
      )
    )

    ;; If anything changed, store and recompute
    (if (local.get $dirty)
      (then
        (i32.store (i32.const 0x3FEF0) (local.get $cx))
        (i32.store (i32.const 0x3FEF4) (local.get $cy))
        (i32.store (i32.const 0x3FEF8) (local.get $half_w))
        (call $compute_mandelbrot)
      )
    )

    ;; --- Palette cycling (always runs) ---
    (local.set $offset (i32.add (i32.load (i32.const 0x3FF00)) (i32.const 1)))
    (i32.store (i32.const 0x3FF00) (local.get $offset))

    (local.set $i (i32.const 1))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 256)))

        (local.set $src_idx (i32.add
          (i32.rem_u
            (i32.add (i32.sub (local.get $i) (i32.const 1)) (local.get $offset))
            (i32.const 255))
          (i32.const 1)))

        (local.set $src_addr (i32.add (i32.const 0x10340)
          (i32.mul (local.get $src_idx) (i32.const 3))))
        (local.set $dst_addr (i32.add (i32.const 0x0040)
          (i32.mul (local.get $i) (i32.const 3))))

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
