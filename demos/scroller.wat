(module
  (import "env" "memory" (memory 4))

  ;; Demoscene scroller: sine-wave scrolling text over plasma background
  ;; Memory layout:
  ;;   0x10040 - sin table (256 bytes)
  ;;   0x10140 - font data (96 chars × 8 bytes = 768 bytes, ends at 0x10440)
  ;;   0x10440 - message string (64 bytes)
  ;;   0x10480 - message length (u32)

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

  (func (export "init")
    (local $i i32) (local $val i32) (local $angle f64)
    ;; Build sin table
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (i32.const 256)))
        (local.set $angle (f64.mul (f64.div (f64.convert_i32_u (local.get $i)) (f64.const 256.0)) (f64.const 6.2832)))
        (local.set $val (i32.trunc_f64_s (f64.add (f64.mul (call $sin_approx (local.get $angle)) (f64.const 127.0)) (f64.const 128.0))))
        (if (i32.lt_s (local.get $val) (i32.const 0)) (then (local.set $val (i32.const 0))))
        (if (i32.gt_s (local.get $val) (i32.const 255)) (then (local.set $val (i32.const 255))))
        (i32.store8 (i32.add (i32.const 0x10040) (local.get $i)) (local.get $val))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)
      )
    )
    ;; Palette: cycling rainbow for plasma + bright white for text
    (local.set $i (i32.const 0))
    (block $pdone
      (loop $plp
        (br_if $pdone (i32.ge_u (local.get $i) (i32.const 256)))
        (call $set_scroller_pal (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $plp)
      )
    )
    ;; Font and message data initialized via data segments at module level
  )

  (func $set_scroller_pal (param $i i32)
    (local $addr i32) (local $r i32) (local $g i32) (local $b i32) (local $f f64) (local $v f64)
    (local.set $addr (i32.add (i32.const 0x0040) (i32.mul (local.get $i) (i32.const 3))))
    ;; 0-239: dark plasma palette (dimmed)
    ;; 240-255: bright text colors (white to cyan)
    (if (i32.lt_u (local.get $i) (i32.const 240))
      (then
        (local.set $f (f64.div (f64.convert_i32_u (local.get $i)) (f64.const 240.0)))
        ;; dimmed rainbow
        (local.set $v (f64.add (f64.mul (call $sin_approx (f64.mul (local.get $f) (f64.const 6.2832))) (f64.const 40.0)) (f64.const 50.0)))
        (local.set $r (i32.trunc_f64_s (local.get $v)))
        (local.set $v (f64.add (f64.mul (call $sin_approx (f64.add (f64.mul (local.get $f) (f64.const 6.2832)) (f64.const 2.094))) (f64.const 40.0)) (f64.const 50.0)))
        (local.set $g (i32.trunc_f64_s (local.get $v)))
        (local.set $v (f64.add (f64.mul (call $sin_approx (f64.add (f64.mul (local.get $f) (f64.const 6.2832)) (f64.const 4.189))) (f64.const 40.0)) (f64.const 50.0)))
        (local.set $b (i32.trunc_f64_s (local.get $v)))
      )
      (else
        ;; bright text: white to cyan gradient
        (local.set $r (i32.sub (i32.const 255) (i32.mul (i32.sub (local.get $i) (i32.const 240)) (i32.const 8))))
        (local.set $g (i32.const 255))
        (local.set $b (i32.const 255))
      )
    )
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

  ;; sin table lookup
  (func $sin_tab (param $idx i32) (result i32)
    (i32.load8_u (i32.add (i32.const 0x10040) (i32.and (local.get $idx) (i32.const 255))))
  )

  ;; Get font pixel: char c, row r (0-7), col k (0-7) — returns 0 or 1
  (func $font_pixel (param $c i32) (param $r i32) (param $k i32) (result i32)
    (local $font_addr i32) (local $row_byte i32)
    ;; char index = c - 32, font at 0x10140
    (local.set $font_addr (i32.add (i32.const 0x10140)
      (i32.add (i32.mul (i32.sub (local.get $c) (i32.const 32)) (i32.const 8)) (i32.sub (i32.const 7) (local.get $r)))))
    (local.set $row_byte (i32.load8_u (local.get $font_addr)))
    ;; bit k from MSB
    (i32.and (i32.shr_u (local.get $row_byte) (i32.sub (i32.const 7) (local.get $k))) (i32.const 1))
  )

  (func (export "frame")
    (local $x i32) (local $y i32) (local $tick i32) (local $fb_addr i32)
    (local $v1 i32) (local $v2 i32) (local $plasma_color i32)
    ;; text vars
    (local $scroll_x i32) (local $msg_len i32) (local $char_idx i32)
    (local $char_code i32) (local $char_col i32) (local $font_row i32)
    (local $text_y i32) (local $wave_offset i32) (local $draw_y i32)
    (local $text_x i32) (local $scale i32)

    (local.set $tick (i32.shr_u (i32.load (i32.const 12)) (i32.const 4)))
    (local.set $msg_len (i32.load (i32.const 0x10480)))
    (if (i32.eqz (local.get $msg_len)) (then (return)))
    ;; scroll position in pixels (each char is 10px wide with 2px gap)
    (local.set $scroll_x (i32.rem_u (local.get $tick) (i32.mul (local.get $msg_len) (i32.const 10))))

    ;; Draw plasma background
    (local.set $y (i32.const 0))
    (block $ydone
      (loop $yloop
        (br_if $ydone (i32.ge_u (local.get $y) (i32.const 200)))
        (local.set $x (i32.const 0))
        (block $xdone
          (loop $xloop
            (br_if $xdone (i32.ge_u (local.get $x) (i32.const 320)))
            (local.set $v1 (call $sin_tab (i32.add (local.get $x) (local.get $tick))))
            (local.set $v2 (call $sin_tab (i32.add (local.get $y) (i32.shl (local.get $tick) (i32.const 1)))))
            ;; map to 0..239 (plasma palette range)
            (local.set $plasma_color (i32.rem_u
              (i32.shr_u (i32.add (local.get $v1) (local.get $v2)) (i32.const 1))
              (i32.const 240)))
            (local.set $fb_addr (i32.add (i32.const 0x0340)
              (i32.add (i32.mul (local.get $y) (i32.const 320)) (local.get $x))))
            (i32.store8 (local.get $fb_addr) (local.get $plasma_color))
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $xloop)
          )
        )
        (local.set $y (i32.add (local.get $y) (i32.const 1)))
        (br $yloop)
      )
    )

    ;; Draw scrolling text with sine wave, scaled 2x
    (local.set $scale (i32.const 2))
    ;; For each screen column, figure out which message character + column
    (local.set $x (i32.const 0))
    (block $txdone
      (loop $txloop
        (br_if $txdone (i32.ge_u (local.get $x) (i32.const 320)))
        ;; virtual x position in message pixel space
        (local.set $text_x (i32.add (local.get $x) (i32.mul (local.get $scroll_x) (local.get $scale))))
        ;; which character (each char = 10 * scale pixels wide: 8*scale char + 2*scale gap)
        (local.set $char_idx (i32.rem_u
          (i32.div_u (local.get $text_x) (i32.mul (i32.const 10) (local.get $scale)))
          (local.get $msg_len)))
        (local.set $char_col (i32.div_u
          (i32.rem_u (local.get $text_x) (i32.mul (i32.const 10) (local.get $scale)))
          (local.get $scale)))
        ;; skip if in gap zone (cols 8-9)
        (if (i32.ge_u (local.get $char_col) (i32.const 8))
          (then
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br $txloop)
          )
        )
        ;; get character
        (local.set $char_code (i32.load8_u (i32.add (i32.const 0x10440) (local.get $char_idx))))
        ;; sine wave y offset
        (local.set $wave_offset (i32.sub
          (i32.shr_u (call $sin_tab (i32.add (i32.mul (local.get $x) (i32.const 2)) (i32.mul (local.get $tick) (i32.const 3)))) (i32.const 2))
          (i32.const 32)))
        ;; base text y position = 80 (center-ish)
        (local.set $text_y (i32.add (i32.const 80) (local.get $wave_offset)))
        ;; draw 8 rows of this font column, scaled
        (local.set $font_row (i32.const 0))
        (block $frdone
          (loop $frlp
            (br_if $frdone (i32.ge_u (local.get $font_row) (i32.const 8)))
            (if (call $font_pixel (local.get $char_code) (local.get $font_row) (local.get $char_col))
              (then
                ;; draw scaled pixel block
                (local.set $draw_y (i32.add (local.get $text_y) (i32.mul (local.get $font_row) (local.get $scale))))
                ;; draw scale rows
                (block $sy_check
                  (if (i32.and
                        (i32.ge_s (local.get $draw_y) (i32.const 0))
                        (i32.lt_s (i32.add (local.get $draw_y) (local.get $scale)) (i32.const 200)))
                    (then
                      ;; color 248 (bright text)
                      (i32.store8 (i32.add (i32.const 0x0340)
                        (i32.add (i32.mul (local.get $draw_y) (i32.const 320)) (local.get $x)))
                        (i32.const 248))
                      (if (i32.lt_s (i32.add (local.get $draw_y) (i32.const 1)) (i32.const 200))
                        (then
                          (i32.store8 (i32.add (i32.const 0x0340)
                            (i32.add (i32.mul (i32.add (local.get $draw_y) (i32.const 1)) (i32.const 320)) (local.get $x)))
                            (i32.const 248))
                        )
                      )
                    )
                  )
                )
              )
            )
            (local.set $font_row (i32.add (local.get $font_row) (i32.const 1)))
            (br $frlp)
          )
        )
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br $txloop)
      )
    )
  )


  ;; 8x8 bitmap font at 0x10140: 96 chars (ASCII 32-127), 8 bytes each
  (data (i32.const 0x10140) "\00\00\00\00\00\00\00\00\00\18\00\18\18\18\18\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\18\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00<fffff<\00~\18\18\18\188\18\00~`0\0c\06f<\00<f\06\1c\06f<\00\0c\0c~L,\1c\0c\00<f\06\06|`~\00<ff|``<\00000\18\0c\06~\00<ff<ff<\00<\06\06>ff<\00\00\18\00\00\18\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00ff~ff<\18\00|ff|ff|\00<f```f<\00\00xlfflx\00~``|``~\00```|``~\00<ffn`f<\00fff~fff\00<\18\18\18\18\18<\00<f\06\06\06\06\06\00flxpxlf\00~``````\00ccck\7fwc\00fnn~vvf\00<fffff<\00```|ff|\00\0e<nfff<\00ffl|ff|\00<f\06<`f<\00\18\18\18\18\18\18~\00<ffffff\00\18<fffff\00cw\7fkccc\00ff<\18<ff\00\18\18\18<fff\00~`0\18\0c\06~\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00")

  ;; Message string at 0x10440, length at 0x10480 (after font+string, no overlap)
  (data (i32.const 0x10440) "HELLO WASM VGA MODE 13H DEMOSCENE!   ")
  (data (i32.const 0x10480) "\25\00\00\00")
)
