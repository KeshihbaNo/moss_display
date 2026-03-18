
`default_nettype none

module tt_um_moss_display (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when powered
    input  wire       clk,      // 25.175 MHz pixel clock
    input  wire       rst_n     // active-low reset
);

  // ── Sprite / ROM parameters (auto-patched by gif_compressor.py) ─────────────
  localparam IDX_BITS     = 2;     // bits per pixel index (= NUM_COLORS.bit_length())
  localparam SIZE_BITS    = 6;     // log2(TARGET_SIZE)
  localparam FRAME_BITS   = 2;     // log2(MAX_FRAMES)

  // Cropped content dimensions (patched by gif_compressor.py)
  localparam CROP_W       = 64;    // visible columns (out-of-crop entries = BG_IDX)
  localparam CROP_H       = 64;    // visible rows
  localparam ROM_ADDR_W   = FRAME_BITS + SIZE_BITS + SIZE_BITS - 1;

  // 4× pixel scaling: each ROM pixel covers a 4×4 block on screen.
  localparam DISP_W       = CROP_W * 4;
  localparam DISP_H       = CROP_H * 4;
  localparam SPRITE_X     = (640 - DISP_W) / 2;
  localparam SPRITE_Y     = (480 - DISP_H) / 2;

  // ── VGA signals ───────────────────────────────────────────────────────────────
  wire        hsync, vsync, video_active;
  wire [9:0]  pix_x, pix_y;
  reg  [1:0]  R, G, B;

  // TinyVGA PMOD pin mapping
  assign uo_out = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};

  // Audio on uio[7], rest unused outputs
  wire audio_pwm;
  assign uio_out = {audio_pwm, 7'b0};
  assign uio_oe  = 8'h80;

  // Suppress unused-signal warnings
  wire _unused = &{ena, uio_in, ui_in[7:1]};

  // ── VGA sync generator ────────────────────────────────────────────────────────
  hvsync_generator hvsync_gen (
      .clk     (clk),
      .reset   (~rst_n),
      .hsync   (hsync),
      .vsync   (vsync),
      .display_on (video_active),
      .hpos    (pix_x),
      .vpos    (pix_y)
  );

  // ── Animation frame counter ───────────────────────────────────────────────────
  reg [7:0] frame_count;    // VGA frame counter
  reg [FRAME_BITS-1:0] gif_frame;  // current animation frame index

  // ── Sprite coordinate mapping (pixel-doubled) ────────────────────────────────
  // Unsigned subtraction wraps when out of bounds; in_sprite guards the result.
  // Plain subtraction (no cast) is Verilog-2001 compatible; the localparam is sign-extended
  // to 10 bits on assignment and wrapping produces large values that fail the < DISP_SIZE check.
  wire [9:0] sprite_dx  = pix_x - SPRITE_X;
  wire [9:0] sprite_dy  = pix_y - SPRITE_Y;
  wire       in_sprite  = (sprite_dx < DISP_W) && (sprite_dy < DISP_H);

  // ROM packs 2 pixels per 3-bit word: {color_even, color_odd, bg_flag}.
  // bg_flag=1 only when BOTH pixels are BG; mixed pairs show as content
  // (BG pixel inherits neighbour's colour). Saves 1 data bit vs naive 4-bit packing.
  // col>>1 addresses the word; sprite_dx[2] selects even/odd pixel within it.
  wire [ROM_ADDR_W-1:0] gif_addr =
      {gif_frame, sprite_dy[SIZE_BITS+1:2], sprite_dx[SIZE_BITS+1:3]};

  // ── GIF pixel ROM ─────────────────────────────────────────────────────────────
  wire [2:0] packed_idx;

  gif_rom_0 rom0 (.addr(gif_addr), .data(packed_idx));

  // Decode: pix_idx = {bg_flag, color_bit}
  //   MSB (bg_flag=1) → pix_idx ≥ 2 → treated as background
  //   MSB (bg_flag=0) → pix_idx = 0 or 1 → content colour
  wire [IDX_BITS-1:0] pix_idx = {packed_idx[0],
                                  sprite_dx[2] ? packed_idx[1] : packed_idx[2]};

  // ── Palette lookup (generated module) ────────────────────────────────────────
  wire [1:0] pal_r, pal_g, pal_b;

  gif_lut_0 lut0 (.color_idx(pix_idx), .r(pal_r), .g(pal_g), .b(pal_b));

  // ── Electric circuit board background ────────────────────────────────────────
  // Black base with a 16-pixel PCB trace grid (dim teal) and animated white
  // electric pulses.  Each row/column has a staggered phase offset so the pulses
  // form diagonal travelling waves across the board.

  // Trace grid — one pixel wide, every 16 pixels in each axis
  wire on_h_trace = (pix_y[3:0] == 4'h0);
  wire on_v_trace = (pix_x[3:0] == 4'h0);
  wire on_node    = on_h_trace && on_v_trace;   // pad/via at intersection

  // Grid row and column indices (16-px cells)
  wire [5:0] row = pix_y[9:4];   // 0..29 within visible area
  wire [5:0] col = pix_x[9:4];   // 0..39 within visible area

  // Only alternate row/column pairs carry pulses (sparser, less busy)
  // Pattern per 4 rows/cols: off, on, on, off  → ~50 % active
  wire h_live = row[1] ^ row[0];
  wire v_live = col[1] ^ col[0];

  // Pulse leading-edge coordinate.  Advances 4 px per VGA frame; each row/column
  // starts at a different offset ({row,4'b0} = row×16) so waves travel diagonally.
  wire [9:0] h_pulse_x = {frame_count, 2'b0} + {row, 4'b0};
  wire [9:0] v_pulse_y = {frame_count, 2'b0} + {col, 4'b0};

  // Pixel is lit when it falls within the 4-pixel window at the pulse front.
  // Unsigned 10-bit wrap: (pix - pulse) < 4 selects [pulse, pulse+3] mod 1024.
  wire h_spark   = on_h_trace && h_live && (pix_x - h_pulse_x < 10'd4);
  wire v_spark   = on_v_trace && v_live && (pix_y - v_pulse_y < 10'd4);
  wire any_spark = h_spark || v_spark;

  // Colour hierarchy (highest priority first):
  //   spark  → white  (3,3,3)
  //   node   → bright teal  (0,3,2)
  //   trace  → dim teal  (0,1,1)
  //   base   → black  (0,0,0)
  wire [1:0] bg_r = any_spark ? 2'b11 : 2'b00;
  wire [1:0] bg_g = any_spark ? 2'b11 : on_node ? 2'b11 :
                    (on_h_trace || on_v_trace) ? 2'b01 : 2'b00;
  wire [1:0] bg_b = any_spark ? 2'b11 : on_node ? 2'b10 :
                    (on_h_trace || on_v_trace) ? 2'b01 : 2'b00;

  // ── Compositing: sprite over background ──────────────────────────────────────
  wire is_bg_pixel = pix_idx[IDX_BITS-1];  // MSB = shared bg_flag
  wire show_sprite = in_sprite && !is_bg_pixel;

  wire [1:0] out_r = show_sprite ? pal_r : bg_r;
  wire [1:0] out_g = show_sprite ? pal_g : bg_g;
  wire [1:0] out_b = show_sprite ? pal_b : bg_b;

  // ── Audio (generated module) ──────────────────────────────────────────────────
  // new_sample fires once per scanline so the audio module advances one ROM entry.
  wire new_sample = (pix_x == 10'd0);

  audio_generator audio_mod (
      .clk        (clk),
      .rst_n      (rst_n),
      .new_sample (new_sample),
      .mute       (ui_in[0]),
      .audio_pwm  (audio_pwm)
  );

  // ── Main sequential logic ─────────────────────────────────────────────────────
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      frame_count <= 8'd0;
      gif_frame   <= {FRAME_BITS{1'b0}};
      R <= 2'b0;
      G <= 2'b0;
      B <= 2'b0;
    end else begin
      // Advance frame counter and GIF animation once per VGA frame
      if (pix_x == 10'd0 && pix_y == 10'd0) begin
        frame_count <= frame_count + 8'd1;
        // Advance animation frame every 8 VGA frames (≈7 fps at 60 Hz VGA)
        if (frame_count[2:0] == 3'b111)
          gif_frame <= (gif_frame == 2'd3) ? {FRAME_BITS{1'b0}} : gif_frame + 1'd1;
      end

      // Pixel output: blank during sync periods
      R <= video_active ? out_r : 2'b0;
      G <= video_active ? out_g : 2'b0;
      B <= video_active ? out_b : 2'b0;
    end
  end

endmodule
