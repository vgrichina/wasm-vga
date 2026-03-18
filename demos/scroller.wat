(module
  (import "env" "memory" (memory 4))

  ;; Demoscene scroller: sine-wave scrolling text over plasma background
  ;; Memory layout:
  ;;   0x10040 - sin table (256 bytes)
  ;;   0x10140 - font data (96 chars * 8 bytes = 768 bytes at 0x10140..0x10440)
  ;;   0x10440 - message string (128 bytes)

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
    ;; Init simple 8x8 bitmap font for A-Z, 0-9, space, and punctuation
    (call $init_font)
    ;; Store message: "HELLO WASM VGA MODE 13H DEMOSCENE   "
    (call $store_message)
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

  ;; Minimal 8x8 font — just uppercase letters + space + digits
  ;; Each char = 8 bytes (8 rows, each byte = 8 pixel columns, MSB left)
  ;; Stored at 0x10140, indexed by (char - 32) * 8
  (func $init_font
    ;; Space (32)
    (i64.store (i32.const 0x10140) (i64.const 0x0000000000000000))
    ;; ! (33)
    (i64.store (i32.const 0x10148) (i64.const 0x0018181818001800))
    ;; Chars 34-47: mostly unused, zero them
    ;; Skip to 0 (48)
    ;; 0
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 16) (i32.const 8)))
      (i64.const 0x3C66666666663C00))
    ;; 1
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 17) (i32.const 8)))
      (i64.const 0x1838181818187E00))
    ;; 2
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 18) (i32.const 8)))
      (i64.const 0x3C66060C30607E00))
    ;; 3
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 19) (i32.const 8)))
      (i64.const 0x3C66061C06663C00))
    ;; 4
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 20) (i32.const 8)))
      (i64.const 0x0C1C2C4C7E0C0C00))
    ;; 5
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 21) (i32.const 8)))
      (i64.const 0x7E607C0606663C00))
    ;; 6
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 22) (i32.const 8)))
      (i64.const 0x3C60607C66663C00))
    ;; 7
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 23) (i32.const 8)))
      (i64.const 0x7E060C1830303000))
    ;; 8
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 24) (i32.const 8)))
      (i64.const 0x3C66663C66663C00))
    ;; 9
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 25) (i32.const 8)))
      (i64.const 0x3C66663E06063C00))
    ;; A (65 - 32 = 33)
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 33) (i32.const 8)))
      (i64.const 0x183C66667E666600))
    ;; B
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 34) (i32.const 8)))
      (i64.const 0x7C66667C66667C00))
    ;; C
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 35) (i32.const 8)))
      (i64.const 0x3C66606060663C00))
    ;; D
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 36) (i32.const 8)))
      (i64.const 0x786C66666C780000))
    ;; E
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 37) (i32.const 8)))
      (i64.const 0x7E60607C60607E00))
    ;; F
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 38) (i32.const 8)))
      (i64.const 0x7E60607C60606000))
    ;; G
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 39) (i32.const 8)))
      (i64.const 0x3C66606E66663C00))
    ;; H
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 40) (i32.const 8)))
      (i64.const 0x6666667E66666600))
    ;; I
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 41) (i32.const 8)))
      (i64.const 0x3C18181818183C00))
    ;; J
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 42) (i32.const 8)))
      (i64.const 0x0606060606663C00))
    ;; K
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 43) (i32.const 8)))
      (i64.const 0x666C7870786C6600))
    ;; L
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 44) (i32.const 8)))
      (i64.const 0x6060606060607E00))
    ;; M
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 45) (i32.const 8)))
      (i64.const 0x63777F6B63636300))
    ;; N
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 46) (i32.const 8)))
      (i64.const 0x6676767E6E6E6600))
    ;; O
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 47) (i32.const 8)))
      (i64.const 0x3C66666666663C00))
    ;; P
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 48) (i32.const 8)))
      (i64.const 0x7C66667C60606000))
    ;; Q
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 49) (i32.const 8)))
      (i64.const 0x3C6666666E3C0E00))
    ;; R
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 50) (i32.const 8)))
      (i64.const 0x7C66667C6C666600))
    ;; S
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 51) (i32.const 8)))
      (i64.const 0x3C66603C06663C00))
    ;; T
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 52) (i32.const 8)))
      (i64.const 0x7E18181818181800))
    ;; U
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 53) (i32.const 8)))
      (i64.const 0x6666666666663C00))
    ;; V
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 54) (i32.const 8)))
      (i64.const 0x66666666663C1800))
    ;; W
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 55) (i32.const 8)))
      (i64.const 0x6363636B7F776300))
    ;; X
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 56) (i32.const 8)))
      (i64.const 0x66663C183C666600))
    ;; Y
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 57) (i32.const 8)))
      (i64.const 0x6666663C18181800))
    ;; Z
    (i64.store (i32.add (i32.const 0x10140) (i32.mul (i32.const 58) (i32.const 8)))
      (i64.const 0x7E060C1830607E00))
  )

  (func $store_message
    ;; "HELLO WASM VGA MODE 13H DEMOSCENE!   " (len=38)
    ;; Store ASCII bytes at 0x10440
    (i32.store8 (i32.const 0x10440) (i32.const 72))  ;; H
    (i32.store8 (i32.const 0x10441) (i32.const 69))  ;; E
    (i32.store8 (i32.const 0x10442) (i32.const 76))  ;; L
    (i32.store8 (i32.const 0x10443) (i32.const 76))  ;; L
    (i32.store8 (i32.const 0x10444) (i32.const 79))  ;; O
    (i32.store8 (i32.const 0x10445) (i32.const 32))  ;; (space)
    (i32.store8 (i32.const 0x10446) (i32.const 87))  ;; W
    (i32.store8 (i32.const 0x10447) (i32.const 65))  ;; A
    (i32.store8 (i32.const 0x10448) (i32.const 83))  ;; S
    (i32.store8 (i32.const 0x10449) (i32.const 77))  ;; M
    (i32.store8 (i32.const 0x1044A) (i32.const 32))  ;; (space)
    (i32.store8 (i32.const 0x1044B) (i32.const 86))  ;; V
    (i32.store8 (i32.const 0x1044C) (i32.const 71))  ;; G
    (i32.store8 (i32.const 0x1044D) (i32.const 65))  ;; A
    (i32.store8 (i32.const 0x1044E) (i32.const 32))  ;; (space)
    (i32.store8 (i32.const 0x1044F) (i32.const 77))  ;; M
    (i32.store8 (i32.const 0x10450) (i32.const 79))  ;; O
    (i32.store8 (i32.const 0x10451) (i32.const 68))  ;; D
    (i32.store8 (i32.const 0x10452) (i32.const 69))  ;; E
    (i32.store8 (i32.const 0x10453) (i32.const 32))  ;; (space)
    (i32.store8 (i32.const 0x10454) (i32.const 49))  ;; 1
    (i32.store8 (i32.const 0x10455) (i32.const 51))  ;; 3
    (i32.store8 (i32.const 0x10456) (i32.const 72))  ;; H
    (i32.store8 (i32.const 0x10457) (i32.const 32))  ;; (space)
    (i32.store8 (i32.const 0x10458) (i32.const 68))  ;; D
    (i32.store8 (i32.const 0x10459) (i32.const 69))  ;; E
    (i32.store8 (i32.const 0x1045A) (i32.const 77))  ;; M
    (i32.store8 (i32.const 0x1045B) (i32.const 79))  ;; O
    (i32.store8 (i32.const 0x1045C) (i32.const 83))  ;; S
    (i32.store8 (i32.const 0x1045D) (i32.const 67))  ;; C
    (i32.store8 (i32.const 0x1045E) (i32.const 69))  ;; E
    (i32.store8 (i32.const 0x1045F) (i32.const 78))  ;; N
    (i32.store8 (i32.const 0x10460) (i32.const 69))  ;; E
    (i32.store8 (i32.const 0x10461) (i32.const 33))  ;; !
    (i32.store8 (i32.const 0x10462) (i32.const 32))  ;; (space)
    (i32.store8 (i32.const 0x10463) (i32.const 32))  ;; (space)
    (i32.store8 (i32.const 0x10464) (i32.const 32))  ;; (space)
    ;; message length stored at 0x10438
    (i32.store (i32.const 0x10438) (i32.const 37))
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
      (i32.add (i32.mul (i32.sub (local.get $c) (i32.const 32)) (i32.const 8)) (local.get $r))))
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
    (local.set $msg_len (i32.load (i32.const 0x10438)))
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
)
