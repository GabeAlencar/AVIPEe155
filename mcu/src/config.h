// config.h
// Gabe Alencar gmenendezdealencar@g.hmc.edu
// 11/19/26
//
// Pins, image size and display settings for the AVIPE display MCU.
// Every setting that may need a change during bring-up is here.

#ifndef CONFIG_H
#define CONFIG_H

// No includes, so the host preview (mcu/test) can use it too. The pin names
// (PA4, ...) come from STM32L432KC_GPIO.h in the files that use them.

// ---- FPGA link: SPI3 slave, FPGA is the master (spi_frame_tx.sv) ----
// mode 0, 16-bit words, MSB first, 3 MHz sck, cs_b low for the whole frame.
#define FPGA_SCK    PB3     // SPI3_SCK  AF6  <- FPGA P46 (J3-12); adapter J1-16
#define FPGA_MOSI   PB5     // SPI3_MOSI AF6  <- FPGA P45 (J3-13); adapter J1-15
#define FPGA_CS     PA9     // GPIO input     <- FPGA P3  (J3-14), cs_b; adapter J3-11

// ---- IT8951 e-paper controller: SPI1 master ----
#define EPD_SCK     PA5     // SPI1_SCK  AF5  -> HAT SCLK, adapter J1-17
#define EPD_MISO    PA11    // SPI1_MISO AF5  <- HAT MISO, adapter J3-6
#define EPD_MOSI    PA12    // SPI1_MOSI AF5  -> HAT MOSI, adapter J3-10
#define EPD_CS      PA8     // GPIO output    -> HAT CS, adapter J1-14
#define EPD_HRDY    PB0     // GPIO input     <- HAT HRDY (high = ready), adapter J1-11
#define EPD_RST     PB1     // GPIO output    -> HAT RST (active low), adapter J3-8

// SPI1 clock = 80 MHz / 2^(EPD_SPI_BR+1). 3 gives 5 MHz.
#define EPD_SPI_BR  3

// VCOM in mV, without the minus sign. It is printed on the display's flat
// cable (for example "VCOM = -1.53V" means 1530). Set it before the first run.
#define EPD_VCOM_MV 1500

// IT8951 waveform modes (the same numbers for every panel: 0 INIT, 1 DU, 2 GC16).
// DU is a fast black/white update. Every EPD_FULL_EVERY updates use GC16 to
// clear the ghosting that DU leaves behind.
#define EPD_MODE_INIT  0
#define EPD_MODE_DU    1
#define EPD_MODE_GC16  2
#define EPD_MODE_FAST  EPD_MODE_DU
#define EPD_FULL_EVERY 30

// 1-bpp packing. If the test screen shows text broken up in 8-pixel groups,
// flip EPD_LSB_FIRST. If it shows pairs of 8-pixel groups swapped, flip
// EPD_SWAP_BYTES.
#define EPD_LSB_FIRST  1
#define EPD_SWAP_BYTES 0

// ---- image ----
// The panel is 1448 x 1072. In 1-bpp mode the width must be a multiple of 32.
#define IMG_W       1440
#define IMG_H       1072
#define ROW_BYTES   (IMG_W / 8)
#define BAND_ROWS   16      // rows drawn and sent at a time; IMG_H must divide evenly

// ---- spectrum ----
#define FS_HZ       15669.7f    // measured sample rate (same as fft_live.py)
#define FFT_N       512
#define BINS        256
#define USE_HAMMING 0           // 1 applies the Hamming window to the bins

// Set to 1 to draw a test screen at boot and stop (display bring-up).
#define TEST_SCREEN_ONLY 0

#endif
